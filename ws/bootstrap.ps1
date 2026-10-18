<#
.SYNOPSIS
    bootstrap.ps1 -- plan 01 G.1: a Windows box with nothing -> WSL2 distro + Git/GCM -> init.sh (clone
    /workspace + ./install.sh).  PowerShell 5.1, no modules.  REAL RUN BY DEFAULT; -DryRun (or $env:WS_DRY=1) changes nothing, prints
    what it would do.

.DESCRIPTION
    Each step prints KEY=ok|WOULD <action>|FAIL <why>; the last line is RESULT=OK|PLAN|FAIL|REBOOT_NEEDED|
    RESTART_NEEDED|REFUSED.
      ADMIN   elevated?  (a real run needs it for WSL / DISTRO installs)
      WSL     `wsl --status`; absent -> `wsl --install --no-distribution` (a Windows reboot is then needed:
              says so and stops)
      DISTRO  -Distro, else a registered Ubuntu-26.04, else the default distro IF it is Ubuntu 26.04
              (docker-desktop* ignored).  The fleet is 26.04 only (emacs 30.1 + bin2md need GLIBC 2.43;
              24.04 has 2.39), so a default distro on another release is LEFT ALONE and Ubuntu-26.04 is
              installed beside it: `wsl --install -d Ubuntu-26.04 --no-launch` (a .wsl package: no
              ubuntu2604.exe launcher; init.sh runs as -u root, so no OOBE user is needed)
      WSL2    version 1 -> `wsl --set-version <distro> 2`
      GIT     git.exe; absent -> `winget install -e --id Git.Git`
      GCM     `git credential-manager --version`; absent -> comes with Git, else
              `winget install -e --id Microsoft.GitCredentialManagerCore`
      INIT    init.sh (next to this file, else -InitUrl) run as root in the distro: dry-run -> its own dry
              run is shown as `  init: ...` lines; real run -> `init.sh --apply`.  On failure the one-liner to
              paste in a WSL root console is printed.
    A distro restart (init.sh says RESTART_NEEDED: systemd was just enabled) is a separate gate
    -AllowRestart, done with `wsl --terminate <distro>` -- never `wsl --shutdown`.  It is refused (the
    command is printed for the user instead) when this script runs from inside WSL or when the distro has
    running containers or tmux sessions.

.EXAMPLE
    irm tinyurl.com/ws-bootstrap | iex                          # real run
    $env:WS_DRY=1; irm tinyurl.com/ws-bootstrap | iex           # dry run (changes nothing)
    $env:WS_ALLOW_RESTART=1; ...                                # also allow one `wsl --terminate`; WS_DISTRO=<name>
    powershell -ExecutionPolicy Bypass -File bootstrap.ps1 [-DryRun] [-AllowRestart]
#>
[CmdletBinding()]
param(
    [switch] $DryRun       = ($env:WS_DRY -eq '1'),             # env twins: `irm | iex` cannot pass parameters
    [switch] $Apply,                                            # accepted for old command lines; the real run is the default
    [switch] $AllowRestart = ($env:WS_ALLOW_RESTART -eq '1'),
    [string] $Distro  = "$env:WS_DISTRO",
    [string] $WsUrl   = 'https://dev.azure.com/MSRADKI/Excel/_git/workspace',
    [string] $InitUrl = ''
)
$ErrorActionPreference = 'Stop'
$Apply = -not $DryRun
Remove-Item Env:WS_DRY, Env:WS_ALLOW_RESTART, Env:WS_DISTRO -ErrorAction SilentlyContinue   # one-shot: a dry run must not stick to the next plain line
$env:WSL_UTF8 = '1'                       # wsl.exe management output in UTF-8 (older WSL: UTF-16, NULs stripped below)
$DefaultInitUrl = 'https://raw.githubusercontent.com/bartuer/provision/main/ws/init.sh'                      # set by bin/gist-publish.sh to the gist raw init.sh URL (G.4)
$NewDistro      = 'Ubuntu-26.04'            # the fleet release (wsl --list --online name)
$WantVersion    = '26.04'                   # VERSION_ID the distro must report
$script:fail = 0; $script:result = ''
function Emit($k, $v) { Write-Output "$k=$v"; if ("$v" -like 'FAIL*') { $script:fail++ } }
function Done($r) { if ($r) { $script:result = $r }; if (-not $script:result) { $script:result = $(if ($script:fail) { 'FAIL' } elseif (-not $Apply) { 'PLAN' } else { 'OK' }) }
                    Write-Output "RESULT=$($script:result)"; $script:exitCode = $(if ($script:result -in @('FAIL','REFUSED')) { 1 } else { 0 }) }
