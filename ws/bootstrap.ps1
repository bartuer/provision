<#
.SYNOPSIS
    bootstrap.ps1 -- plan 01 G.1: a Windows box with nothing -> WSL2 distro + Git/GCM -> init.sh (clone
    /workspace + ./install.sh).  PowerShell 5.1, no modules.  DRY-RUN BY DEFAULT: changes nothing, prints
    what it would do.

.DESCRIPTION
    Each step prints KEY=ok|WOULD <action>|FAIL <why>; the last line is RESULT=OK|PLAN|FAIL|REBOOT_NEEDED|
    RESTART_NEEDED|REFUSED.
      ADMIN   elevated?  (-Apply needs it for WSL / DISTRO installs)
      WSL     `wsl --status`; absent -> `wsl --install --no-distribution` (a Windows reboot is then needed:
              says so and stops)
      DISTRO  -Distro, else the default distro (docker-desktop* ignored); none -> `wsl --install -d
              Ubuntu-24.04 --no-launch` + `ubuntu2404.exe install --root`
      WSL2    version 1 -> `wsl --set-version <distro> 2`
      GIT     git.exe; absent -> `winget install -e --id Git.Git`
      GCM     `git credential-manager --version`; absent -> comes with Git, else
              `winget install -e --id Microsoft.GitCredentialManagerCore`
      INIT    init.sh (next to this file, else -InitUrl) run as root in the distro: dry-run -> its own dry
              run is shown as `  init: ...` lines; -Apply -> `init.sh --apply`.  On failure the one-liner to
              paste in a WSL root console is printed.
    A distro restart (init.sh says RESTART_NEEDED: systemd was just enabled) is a separate gate
    -AllowRestart, done with `wsl --terminate <distro>` -- never `wsl --shutdown`.  It is refused (the
    command is printed for the user instead) when this script runs from inside WSL or when the distro has
    running containers or tmux sessions.

.EXAMPLE
    irm https://tinyurl.com/<alias> | iex                                         # dry run
    & ([scriptblock]::Create((irm https://tinyurl.com/<alias>))) -Apply           # do it
    powershell -ExecutionPolicy Bypass -File bootstrap.ps1 -Apply -AllowRestart
#>
[CmdletBinding()]
param(
    [switch] $Apply,
    [switch] $AllowRestart,
    [string] $Distro  = '',
    [string] $WsUrl   = 'https://dev.azure.com/MSRADKI/Excel/_git/workspace',
    [string] $InitUrl = ''
)
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'                       # wsl.exe management output in UTF-8 (older WSL: UTF-16, NULs stripped below)
$DefaultInitUrl = 'https://raw.githubusercontent.com/bartuer/provision/main/ws/init.sh'                      # set by bin/gist-publish.sh to the gist raw init.sh URL (G.4)
$NewDistro      = 'Ubuntu-24.04'
$NewDistroExe   = 'ubuntu2404.exe'
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
if ($Distro) { $d = $all | Where-Object { $_.name -eq $Distro } | Select-Object -First 1 }
else { $d = $all | Where-Object { $_.default } | Select-Object -First 1; if (-not $d) { $d = $all | Select-Object -First 1 } }
if ($d) { $script:D = $d.name; Emit 'DISTRO' "ok $($d.name)" }
else {
    $want = $(if ($Distro) { $Distro } else { $NewDistro }); $script:D = $want
    $exe  = $(if ($want -eq $NewDistro) { $NewDistroExe } else { ($want -replace '[-.]', '').ToLower() + '.exe' })
    if (-not $Apply) { Emit 'DISTRO' "WOULD wsl --install -d $want --no-launch + $exe install --root" }
    else {
        Native 'wsl.exe' @('--install', '-d', $want, '--no-launch') | ForEach-Object { "  wsl: $_" }
        Native $exe @('install', '--root') | ForEach-Object { "  distro: $_" }
        if (Distros | Where-Object { $_.name -eq $want }) { Emit 'DISTRO' "did wsl --install -d $want + $exe install --root" }
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
