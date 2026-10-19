<#
.SYNOPSIS
    bootstrap.ps1 -- plan 01 G.1: a Windows box with nothing -> WSL2 distro + Git/GCM -> init.sh (clone
    /workspace + ./install.sh).  PowerShell 5.1, no modules.  REAL RUN BY DEFAULT; -DryRun (or $env:WS_DRY=1) changes nothing, prints
    what it would do.

.DESCRIPTION
    Each step prints KEY=ok|WOULD <action>|FAIL <why>; the last line is RESULT=OK|PLAN|FAIL|REBOOT_NEEDED|
    RESTART_NEEDED|REFUSED.
      ADMIN   elevated?  (a real run needs it for WSL / DISTRO installs)
      WSL     Ubuntu-26.04 on WSL2: absent -> `wsl --install -d Ubuntu-26.04 --no-launch` (engine + distro in one
              step; a Windows reboot may then be needed: says so and stops, re-run after it)
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
function Q([string]$x) { if ($x -eq '' -or $x -match '[\s"]') { '"' + ($x -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' } else { $x } }
function Native([string]$exe, [string[]]$a, [int]$Timeout = 120, [string]$Tag = '') {
    # run a native exe LIVE: every line is shown as it arrives (`  <tag>: ...`, \r progress redrawn in place),
    # a heartbeat every 15s of silence, killed after $Timeout s (rc 1460).  stdin is CLOSED, so a "press any key"
    # prompt (the inbox wsl.exe stub on a box without WSL) gets EOF instead of hanging forever.
    # Returns the \n-terminated lines (NULs stripped); $script:rc = exit code.
    if (-not $Tag) { $Tag = [IO.Path]::GetFileNameWithoutExtension($exe) }
    $cmdline = "$exe $($a -join ' ')"
    $out = New-Object System.Collections.Generic.List[string]
    $path = (Get-Command $exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $path) { $script:rc = 9009; Write-Host "  ${Tag}: not found: $exe"; return @() }
    $psi = New-Object Diagnostics.ProcessStartInfo $path
    $psi.Arguments = ($a | ForEach-Object { Q $_ }) -join ' '
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
    try { $p = [Diagnostics.Process]::Start($psi) } catch { $script:rc = 9009; Write-Host "  ${Tag}: start failed: $_"; return @() }
    try { $p.StandardInput.Close() } catch {}
    $rd = @(@{ s = $p.StandardOutput; b = New-Object char[] 4096; t = $null; acc = ''; done = $false },
            @{ s = $p.StandardError;  b = New-Object char[] 4096; t = $null; acc = ''; done = $false })
    $sw = [Diagnostics.Stopwatch]::StartNew(); $last = 0; $cr = $false
    $show = { param($l, $isCr)
        $l = ($l -replace "`0", '').TrimEnd()
        if ($l -eq '') { return }
        if ($isCr) { Write-Host -NoNewline ("`r  ${Tag}: " + $l + '   '); $script:crOpen = $true }
        else { if ($script:crOpen) { Write-Host '' ; $script:crOpen = $false }; Write-Host "  ${Tag}: $l"; $out.Add($l) } }
    $script:crOpen = $false
    while ($true) {
        $busy = $false
        foreach ($r in $rd) {
            if ($r.done) { continue }
            if (-not $r.t) { $r.t = $r.s.ReadAsync($r.b, 0, $r.b.Length) }
            if ($r.t.IsCompleted) {
                $busy = $true; $n = $r.t.Result; $r.t = $null
                if ($n -le 0) { $r.done = $true; if ($r.acc) { & $show $r.acc $false; $r.acc = '' }; continue }
                $r.acc += (New-Object string ($r.b, 0, $n))
                while ($r.acc -match '^([^\r\n]*)([\r\n])') {
                    $seg = $Matches[1]; $sep = $Matches[2]; $r.acc = $r.acc.Substring($seg.Length + 1)
                    if ($sep -eq "`r" -and $r.acc.StartsWith("`n")) { $r.acc = $r.acc.Substring(1); $sep = "`n" }
                    & $show $seg ($sep -eq "`r")
                }
                $last = $sw.Elapsed.TotalSeconds
            }
        }
        if ($rd[0].done -and $rd[1].done) { break }
        $t = $sw.Elapsed.TotalSeconds
        if ($t -gt $Timeout) {
            try { $p.Kill() } catch {}
            if ($script:crOpen) { Write-Host ''; $script:crOpen = $false }
            Write-Host "  ${Tag}: TIMEOUT after $([int]$t)s -- killed: $cmdline"; $script:rc = 1460; return @($out)
        }
        if ($t - $last -ge 15) { if ($script:crOpen) { Write-Host ''; $script:crOpen = $false }
                                 Write-Host "  ${Tag}: ... still running $([int]$t)s (timeout ${Timeout}s): $cmdline"; $last = $t }
        if (-not $busy) { Start-Sleep -Milliseconds 100 }
    }
    if ($script:crOpen) { Write-Host ''; $script:crOpen = $false }
    $p.WaitForExit(); $script:rc = $p.ExitCode
    return @($out)
}
function Step([string]$m) { Write-Host "-- $m" }
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

# WSL -- one step, one target: Ubuntu-26.04 on WSL2.  `wsl --install -d Ubuntu-26.04 --no-launch` installs the WSL
# engine, the Windows features (VirtualMachinePlatform) and the distro, as WSL2 (the default).  A first install
# asks for a Windows reboot: say so and stop; the re-run after the reboot finds it and moves on.
$script:D = $(if ($Distro) { $Distro } else { $NewDistro })
function HaveDistro { [bool](Distros | Where-Object { $_.name -eq $script:D }) }
function DistroVer { Step "WSL: start $($script:D) (first start can take a minute)"
    (Native 'wsl.exe' @('-d', $script:D, '-u', 'root', '-e', 'sh', '-c', '. /etc/os-release; echo $ID $VERSION_ID') -Timeout 300 | Select-Object -Last 1) }
$haveWsl = [bool](Get-Command wsl.exe -ErrorAction SilentlyContinue)
Step "WSL: is $($script:D) installed? (wsl -l -v)"
$have = $haveWsl -and (HaveDistro)
if ($haveWsl -and -not $have -and -not $Distro) {   # an existing default distro that IS ubuntu 26.04 (e.g. named `Ubuntu`): use it
    $dd = Distros | Where-Object { $_.default -and $_.name -notlike 'docker-desktop*' } | Select-Object -First 1
    if ($dd) { $keep = $script:D; $script:D = $dd.name
               if ((DistroVer) -eq "ubuntu $WantVersion") { $have = $true } else { $script:D = $keep } }
}
if (-not $have) {
    if (-not $Apply) { Emit 'WSL' "WOULD wsl --install -d $($script:D) --no-launch (WSL2; then maybe a Windows reboot)"; return (Done) }
    if (-not $isAdmin) { Emit 'WSL' 'FAIL not admin: re-run from an elevated PowerShell'; return (Done) }
    Step "WSL: wsl --install -d $($script:D) --no-launch --web-download (WSL engine + distro, WSL2; progress below, timeout 30 min)"
    $io = Native 'wsl.exe' @('--install', '-d', $script:D, '--no-launch', '--web-download') -Timeout 1800; $irc = $script:rc
    if ((($io -join ' ') -match 'reboot|restart') -or -not (HaveDistro)) {
        Emit 'WSL' "did wsl --install -d $($script:D) (rc=${irc}) -- REBOOT Windows, then run this again"; return (Done 'REBOOT_NEEDED') }
}
$d = Distros | Where-Object { $_.name -eq $script:D } | Select-Object -First 1
if ($d.ver -ne 2) {
    if (-not $Apply) { Emit 'WSL' "WOULD wsl --set-version $($script:D) 2"; return (Done) }
    Step "WSL: wsl --set-version $($script:D) 2"
    Native 'wsl.exe' @('--set-version', $script:D, '2') -Timeout 1800 | Out-Null
    if ($script:rc -ne 0) { Emit 'WSL' "FAIL wsl --set-version $($script:D) 2 rc=$($script:rc) -- REBOOT Windows and run this again"; return (Done 'REBOOT_NEEDED') }
}
$v = DistroVer
if ($v -eq "ubuntu $WantVersion") { Emit 'WSL' "ok $($script:D) WSL2 ($v)" }
else { Emit 'WSL' "FAIL $($script:D) reports '$v', the fleet needs ubuntu $WantVersion (rc=$($script:rc))"; return (Done) }

# GIT
if (Get-Command git.exe -ErrorAction SilentlyContinue) { Emit 'GIT' 'ok' }
elseif (-not $Apply) { Emit 'GIT' 'WOULD winget install -e --id Git.Git' }
else { Step 'GIT: winget install Git.Git (timeout 30 min)'
       Native 'winget.exe' -Timeout 1800 -a @('install', '-e', '--id', 'Git.Git', '--silent', '--accept-package-agreements', '--accept-source-agreements') | Out-Null
       RefreshPath
       if (Get-Command git.exe -ErrorAction SilentlyContinue) { Emit 'GIT' 'did winget install Git.Git' } else { Emit 'GIT' "FAIL winget install Git.Git rc=$($script:rc)" } }

# GCM
$gcmOk = $false
if (Get-Command git.exe -ErrorAction SilentlyContinue) { Native 'git.exe' @('credential-manager', '--version') | Out-Null; $gcmOk = ($script:rc -eq 0) }
if ($gcmOk) { Emit 'GCM' 'ok' }
elseif (-not $Apply) { Emit 'GCM' 'WOULD (ships with Git for Windows) else winget install -e --id Microsoft.GitCredentialManagerCore' }
else { Step 'GCM: winget install Microsoft.GitCredentialManagerCore (timeout 30 min)'
       Native 'winget.exe' -Timeout 1800 -a @('install', '-e', '--id', 'Microsoft.GitCredentialManagerCore', '--silent', '--accept-package-agreements', '--accept-source-agreements') | Out-Null
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
    Step "INIT: init.sh $mode as root in $($script:D) (live output below)"
    $script:initOut = @(& wsl.exe -d $script:D -u root -e bash -c $cmd 2>&1 | ForEach-Object { $l = "$_"; Write-Host "  init: $l"; $l }); $script:rc = $LASTEXITCODE
    $ErrorActionPreference = $old
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
$LogFile = Join-Path $env:TEMP 'ws-bootstrap.log'
try { Start-Transcript -Path $LogFile -Append -ErrorAction Stop | Out-Null; $tr = $true } catch { $tr = $false }
Write-Host "-- log: $LogFile  (watch from another window: Get-Content -Wait '$LogFile')"
Main
if ($tr) { try { Stop-Transcript | Out-Null } catch {} }
if ($PSCommandPath) { exit $script:exitCode }   # -File: rc; irm|iex: never close the console