function Native([string]$exe, [string[]]$a) {   # run a native exe, return stdout lines (NULs stripped), $script:rc
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & $exe @a 2>&1 | ForEach-Object { "$_" -replace "`0", '' } ; $script:rc = $LASTEXITCODE }
    catch { $o = @("$_"); $script:rc = 9009 }
    finally { $ErrorActionPreference = $old }
    return @($o | Where-Object { $_ -ne '' })
}
function InWsl {   # this PowerShell started from a WSL shell (interop)?  then terminating the distro kills us
    if ($env:WSL_DISTRO_NAME) { return $true }
    $id = $PID
    for ($i = 0; $i -lt 8; $i++) {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
        if (-not $p) { break }
        if ($p.Name -in @('wslhost.exe','wsl.exe','wslrelay.exe','bash.exe')) { return $true }
        $id = $p.ParentProcessId
    }
    return $false
}
function RefreshPath { $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User') }
function Distros {   # @{name=..; ver=..; default=$bool} from `wsl -l -v`
    $r = @()
    foreach ($l in (Native 'wsl.exe' @('-l','-v'))) {
        if ($l -match '^\s*(\*)?\s*(\S+)\s+(Running|Stopped|Installing|Converting|Uninstalling)\s+(\d)\s*$') {
            $r += [pscustomobject]@{ name = $Matches[2]; ver = [int]$Matches[4]; default = [bool]$Matches[1] }
        }
    }
    return $r
}
function InDistro([string]$cmd) { return Native 'wsl.exe' @('-d', $script:D, '-u', 'root', '-e', 'sh', '-c', $cmd) }

function Main {
Write-Output "MODE=$(if ($Apply) { 'apply' } else { 'dry-run' })"

# ADMIN
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Emit 'ADMIN' $(if ($isAdmin) { 'ok' } else { 'NO (installs of WSL / a distro need an elevated PowerShell)' })

# WSL
$haveWsl = [bool](Get-Command wsl.exe -ErrorAction SilentlyContinue)
if ($haveWsl) { Native 'wsl.exe' @('--status') | Out-Null }
if ($haveWsl -and $script:rc -eq 0) { Emit 'WSL' 'ok' }
elseif (-not $Apply) { Emit 'WSL' 'WOULD wsl --install --no-distribution (then a Windows reboot)'; Emit 'DISTRO' "WOULD wsl --install -d $NewDistro --no-launch (after reboot)"; return (Done) }
elseif (-not $isAdmin) { Emit 'WSL' 'FAIL not admin: re-run from an elevated PowerShell'; return (Done) }
else {
    $o = Native 'wsl.exe' @('--install', '--no-distribution'); $o | ForEach-Object { "  wsl: $_" }
    Native 'wsl.exe' @('--status') | Out-Null
    if ($script:rc -eq 0) { Emit 'WSL' 'did wsl --install --no-distribution' }
    else { Emit 'WSL' 'did wsl --install --no-distribution -- REBOOT Windows, then run this again'; return (Done 'REBOOT_NEEDED') }
}

# DISTRO
$all = @(Distros | Where-Object { $_.name -notlike 'docker-desktop*' })
function DistroVer([string]$n) { (Native 'wsl.exe' @('-d', $n, '-u', 'root', '-e', 'sh', '-c', '. /etc/os-release; echo $ID $VERSION_ID') | Select-Object -Last 1) }
if ($Distro) { $d = $all | Where-Object { $_.name -eq $Distro } | Select-Object -First 1 }
else {
    $d = $all | Where-Object { $_.name -eq $NewDistro } | Select-Object -First 1
    if (-not $d) {
        $dd = $all | Where-Object { $_.default } | Select-Object -First 1
        if ($dd) { $v = DistroVer $dd.name
                   if ($v -eq "ubuntu $WantVersion") { $d = $dd }
                   else { Emit 'DISTRO' "skip default $($dd.name) ($v) -- not ubuntu $WantVersion, left untouched" } }
    }
}
if ($d) {
    $v = DistroVer $d.name; $script:D = $d.name
    if ($v -eq "ubuntu $WantVersion") { Emit 'DISTRO' "ok $($d.name) ($v)" }
    else { Emit 'DISTRO' "FAIL $($d.name) is '$v', the fleet needs ubuntu $WantVersion (omit -Distro to install $NewDistro beside it)"; return (Done) }
}
else {
    $want = $(if ($Distro) { $Distro } else { $NewDistro }); $script:D = $want
    if (-not $Apply) { Emit 'DISTRO' "WOULD wsl --install -d $want --no-launch" }
    else {
        Native 'wsl.exe' @('--install', '-d', $want, '--no-launch') | ForEach-Object { "  wsl: $_" }
        $v = $(if (Distros | Where-Object { $_.name -eq $want }) { DistroVer $want } else { '' })
        if ($v -eq "ubuntu $WantVersion") { Emit 'DISTRO' "did wsl --install -d $want --no-launch ($v)" }
        elseif ($v) { Emit 'DISTRO' "FAIL $want installed but reports '$v', not ubuntu $WantVersion"; return (Done) }
        else { Emit 'DISTRO' "FAIL $want not registered after install (rc=$($script:rc))"; return (Done) }
    }
}

# WSL2
$d = Distros | Where-Object { $_.name -eq $script:D } | Select-Object -First 1
if (-not $d) { Emit 'WSL2' "WOULD check version of $($script:D) (not installed yet)" }
elseif ($d.ver -eq 2) { Emit 'WSL2' 'ok' }
elseif (-not $Apply) { Emit 'WSL2' "WOULD wsl --set-version $($script:D) 2" }
else { Native 'wsl.exe' @('--set-version', $script:D, '2') | Out-Null
       if ($script:rc -eq 0) { Emit 'WSL2' "did wsl --set-version $($script:D) 2" } else { Emit 'WSL2' "FAIL wsl --set-version rc=$($script:rc)" } }

# GIT
if (Get-Command git.exe -ErrorAction SilentlyContinue) { Emit 'GIT' 'ok' }
elseif (-not $Apply) { Emit 'GIT' 'WOULD winget install -e --id Git.Git' }
else { Native 'winget.exe' @('install', '-e', '--id', 'Git.Git', '--silent', '--accept-package-agreements', '--accept-source-agreements') | Out-Null
       RefreshPath
       if (Get-Command git.exe -ErrorAction SilentlyContinue) { Emit 'GIT' 'did winget install Git.Git' } else { Emit 'GIT' "FAIL winget install Git.Git rc=$($script:rc)" } }

# GCM
$gcmOk = $false
if (Get-Command git.exe -ErrorAction SilentlyContinue) { Native 'git.exe' @('credential-manager', '--version') | Out-Null; $gcmOk = ($script:rc -eq 0) }
if ($gcmOk) { Emit 'GCM' 'ok' }
elseif (-not $Apply) { Emit 'GCM' 'WOULD (ships with Git for Windows) else winget install -e --id Microsoft.GitCredentialManagerCore' }
else { Native 'winget.exe' @('install', '-e', '--id', 'Microsoft.GitCredentialManagerCore', '--silent', '--accept-package-agreements', '--accept-source-agreements') | Out-Null
       RefreshPath; Native 'git.exe' @('credential-manager', '--version') | Out-Null
       if ($script:rc -eq 0) { Emit 'GCM' 'did winget install GitCredentialManagerCore' } else { Emit 'GCM' 'FAIL git credential-manager still absent' } }

# INIT
$here = $(if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { '' })
$local = $(if ($here) { Join-Path $here 'init.sh' } else { '' })
$url = $(if ($InitUrl) { $InitUrl } else { $DefaultInitUrl })
$src = ''; $init = $null
if ($local -and (Test-Path $local)) { $src = $local; $init = [IO.File]::ReadAllText($local) }
elseif ($url) { $src = $url; try { $init = (Invoke-RestMethod -UseBasicParsing $url) } catch { $init = $null } }
$oneLiner = $(if ($url) { "curl -fsSL '$url' | WS_URL='$WsUrl' bash -s -- --apply" } else { "WS_URL='$WsUrl' bash init.sh --apply   # init.sh from the bootstrap gist" })
function RunInit([string]$mode) {   # init.sh via base64 (no CRLF / encoding mangling), stdin left to the console
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($init -replace "`r`n", "`n")))
    $cmd = "echo $b64 | base64 -d > /tmp/ws-init.sh && WS_URL='$WsUrl' bash /tmp/ws-init.sh $mode; rc=`$?; rm -f /tmp/ws-init.sh; exit `$rc"
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $script:initOut = @(& wsl.exe -d $script:D -u root -e bash -c $cmd 2>&1 | ForEach-Object { "$_" }); $script:rc = $LASTEXITCODE
    $ErrorActionPreference = $old
    $script:initOut | ForEach-Object { "  init: $_" }
}
if (-not $init) { Emit 'INIT' "FAIL no init.sh (not next to this script; -InitUrl '$url' unreadable) -- in a WSL root console: $oneLiner"; return (Done) }
$distroUp = [bool](Distros | Where-Object { $_.name -eq $script:D })
if (-not $Apply) {
    if ($distroUp) { RunInit '--dry-run' }
    Emit 'INIT' "WOULD run init.sh --apply ($src) as root in $($script:D): WS_URL=$WsUrl -> /workspace + ./install.sh"
    return (Done)
}
if (-not $distroUp) { Emit 'INIT' "FAIL distro $($script:D) not registered"; return (Done) }
RunInit '--apply'
$r = ($script:initOut | Where-Object { $_ -match '^RESULT=' } | Select-Object -Last 1) -replace '^RESULT=', ''
if ($r -eq 'RESTART_NEEDED') {
    $restartCmd = "wsl --terminate $($script:D)"
    if (-not $AllowRestart) { Emit 'INIT' "RESTART NEEDED -- run: $restartCmd ; then run this again (or pass -AllowRestart)"; return (Done 'RESTART_NEEDED') }
    if (InWsl) { Emit 'RESTART' "REFUSE running from inside WSL -- from a Windows PowerShell run: $restartCmd ; then run this again"; return (Done 'REFUSED') }
    $busy = @(InDistro 'command -v docker >/dev/null && docker ps -q 2>/dev/null; command -v tmux >/dev/null && tmux ls 2>/dev/null' | Where-Object { $_ -match '\S' })
    if ($busy.Count) { Emit 'RESTART' "REFUSE $($script:D) has running containers/tmux ($($busy.Count)) -- stop them, then: $restartCmd"; return (Done 'REFUSED') }
    Native 'wsl.exe' @('--terminate', $script:D) | Out-Null
    Emit 'RESTART' "did $restartCmd"
    RunInit '--apply'
    $r = ($script:initOut | Where-Object { $_ -match '^RESULT=' } | Select-Object -Last 1) -replace '^RESULT=', ''
}
if ($r -eq 'OK') { Emit 'INIT' "ok init.sh --apply in $($script:D)" }
else { Emit 'INIT' "FAIL init.sh RESULT=$r rc=$($script:rc) -- in a WSL root console (wsl -d $($script:D) -u root): $oneLiner" }
return (Done)
}
$script:exitCode = 0
Main
if ($PSCommandPath) { exit $script:exitCode }   # -File: rc; irm|iex: never close the console
