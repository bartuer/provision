<#
.SYNOPSIS
    bootstrap.ps1 -- plan 01 G.1: a Windows box with nothing -> WSL2 distro + Git/GCM -> init.sh (clone
    /workspace + ./install.sh).  PowerShell 5.1, no modules.  REAL RUN BY DEFAULT; -DryRun (or $env:WS_DRY=1) changes nothing, prints
    what it would do.

.DESCRIPTION
    Each step prints KEY=ok|WOULD <action>|FAIL <why>; the last line is RESULT=OK|PLAN|FAIL|PENDING|REBOOT_NEEDED|
    RESTART_NEEDED|REFUSED.
      ADMIN   elevated?  (a real run needs it for WSL / DISTRO installs)
      WSL     Ubuntu-26.04 on WSL2: absent -> `wsl --install -d Ubuntu-26.04 --no-launch` (engine + distro in one
              step, live progress); a first install whose Windows features wait for a reboot (wsl --install then fails
              e.g. 'Forbidden (403)') -> RESULT=REBOOT_NEEDED: reboot, re-run the same command)
      GIT     git.exe; absent -> Git for Windows from its GitHub release (winget only as fallback)
      GCM     `git credential-manager --version`; absent -> comes with Git, else the GCM GitHub release
      NODE    Windows node.exe >= v24 (tserver mints the ADO token via WAM under Windows node); absent OR older
              (v18 = EOL, removed by corp IT 'MDEE-NodeJSEOL' cleanup) -> nodejs.org v24.22.1 LTS MSI, silent
              msiexec into C:\Program Files\nodejs (an MSI major upgrade replaces the old one in place)
      INIT    init.sh (next to this file, else -InitUrl) run as root in the distro: dry-run -> its own dry
              run is shown as `  init: ...` lines; real run -> `init.sh --apply`.  On failure the one-liner to
              re-run is this same bootstrap (everything is idempotent).
      WIN     after INIT ok: the Windows half, install.ps1 from the distro (WebView2 149 + pin, Excel shim,
              WEF, ASR, ssh, docker shims, VM boot task).  WS_SKIP_WIN=1 skips.
      BENCH   after WIN: install.sh 10 = bin/bench-ctxcore.sh --fix --make-lane-on, then its --check clean.
              WS_SKIP_BENCH=1 skips.  CLI (in /workspace) opens only if BENCH ok; else a WSL shell there.
      SMOKE   after CLI (BENCH ok): bin/smoke-addup.sh = one ssg turn via wserver -- new sheet Numbers 1..10,
              A11 = SUM = 55; the Excel window stays open.  WS_SMOKE=0 skips.
      REPORT  last, success or failure: bin/install-report.sh = install result, errors, stage times, network
              (LFS + image pull MB/s), auth (GCM, tserver, kiss-auth), SMOKE -> redacted, committed under
              fix.archive/install-reports/<host>-<UTC>/ and pushed.  WS_REPORT=0 skips.  Never fails the run.
    A distro restart (init.sh says RESTART_NEEDED: systemd was just enabled) is a separate gate
    done here automatically with `wsl --terminate <distro>` -- never `wsl --shutdown`.  It is refused (the
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
    [string] $InitUrl = '',
    [string] $User    = "$env:WS_USER"                          # WSL login user; default = the Windows user name
)
$ErrorActionPreference = 'Stop'
$Apply = -not $DryRun
Remove-Item Env:WS_DRY, Env:WS_ALLOW_RESTART, Env:WS_DISTRO, Env:WS_USER -ErrorAction SilentlyContinue   # one-shot: a dry run must not stick to the next plain line
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
    $sw = [Diagnostics.Stopwatch]::StartNew(); $last = 0; $cr = $false; $said = $false
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
            Write-Host "  ${Tag}: TIMEOUT after $([int]$t)s -- stopped this wsl.exe CLIENT only (the WSL VM and distros keep running): $cmdline"; $script:rc = 1460; return @($out)
        }
        # heartbeat: the command once (cut to 120 chars -- report's --smoke carries the whole answer), then elapsed only
        if ($t - $last -ge 15) { if ($script:crOpen) { Write-Host ''; $script:crOpen = $false }
                                 $hb = "  ${Tag}: ... still running $([int]$t)s (timeout ${Timeout}s)"
                                 if (-not $said) { $c = $cmdline; if ($c.Length -gt 120) { $c = $c.Substring(0, 117) + '...' }; $hb += ": $c"; $said = $true }
                                 Write-Host $hb; $last = $t }
        if (-not $busy) { Start-Sleep -Milliseconds 100 }
        if ($t -ge 2) { Write-Progress -Activity "${Tag}: $cmdline" -Status ("{0}s elapsed (timeout {1}s)" -f [int]$t, $Timeout) -PercentComplete ([math]::Min(99, [int](100 * $t / $Timeout))) }
    }
    if ($script:crOpen) { Write-Host ''; $script:crOpen = $false }
    $p.WaitForExit(); $script:rc = $p.ExitCode
    Write-Progress -Activity "${Tag}: $cmdline" -Completed
    return @($out)
}
function RebootPending {   # a WSL Windows feature enabled but not active until a reboot (CBS/WU keys are NOT used:
    # on a managed laptop they stay set after the reboot, laptop 2026-10-30)
    [bool](@('VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux' | ForEach-Object { Get-WindowsOptionalFeature -Online -FeatureName $_ -ErrorAction SilentlyContinue }) | Where-Object { "$($_.State)" -eq 'EnablePending' }) }
function Step([string]$m) { Write-Host "-- $m" }
function Live([string]$exe, [string[]]$a, [int]$Timeout = 1800, [string]$What = '') {
    # run a long native step ON THIS CONSOLE (not redirected), so wsl.exe / winget draw their own % progress bar;
    # on top, a PowerShell progress bar shows the step and its elapsed time.  Killed after $Timeout s (rc 1460).
    if (-not $What) { $What = "$exe $($a -join ' ')" }
    $path = (Get-Command $exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $path) { $script:rc = 9009; Write-Host "  not found: $exe"; return }
    try { $p = Start-Process -FilePath $path -ArgumentList (($a | ForEach-Object { Q $_ }) -join ' ') -NoNewWindow -PassThru }
    catch { $script:rc = 9009; Write-Host "  start failed: $_"; return }
    $null = $p.Handle   # PS 5.1: without touching Handle, ExitCode reads $null after exit
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.WaitForExit(1000)) {
        $t = [int]$sw.Elapsed.TotalSeconds
        Write-Progress -Activity $What -Status ("{0}m{1:d2}s elapsed (timeout {2}m)" -f [int][math]::Floor($t / 60), ($t % 60), [int]($Timeout / 60)) -PercentComplete ([math]::Min(99, [int](100 * $t / $Timeout)))
        if ($t -gt $Timeout) { try { $p.Kill() } catch {}; Write-Progress -Activity $What -Completed
                               Write-Host "  TIMEOUT after ${t}s -- killed: $What"; $script:rc = 1460; return }
    }
    $p.WaitForExit(); Write-Progress -Activity $What -Completed
    $script:rc = $p.ExitCode
    Write-Host ("  {0}: rc={1} in {2}s" -f $What, $script:rc, [int]$sw.Elapsed.TotalSeconds)
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
    foreach ($l in (Native 'wsl.exe' @('-l','-v') -Timeout 20 -Tag 'wsl -l -v')) {   # answers in <2s; a hang = the WSL service is stuck, not slow
        if ($l -match '^\s*(\*)?\s*(\S+)\s+(Running|Stopped|Installing|Converting|Uninstalling)\s+(\d)\s*$') {
            $r += [pscustomobject]@{ name = $Matches[2]; state = $Matches[3]; ver = [int]$Matches[4]; default = [bool]$Matches[1] }
        }
    }
    return $r
}
function InDistro([string]$cmd) { return Native 'wsl.exe' @('-d', $script:D, '-u', 'root', '-e', 'sh', '-c', $cmd) -Timeout 30 }

