<#
    Exec-Pod.ps1

    Exec into a VFP-wired pod created by New-VfpPod.ps1 and run commands from
    inside the Hyper-V guest VM.

    It resolves the running workload container for a given pod *name*
    (New-VfpPod.ps1 names the container after the pod) and then either:
      * opens an interactive shell in the container (default), or
      * runs one or more commands and prints their output (-Command / -Script).

    Note on images:
      * nanoserver has cmd.exe but NOT powershell.exe -> use -Shell cmd (default).
      * servercore / full images have powershell.exe  -> use -Shell powershell.

    Usage:
      .\Exec-Pod.ps1 sender                         # interactive cmd shell
      .\Exec-Pod.ps1 sender -Shell powershell       # interactive powershell
      .\Exec-Pod.ps1 sender ipconfig /all           # run any command (passthrough)
      .\Exec-Pod.ps1 sender -Command 'ipconfig /all'
      .\Exec-Pod.ps1 sender -Command 'hostname','ipconfig','ping -n 2 10.244.0.1'
      .\Exec-Pod.ps1 listener -Shell powershell -Script 'Get-NetIPAddress | ft'
      .\Exec-Pod.ps1 sender -ContainerId 1a2b3c...  # target an explicit container
#>

[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
    # Pod name (as passed to New-VfpPod.ps1). Positional.
    [Parameter(Mandatory = $true, Position = 0)]
    [Alias('Name', 'Pod')]
    [string]$PodName,

    # Shell to launch / run commands through inside the container.
    [Parameter(Mandatory = $false)]
    [ValidateSet('cmd', 'powershell')]
    [string]$Shell = 'cmd',

    # One or more commands to run non-interactively. Each is executed in its
    # own exec through the selected shell; output is streamed back.
    [Parameter(Mandatory = $true, ParameterSetName = 'Command')]
    [string[]]$Command,

    # A single script string to run non-interactively (alternative to -Command).
    [Parameter(Mandatory = $true, ParameterSetName = 'Script')]
    [string]$Script,

    # Any trailing tokens are captured and run as a single command inside the
    # pod, e.g.  .\Exec-Pod.ps1 sender ipconfig /all
    [Parameter(Mandatory = $false, Position = 1, ValueFromRemainingArguments = $true, ParameterSetName = 'Passthrough')]
    [string[]]$Exec,

    # Target an explicit container id instead of resolving by pod name.
    [Parameter(Mandatory = $false)]
    [string]$ContainerId,

    # crictl.exe path (matches Install-ContainerdHnsVfp.ps1 default).
    [Parameter(Mandatory = $false)]
    [string]$CrictlExe = 'C:\Tools\bin\crictl.exe',

    # Per-exec timeout (seconds) for non-interactive commands, so a hung exec
    # cannot block forever. 0 disables the timeout.
    [Parameter(Mandatory = $false)]
    [int]$Timeout = 30,

    # containerd CRI endpoint. Setting it silences crictl's default-endpoint
    # deprecation warnings (which otherwise surface as NativeCommandError).
    [Parameter(Mandatory = $false)]
    [string]$RuntimeEndpoint = 'npipe:////./pipe/containerd-containerd'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# crictl base args used for every invocation: pin the endpoints so the
# deprecation warnings are not emitted to stderr.
$script:CrictlBase = @('--runtime-endpoint', $RuntimeEndpoint, '--image-endpoint', $RuntimeEndpoint)

function Write-Section {
    param([string]$Text)
    Write-Host ""
    Write-Host "==== $Text ====" -ForegroundColor Cyan
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}

# ------------------------------------------------------------
#  Resolve the target container id for the pod name
# ------------------------------------------------------------
function Resolve-ContainerId {
    param([string]$Pod)

    # 1. Find the pod sandbox id by name (newest first; pick Ready if possible).
    $podIds = @(& $CrictlExe @script:CrictlBase pods --name $Pod -q 2>$null | Where-Object { $_ -and $_ -notmatch '\s' })
    if ($podIds.Count -eq 0) {
        throw "No pod found with name '$Pod'. List pods with: `"$CrictlExe`" pods"
    }

    # 2. Find a running container inside any of those sandboxes.
    foreach ($sandboxId in $podIds) {
        $ctrIds = @(& $CrictlExe @script:CrictlBase ps --pod $sandboxId --state Running -q 2>$null | Where-Object { $_ -and $_ -notmatch '\s' })
        if ($ctrIds.Count -gt 0) { return $ctrIds[0] }
    }

    # 3. Fall back to any (non-running) container in the pod, for a clearer error.
    foreach ($sandboxId in $podIds) {
        $anyIds = @(& $CrictlExe @script:CrictlBase ps --pod $sandboxId -a -q 2>$null | Where-Object { $_ -and $_ -notmatch '\s' })
        if ($anyIds.Count -gt 0) {
            throw "Pod '$Pod' has a container but it is not Running. Check: `"$CrictlExe`" ps -a --pod $sandboxId"
        }
    }

    throw "Pod '$Pod' has no workload container. Recreate it without -SandboxOnly: .\New-VfpPod.ps1 $Pod"
}

# ------------------------------------------------------------
#  Main
# ------------------------------------------------------------
if (-not (Test-IsAdmin)) {
    throw "Run this script from an *elevated* PowerShell inside the guest VM (Run as Administrator)."
}
if (-not (Test-Path $CrictlExe)) {
    throw "crictl.exe not found at '$CrictlExe'. Run Install-ContainerdHnsVfp.ps1 first."
}

if (-not $ContainerId) {
    $ContainerId = Resolve-ContainerId -Pod $PodName
}
Write-Host "Target pod='$PodName' container=$ContainerId shell=$Shell" -ForegroundColor Green

# Build the shell invocation prefix.
$shellPrefix = if ($Shell -eq 'cmd') { @('cmd', '/c') } else { @('powershell', '-NoProfile', '-Command') }

# crictl global args: endpoints + a timeout so non-interactive execs cannot hang forever.
$globalArgs = @() + $script:CrictlBase
if ($Timeout -gt 0) { $globalArgs += @('--timeout', "${Timeout}s") }

function Invoke-PodExec {
    param([string]$CommandLine)
    Write-Section "exec: $CommandLine"
    & $CrictlExe @globalArgs exec $ContainerId @shellPrefix $CommandLine
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  (command exited with code $LASTEXITCODE)" -ForegroundColor Yellow
    }
}

switch ($PSCmdlet.ParameterSetName) {
    'Command' {
        foreach ($c in $Command) { Invoke-PodExec -CommandLine $c }
    }
    'Script' {
        Invoke-PodExec -CommandLine $Script
    }
    'Passthrough' {
        Invoke-PodExec -CommandLine ($Exec -join ' ')
    }
    default {
        # Interactive shell. NOTE: crictl's interactive TTY attach to Windows
        # containers (especially Hyper-V isolated) can hang with no prompt.
        # If it hangs, press Ctrl+C and run commands non-interactively instead,
        # e.g.  .\Exec-Pod.ps1 $PodName <your command>
        Write-Section "Opening interactive $Shell (Ctrl+C to break out if it hangs)"
        Write-Host "  If this stalls with no prompt, use non-interactive mode:" -ForegroundColor Yellow
        Write-Host "    .\Exec-Pod.ps1 $PodName ipconfig /all" -ForegroundColor Yellow
        & $CrictlExe @script:CrictlBase exec -it $ContainerId $Shell
    }
}