# WIN: the Windows half of install (install.ps1: WV2 tree, PIN, SHIM, WEF, ASR, SSH, DOCKER, VMBOOT).  It needs
# admin, which this bootstrap already is; before 2026-10-21 a new box had to run it by hand and
# bench-ctxcore.sh --check showed win-WV2/PIN/SHIM FAIL.  install.ps1 + its bin\ helpers are copied out of the
# distro to %TEMP% (a ps1 on \\wsl.localhost is a network path: zone/policy prompts).
function WinTier {
    if ($env:WS_SKIP_WIN -eq '1') { Emit 'WIN' 'skip (WS_SKIP_WIN=1)'; return }
    $src = "\\wsl.localhost\$($script:D)\workspace"
    if (-not (Test-Path "$src\install.ps1")) { $src = "\\wsl$\$($script:D)\workspace" }
    if (-not (Test-Path "$src\install.ps1")) { Emit 'WIN' "FAIL no $src\install.ps1"; return }
    $dst = Join-Path $env:TEMP 'ws-install'; Remove-Item -Recurse -Force $dst -EA SilentlyContinue
    New-Item -ItemType Directory -Force "$dst\bin" | Out-Null
    Copy-Item "$src\install.ps1" $dst
    foreach ($f in 'pin-wv2-149.ps1', 'docker.cmd', 'bench.cmd') { Copy-Item "$src\bin\$f" "$dst\bin\" -EA SilentlyContinue }
    Step "WIN: install.ps1 (WebView2 149 tree + pin, Excel shim, WEF, ASR, ssh, docker shims, VM boot task)"
    $ps = (Get-Command powershell.exe).Source
    # pwsh 7 host: Process.Start hands 5.1 pwsh's PSModulePath -> Set-Acl CouldNotAutoloadMatchingModule (cloud PC
    # 2026-10-26).  Give the 5.1 child the machine+user module path for the call.
    $savedPMP = $env:PSModulePath
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $env:PSModulePath = (@([Environment]::GetEnvironmentVariable('PSModulePath', 'User'), [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')) | Where-Object { $_ }) -join ';' }
    try {
        if ($isAdmin) { $out = Native $ps @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$dst\install.ps1", '-Distro', $script:D, '-Repo', '/workspace') -Timeout 900 -Tag 'install.ps1' }
        else {
            # NOT elevated (laptop 2026-10-30: PIN=FAIL rc=2 -> Excel on the shipped WV2 150+, which strips
            # --ignore-certificate-errors -> pane "invalid security certificate" -> SMOKE connect timeout).
            # Only this step needs admin: ONE UAC prompt, output captured to a log and parsed as before.
            $log = Join-Path $dst 'install.ps1.log'; Remove-Item $log -EA SilentlyContinue
            Write-Host "  install.ps1: not elevated -- approve the UAC prompt (WebView2 pin + cert args need admin)"
            $cmd = "& '$dst\install.ps1' -Distro '$($script:D)' -Repo '/workspace' *>&1 | Out-File -Encoding utf8 '$log'"
            try { $p = Start-Process $ps -Verb RunAs -Wait -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd) }
            catch { Write-Host "  install.ps1: UAC declined ($($_.Exception.Message))" }
            $out = @(if (Test-Path $log) { Get-Content $log } else { 'RESULT=FAIL UAC declined / no log' })
            $out | ForEach-Object { Write-Host "  install.ps1: $_" }
        }
    }
    finally { $env:PSModulePath = $savedPMP }
    $res = (@($out) | Where-Object { $_ -match '^RESULT=' } | Select-Object -Last 1) -replace '^RESULT=', ''
    $bad = @(@($out) | Where-Object { $_ -match '^[A-Z0-9_]+=(ABSENT|MISSING|FAIL|NO)' }) -join '; '
    if ($res -eq 'OK') { Emit 'WIN' 'ok install.ps1' } else { Emit 'WIN' "FAIL install.ps1 RESULT=$res $bad (re-run elevated: powershell -ExecutionPolicy Bypass -File $dst\install.ps1 -Distro $($script:D))" }
}
# BENCH = install.sh 10 (plan 02 E.2): the LAST install stage -- bench-ctxcore.sh --fix --make-lane-on, then its
# --check (cihc grader at the OA pin, lane on :6030, wserver, win-* rows WIN just fixed) + CLI trusts /workspace.
# Runs after WIN because the win-* rows need install.ps1.  The CLI window opens only if BENCH is ok.
function BenchReady {
    if ($env:WS_SKIP_BENCH -eq '1') { $script:benchOk = $true; Emit 'BENCH' 'skip (WS_SKIP_BENCH=1)'; return }
    Step "BENCH: install.sh 10 (bench-ctxcore.sh --fix --make-lane-on, then --check)"
    $out = Native 'wsl.exe' @('-d', $script:D, '-u', 'root', '-e', 'bash', '-c', 'cd /workspace && WS_CLI=0 ./install.sh 10') -Timeout 900 -Tag 'bench'
    $line = @(@($out) | Where-Object { $_ -match '^STAGE=10 ' } | Select-Object -Last 1) -join ''
    $script:benchOk = ($script:rc -eq 0)
    if ($script:benchOk) { Emit 'BENCH' "ok $line"; return }
    if ($script:rc -eq 1460) { Emit 'BENCH' "PENDING watch timed out after 900s, install.sh 10 may still run in WSL (check: wsl -u root, cd /workspace, ./install.sh --check 10)"; return }
    Emit 'BENCH' "FAIL $line (re-run: wsl -u root, cd /workspace, ./install.sh 10 -- detail: bin/bench-ctxcore.sh --check)"
}

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
    (Native 'wsl.exe' @('-d', $script:D, '-u', 'root', '-e', 'sh', '-c', '. /etc/os-release; echo $ID $VERSION_ID') -Timeout 90 | Select-Object -Last 1) }
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
    Step "WSL: wsl --install -d $($script:D) --no-launch --web-download (WSL engine + distro, WSL2; wsl's own progress below)"
    Native 'wsl.exe' @('--version') | Out-Null; $engine = ($script:rc -eq 0)
    $cacheImg = Join-Path $env:LOCALAPPDATA ('ws-bootstrap\' + ($DistroImg -split '/')[-1])
    # engine there + Ubuntu-26.04: go straight to the cached/direct image (a re-run must not download it again via wsl.exe)
    if (-not ($engine -and $script:D -eq "Ubuntu-$WantVersion")) {
        Live 'wsl.exe' @('--install', '-d', $script:D, '--no-launch', '--web-download') -What "wsl --install -d $($script:D)" }
    # new laptop 2026-10-30: wsl --install --web-download -> 'Forbidden (403)' = its GitHub API release lookup (rate limit /
    # corp proxy), before AND after a reboot.  Fallback: the pinned WSL MSI by its plain release URL (no API), then the
    # distro again (wsl's own distro list is raw.githubusercontent, not the API).
    # engine already there: the 403 is the distro fetch, skip the msi (3010 would loop the reboot)
    if (-not (HaveDistro) -and -not $engine) {
        $msi = Join-Path $env:TEMP ($WslMsi -split '/')[-1]
        Step "WSL: fallback -- WSL engine from $WslMsi (no GitHub API), then the distro"
        try { Start-BitsTransfer -Source $WslMsi -Destination $msi -DisplayName 'download wsl msi' -ErrorAction Stop }
        catch { try { Invoke-WebRequest -UseBasicParsing $WslMsi -OutFile $msi } catch { Write-Host "  WSL: msi download failed: $($_.Exception.Message)" } }
        if (Test-Path $msi) { Live 'msiexec.exe' @('/i', $msi, '/qn', '/norestart') -What 'install wsl msi' -Timeout 900; Remove-Item $msi -ErrorAction SilentlyContinue
            if ($script:rc -eq 3010) { Emit 'WSL' 'REBOOT WSL engine installed, Windows asks for a reboot -- reboot, then run the same command again'; return (Done 'REBOOT_NEEDED') }
            Live 'wsl.exe' @('--install', '-d', $script:D, '--no-launch') -What "wsl --install -d $($script:D) (after msi)" }
    }
    # new laptop 10-30 (latest OS): still 403 after the msi = the distro fetch itself is blocked.  Fallback 2: the
    # distro image from releases.ubuntu.com (the Url+Sha256 of microsoft/WSL DistributionInfo.json), no GitHub at all,
    # then `wsl --install --from-file` (WSL >= 2.4.4), else `wsl --import` (init.sh creates INIT_USER itself).
    if (-not (HaveDistro) -and $script:D -eq "Ubuntu-$WantVersion") {
        $img = $cacheImg; New-Item -ItemType Directory -Force (Split-Path $img) | Out-Null
        if ((Test-Path $img) -and ((Get-FileHash $img -Algorithm SHA256).Hash -eq $DistroSha)) { Step "WSL: $($script:D) image already downloaded ($img, sha256 ok) -- no download" }
        else { Remove-Item $img -ErrorAction SilentlyContinue
        Step "WSL: fallback -- $($script:D) image from $DistroImg (no GitHub) -> $img (kept until the distro is registered)"
        try { Start-BitsTransfer -Source $DistroImg -Destination $img -DisplayName 'download ubuntu wsl image' -ErrorAction Stop }
        catch { try { Invoke-WebRequest -UseBasicParsing $DistroImg -OutFile $img } catch { Write-Host "  WSL: image download failed: $($_.Exception.Message)" } } }
        if ((Test-Path $img) -and ((Get-FileHash $img -Algorithm SHA256).Hash -ne $DistroSha)) { Write-Host "  WSL: image sha256 mismatch, dropped"; Remove-Item $img -ErrorAction SilentlyContinue }
        if (Test-Path $img) {
            Live 'wsl.exe' @('--install', '--from-file', $img, '--name', $script:D, '--no-launch') -What "wsl --install --from-file ($($script:D))" -Timeout 900
            if (-not (HaveDistro)) {
                $dir = Join-Path $env:LOCALAPPDATA "wsl\$($script:D)"; New-Item -ItemType Directory -Force $dir | Out-Null
                Live 'wsl.exe' @('--import', $script:D, $dir, $img, '--version', '2') -What "wsl --import $($script:D)" -Timeout 900 }
            if (HaveDistro) { Remove-Item $img -ErrorAction SilentlyContinue } }
    }
    if (-not (HaveDistro) -and (RebootPending)) { Emit 'WSL' "REBOOT Windows features for WSL are pending a reboot (wsl --install rc=$($script:rc)) -- reboot, then run the same command again"; return (Done 'REBOOT_NEEDED') }
    if (-not (HaveDistro)) { Emit 'WSL' "FAIL $($script:D) not registered after wsl --install (rc=$($script:rc)) -- if wsl asked for a Windows reboot, reboot and run this again"; return (Done) }
    Emit 'WSL' "did wsl --install -d $($script:D) --no-launch --web-download"
}
$d = Distros | Where-Object { $_.name -eq $script:D } | Select-Object -First 1
if ($d.ver -ne 2) {
    if (-not $Apply) { Emit 'WSL' "WOULD wsl --set-version $($script:D) 2"; return (Done) }
    Step "WSL: wsl --set-version $($script:D) 2"
    Live 'wsl.exe' @('--set-version', $script:D, '2') -What "wsl --set-version $($script:D) 2"
    if ($script:rc -ne 0) { Emit 'WSL' "FAIL wsl --set-version $($script:D) 2 rc=$($script:rc)"; return (Done) }
}
$v = DistroVer
if ($v -eq "ubuntu $WantVersion") { Emit 'WSL' "ok $($script:D) WSL2 ($v)" }
else { Emit 'WSL' "FAIL $($script:D) reports '$v', the fleet needs ubuntu $WantVersion (rc=$($script:rc))"; return (Done) }

# GIT + GCM -- straight from the GitHub releases (Invoke-RestMethod/BITS use the Windows cert store, so a
# TLS-inspecting corporate proxy is trusted).  winget is only the FALLBACK: on a devbox it fails twice --
# msstore "No packages were found" and "The server certificate did not match any of the expected values"
# (winget pins its CDN certificate, the proxy re-signs it).
function HaveGit { RefreshPath; [bool](Get-Command git.exe -ErrorAction SilentlyContinue) }
function HaveGcm { if (-not (HaveGit)) { return $false }; Native 'git.exe' @('credential-manager', '--version') | Out-Null; return ($script:rc -eq 0) }
function GhInstall([string]$repo, [string]$pattern, [string[]]$args2, [string]$what, [string]$pin = '') {
    # $pin (a fixed release asset URL, the version proven on c17) first; else the latest release asset of
    # github.com/$repo matching $pattern -> %TEMP% (BITS progress bar) -> run silent (Live)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    $u = $null; $name = $null
    if ($pin) { $u = $pin; $name = ($pin -split '/')[-1]; Step "${what}: pinned $name" }
    else { Step "${what}: latest release of github.com/$repo" }
    if (-not $u) { try {
        $rel = Invoke-RestMethod -UseBasicParsing "https://api.github.com/repos/$repo/releases/latest"
        $as = $rel.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
        if ($as) { $u = $as.browser_download_url; $name = $as.name }
    } catch { Write-Host "  ${what}: api.github.com failed ($($_.Exception.Message)); trying the release page" } }
    if (-not $u) {   # api rate limit / blocked: scrape the expanded-assets page of the latest tag
        try {
            $r = Invoke-WebRequest -UseBasicParsing "https://github.com/$repo/releases/latest" -MaximumRedirection 5
            $tag = ($r.BaseResponse.ResponseUri.AbsoluteUri -split '/tag/')[-1]
            $page = (Invoke-WebRequest -UseBasicParsing "https://github.com/$repo/releases/expanded_assets/$tag").Content
            $m = [regex]::Matches($page, 'href="(/' + [regex]::Escape($repo) + '/releases/download/[^"]+)"') | ForEach-Object { $_.Groups[1].Value } |
                 Where-Object { ($_ -split '/')[-1] -match $pattern } | Select-Object -First 1
            if ($m) { $u = "https://github.com$m"; $name = ($m -split '/')[-1] }
        } catch { Write-Host "  ${what}: release page failed ($($_.Exception.Message))" }
    }
    if (-not $u) { Write-Host "  ${what}: no installer matching $pattern found"; $script:rc = 2; return }
    # cached in %LOCALAPPDATA%\ws-bootstrap (laptop 10-30: every re-run downloaded it again); a complete file is
    # renamed in from .part, so a present file = a whole download; it is removed only after a clean install
    $cache = Join-Path $env:LOCALAPPDATA 'ws-bootstrap'; New-Item -ItemType Directory -Force $cache | Out-Null
    $exe = Join-Path $cache $name
    if (Test-Path $exe) { Step "${what}: $name already downloaded ($exe) -- no download" }
    else {
        $part = "$exe.part"; Remove-Item $part -ErrorAction SilentlyContinue
        Step "${what}: download $name"
        try { Start-BitsTransfer -Source $u -Destination $part -DisplayName "download $name" -ErrorAction Stop }
        catch { Write-Host "  ${what}: BITS failed ($($_.Exception.Message)), plain download"
                try { $ProgressPreference = 'Continue'; Invoke-WebRequest -UseBasicParsing $u -OutFile $part } catch { Write-Host "  ${what}: download failed: $($_.Exception.Message)"; $script:rc = 3; return } }
        Move-Item $part $exe -Force
    }
    Step "${what}: $name (silent install; Defender scans every file, a few minutes on a new box)"
    Live $exe $args2 -What "install $name" -Timeout 1200
    if ($script:rc -eq 0) { Remove-Item $exe -ErrorAction SilentlyContinue }
}
function WingetInstall([string]$id, [string]$what) {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { return }
    Step "${what}: fallback winget install $id --source winget"
    Live 'winget.exe' -a @('install', '-e', '--id', $id, '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements') -Timeout 900
}
# Pinned to what works on c17 (Git for Windows 2.55.0.5 bundles GCM 2.9.1): same build on every devbox, fixed
# GCM path C:\Program Files\Git\mingw64\bin\git-credential-manager.exe.  Latest release / winget only as fallbacks.
$GitPin = 'https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.5/Git-2.55.0.5-64-bit.exe'
$GitDir = "$env:ProgramFiles\Git"
$inno = @('/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/SUPPRESSMSGBOXES')
if (HaveGit) { Emit 'GIT' 'ok' }
elseif (-not $Apply) { Emit 'GIT' 'WOULD install Git for Windows 2.55.0.5 (pinned; bundles GCM) into $GitDir' }
else {
    GhInstall 'git-for-windows/git' '' ($inno + @("/DIR=$GitDir")) 'GIT' $GitPin   # pinned: brings GCM at $GitDir\mingw64\bin
    if (-not (HaveGit)) { GhInstall 'git-for-windows/git' '^Git-[\d.]+-64-bit\.exe$' ($inno + @("/DIR=$GitDir")) 'GIT' }
    if (-not (HaveGit)) { WingetInstall 'Git.Git' 'GIT' }
    if (HaveGit) { Emit 'GIT' "did install Git for Windows ($((& git.exe --version) -join ''))" }
    else { Emit 'GIT' "FAIL git.exe still absent (github download and winget both failed, rc=$($script:rc)) -- log: $LogFile" }
}
function GcmExe {   # the Windows git-credential-manager.exe (WINDOWS path; init.sh converts it with wslpath)
    RefreshPath
    $c = New-Object System.Collections.Generic.List[string]
    $c.Add("$env:ProgramFiles\Git Credential Manager\git-credential-manager.exe")   # the standalone install (preferred)
    $g = (Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if ($g) {
        try { $ep = (& $g --exec-path 2>$null | Select-Object -First 1) -replace '/', '\' } catch { $ep = '' }   # ...\mingw64\libexec\git-core
        if ($ep) { $c.Add("$ep\git-credential-manager.exe"); $c.Add((Join-Path (Split-Path (Split-Path $ep -Parent) -Parent) 'bin\git-credential-manager.exe')) }
        $root = Split-Path (Split-Path $g -Parent) -Parent   # ...\Git\cmd\git.exe -> ...\Git
        $c.Add("$root\mingw64\bin\git-credential-manager.exe"); $c.Add("$root\mingw64\libexec\git-core\git-credential-manager.exe")
    }
    $w = (Get-Command git-credential-manager.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source; if ($w) { $c.Add($w) }
    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\Programs", "$env:LOCALAPPDATA")) {
        if ($pf) { $c.Add("$pf\Git Credential Manager\git-credential-manager.exe"); $c.Add("$pf\Git\mingw64\bin\git-credential-manager.exe") } }
    $hit = $c | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $hit) {   # last resort: search the git root, then the usual roots
        foreach ($r in @($(if ($g) { Split-Path (Split-Path $g -Parent) -Parent }), $env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\Programs")) {
            if (-not $r -or -not (Test-Path $r)) { continue }
            $hit = Get-ChildItem -Path $r -Filter 'git-credential-manager*.exe' -Recurse -Depth 5 -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
            if ($hit) { break }
        }
    }
    if (-not $hit) { Write-Host "  gcm: NOT FOUND (git.exe=$g; tried: $($c -join ' | '))"; return '' }
    return $hit
}
# GCM: always the STANDALONE installer (user ruling 2026-10-19: it is what pops the sign-in window for the
# ADO clone from WSL), pinned, into a fixed dir so init.sh gets one known path.
$GcmPin = 'https://github.com/git-ecosystem/git-credential-manager/releases/download/v2.7.3/gcm-win-x64-2.7.3.exe'
$GcmDir = "$env:ProgramFiles\Git Credential Manager"
function HaveGcmStd { Test-Path -LiteralPath "$GcmDir\git-credential-manager.exe" }
if (HaveGcmStd) { Emit 'GCM' "ok $GcmDir\git-credential-manager.exe ($((& "$GcmDir\git-credential-manager.exe" --version 2>$null) -join ''))" }
elseif (-not $Apply) { Emit 'GCM' "WOULD install standalone Git Credential Manager 2.7.3 (pinned) into $GcmDir" }
else {
    GhInstall 'git-ecosystem/git-credential-manager' '' ($inno + @("/DIR=$GcmDir")) 'GCM' $GcmPin
    if (-not (HaveGcmStd)) { GhInstall 'git-ecosystem/git-credential-manager' '^gcm-win-x64-[\d.]+\.exe$' ($inno + @("/DIR=$GcmDir")) 'GCM' }
    if (-not (HaveGcmStd)) { WingetInstall 'Git.GCM' 'GCM' }
    $x = GcmExe
    if (HaveGcmStd) { Emit 'GCM' "did install Git Credential Manager: $GcmDir\git-credential-manager.exe" }
    elseif ($x) { Emit 'GCM' "did install Git Credential Manager (not in $GcmDir): $x" }
    else { Emit 'GCM' "FAIL git-credential-manager.exe absent after install (rc=$($script:rc)) -- log: $LogFile" }
}

# NODE: Windows node.exe -- tserver (install.sh stage 6) mints the ADO token by running the WAM broker under
# WINDOWS node (/mnt/c/Program Files/nodejs/node.exe; the MSAL runtime is a Windows DLL).  A fresh devbox
# has none -> stage 6 "gave no token".  MEASURED 2026-10-23: corp IT ("MDEE-NodeJSEOL", SYSTEM, silent
# msiexec REMOVE=ALL) uninstalls out-of-support Node (v18) from fleet boxes and laptops -- a v18 that is
# present at bootstrap time is gone by stage 6 / the next day.  So: require major >= $NodeMin, pin a current
# LTS (= the version the fleet was repaired to), and upgrade an older one in place (MSI major upgrade).
$NodeMin = 24
$WslMsi = 'https://github.com/microsoft/WSL/releases/download/2.7.14/wsl.2.7.14.0.x64.msi'   # = fleet c17 `wsl --version`; plain release URL, no API
$DistroImg = 'https://releases.ubuntu.com/26.04.1/ubuntu-26.04.1-wsl-amd64.wsl'   # = microsoft/WSL DistributionInfo.json Ubuntu-26.04
$DistroSha = '48D56724B5C8E60F24893E83E73BBB58C60B3CA22FBA3DA977075420ACD54104'
$NodePin = 'https://nodejs.org/dist/v24.22.1/node-v24.22.1-x64.msi'
$NodeExe = "$env:ProgramFiles\nodejs\node.exe"
function NodeVer { if (Test-Path -LiteralPath $NodeExe) { "$((& $NodeExe --version 2>$null) -join '')".Trim() } else { '' } }
function NodeMajor { if ((NodeVer) -match '^v(\d+)\.') { [int]$Matches[1] } else { 0 } }
function HaveNode { (NodeMajor) -ge $NodeMin }
$nv0 = NodeVer
if (HaveNode) { Emit 'NODE' "ok $NodeExe ($nv0)" }
elseif (-not $Apply) { Emit 'NODE' "WOULD $(if ($nv0) { "upgrade $nv0 (EOL; corp IT cleanup removes it)" } else { 'install' }) -> Node.js $((($NodePin -split '/')[-2])) LTS MSI into $env:ProgramFiles\nodejs" }
else {
    if ($nv0) { Write-Host "  NODE: $NodeExe is $nv0 (< v$NodeMin, EOL: corp IT cleanup uninstalls it) -- upgrading" }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    $msi = Join-Path $env:TEMP ($NodePin -split '/')[-1]
    Step "NODE: download $(($NodePin -split '/')[-1])"
    try { Start-BitsTransfer -Source $NodePin -Destination $msi -DisplayName 'download node msi' -ErrorAction Stop }
    catch { Write-Host "  NODE: BITS failed ($($_.Exception.Message)), plain download"
            try { Invoke-WebRequest -UseBasicParsing $NodePin -OutFile $msi } catch { Write-Host "  NODE: download failed: $($_.Exception.Message)" } }
    if (Test-Path $msi) { Step 'NODE: msiexec /qn (silent install)'
        Live 'msiexec.exe' @('/i', $msi, '/qn', '/norestart') -What 'install node.js msi' -Timeout 900
        Remove-Item $msi -ErrorAction SilentlyContinue }
    if (-not (HaveNode)) { WingetInstall 'OpenJS.NodeJS.LTS' 'NODE' }
    if (HaveNode) { Emit 'NODE' "did $(if ($nv0) { "upgrade $nv0 ->" } else { 'install' }) Node.js: $NodeExe ($(NodeVer))" }
    else { Emit 'NODE' "FAIL $NodeExe $(if (NodeVer) { "is $(NodeVer) (< v$NodeMin)" } else { 'absent' }) after install (rc=$($script:rc)) -- tserver (stage 6) cannot mint the ADO token; log: $LogFile" }
}

# EXCEL: dogfood Excel (plan 01 Phase R).  wserver drives the LOCAL Excel; the OfficeAgent add-in loads only on a
# Dogfood::DevMain build.  Target = the DevMain CDN build proven on c17/fleet (16.0.20306.20002); a NEWER DevMain
# build already there is kept (no downgrade); 20301 is never accepted (deterministic mso40uiwin32client.dll crash on
# the Copilot FAB, OfficeAgent KNOWN-ISSUES F24).  Auto-update off at 3 layers so the pin holds.
$ExcelPin    = $(if ($env:WS_EXCEL_PIN) { $env:WS_EXCEL_PIN } else { '16.0.20306.20002' })
$DevMainGuid = 'ea4a4090-de26-49d7-93c1-91bff9e53fc3'
$DevMainCdn  = "http://officecdn.microsoft.com/pr/$DevMainGuid"
$OdtUrl      = 'https://officecdn.microsoft.com/pr/wsus/setup.exe'
$ExcelExe    = "$env:ProgramFiles\Microsoft Office\root\Office16\EXCEL.EXE"
$C2rCfg      = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
$OfficePol   = 'HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\OfficeUpdate'
function ExcelBuild([string]$v) { $p = "$v" -split '\.'; if ($p.Count -ge 3 -and $p[2] -match '^\d+$') { [int]$p[2] } else { 0 } }
function ExcelNeed([string]$ver, [string]$aud, [string]$upd, [string]$pin = '16.0.20306.20002') {
    # -> 'none' | 'updates-off' | 'install'   (pure: unit-tested by test/bootstrap.test.sh (g))
    $b = ExcelBuild $ver
    if (-not $ver -or $aud -ne 'Dogfood::DevMain' -or $b -eq 20301 -or $b -lt (ExcelBuild $pin)) { return 'install' }
    if ("$upd" -ne 'False') { return 'updates-off' }
    return 'none'
}
# Office auto-update off -- parity with OfficeAgent eval/host/install/disable-office-updates.ps1 (the cluster's own
# harness only verifies; OA is the source): it rolled DevMain back to Beta/InsiderFast and dropped the add-in flights.
# Any ONE layer can turn updates back on, so ALL must hold: (1) HKLM policy enableautomaticupdates=0 + updatetoversion
# pinned to the installed build + updatepath on the DevMain CDN (never updatebranch=InsiderFast: 5440fd1f is not DevMain);
# (2) C2R Configuration UpdatesEnabled=False + UpdateChannel/UpdateUrl on the DevMain CDN (a Cloud PC was found with
# UpdateChannel=InsiderFast); (3) every updater-family scheduled task disabled; (4) a running OfficeC2RClient is killed so
# it cannot re-persist the old values.
$OfficeUpdTasks = @('Office Automatic Updates*','Office Feature Updates*','OfficeTelemetry*','Office ClickToRun Service*',
                    '*OfficeUpdate*','Office Serviceability Manager*','Office Background Push Maintenance*')
function OfficeUpdTaskOn { @(Get-ScheduledTask -TaskPath '\Microsoft\Office\' -ErrorAction SilentlyContinue | Where-Object { $n = $_.TaskName; $_.State -ne 'Disabled' -and ($OfficeUpdTasks | Where-Object { $n -like $_ }) }) }
function ExcelState {
    $v = ''; if (Test-Path -LiteralPath $ExcelExe) { $v = (Get-Item -LiteralPath $ExcelExe).VersionInfo.ProductVersion }
    $c = Get-ItemProperty $C2rCfg -ErrorAction SilentlyContinue
    $tasks = @(OfficeUpdTaskOn)   # @(): no enabled task returns NOTHING, and $null.Count read as "" -> upd stayed True on a fully-off box
    $p = Get-ItemProperty $OfficePol -ErrorAction SilentlyContinue; $pol = $p.enableautomaticupdates
    $chan = $(if ("$($c.UpdateChannel)$($c.UpdateUrl)" -and ("$($c.UpdateChannel)" -notmatch $DevMainGuid -or "$($c.UpdateUrl)" -notmatch $DevMainGuid)) { 'off-devmain' } else { 'devmain' })
    $pin = $(if ($v -and "$($p.updatetoversion)" -ne $v) { 'unpinned' } else { 'pinned' })
    # updates count as off only when EVERY layer holds
    $upd = $(if ("$($c.UpdatesEnabled)" -eq 'False' -and $pol -eq 0 -and $tasks.Count -eq 0 -and $chan -eq 'devmain' -and $pin -eq 'pinned') { 'False' } else { 'True' })
    [pscustomobject]@{ ver = $v; aud = "$($c.AudienceData)"; upd = $upd; c2rUpd = "$($c.UpdatesEnabled)"; pol = $pol; tasks = $tasks.Count; chan = $chan; pin = $pin }
}
function ExcelUpdatesOff {
    foreach ($n in @('OfficeC2RClient','OfficeClickToRun')) { Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
    if (-not (Test-Path $OfficePol)) { New-Item -Path $OfficePol -Force | Out-Null }
    Set-ItemProperty -Path $OfficePol -Name 'enableautomaticupdates' -Value 0 -Type DWord
    Set-ItemProperty -Path $OfficePol -Name 'hideupdatenotifications' -Value 1 -Type DWord
    Set-ItemProperty -Path $OfficePol -Name 'updatepath' -Value $DevMainCdn -Type String
    Remove-ItemProperty -Path $OfficePol -Name 'updatebranch','updatedeadline' -ErrorAction SilentlyContinue
    $v = $(if (Test-Path -LiteralPath $ExcelExe) { (Get-Item -LiteralPath $ExcelExe).VersionInfo.ProductVersion } else { '' })
    if ($v) { Set-ItemProperty -Path $OfficePol -Name 'updatetoversion' -Value $v -Type String }   # the build we HAVE (never downgrade a newer DevMain)
    if (Test-Path $C2rCfg) {
        Set-ItemProperty -Path $C2rCfg -Name 'UpdatesEnabled' -Value 'False' -Type String
        Set-ItemProperty -Path $C2rCfg -Name 'UpdateChannel' -Value $DevMainCdn -Type String
        Set-ItemProperty -Path $C2rCfg -Name 'UpdateUrl' -Value $DevMainCdn -Type String
        Set-ItemProperty -Path $C2rCfg -Name 'CDNBaseUrl' -Value $DevMainCdn -Type String   # a stale Beta 492350f6 base breaks revert (cluster provision-left C-revert)
    }
    OfficeUpdTaskOn | ForEach-Object { Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue | Out-Null }
}
$xs = ExcelState
Emit 'EXCEL_NOW' "$(if ($xs.ver) { $xs.ver } else { 'ABSENT' }) audience=$(if ($xs.aud) { $xs.aud } else { '-' }) updates=$(if ($xs.upd -eq 'False') { 'off' } else { "on(c2r=$($xs.c2rUpd) policy=$($xs.pol) tasks=$($xs.tasks) channel=$($xs.chan) version=$($xs.pin))" })"
$need = ExcelNeed $xs.ver $xs.aud $xs.upd $ExcelPin
if ($env:WS_SKIP_EXCEL -eq '1') { Emit 'EXCEL' 'skip (WS_SKIP_EXCEL=1)' }
elseif ((ExcelBuild $ExcelPin) -eq 20301) { Emit 'EXCEL' "FAIL WS_EXCEL_PIN=$ExcelPin is 20301 (Copilot FAB crash) -- pin 20306 or later" }
elseif ($need -eq 'none') { Emit 'EXCEL' "ok $($xs.ver) $($xs.aud), auto-update off" }
elseif ($Apply -and -not $isAdmin) { Emit 'EXCEL' "FAIL need an elevated PowerShell to $need dogfood Excel" }
elseif (-not $Apply) { Emit 'EXCEL' $(if ($need -eq 'install') { "WOULD install dogfood Excel $ExcelPin (Dogfood::DevMain, ODT from the DevMain CDN, ~4 GB / ~7 min) + turn Office auto-update off" } else { 'WOULD turn Office auto-update off (policy + version pin + C2R channel=DevMain + scheduled tasks)' }) }
elseif ($need -eq 'updates-off') {
    Step 'EXCEL: dogfood build already there -- turning Office auto-update off'
    ExcelUpdatesOff; $xs = ExcelState
    if ($xs.upd -eq 'False') { Emit 'EXCEL' "did turn auto-update off; ok $($xs.ver) $($xs.aud)" } else { Emit 'EXCEL' "FAIL auto-update still on (c2r=$($xs.c2rUpd) policy=$($xs.pol) tasks=$($xs.tasks) channel=$($xs.chan) version=$($xs.pin)) -- a Cloud PC/Intune Office policy may be re-applying it" }
}
elseif (Get-Process -Name EXCEL -ErrorAction SilentlyContinue) { Emit 'EXCEL' 'REFUSE Excel is running -- save your work, close Excel, then run this bootstrap again (the dogfood install force-closes Office)' }
else {
    $ok = $true
    try { $h = Invoke-WebRequest -UseBasicParsing -Method Head "$DevMainCdn/office/data/v64_$ExcelPin.cab"; $ok = ($h.StatusCode -eq 200) } catch { $ok = $false }
    if (-not $ok) { Emit 'EXCEL' "FAIL DevMain CDN no longer serves $ExcelPin (it keeps ~5 builds) -- set `$env:WS_EXCEL_PIN to a current DevMain build (never 20301) and run again" }
    else {
        $od = 'C:\temp\ws-office'; New-Item -ItemType Directory -Path $od -Force | Out-Null
        $setup = Join-Path $od 'setup.exe'; $xml = Join-Path $od 'dogfood-devmain.xml'
        # ODT setup.exe: the corp \\offdog share first (devbox: readable, user 2026-10-20), else the public CDN
        # (a WORKGROUP box cannot read the share -- cluster bin/excel-stage.sh).  Same tool either way; the BUILD
        # comes from the DevMain CDN in the XML below, never from the share (it holds no Office\Data).
        $share = '\\offdog\ODFServer\V2\OfficeChannelInstaller\setup.exe'
        $got = $false
        try { if (Test-Path -LiteralPath $share) { Step "EXCEL: Office Deployment Tool from $share"; Copy-Item -LiteralPath $share $setup -Force; $got = $true } } catch { Write-Host "  EXCEL: $share not readable ($($_.Exception.Message))" }
        if (-not $got) {
            Step "EXCEL: download the Office Deployment Tool ($OdtUrl)"
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
            try { $ProgressPreference = 'Continue'; Invoke-WebRequest -UseBasicParsing $OdtUrl -OutFile $setup } catch { Write-Host "  EXCEL: download failed: $($_.Exception.Message)" }
        }
        @"
<Configuration>
  <Add SourcePath="$DevMainCdn" OfficeClientEdition="64" MigrateArch="TRUE" Version="$ExcelPin">
    <Product ID="O365ProPlusRetail">
      <Language ID="en-us"/>
      <ExcludeApp ID="Groove"/>
    </Product>
  </Add>
  <Updates Enabled="FALSE" UpdatePath="$DevMainCdn"/>
  <Display Level="Full" AcceptEULA="TRUE"/>
  <Logging Level="Standard" Path="$od"/>
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE"/>
</Configuration>
"@ | Out-File $xml -Encoding ASCII
        if (-not (Test-Path $setup)) { Emit 'EXCEL' "FAIL could not download $OdtUrl" }
        else {
            # F29 (OfficeAgent runbook): the per-user add-in manifest cache survives install AND uninstall and
            # carries the old build's add-in state -> wipe it while Office is closed.
            foreach ($t in @("$env:LOCALAPPDATA\Microsoft\Office\16.0\Wef", "$env:LOCALAPPDATA\Microsoft\Office\16.0\WebServiceCache")) {
                if (Test-Path $t) { Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "  EXCEL: wiped $t" } }
            Get-Process -Name 'WINWORD','POWERPNT','OUTLOOK','ONENOTE','ms-teams','OneDrive' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            # stale corp pins would drag the install back to the corp build
            Remove-ItemProperty -Path $OfficePol -Name 'updatetoversion','updatedeadline' -ErrorAction SilentlyContinue
            # 1st: IN PLACE.  Click-to-Run is ONE platform: /configure with the DevMain SourcePath + Version moves
            #      every installed product (Excel, Visio, ...) to that channel + build -- no uninstall needed.
            Step "EXCEL: setup.exe /configure -> dogfood Excel $ExcelPin IN PLACE (Dogfood::DevMain; ~4 GB from the CDN, ~7 min; Office apps are closed) -- the Office installer window shows the download/install %; no clicks needed"
            Live $setup @('/configure', $xml) -What "install dogfood Excel $ExcelPin" -Timeout 3600
            $xs = ExcelState; $how = 'in place'
            if ((ExcelNeed $xs.ver $xs.aud 'False' $ExcelPin) -ne 'none') {
                # 2nd: the in-place switch did not land (EXCEL.EXE / audience still the corp build) -> remove ALL
                #      Click-to-Run products (ODT <Remove All>, silent -- not the runbook's interactive .bat), then
                #      a clean install.  The other Office apps come back from the same O365ProPlusRetail product.
                Write-Host "  EXCEL: in-place switch left $($xs.ver) audience=$($xs.aud) -- removing Office, then a clean install" -ForegroundColor Yellow
                $rm = Join-Path $od 'remove-all.xml'
                '<Configuration><Remove All="TRUE"/><Display Level="Full" AcceptEULA="TRUE"/><Property Name="FORCEAPPSHUTDOWN" Value="TRUE"/></Configuration>' | Out-File $rm -Encoding ASCII
                Step 'EXCEL: setup.exe /configure remove-all.xml (uninstall every Click-to-Run product)'
                Live $setup @('/configure', $rm) -What 'uninstall Office (Click-to-Run)' -Timeout 1800
                Step "EXCEL: setup.exe /configure -> dogfood Excel $ExcelPin (clean install)"
                Live $setup @('/configure', $xml) -What "install dogfood Excel $ExcelPin" -Timeout 3600
                $how = 'after uninstall'
            }
            # F19 (OfficeAgent runbook): a fresh install may not reflect VFS -> Common Files\Microsoft Shared\Office16
            foreach ($pair in @(@("$env:ProgramFiles\Microsoft Office\root\vfs\ProgramFilesCommonX64\Microsoft Shared\Office16", "$env:ProgramFiles\Common Files\Microsoft Shared\Office16"),
                                @("$env:ProgramFiles\Microsoft Office\root\vfs\ProgramFilesCommonX86\Microsoft Shared\Office16", "${env:ProgramFiles(x86)}\Common Files\Microsoft Shared\Office16"))) {
                if ((Test-Path $pair[0]) -and -not (Test-Path $pair[1])) { Copy-Item -Path $pair[0] -Destination $pair[1] -Recurse -Force; Write-Host "  EXCEL: staged $($pair[1])" } }
            ExcelUpdatesOff
            $xs = ExcelState; $need = ExcelNeed $xs.ver $xs.aud $xs.upd $ExcelPin
            if ($need -eq 'none') { Emit 'EXCEL' "did install dogfood Excel $($xs.ver) $($xs.aud) ($how), auto-update off -- reboot Windows before the first Excel run" }
            else { Emit 'EXCEL' "FAIL after setup.exe (rc=$($script:rc)): $($xs.ver) audience=$($xs.aud) updates=$($xs.upd) -- logs in $od" }
        }
    }
}

# M365 (cluster plan 96 H, bin/m365-sca.sh): Shared Computer Activation -- Office licenses this box without
# taking one of the account's ~5 device seats ("you've reached the device limit").  SCA licence = 30 days,
# Office renews it itself at each launch.  The seat files of an earlier activation are backed up then removed;
# seats already counted stay until removed at https://myaccount.microsoft.com/device-list (human).
$ScaK1 = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
$ScaK2 = 'HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\Licensing'
$SeatDir = "$env:LOCALAPPDATA\Microsoft\Office\Licenses\5"
function ScaOn { ("$((Get-ItemProperty $ScaK1 -ErrorAction SilentlyContinue).SharedComputerLicensing)" -eq '1') -and ("$((Get-ItemProperty $ScaK2 -ErrorAction SilentlyContinue).SharedComputerLicensing)" -eq '1') }
function Seats { @(Get-ChildItem -LiteralPath $SeatDir -File -ErrorAction SilentlyContinue).Count }
if ($env:WS_SKIP_M365 -eq '1') { Emit 'M365' 'skip (WS_SKIP_M365=1)' }
elseif (-not (Test-Path -LiteralPath $ExcelExe)) { Emit 'M365' 'n/a (no Office)' }
elseif ((ScaOn) -and (Seats) -eq 0) { Emit 'M365' 'ok shared computer activation on, 0 device-seat files' }
elseif (-not $Apply) { Emit 'M365' "WOULD turn on shared computer activation (SharedComputerLicensing=1 in C2R + policy) and back up/remove $(Seats) device-seat file(s) in $SeatDir" }
elseif (-not $isAdmin) { Emit 'M365' 'FAIL need an elevated PowerShell to turn on shared computer activation' }
else {
    Step 'M365: shared computer activation (no device seat; fixes the M365 device limit)'
    if (Test-Path $ScaK1) { Set-ItemProperty -Path $ScaK1 -Name 'SharedComputerLicensing' -Value '1' -Type String }
    if (-not (Test-Path $ScaK2)) { New-Item -Path $ScaK2 -Force | Out-Null }
    Set-ItemProperty -Path $ScaK2 -Name 'SharedComputerLicensing' -Value 1 -Type DWord
    $n = Seats; $bk = ''
    if ($n -gt 0) {
        if (Get-Process -Name EXCEL,WINWORD,POWERPNT,OUTLOOK -ErrorAction SilentlyContinue) { Write-Host '  M365: an Office app is running -- seat files left in place (close Office and run again to drop them)' -ForegroundColor Yellow }
        else {
            $bk = "C:\temp\ws-office\m365-backup.$(Get-Date -Format yyyyMMddTHHmm)"; New-Item -ItemType Directory -Path $bk -Force | Out-Null
            Copy-Item -Path "$SeatDir\*" -Destination $bk -Force; Remove-Item -Path "$SeatDir\*" -Force -ErrorAction SilentlyContinue
        }
    }
    if (ScaOn) { Emit 'M365' "did turn on shared computer activation; seat files $n -> $(Seats)$(if ($bk) { " (backup $bk)" }) -- the next Excel start signs in and mints a 30-day SCA licence; still blocked? remove old devices at https://myaccount.microsoft.com/device-list" }
    else { Emit 'M365' 'FAIL SharedComputerLicensing did not stick (an Intune/Cloud PC policy may own it)' }
}

# INIT
$here = $(if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { '' })
$local = $(if ($here) { Join-Path $here 'init.sh' } else { '' })
$url = $(if ($InitUrl) { $InitUrl } else { $DefaultInitUrl })
$src = ''; $init = $null
if ($local -and (Test-Path $local)) { $src = $local; $init = [IO.File]::ReadAllText($local) }
elseif ($url) { $src = $url; try { $init = (Invoke-RestMethod -UseBasicParsing $url) } catch { $init = $null } }
if (-not $User) { $User = "$env:USERNAME".ToLower() -replace '[^a-z0-9_-]', '' }
if ($User -notmatch '^[a-z][a-z0-9_-]{0,31}$') { $User = 'dev' }
$oneLiner = $(if ($url) { "curl -fsSL '$url' | WS_URL='$WsUrl' bash -s -- --apply" } else { "WS_URL='$WsUrl' bash init.sh --apply   # init.sh from the bootstrap gist" })
Step 'GCM: locate git-credential-manager.exe for WSL'
$GcmWin = GcmExe
$GitWin = (Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
Write-Host "  git.exe : $(if ($GitWin) { $GitWin } else { 'NOT FOUND' })" -ForegroundColor Cyan
$NodeWin = $(if (HaveNode) { $NodeExe } else { '' })
# the host's IPv4 DNS servers, for init.sh's DNS repair when the distro cannot resolve
$DnsWin = ''
try { $DnsWin = ((Get-DnsClientServerAddress -AddressFamily IPv4 -EA Stop | ForEach-Object { $_.ServerAddresses } | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notmatch '^(127|169\.254)\.' } | Select-Object -Unique) -join ' ') } catch {}
Write-Host "  node.exe: $(if ($NodeWin) { "$NodeWin ($((& $NodeWin --version 2>$null) -join ''))" } else { 'NOT FOUND (tserver stage 6 will give no token)' })" -ForegroundColor $(if ($NodeWin) { 'Green' } else { 'Red' })
if ($GcmWin) { Write-Host "  gcm     : $GcmWin" -ForegroundColor Green } else { Write-Host "  gcm     : NOT FOUND (see the 'tried' list above)" -ForegroundColor Red }
# init.sh job state, ONE line: done:<rc> | running:<pid> | gone.  Anything else is a failed probe (wsl.exe prints
# its own errors on stdout) and is never read as done (plan 05: a failed probe ended the watch as "rc=1").
$InitProbe = 'if [ -s /tmp/ws-init.rc ]; then echo done:$(tr -dc 0-9 < /tmp/ws-init.rc); elif [ -s /tmp/ws-init.pid ] && kill -0 $(cat /tmp/ws-init.pid) 2>/dev/null; then echo running:$(cat /tmp/ws-init.pid); else echo gone; fi'   # no double quotes: PS 5.1 does not escape them on a native argv
function WatchInit($probe, $tail, $p, [int]$Budget = 7200, [double]$Sleep = 5, [int]$Stall = 900, [int]$GoneMax = 24) {
    # -> @{state=DONE|FAILED|LOST|TIMEOUT; rc}.  TIMEOUT = budget spent AND output stalled $Stall s.  Only DONE/FAILED come from init.sh; a closed console is only logged.
    $sw = [Diagnostics.Stopwatch]::StartNew(); $gone = 0; $last = ''; $lastT = 0; $warned = $false; $cexit = $false; $stage = ''; $over = $false
    while ($true) {
        $s = "$(& $probe)".Trim()
        if ($s -match '^done:(\d+)$') { $rc = [int]$Matches[1]; Write-Host "  init: probe $s"; return @{ state = $(if ($rc) { 'FAILED' } else { 'DONE' }); rc = $rc } }
        if ($s -match '^running:\d+$') { $gone = 0 }
        elseif ($s -eq 'gone') { $gone++; if ($gone -ge $GoneMax) { Write-Host "  init: probe gone x$gone (no rc file, no live job)"; return @{ state = 'LOST'; rc = $null } } }
        else { Write-Host ("  init: probe error at {0}s (not done, retrying): {1}" -f [int]$sw.Elapsed.TotalSeconds, ($s -replace "`0", '')) }
        if ($p -and -not $cexit -and $p.HasExited) { $cexit = $true; Write-Host "  init: client-exit (console window closed rc=$($p.ExitCode)) -- still watching the WSL job" }
        $t = [int]$sw.Elapsed.TotalSeconds
        $tl = @(& $tail | ForEach-Object { ("$_" -replace "`0", '').Trim() } | Where-Object { $_ })
        foreach ($l in $tl) { if ($l -match '^STAGE=(\d+ \S+)') { $stage = $Matches[1] } }
        $cur = $(if ($tl.Count) { $tl[-1] } else { '' }); if ($cur.Length -gt 100) { $cur = $cur.Substring(0, 100) }
        if ($cur -ne $last) { $last = $cur; $lastT = $t; $warned = $false }
        elseif (-not $warned -and $t - $lastT -ge $Stall) { $warned = $true; Write-Host "  init: WARN no new output for $($t - $lastT)s (still watching): $cur" }
        # plan 05 D.2: the budget is NOT a wall clock.  A live job whose log still moves (stage 9 pulls a 4.2 GB
        # image) is kept; TIMEOUT only when the budget is spent AND nothing new was printed for $Stall s.
        if ($t -gt $Budget) {
            if ($t - $lastT -ge $Stall) { Write-Host "  init: TIMEOUT after ${t}s (budget ${Budget}s, no new output for $($t - $lastT)s): $cur"; return @{ state = 'TIMEOUT'; rc = $null } }
            if (-not $over) { $over = $true; Write-Host "  init: budget ${Budget}s passed, output still moving -- still watching" }
        }
        $act = $(if ($stage) { "init.sh after STAGE=$stage" } else { 'init.sh --apply (in the Ubuntu window)' })
        Write-Progress -Id 7 -Activity $act -Status ("{0}m{1:d2}s  {2}  {3}" -f [int][math]::Floor($t / 60), ($t % 60), $(if ($s -match '^running') { 'running' } else { 'waiting' }), $cur) -PercentComplete -1
        Start-Sleep -Milliseconds ([int](1000 * $Sleep))
    }
}
function RunInit([string]$mode) {   # init.sh via base64 (no CRLF / encoding mangling), stdin left to the console
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($init -replace "`r`n", "`n")))
    # init.sh goes over STDIN: its base64 (~33 KB) on the command line exceeds the 32767-char Windows limit
    # ("The filename or extension is too long" -- init.sh then never starts).  Only short commands go on argv.
    $null = ($b64 | & wsl.exe -d $script:D -u root -e sh -c "tr -d '\r\n' | base64 -d > /tmp/ws-init.sh" 2>&1)
    $cmd = "INIT_GCM_WIN='$GcmWin' INIT_GIT_WIN='$GitWin' INIT_NODE_WIN='$NodeWin' INIT_DNS_WIN='$DnsWin' INIT_USER='$User' WS_URL='$WsUrl' bash /tmp/ws-init.sh $mode; rc=`$?; rm -f /tmp/ws-init.sh; exit `$rc"
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    if ($mode -eq '--apply') {   # long (apt, clone + ADO auth, lfs, install.sh): run in its OWN Ubuntu window = a real tty,
        # so apt / git clone / lfs draw their native progress and a credential prompt can be answered there.
        # `script` keeps the pty AND logs to /tmp/ws-init.out; this window shows a progress bar + the last log line.
        $ErrorActionPreference = $old
        $run = "echo `$`$ > /tmp/ws-init.pid; [ -f /tmp/ws-init.out ] && mv -f /tmp/ws-init.out /tmp/ws-init.`$(date -u +%Y%m%dT%H%M%SZ -r /tmp/ws-init.out).out; " +
               "export INIT_GCM_WIN='$GcmWin' INIT_GIT_WIN='$GitWin' INIT_NODE_WIN='$NodeWin' INIT_DNS_WIN='$DnsWin' INIT_USER='$User'; if command -v script >/dev/null; then WS_URL='$WsUrl' script -qefc 'bash /tmp/ws-init.sh --apply' /tmp/ws-init.out; " +
               "else WS_URL='$WsUrl' bash /tmp/ws-init.sh --apply 2>&1 | tee /tmp/ws-init.out; fi; rc=`$?; rm -f /tmp/ws-init.sh; echo `$rc > /tmp/ws-init.rc; " +
               "if [ `$rc != 0 ]; then echo; echo 'init.sh FAILED (rc='`$rc') -- see the FAIL line above; press Enter to close'; read x; fi; exit `$rc"
        Step "INIT: init.sh --apply as root in a NEW Ubuntu window ($($script:D)) -- type the password for WSL user '$User' there, then watch apt / git clone / sign-in"
        $path = (Get-Command wsl.exe).Source
        # Windows Terminal when present (readable font; user ruling 2026-10-19).  $env:WS_WT=0 forces the classic wsl.exe console.
        # The command goes to a file first: wt treats ';' as its own separator, so it must not see $run.
        $rb64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($run))
        $probe = { "$(& wsl.exe -d $script:D -u root -e sh -c $InitProbe 2>&1)" }
        $p = $null; $s0 = & $probe
        if ($s0 -match '^running:\d+$') { Write-Host "  init: re-attach: an init.sh job is already running ($s0) -- watching it, not starting a second one" }
        else {
        $null = ($rb64 | & wsl.exe -d $script:D -u root -e sh -c "rm -f /tmp/ws-init.rc /tmp/ws-init.pid; tr -d '\r\n' | base64 -d > /tmp/ws-run.sh" 2>&1)
        $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
        Write-Host "  init: window=$(if ($wt -and $env:WS_WT -ne '0') { 'wt' } else { 'classic' })"
        if ($wt -and $env:WS_WT -ne '0') {
            Start-Process -FilePath $wt.Source -ArgumentList ((@('-w', 'new', 'new-tab', '--title', 'workspace init', $path, '-d', $script:D, '-u', 'root', '-e', 'bash', '/tmp/ws-run.sh') | ForEach-Object { Q $_ }) -join ' ')
            $p = $null
        } else {
            $p = Start-Process -FilePath $path -ArgumentList ((@('-d', $script:D, '-u', 'root', '-e', 'bash', '/tmp/ws-run.sh') | ForEach-Object { Q $_ }) -join ' ') -PassThru
            $null = $p.Handle
        }
        }
        $tailF = { & wsl.exe -d $script:D -u root -e sh -c "tail -c 200000 /tmp/ws-init.out 2>/dev/null | tr '\r' '\n' | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' | grep -av '^[[:space:]]*$' | { grep -a '^STAGE=' | tail -n 1; } ; tail -c 4000 /tmp/ws-init.out 2>/dev/null | tr '\r' '\n' | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' | grep -av '^[[:space:]]*$' | tail -n 1" 2>$null }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $w = WatchInit $probe $tailF $p
        Write-Progress -Id 7 -Activity 'init.sh' -Completed
        $script:initState = $w.state
        $script:rc = $(if ($w.state -in @('DONE', 'FAILED')) { $w.rc } else { 1 })
        $script:initOut = @(& wsl.exe -d $script:D -u root -e sh -c "tr '\r' '\n' < /tmp/ws-init.out 2>/dev/null | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' | grep -aE '^[A-Z_]+='" 2>$null | ForEach-Object { ("$_" -replace "`0", '').Trim() } | Where-Object { $_ })
        foreach ($l in $script:initOut) { Write-Host "  init: $l" }
        Write-Host ("  init: {0} rc={1} in {2}s  (full log in the distro: /tmp/ws-init.out)" -f $w.state, $script:rc, [int]$sw.Elapsed.TotalSeconds)
        return
    }
    Step "INIT: init.sh $mode as root in $($script:D) (live output below)"
    $script:initOut = @(& wsl.exe -d $script:D -u root -e bash -c $cmd 2>&1 | ForEach-Object { $l = "$_"; Write-Host "  init: $l"; $l }); $script:rc = $LASTEXITCODE
    $ErrorActionPreference = $old
}
function InitPending {   # the watch ended without the job's rc: say so, never call it an init.sh failure
    if ($script:initState -notin @('LOST', 'TIMEOUT')) { return $false }
    Emit 'INIT' "PENDING watch ended ($($script:initState)) without init.sh's result -- the WSL job may still run (log: wsl -d $($script:D) -u root tail /tmp/ws-init.out); re-run this bootstrap to re-attach"
    return $true
}
if (-not $init) { Emit 'INIT' "FAIL could not download init.sh from $url -- check the network, then run this bootstrap again"; return (Done) }
# WSLNET -- a devbox runs WSL in NAT (the WSL default).  MEASURED 2026-10-19 on a Global Secure Access devbox:
# mirrored resolves archive.ubuntu.com but every connect is "Network is unreachable"; NAT works.
# So .wslconfig is ALWAYS exactly [wsl2] networkingMode=nat vmIdleTimeout=-1 memory=<75% host>GB swap=16GB (old file -> .ws-bak; takes effect
# on the next VM start).  Only when the distro cannot reach archive.ubuntu.com NOW: the distro's DNS pins are
# removed and `wsl --shutdown` runs -- and only when nothing is running.
$DevWslCfg = [ordered]@{ networkingMode = 'nat'; vmIdleTimeout = '-1' }
# A cluster-enrolled box (cluster bin/box-bootstrap.sh) runs MIRRORED: peers reach its 10.30 address on :2200/:2222.
# Rewriting it to NAT hid helix from the fleet (2026-10-30).  So an existing networkingMode=mirrored is KEPT
# (NetOk below still falls back to NAT + wsl --shutdown if the mirrored distro has no network); WS_NET=nat|mirrored forces it.
$curNet = $null; $wcf = Join-Path $env:USERPROFILE '.wslconfig'
if (Test-Path $wcf) { $m = Select-String -Path $wcf -Pattern '^\s*networkingMode\s*=\s*(\w+)' | Select-Object -First 1; if ($m) { $curNet = $m.Matches[0].Groups[1].Value.ToLower() } }
if ($env:WS_NET -in @('nat', 'mirrored')) { $DevWslCfg['networkingMode'] = $env:WS_NET }
elseif ($curNet -eq 'mirrored') { $DevWslCfg['networkingMode'] = 'mirrored' }
# WSLMEM -- memory = 75% of host RAM + swap=16GB (cluster fix.archive/wsl-memory-75pct.md, port of bin/wslcfg-mem.sh).
# With no memory= WSL caps the VM at 50% of host RAM: MEASURED 2026-10-25 cj02 (64G host) OOM-killed 4x at 31G.
# Raise only: a larger memory=/swap= already in .wslconfig is kept.  Applies on the next WSL start, like the rest.
function WslCfgGB($key) {   # current [wsl2] value of $key in GB (0 if absent); NNGB / NNMB / NNTB / bytes
    $f = Join-Path $env:USERPROFILE '.wslconfig'; if (-not (Test-Path $f)) { return 0 }
    $in = $false
    foreach ($l in Get-Content $f) {
        $t = $l.Trim(); if ($t -match '^\[(.+)\]$') { $in = ($Matches[1] -eq 'wsl2'); continue }
        if ($in -and $t -match "^$key\s*=\s*([0-9.]+)\s*([A-Za-z]*)") {
            $n = [double]$Matches[1]; $u = $Matches[2].ToUpper()
            if ($u -like 'T*') { $n *= 1024 } elseif ($u -like 'M*') { $n /= 1024 } elseif ($u -notlike 'G*') { $n /= 1GB }
            return [int][math]::Floor($n)
        }
    }
    return 0
}
$WslMemPct = $(if ($env:WSLMEM_PCT) { [int]$env:WSLMEM_PCT } else { 75 })
$WslSwapGB = $(if ($env:WSLMEM_SWAP_GB) { [int]$env:WSLMEM_SWAP_GB } else { 16 })
$hostGB = 0; try { $hostGB = [int][math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB) } catch { }
if ($hostGB -gt 0) {
    $memGB = [math]::Max([int][math]::Floor($hostGB * $WslMemPct / 100), (WslCfgGB 'memory'))
    $DevWslCfg['memory'] = "${memGB}GB"
}
$DevWslCfg['swap'] = "$([math]::Max($WslSwapGB, (WslCfgGB 'swap')))GB"
function NetOk {   # DNS AND a TCP connect to archive.ubuntu.com:80 -- "resolves but Network is unreachable" is NOT ok
    $o = InDistro 'timeout 6 getent ahosts archive.ubuntu.com >/dev/null 2>&1 || exit; timeout 10 bash -c "exec 3<>/dev/tcp/archive.ubuntu.com/80" 2>/dev/null && echo NETOK'
    return [bool]($o -match 'NETOK')
}
function WslCfgSet($want) {   # CLEAN: .wslconfig becomes exactly the fleet file ([wsl2] + $want, nothing else); returns $true if it changed
    # Extra keys from manual tries (dnsTunneling, firewall, [experimental], proxies) are what broke devboxes:
    # with Global Secure Access, WSL disables DNS tunneling anyway.
    $f = Join-Path $env:USERPROFILE '.wslconfig'
    $out = @('[wsl2]') + @($want.Keys | ForEach-Object { "$_=$($want[$_])" })
    $cur = @(); if (Test-Path $f) { $cur = @(Get-Content $f | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) }
    if (($cur -join "`n") -eq ($out -join "`n")) { return $false }
    if (Test-Path $f) { Copy-Item $f "$f.ws-bak" -Force; foreach ($l in $cur) { Write-Host "    wslconfig-old: $l" } }
    [IO.File]::WriteAllLines($f, [string[]]$out)   # no BOM: WSL ignores a .wslconfig that starts with one
    return $true
}
function FixWslNet {
    $desc = ($DevWslCfg.Keys | ForEach-Object { "$_=$($DevWslCfg[$_])" }) -join ' '
    $net = NetOk
    $f = Join-Path $env:USERPROFILE '.wslconfig'
    $want = @('[wsl2]') + @($DevWslCfg.Keys | ForEach-Object { "$_=$($DevWslCfg[$_])" })
    $isNat = (Test-Path $f) -and ((@(Get-Content $f | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join "`n") -eq ($want -join "`n"))
    $state = $(if ($net) { 'ok net;' } else { 'net BROKEN;' })
    if (-not $Apply) {
        Emit 'WSLNET' ("$state {0}" -f $(if ($isNat) { ".wslconfig already [wsl2] $desc" } else { "WOULD set .wslconfig [wsl2] $desc" + $(if ($net) { ' (applies on next WSL start)' } else { ' + wsl --shutdown' }) }))
        $script:netOk = $true; return
    }
    if (InWsl) {
        if ($net) { Emit 'WSLNET' "ok net (running inside WSL: .wslconfig not checked)"; $script:netOk = $true }
        else { Emit 'WSLNET' "REFUSE distro network is broken; from Windows PowerShell set .wslconfig [wsl2] $desc and run wsl --shutdown"; $script:netOk = $false }
        return
    }
    $changed = WslCfgSet $DevWslCfg   # always NAT; takes effect on the next VM start
    if ($net) { Emit 'WSLNET' ("ok net; .wslconfig {0}" -f $(if ($changed) { "set to [wsl2] $desc (applies on next WSL start; no restart now)" } else { "already [wsl2] $desc" })); $script:netOk = $true; return }
    $busy = @()
    foreach ($d in @(Distros | Where-Object { $_.state -eq 'Running' })) {
        $busy += @(Native 'wsl.exe' @('-d', $d.name, '-u', 'root', '-e', 'sh', '-c', 'command -v docker >/dev/null && docker ps -q 2>/dev/null; command -v tmux >/dev/null && tmux ls 2>/dev/null') -Timeout 30 | Where-Object { $_ -match '\S' })
    }
    if ($busy.Count) { Emit 'WSLNET' "REFUSE distro network is broken; .wslconfig is now [wsl2] $desc but running containers/tmux ($($busy.Count)) block the restart -- stop them, then: wsl --shutdown ; and run this again"; $script:netOk = $false; return }
    if ($DevWslCfg['networkingMode'] -eq 'mirrored' -and $env:WS_NET -ne 'mirrored') { $DevWslCfg['networkingMode'] = 'nat'; $null = WslCfgSet $DevWslCfg; $desc = ($DevWslCfg.Keys | ForEach-Object { "$_=$($DevWslCfg[$_])" }) -join ' ' }
    Step "WSLNET: distro network is broken; .wslconfig = [wsl2] $desc; restarting the WSL VM (wsl --shutdown) -- nothing was running"
    # earlier DNS pins (static resolv.conf, generateResolvConf=false) would override WSL's own DNS
    $null = InDistro "sed -i '/^generateResolvConf/d' /etc/wsl.conf 2>/dev/null; [ -L /etc/resolv.conf ] || rm -f /etc/resolv.conf"
    Native 'wsl.exe' @('--shutdown') -Timeout 60 | Out-Null
    Start-Sleep -Seconds 8
    $null = DistroVer
    if (NetOk) { Emit 'WSLNET' "did .wslconfig [wsl2] $desc + wsl --shutdown; net ok"; $script:netOk = $true; return }
    # not fatal: init.sh's NET step reports it again before apt
    Emit 'WSLNET' "WARN archive.ubuntu.com unreachable from WSL with [wsl2] $desc (Windows reaches it) -- check VPN / proxy"; $script:netOk = $true
}
$distroUp = [bool](Distros | Where-Object { $_.name -eq $script:D })
if (-not $Apply) {
    if ($distroUp) { FixWslNet; RunInit '--dry-run' }
    Emit 'INIT' "WOULD run init.sh --apply ($src) as root in $($script:D): WS_URL=$WsUrl -> /workspace + ./install.sh"
    Emit 'WIN' $(if ($env:WS_SKIP_WIN -eq '1') { 'skip (WS_SKIP_WIN=1)' } else { 'WOULD run install.ps1 from the distro (WV2 PIN SHIM WEF ASR SSH DOCKER VMBOOT)' })
    Emit 'BENCH' $(if ($env:WS_SKIP_BENCH -eq '1') { 'skip (WS_SKIP_BENCH=1)' } else { 'WOULD run install.sh 10 (bench-ctxcore.sh --fix --make-lane-on, --check)' })
    Write-Output $(if ($env:WS_REPORT -eq '0') { 'REPORT=skip (WS_REPORT=0)' } else { 'REPORT=WOULD run bin/install-report.sh (collect, redact, commit, push the install evidence)' })
    Emit 'SMOKE' $(if ($env:WS_SMOKE -eq '0' -or $env:WS_SKIP_BENCH -eq '1') { 'skip (WS_SMOKE=0)' } else { 'WOULD run bin/smoke-addup.sh after the CLI opens (Excel add-up, window kept open)' })
    return (Done)
}
if (-not $distroUp) { Emit 'INIT' "FAIL distro $($script:D) not registered"; return (Done) }
FixWslNet
if (-not $script:netOk) { return (Done) }
RunInit '--apply'
if (InitPending) { return (Done 'PENDING') }
$r = ($script:initOut | Where-Object { $_ -match '^RESULT=' } | Select-Object -Last 1) -replace '^RESULT=', ''
if ($r -eq 'RESTART_NEEDED') {
    $restartCmd = "wsl --terminate $($script:D)"
    if (InWsl) { Emit 'RESTART' "REFUSE running from inside WSL -- from a Windows PowerShell run: $restartCmd ; then run this again"; return (Done 'REFUSED') }
    $busy = @(InDistro 'command -v docker >/dev/null && docker ps -q 2>/dev/null; command -v tmux >/dev/null && tmux ls 2>/dev/null' | Where-Object { $_ -match '\S' })
    if ($busy.Count) { Emit 'RESTART' "REFUSE $($script:D) has running containers/tmux ($($busy.Count)) -- stop them, then: $restartCmd"; return (Done 'REFUSED') }
    Native 'wsl.exe' @('--terminate', $script:D) | Out-Null
    Emit 'RESTART' "did $restartCmd"
    RunInit '--apply'
    if (InitPending) { return (Done 'PENDING') }
    $r = ($script:initOut | Where-Object { $_ -match '^RESULT=' } | Select-Object -Last 1) -replace '^RESULT=', ''
}
Emit 'GCMPATH' "win=$(if ($GcmWin) { $GcmWin } else { 'NOT FOUND' }) git=$GitWin"
Emit 'NODEPATH' "win=$(if ($NodeWin) { $NodeWin } else { 'NOT FOUND' })"
if ($r -eq 'OK') {
    Emit 'INIT' "ok init.sh --apply in $($script:D)"
    WinTier
    BenchReady
    # Land the user in GHCP CLI inside the bench container, in its OWN window (init.sh runs install.sh with WS_CLI=0:
    # a TUI inside the init window filled /tmp/ws-init.out with binary and replaced the window).  $env:WS_CLI=0 skips.
    # BENCH FAIL -> a plain WSL root shell in /workspace instead (fix, then ./install.sh 10 opens the CLI itself).
    if ($env:WS_CLI -ne '0') {
        $path = (Get-Command wsl.exe).Source
        if ($script:benchOk) { $title = 'GHCP CLI (officeagent-dev)'
            $cli = @('-d', $script:D, '-u', 'root', '-e', 'docker', 'exec', '-it', '-w', '/workspace', 'officeagent-dev', 'bash', '-ic', 't main || echo "GHCP CLI exited rc=$? -- staying in the container shell (t = copilot in tmux, h = pick model, ec = emacs)" && exec bash -i') }
        else { $title = 'WSL /workspace (BENCH FAIL)'
            $cli = @('-d', $script:D, '-u', 'root', '--cd', '/workspace', '-e', 'bash', '-c', 'echo "BENCH FAIL -- fix the rows below, then ./install.sh 10 (opens GHCP CLI)" && bin/bench-ctxcore.sh --check && exec bash -i || exec bash -i') }
        # NO ';' in $cli: wt.exe splits its command line on ';' (a 2nd tab ran 'exec' -> 'cannot find the file specified')
        $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
        if ($wt -and $env:WS_WT -ne '0') { Start-Process -FilePath $wt.Source -ArgumentList ((@('-w', 'new', 'new-tab', '--title', $title, $path) + $cli | ForEach-Object { Q $_ }) -join ' ') }
        else { Start-Process -FilePath $path -ArgumentList (($cli | ForEach-Object { Q $_ }) -join ' ') }
        if (-not $script:benchOk) { Emit 'CLI' "NOT opened (BENCH FAIL) -- opened a WSL shell in /workspace; fix, then ./install.sh 10" }
        else { Emit 'CLI' "opened GHCP CLI in officeagent-dev:/workspace (new window; tmux 'main', detach C-b d). Later: wsl, then docker exec -it officeagent-dev bash -> t / h / ec" }
    }
    # SMOKE: one real turn through wserver (Excel + our pane -> aserver): new sheet Numbers 1..10, A11 = sum (55).
    # The Excel window is LEFT OPEN for the user; the next smoke closes only windows it kept itself.
    # $env:WS_SMOKE=0 skips.  bin/smoke-addup.sh settles the pane first (the NAA relay reloads it once ~10 s in).
    if ($script:benchOk -and $env:WS_SMOKE -ne '0' -and $env:WS_SKIP_BENCH -ne '1') {
        Step "SMOKE: ssg add-up via wserver (sheet Numbers 1..10, A11=SUM -> 55; Excel stays open)"
        $out = Native 'wsl.exe' @('-d', $script:D, '-u', 'root', '-e', 'bash', '-c', 'cd /workspace && bin/smoke-addup.sh') -Timeout 600 -Tag 'smoke'
        $line = (@(@($out) | Where-Object { $_ -match '^SMOKE ' } | Select-Object -Last 1) -join '') -replace '^SMOKE ', ''
        if (-not $line) { $line = "FAIL no SMOKE line rc=$($script:rc)" }
        $script:smokeLine = "SMOKE $line"
        if ($line -like 'ok*') { Emit 'SMOKE' $line } else { Emit 'SMOKE' "$line (re-run: wsl -u root, cd /workspace, bin/smoke-addup.sh)" }
    }
}
else {
    $why = @($script:initOut | Where-Object { $_ -match '=FAIL' }) -join '; '
    if (-not $why) { $why = "RESULT=$r rc=$($script:rc)" }
    Emit 'INIT' "FAIL $why -- fix that, then re-run this bootstrap (init.sh is idempotent: it does the git clone itself and skips what is done; log: wsl -d $($script:D) -u root cat /tmp/ws-init.out)"
}
# REPORT: bin/install-report.sh collects this install (result, errors, stage times, LFS/pull bandwidth, GCM/tserver/
# kiss-auth, SMOKE), redacts it, commits it to fix.archive/install-reports/<host>-<UTC>/ and pushes -- success
# AND failure, so every install reaches us.  Needs /workspace cloned (INIT got that far).  WS_REPORT=0 skips.
if ($env:WS_REPORT -ne '0') {
    $has = @(InDistro 'test -x /workspace/bin/install-report.sh && echo yes') -contains 'yes'
    if ($has) {
        Step "REPORT: bin/install-report.sh (collect + redact + commit + push the install evidence)"
        $q = { param($x) "'" + ("$x" -replace "'", "'\''") + "'" }
        $rcmd = "cd /workspace && bin/install-report.sh --bootstrap $(& $q "INIT=$r BENCH=$($script:benchOk) fail=$($script:fail)")"
        if ($script:smokeLine) { $rcmd += " --smoke $(& $q $script:smokeLine)" }
        $out = Native 'wsl.exe' @('-d', $script:D, '-u', 'root', '-e', 'bash', '-c', $rcmd) -Timeout 900 -Tag 'report'
        $line = (@(@($out) | Where-Object { $_ -match '^REPORT ' } | Select-Object -Last 1) -join '') -replace '^REPORT ', ''
        if (-not $line) { $line = "FAIL no REPORT line rc=$($script:rc)" }
        if ($line -like 'ok*') { Write-Output "REPORT=$line" } else { Write-Output "REPORT=WARN $line" }
    } else { Write-Output 'REPORT=skip (/workspace/bin/install-report.sh absent: INIT did not clone)' }
}
return (Done)
}
$script:exitCode = 0
$LogFile = Join-Path $env:TEMP 'ws-bootstrap.log'
# ELEVATE + PWSH: the real run needs (1) admin -- WSL/distro install, Excel/M365, and WIN's WebView2 149 pin (no pin
# -> Excel's WV2 150+ strips --ignore-certificate-errors -> pane "invalid security certificate", laptop 2026-10-30)
# and (2) PowerShell 7.6+ (pwsh): UTF-8 native pipes and sane wsl.exe/bash quoting, where 5.1 mangles both.
# Either missing -> write a launcher to %TEMP% and run it ELEVATED (one UAC prompt; already admin = no prompt): it
# installs the LATEST pwsh (GitHub releases/latest MSI; known MSI as fallback) if absent/<7.6, then re-runs this bootstrap in pwsh IN THAT WINDOW.
# An elevated process does not inherit our env, so WS_* + params are written into the launcher.
# Dry runs stay where they are; WS_NO_ELEVATE=1 opts out; UAC declined -> carry on here as before.
$PwshFallback = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.9/PowerShell-7.6.9-win-x64.msi'   # only if releases/latest is unreachable
$isAdminNow = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
              ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isPwsh76 = $PSVersionTable.PSVersion -ge [version]'7.6'
if ($Apply -and -not ($isAdminNow -and $isPwsh76) -and $env:WS_NO_ELEVATE -ne '1') {
    $kv = [ordered]@{}; Get-ChildItem Env: | Where-Object { $_.Name -like 'WS_*' } | ForEach-Object { $kv[$_.Name] = $_.Value }
    if ($AllowRestart) { $kv['WS_ALLOW_RESTART'] = '1' }; if ($Distro) { $kv['WS_DISTRO'] = $Distro }; if ($User) { $kv['WS_USER'] = $User }
    $kv['WS_NO_ELEVATE'] = '1'                                     # the relaunch never loops back here
    $set = ($kv.GetEnumerator() | ForEach-Object { "`$env:$($_.Key) = '$($_.Value -replace "'", "''")'" }) -join "`r`n"
    $run = $(if ($PSCommandPath) { "& '$($PSCommandPath -replace "'", "''")'" }
             else { "irm '$($DefaultInitUrl -replace '/init\.sh$', '/bootstrap.ps1')' | iex" })
    $launcher = Join-Path $env:TEMP 'ws-bootstrap-launch.ps1'
    @"
# written by bootstrap.ps1: admin + latest pwsh (>= 7.6), then the bootstrap again
$set
function PwshOk { `$p = @((Get-Command pwsh.exe -EA 0).Source, "`$env:ProgramFiles\PowerShell\7\pwsh.exe") | Where-Object { `$_ -and (Test-Path `$_) } | Select-Object -First 1
    if (`$p -and [version](((Get-Item `$p).VersionInfo.ProductVersion -split '[ -]')[0]) -ge [version]'7.6') { return `$p } }
`$pw = PwshOk
if (-not `$pw) {
    `$cache = Join-Path `$env:LOCALAPPDATA 'ws-bootstrap'; New-Item -ItemType Directory -Force `$cache | Out-Null
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    `$url = '$PwshFallback'
    try { `$url = (Invoke-RestMethod -UseBasicParsing 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -TimeoutSec 20).assets |
              Where-Object { `$_.name -like '*-win-x64.msi' } | Select-Object -First 1 -ExpandProperty browser_download_url } catch {}
    if (-not `$url) { `$url = '$PwshFallback' }
    `$msi = Join-Path `$cache ((`$url -split '/')[-1])
    if (-not (Test-Path `$msi)) { Write-Host "-- PWSH: download latest PowerShell (`$url)"
        try { Start-BitsTransfer -Source `$url -Destination "`$msi.part" -ErrorAction Stop } catch { Invoke-WebRequest -UseBasicParsing `$url -OutFile "`$msi.part" }
        Move-Item "`$msi.part" `$msi -Force }
    Write-Host "-- PWSH: install `$((`$msi -split '\\')[-1]) (msiexec, silent)"
    `$p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList @('/i', "``"`$msi``"", '/qn', '/norestart', 'ADD_PATH=1', 'REGISTER_MANIFEST=1')
    Write-Host "PWSH=msiexec rc=`$(`$p.ExitCode)"
    `$pw = PwshOk
}
if (`$pw) { Write-Host "PWSH=ok `$pw -- bootstrap continues in PowerShell `$((Get-Item `$pw).VersionInfo.ProductVersion) (Administrator)"
            & `$pw -NoExit -NoProfile -ExecutionPolicy Bypass -Command "$($run -replace '"', '`"')" }
else { Write-Host 'PWSH=WARN install failed -- bootstrap continues in Windows PowerShell 5.1 (Administrator)'; $run }
"@ | Set-Content -Encoding UTF8 $launcher
    if ($isAdminNow) {
        Write-Output "ELEVATE=already admin; PWSH=switching this window to PowerShell 7 (latest)"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher
        if ($PSCommandPath) { exit 0 }; return
    }
    Write-Output "ELEVATE=asking UAC: the install continues in a NEW Administrator window on PowerShell 7 (latest) (this one can be closed)"
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$launcher`"") -ErrorAction Stop | Out-Null
        Write-Output 'RESULT=ELEVATED (see the Administrator window)'
        if ($PSCommandPath) { exit 0 }; return
    } catch { Write-Output "ELEVATE=WARN UAC declined ($($_.Exception.Message)); continuing NOT elevated -- WSL/Excel installs and the WebView2 pin will fail" }
}
try { Start-Transcript -Path $LogFile -Append -ErrorAction Stop | Out-Null; $tr = $true } catch { $tr = $false }
Write-Host "-- log: $LogFile  (watch from another window: Get-Content -Wait '$LogFile')"
# AWAKE: a laptop that sleeps mid-install drops Wi-Fi, and apt / git clone / LFS / docker pull die as "network
# failure" (MEASURED 2026-10-30 on the new laptop).  SetThreadExecutionState(ES_CONTINUOUS|ES_SYSTEM_REQUIRED) holds
# off idle sleep while THIS PowerShell runs (it waits on init.sh + install.sh to the end) and is released in the
# finally -- and by Windows itself when the process exits, so nothing persists: no powercfg change.  A lid close or
# the Start-menu Sleep still sleeps the box (that is the user's action, not idle); WS_KEEP_AWAKE=0 skips.
$script:awake = $false
if ($env:WS_KEEP_AWAKE -ne '0') {
    try {
        Add-Type -Namespace WsBoot -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);' -ErrorAction Stop
        $script:awake = ([WsBoot.Power]::SetThreadExecutionState([uint32]'0x80000001') -ne 0)   # ES_CONTINUOUS|ES_SYSTEM_REQUIRED
    } catch {}
}
Write-Output "AWAKE=$(if ($script:awake) { 'ok (idle sleep held off until this bootstrap ends; keep the lid open)' } elseif ($env:WS_KEEP_AWAKE -eq '0') { 'skip' } else { 'WARN could not hold off sleep -- set Power to never sleep while installing' })"
try { Main }
finally {
    if ($script:awake) { try { [WsBoot.Power]::SetThreadExecutionState([uint32]'0x80000000') | Out-Null } catch {} }   # ES_CONTINUOUS alone = release
}
if ($tr) { try { Stop-Transcript | Out-Null } catch {} }
if ($PSCommandPath) { exit $script:exitCode }   # -File: rc; irm|iex: never close the console
