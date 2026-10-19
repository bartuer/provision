#!/usr/bin/env bash
# init.sh -- plan 01 G.2: turn a bare WSL distro into a workspace box.  Runs as ROOT inside WSL.
#   bash init.sh            dry-run (DEFAULT): prints KEY=ok|WOULD <action>|FAIL <why>, changes nothing
#   bash init.sh --apply    (or INIT_APPLY=1) does the work; acted steps print KEY=did <action>
# Steps: ROOT, OS (ubuntu 26.04), WS (refuse a foreign /workspace -- checked first, before anything changes), APT (git git-lfs
#   docker.io ca-certificates curl jq), DOCKERD (systemd -> enable --now; WSL without systemd -> [boot]
#   systemd=true in /etc/wsl.conf + RESTART NEEDED, never restarts itself), GCM (git credential.helper ->
#   the Windows Git Credential Manager under /mnt/c, so ADO auth pops on Windows), LFS (git lfs install),
#   CLONE (cd / && git clone $WS_URL workspace + submodule ssg_agent + git lfs pull; INIT_SUBMODULES=1 = every
#   submodule, shallow single-branch -- build boxes only), INSTALL (./install.sh).
# Last line RESULT=OK|PLAN|RESTART_NEEDED|REFUSED|FAIL.  rc: 0 OK/PLAN/RESTART_NEEDED, 1 FAIL, 2 REFUSED, 64 usage.
# Env: WS_URL, INIT_ANY_OS=1, WS_DIR (/workspace), INIT_APPLY=1, INIT_SKIP_INSTALL=1, INIT_SKIP_SUBMODULES=1,
#      INIT_SUBMODULES=1 (all submodules), INIT_SKIP_LFS=1,
#      INIT_GCM (explicit helper exe), INIT_MNT (/mnt/c).
# Idempotent: a 2nd --apply on a done box prints no `did` line.
set -u
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

WS_URL="${WS_URL:-https://dev.azure.com/MSRADKI/Excel/_git/workspace}"
WS_DIR="${WS_DIR:-/workspace}"
APPLY="${INIT_APPLY:-0}"
MNT="${INIT_MNT:-/mnt/c}"
PKGS="git git-lfs docker.io ca-certificates curl jq"
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --dry-run) APPLY=0 ;;
    -h|--help) echo "usage: init.sh [--apply|--dry-run]  (as root in WSL; dry-run is the default)"; exit 0 ;;
    *) echo "usage: init.sh [--apply|--dry-run]" >&2; exit 64 ;;
  esac
done

fail=0; restart=0
say() { echo "$1=$2"; }
bad() { echo "$1=FAIL $2"; fail=1; }
# act KEY "description" cmd... : dry-run -> WOULD, apply -> run it (did | FAIL)
planned=0
act() {
  local k="$1" d="$2"; shift 2
  if [ "$APPLY" != 1 ]; then say "$k" "WOULD $d"; planned=1; return 0; fi
  if "$@"; then say "$k" "did $d"; return 0; fi
  bad "$k" "$d"; return 1
}
finish() {
  if [ "${1:-}" = REFUSED ]; then echo "RESULT=REFUSED"; exit 2; fi
  if [ "$fail" != 0 ]; then echo "RESULT=FAIL"; exit 1; fi
  if [ "$restart" != 0 ]; then echo "RESULT=RESTART_NEEDED"; exit 0; fi
  if [ "$planned" != 0 ]; then echo "RESULT=PLAN"; exit 0; fi
  echo "RESULT=OK"; exit 0
}
is_wsl() { [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; }
norm()   { local u="${1%/}"; echo "${u%.git}"; }

say MODE "$([ "$APPLY" = 1 ] && echo apply || echo dry-run)"

# ROOT
if [ "$(id -u)" = 0 ]; then say ROOT ok; else bad ROOT "not root (run: wsl -u root ...)"; finish; fi

# OS -- the fleet is Ubuntu 26.04 only: emacs 30.1 + bin2md need GLIBC 2.43 (24.04 = 2.39).  INIT_ANY_OS=1 waives.
os_id="$( . /etc/os-release 2>/dev/null; echo "${ID:-?} ${VERSION_ID:-?}")"
if [ "$os_id" = "ubuntu 26.04" ]; then say OS "ok $os_id"
elif [ "${INIT_ANY_OS:-0}" = 1 ]; then say OS "ok $os_id (INIT_ANY_OS=1, not the fleet release)"
else bad OS "$os_id -- the fleet needs ubuntu 26.04 (wsl --install -d Ubuntu-26.04; INIT_ANY_OS=1 waives)"; finish; fi

# WS -- refuse before anything changes
ws_state=absent
if [ -e "$WS_DIR" ]; then
  if [ -e "$WS_DIR/.git" ]; then
    o="$(git -C "$WS_DIR" config --get remote.origin.url 2>/dev/null || true)"
    if [ "$(norm "$o")" = "$(norm "$WS_URL")" ]; then ws_state=clone; say WS "ok $WS_DIR is a clone of $WS_URL"
    else echo "WS=REFUSE $WS_DIR exists, origin '${o:-none}' != $WS_URL -- move it away by hand"; finish REFUSED; fi
  elif [ -d "$WS_DIR" ] && [ -z "$(ls -A "$WS_DIR" 2>/dev/null)" ]; then
    ws_state=empty; say WS "ok $WS_DIR empty"
  else
    echo "WS=REFUSE $WS_DIR exists and is not a workspace clone -- move it away by hand"; finish REFUSED
  fi
else
  say WS "ok $WS_DIR absent"
fi

# USER -- the WSL login user (`wsl --install --no-launch` skips Ubuntu's first-run, so none exists and wsl logs
# in as root).  INIT_USER (the bootstrap passes the Windows user name): create it (uid 1000 on a fresh distro,
# groups sudo + docker after APT), make it the [user] default in /etc/wsl.conf, and on a tty ask its password.
U="${INIT_USER:-}"
wslconf_set() {   # wslconf_set SECTION KEY VALUE -- every other line kept
  local f=/etc/wsl.conf t; t="$(mktemp)"
  if grep -qiE "^[[:space:]]*\[$1\]" "$f" 2>/dev/null; then
    awk -v s="[$1]" -v k="$2" -v v="$3" 'tolower($1)==s{print; print k"="v; ins=1; next}
         /^[[:space:]]*\[/{ins=0} ins && $0 ~ "^[[:space:]]*"k"[[:space:]]*="{next} {print}' "$f" > "$t"
  else { [ -s "$f" ] && cat "$f" && echo; printf '[%s]\n%s=%s\n' "$1" "$2" "$3"; } > "$t"; fi
  cat "$t" > "$f"; rm -f "$t"
}
user_do() {
  id "$U" >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo "$U" || return 1
  wslconf_set user default "$U"
  if [ -t 0 ] && [ -t 1 ]; then
    echo "== set the password for WSL user '$U' (used by sudo) =="
    until passwd "$U"; do echo "try again"; done
  fi
}
user_ok() { id "$U" >/dev/null 2>&1 && grep -qE "^[[:space:]]*default[[:space:]]*=[[:space:]]*$U[[:space:]]*$" /etc/wsl.conf 2>/dev/null; }
if [ -z "$U" ]; then say USER "skip (no INIT_USER)"
elif ! printf '%s' "$U" | grep -qE '^[a-z][a-z0-9_-]{0,31}$'; then bad USER "bad name '$U'"
elif user_ok; then
  if [ "$APPLY" = 1 ] && [ -t 0 ] && [ -t 1 ] && passwd -S "$U" 2>/dev/null | grep -qE "^$U (L|NP) "; then act USER "passwd $U" user_do
  else say USER "ok $U"; fi
else act USER "useradd $U (sudo), /etc/wsl.conf [user] default=$U, passwd" user_do; fi

# APT
missing=""
have_pkg() {   # a tool already on PATH counts (docker-ce instead of docker.io, a source-built git)
  case "$1" in
    git) command -v git >/dev/null 2>&1 && return 0 ;;
    git-lfs) command -v git-lfs >/dev/null 2>&1 && return 0 ;;
    docker.io) command -v docker >/dev/null 2>&1 && return 0 ;;
    curl) command -v curl >/dev/null 2>&1 && return 0 ;;
  esac
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'
}
for p in $PKGS; do have_pkg "$p" || missing="$missing $p"; done
apt_do() {   # on a tty (the bootstrap's Ubuntu window): apt's own progress; else quiet
  if [ -t 1 ]; then
    apt-get update && apt-get install -y --no-install-recommends $missing   # shellcheck disable=SC2086
  else
    apt-get update -qq >/dev/null 2>&1
    # shellcheck disable=SC2086
    apt-get install -y -qq --no-install-recommends $missing >/dev/null 2>&1
  fi
}
if [ -z "$missing" ]; then say APT ok; else act APT "apt-get install$missing" apt_do || finish; fi

# the login user may run docker
if [ "$APPLY" = 1 ] && [ -n "$U" ] && id "$U" >/dev/null 2>&1 && getent group docker >/dev/null && ! id -nG "$U" | grep -qw docker; then
  usermod -aG docker "$U" && say DOCKERGRP "did usermod -aG docker $U"
fi

# DOCKERD
docker_up()      { command -v docker >/dev/null 2>&1 && docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; }
has_systemd()    { [ -d /run/systemd/system ]; }
wslconf_systemd(){ grep -qiE '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true' /etc/wsl.conf 2>/dev/null; }
write_wslconf() {   # systemd=true under [boot]; every other line kept
  local f=/etc/wsl.conf t; t="$(mktemp)"
  if grep -qiE '^[[:space:]]*\[boot\]' "$f" 2>/dev/null; then
    awk '/^[[:space:]]*\[boot\]/{print; print "systemd=true"; next}
         /^[[:space:]]*systemd[[:space:]]*=/{next} {print}' "$f" > "$t"
  else
    { [ -s "$f" ] && cat "$f" && echo; printf '[boot]\nsystemd=true\n'; } > "$t"
  fi
  cat "$t" > "$f"; rm -f "$t"
}
# DOCKERCFG: dockerd pulls 3 layers at a time by default; the OA base is 36 layers (one 1.1 GB) -> 16 like LFS
DOCKER_JOBS="${INIT_DOCKER_JOBS:-16}"
dockercfg_ok() { grep -q '"max-concurrent-downloads"' /etc/docker/daemon.json 2>/dev/null; }
dockercfg_do() {   # only creates a MISSING daemon.json; restarts dockerd only when it runs no container
  mkdir -p /etc/docker && printf '{\n  "max-concurrent-downloads": %s\n}\n' "$DOCKER_JOBS" > /etc/docker/daemon.json || return 1
  if docker_up && has_systemd; then
    if [ -z "$(docker ps -q 2>/dev/null)" ]; then systemctl restart docker.service >/dev/null 2>&1
    else echo "DOCKERCFG: containers running -- dockerd keeps 3 until its next restart"; fi
  fi
}
if dockercfg_ok; then say DOCKERCFG ok
elif [ -e /etc/docker/daemon.json ]; then say DOCKERCFG "WARN /etc/docker/daemon.json exists without max-concurrent-downloads -- left alone (pulls 3 layers at a time)"
else act DOCKERCFG "/etc/docker/daemon.json max-concurrent-downloads=$DOCKER_JOBS (default 3)" dockercfg_do; fi
if docker_up; then say DOCKERD ok
elif has_systemd; then
  act DOCKERD "systemctl enable --now docker" sh -c 'systemctl enable --now docker.service >/dev/null 2>&1'
  if [ "$APPLY" = 1 ] && ! docker_up; then bad DOCKERD "docker.service enabled but docker info fails"; fi
elif is_wsl; then
  restart=1
  if wslconf_systemd; then say DOCKERD "RESTART NEEDED -- /etc/wsl.conf has systemd=true; from Windows: wsl --terminate ${WSL_DISTRO_NAME:-<distro>}, then re-run"
  else act DOCKERD "[boot] systemd=true -> /etc/wsl.conf, then RESTART NEEDED (wsl --terminate ${WSL_DISTRO_NAME:-<distro>})" write_wslconf; fi
else
  say DOCKERD "WARN no docker server, no systemd, not WSL -- start dockerd yourself"
fi

# GCM
gcm="${INIT_GCM:-}"; gcm_why=""
if [ -z "$gcm" ] && [ -n "${INIT_GCM_WIN:-}" ]; then   # the bootstrap found it on Windows: C:\...\x.exe -> /mnt/c/... (honours wsl.conf automount root)
  gcm="$(wslpath -u "$INIT_GCM_WIN" 2>/dev/null)"
  [ -n "$gcm" ] || { d="$(printf '%s' "$INIT_GCM_WIN" | cut -c1 | tr A-Z a-z)"; gcm="$MNT/../$d/$(printf '%s' "$INIT_GCM_WIN" | cut -c4- | tr '\\' /)"; }
fi
if [ -n "$gcm" ] && [ ! -f "$gcm" ]; then gcm_why=" (given '${INIT_GCM_WIN:-$gcm}' -> '$gcm': not a file; is $MNT mounted? $(ls -d "$MNT" 2>&1 | head -1))"; gcm=""; fi
[ -z "${INIT_GCM_WIN:-}${INIT_GCM:-}" ] && gcm_why=" (the bootstrap passed no path)"
if [ -z "$gcm" ]; then
  for g in "$MNT/Program Files/Git Credential Manager/git-credential-manager.exe" \
           "$MNT/Program Files/Git/mingw64/bin/git-credential-manager.exe" \
           "$MNT/Program Files/Git/mingw64/libexec/git-core/git-credential-manager.exe" \
           "$MNT"/Program\ Files*/Git\ Credential\ Manager*/git-credential-manager*.exe \
           "$MNT"/Users/*/AppData/Local/Programs/Git/mingw64/bin/git-credential-manager.exe; do
    [ -f "$g" ] && { gcm="$g"; gcm_why=""; break; }
  done
fi
gcm_args=""
if [ -z "$gcm" ] && [ -n "${INIT_GIT_WIN:-}" ]; then   # fallback: the Windows git.exe runs GCM itself (`git.exe credential-manager get`)
  gw="$(wslpath -u "$INIT_GIT_WIN" 2>/dev/null)"
  if [ -n "$gw" ] && [ -f "$gw" ]; then gcm="$gw"; gcm_args=" credential-manager"; gcm_why=""
  else gcm_why="$gcm_why (git.exe '$INIT_GIT_WIN' -> '$gw': not a file)"; fi
fi
if [ -z "$gcm" ]; then
  # ADO refuses a typed password, so a clone without GCM can only fail: stop here, before git prompts for one
  if [ "$ws_state" != clone ] && [ "$APPLY" = 1 ] && case "$WS_URL" in https://*) true;; *) false;; esac; then bad GCM "no Windows git-credential-manager.exe under $MNT$gcm_why -- the bootstrap installs Git for Windows (it brings GCM); re-run it"; finish; fi
  say GCM "WARN no Windows git-credential-manager.exe under $MNT$gcm_why"
elif ! command -v git >/dev/null 2>&1; then say GCM "WOULD credential.helper -> $gcm (after APT)"
else
  helper="$(printf '%s' "$gcm" | sed 's/ /\\ /g')$gcm_args"
  if [ "$(git config --system --get credential.helper 2>/dev/null)" = "$helper" ]; then say GCM "ok $helper"
  else
    gcm_do() { git config --system credential.helper "$helper" && git config --system credential.https://dev.azure.com.useHttpPath true; }
    act GCM "git config --system credential.helper $helper" gcm_do
  fi
fi

# NODE: Windows node.exe -- install.sh stage 6 (tserver) mints the ADO token by running the WAM broker under
# WINDOWS node at "$MNT/Program Files/nodejs/node.exe" (ado-token.mjs).  The bootstrap installs it (pinned
# v18.20.6 = c17) and passes INIT_NODE_WIN; here we prove WSL interop can run it.  Absent = WARN (stage 6 fails).
node_win=""
[ -n "${INIT_NODE_WIN:-}" ] && node_win="$(wslpath -u "$INIT_NODE_WIN" 2>/dev/null)"
[ -n "$node_win" ] && [ -f "$node_win" ] || node_win="$MNT/Program Files/nodejs/node.exe"
if [ -f "$node_win" ]; then
  nv="$(timeout 20 "$node_win" --version 2>/dev/null | tr -d '\r')"
  if [ -n "$nv" ]; then say NODE "ok $node_win ($nv)"
  else say NODE "WARN $node_win present but did not run over WSL interop (tserver stage 6 will give no token)"; fi
else say NODE "WARN no Windows node.exe at $node_win -- re-run the bootstrap (it installs Node.js v18.20.6); tserver stage 6 needs it"; fi

# LFS
if ! command -v git >/dev/null 2>&1 || ! git lfs version >/dev/null 2>&1; then say LFS "WOULD git lfs install --system (after APT)"
elif git config --system --get filter.lfs.process >/dev/null 2>&1; then say LFS ok
else act LFS "git lfs install --system" sh -c 'git lfs install --system >/dev/null'; fi

# CLONE (plan 01 Q.3): a user box = the workspace clone + `git lfs pull` (the bundles: AL tree, OA image
# layers, services, datasets) + ONE submodule, ssg_agent (skills).  OfficeAgent / augloop-workflows /
# lserver / tserver / wwwrootsdx are never checked out -- install.sh runs them from archive/.
# INIT_SUBMODULES=1 = the build-box form (every submodule, shallow single-branch).
# The clone skips the LFS smudge (one stream, ~4 MB/s) and `git lfs pull` fetches with
# lfs.concurrenttransfers=8 instead.
SUB_ARGS="--init --progress --depth 1 --single-branch --jobs 6"
sub_paths() { [ "${INIT_SUBMODULES:-0}" = 1 ] || echo ssg_agent; }
sub_do() {   # ssg_agent carries ~250 MB of LFS (archive/*.tar.gz): the checkout smudge fetches those ONE at a time
  # (~5 min), so skip it and `lfs pull` them in parallel afterwards
  GIT_TERMINAL_PROMPT=0 GIT_LFS_SKIP_SMUDGE=1 git -C "$WS_DIR" submodule update $SUB_ARGS $(sub_paths) || return 1
  [ "${INIT_SKIP_LFS:-0}" = 1 ] && return 0
  git -C "$WS_DIR" submodule foreach --quiet 'git config lfs.concurrenttransfers '"$LFS_JOBS"' && git lfs pull && echo "LFS $sm_path: $(git lfs ls-files | wc -l) objects"'
}
LFS_JOBS="${INIT_LFS_JOBS:-16}"   # parallel LFS downloads (126 MB parts; one stream is ~4 MB/s)
lfs_do() {   # foreground, so its meter owns the tty: "Downloading LFS objects: 45% (35/78), 2.7 GB | 40 MB/s"
  [ "${INIT_SKIP_LFS:-0}" = 1 ] && return 0
  git -C "$WS_DIR" config lfs.concurrenttransfers "$LFS_JOBS" || return 1
  # details: the object store is the truth (GIT_LFS_PROGRESS reports size -1 for ADO): a finished object lands in
  # .git/lfs/objects/<oid>, the one in flight grows in .git/lfs/incomplete.  lfs_watch prints one line per
  # finished file + a status line every 10s; git's own \r meter would scramble with those, so it goes to a log.
  local map=/tmp/ws-lfs.map
  git -C "$WS_DIR" lfs ls-files -l -s 2>/dev/null | sed -n 's/^\([0-9a-f]*\) [-*] \(.*\) (\(.*\))$/\1\t\2\t\3/p' >"$map"
  local n tot; n="$(grep -c . "$map")"
  tot="$(awk -F'\t' '{split($3,a," "); m=(a[2]=="GB")?1024:(a[2]=="KB")?1/1024:(a[2]=="B")?1/1048576:1; t+=a[1]*m} END {printf "%.1f GB", t/1024}' "$map")"
  echo "LFS: $n objects, $tot, $LFS_JOBS downloads in parallel (git's meter: /tmp/ws-lfs.err)"
  export LFS_T0 LFS_G0; LFS_T0="$(date +%s)"; LFS_G0="$(du -sb "$WS_DIR/.git/lfs/objects" 2>/dev/null | cut -f1)"
  : >/tmp/ws-lfs.err
  lfs_watch "$WS_DIR" "$map" "$n" & local w=$!
  # STALL guard (measured 2026-10-19: a devbox sat at 91/115 for 30+ min while c17 pulls all 115 in 119s):
  # when the object store + in-flight bytes do not grow for LFS_STALL s, kill the pull and start it again --
  # finished objects are kept, so a retry fetches only the rest.  Up to LFS_TRIES pulls.
  local rc=1 try=1 tries="${LFS_TRIES:-4}" stall="${LFS_STALL:-120}"
  while :; do
    git -C "$WS_DIR" lfs pull 2>>/tmp/ws-lfs.err & local p=$!
    local last=-1 still=0 now
    while kill -0 "$p" 2>/dev/null; do
      sleep 5
      now="$(du -sb "$WS_DIR/.git/lfs/objects" "$WS_DIR/.git/lfs/incomplete" 2>/dev/null | awk '{t+=$1} END {print t+0}')"
      if [ "$now" = "$last" ]; then still=$((still+5)); else still=0; last="$now"; fi
      if [ "$still" -ge "$stall" ]; then
        if [ "$try" -lt "$tries" ]; then echo "LFS: STALLED -- no bytes for ${stall}s; restarting git lfs pull (try $((try+1))/$tries, done files are kept)"
        else echo "LFS: STALLED -- no bytes for ${stall}s; giving up after $tries tries (re-run to resume)"; fi
        pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; break
      fi
    done
    wait "$p"; rc=$?
    [ "$still" -ge "$stall" ] && rc=124
    [ $rc = 0 ] && break
    try=$((try+1)); [ $try -gt "$tries" ] && break
    [ $rc != 124 ] && echo "LFS: git lfs pull rc=$rc; retry $try/$tries"
    sleep 3
  done
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  lfs_status "$WS_DIR" "$map" "$n" "$LFS_T0" final
  oa_pull_status
  if [ $rc = 0 ]; then local m; m="$(lfs_missing | wc -l)"
    [ "$m" = 0 ] || { echo "LFS: git lfs pull rc=0 but $m files are still pointers: $(lfs_missing | head -3 | tr '\n' ' ')"; rc=1; }; fi
  [ $rc = 0 ] || { echo "LFS: git lfs pull FAILED (rc=$rc):"; tr '\r' '\n' </tmp/ws-lfs.err | tail -20; }
  return $rc
}
lfs_have() { find "$1/.git/lfs/objects" -type f -size +0 2>/dev/null | sed 's|.*/||'; }   # oids already local
lfs_status() {   # dir map n t0 [tag]: files done, GB, MB/s since t0, bytes in flight
  local d g f el
  d="$(lfs_have "$1" | grep -cFf - <(cut -f1 "$2"))"
  g="$(du -sb "$1/.git/lfs/objects" 2>/dev/null | cut -f1)"; f="$(du -sb "$1/.git/lfs/incomplete" 2>/dev/null | cut -f1)"
  el=$(( $(date +%s) - $4 )); [ $el -lt 1 ] && el=1
  awk -v d="$d" -v n="$3" -v g="${g:-0}" -v f="${f:-0}" -v el="$el" -v tag="${5:-progress}" -v g0="${LFS_G0:-0}" \
    'BEGIN { printf "LFS %s: %d/%d files, %.2f GB, %.1f MB/s, %dm%02ds\n", tag, d, n, (g+f)/1073741824, (g+f-g0)/1048576/el, el/60, el%60 }'
}
oa_pull_status() {   # one line: background docker pull of the OA base (install.sh --pull-base)
  local L=/tmp/ws-oa-pull.log t0 n c mb gb
  [ -s "$L" ] || return 0
  if grep -q '^rc=' "$L"; then echo "OA base pull: $(grep '^rc=' "$L" | tail -1)"; return 0; fi
  t0="$(sed -n 's/^t0=\([0-9]*\).*/\1/p' "$L" | head -1)"
  n="$(grep -c . "$L.map" 2>/dev/null)"; c="$(oa_layers_done | grep -c .)"
  gb="$(awk -F'\t' '{s+=$2} END {printf "%.2f", s/1073741824}' "$L.map" 2>/dev/null)"
  mb="$(du -sm /var/lib/containerd/io.containerd.content.v1.content/ingest 2>/dev/null | cut -f1)"
  echo "OA base pull: ${c}/${n:-?} layers of ${gb:-?} GB, ${mb:-?} MB in flight, $(( ($(date +%s) - ${t0:-$(date +%s)}) / 60 ))m (background, shares bandwidth)"
}
oa_layers_done() {   # finished LAYER ids only (docker also reports config/index blobs -- not in the map)
  sed -n 's/^\([0-9a-f]\{12\}\): \(Download complete\|Pull complete\|Already exists\)$/\1/p' /tmp/ws-oa-pull.log 2>/dev/null | sort -u \
    | grep -xFf <(cut -f1 /tmp/ws-oa-pull.log.map 2>/dev/null) 2>/dev/null
}
oa_watch_step() {   # print "OA done c/n id (size)" for each layer newly finished; state in OA_SEEN
  local M=/tmp/ws-oa-pull.log.map id sz n
  [ -s "$M" ] || return 0; n="$(grep -c . "$M")"
  for id in $(oa_layers_done); do
    case " $OA_SEEN " in *" $id "*) continue;; esac
    OA_SEEN="$OA_SEEN $id"; OA_C=$((OA_C+1)); sz="$(awk -F'\t' -v i="$id" '$1==i {printf "%.0f MB", $2/1048576}' "$M")"
    echo "OA done $OA_C/$n $id (${sz:-? MB})"
  done
}
lfs_watch() {    # dir map n: "LFS done 12/78 archive/x.tar.gz.03 (126 MB)" per finished file, status every 10s
  local t0="${LFS_T0:-$(date +%s)}" i=0 done c=0 oid name size; OA_SEEN=; OA_C=0
  done="$(lfs_have "$1")"; c="$(lfs_have "$1" | grep -cFf - <(cut -f1 "$2"))"
  while sleep 2; do
    while IFS=$'\t' read -r oid name size; do
      case "$done" in *"$oid"*) continue;; esac
      [ -s "$1/.git/lfs/objects/${oid:0:2}/${oid:2:2}/$oid" ] || continue
      done="$done $oid"; c=$((c+1)); echo "LFS done $c/$3 $name ($size)"
    done <"$2"
    oa_watch_step
    i=$((i+1)); [ $((i % 5)) = 0 ] && lfs_status "$1" "$2" "$3" "$t0"
    [ $((i % 15)) = 0 ] && oa_pull_status
  done
}
sub_lfs_do() {   # ssg_agent (no LFS) clones in the BACKGROUND while the LFS bundles download; its log -> /tmp/ws-sub.log
  local pid=""
  if [ "${INIT_SKIP_SUBMODULES:-0}" != 1 ]; then
    echo "SUBMODULE: $SUB_WHAT in background (log /tmp/ws-sub.log)"
    sub_do >/tmp/ws-sub.log 2>&1 & pid=$!
  fi
  lfs_do; local lrc=$?
  if [ -n "$pid" ]; then
    kill -0 "$pid" 2>/dev/null && echo "SUBMODULE: waiting for ssg_agent ..."
    wait "$pid" || { echo "SUBMODULE: FAILED:"; tail -20 /tmp/ws-sub.log; return 1; }
    echo "SUBMODULE: ssg_agent done ($(grep -c . /tmp/ws-sub.log) log lines; $(grep '^LFS ' /tmp/ws-sub.log | tr '\n' ' '))"
  fi
  return $lrc
}
clone_do() {
  if [ "$ws_state" = empty ]; then rmdir "$WS_DIR" || return 1; fi
  (cd "$(dirname "$WS_DIR")" && GIT_TERMINAL_PROMPT=0 GIT_LFS_SKIP_SMUDGE=1 git clone --progress "$WS_URL" "$(basename "$WS_DIR")") || return 1
  # Q.5: the public OA base (4.2 GB from mcr) downloads CONCURRENT with the LFS fetch; install.sh stage 9 awaits it
  # install.sh checks first: a base already present with the pinned layers is NOT pulled again
  [ "${INIT_SKIP_LFS:-0}" = 1 ] || (cd "$WS_DIR" && ./install.sh --pull-base) 2>/dev/null | grep '^OA base pull:' 
  sub_lfs_do
}
sub_missing() { [ "${INIT_SKIP_SUBMODULES:-0}" != 1 ] && git -C "$WS_DIR" submodule status $(sub_paths) 2>/dev/null | grep -q '^-'; }
SUB_WHAT="$([ "${INIT_SUBMODULES:-0}" = 1 ] && echo "git submodule update $SUB_ARGS" || echo "git submodule update $SUB_ARGS ssg_agent")"
# UPDATE: an existing clone is fast-forwarded to origin first -- otherwise a re-run resumes the LFS objects of an
# OLD commit (measured 2026-10-19: a devbox clone from before 48b3021 downloaded the retired alserver.tar.gz.XX
# parts instead of the alserver.NN shards).  Only a clean tree is moved; local commits/edits -> WARN, left alone.
update_do() {
  GIT_TERMINAL_PROMPT=0 git -C "$WS_DIR" fetch --quiet origin || { echo "UPDATE: git fetch failed"; return 1; }
  local up; up="$(git -C "$WS_DIR" rev-parse --abbrev-ref '@{u}' 2>/dev/null)" || { echo "UPDATE: no upstream branch -- left alone"; return 0; }
  local h u; h="$(git -C "$WS_DIR" rev-parse HEAD)"; u="$(git -C "$WS_DIR" rev-parse "$up")"
  [ "$h" = "$u" ] && { echo "UPDATE: at $up ${h:0:7}"; return 0; }
  if [ -n "$(git -C "$WS_DIR" status --porcelain --untracked-files=no)" ]; then
    echo "UPDATE: WARN local edits -- not moving ${h:0:7} to $up ${u:0:7}"; return 0; fi
  GIT_LFS_SKIP_SMUDGE=1 git -C "$WS_DIR" merge --ff-only --quiet "$up" \
    || { echo "UPDATE: WARN ${h:0:7} cannot fast-forward to $up ${u:0:7} -- left alone"; return 0; }
  echo "UPDATE: ${h:0:7} -> ${u:0:7} ($up)"
}
lfs_missing() {   # LFS files whose content is not in the working tree yet ("-" = pointer only)
  [ "${INIT_SKIP_LFS:-0}" = 1 ] && return 0
  git -C "$WS_DIR" lfs ls-files 2>/dev/null | awk '$2 == "-" {print $3}'
}
behind() {   # the clone is clean and origin has commits it lacks (fetch first; dry-run only reads)
  [ "$APPLY" = 1 ] && GIT_TERMINAL_PROMPT=0 git -C "$WS_DIR" fetch --quiet origin 2>/dev/null
  local up; up="$(git -C "$WS_DIR" rev-parse --abbrev-ref '@{u}' 2>/dev/null)" || return 1
  [ "$(git -C "$WS_DIR" rev-parse HEAD)" != "$(git -C "$WS_DIR" rev-parse "$up")" ]
}
if [ "$ws_state" = clone ]; then
  if behind; then
    resume_do() { update_do || return 1; if sub_missing; then sub_lfs_do; else lfs_do; fi; }
    act CLONE "git fast-forward to origin + $(sub_missing && echo "$SUB_WHAT (resume) + ")git lfs pull" resume_do || finish
  elif sub_missing; then resume_do() { sub_lfs_do; }
    act CLONE "$SUB_WHAT (resume) + git lfs pull" resume_do || finish
  elif [ -n "$(lfs_missing)" ]; then   # measured 2026-10-19: an interrupted pull (91/115) re-ran as CLONE=ok
    act CLONE "git lfs pull (resume: $(lfs_missing | wc -l) LFS files not downloaded yet)" lfs_do || finish
  else say CLONE ok; fi
else act CLONE "cd $(dirname "$WS_DIR") && git clone $WS_URL + $SUB_WHAT + git lfs pull (lfs.concurrenttransfers=$LFS_JOBS, ssg_agent in parallel)" clone_do || finish; fi

# INSTALL
if [ "${INIT_SKIP_INSTALL:-0}" = 1 ]; then say INSTALL "skip (INIT_SKIP_INSTALL=1)"
elif [ "$restart" = 1 ]; then say INSTALL "WOULD $WS_DIR/install.sh after the distro restart (re-run init.sh --apply)"
elif [ "$APPLY" != 1 ]; then say INSTALL "WOULD cd $WS_DIR && ./install.sh"
else
  (cd "$WS_DIR" && ./install.sh); rc=$?
  if [ $rc = 0 ]; then say INSTALL ok; else bad INSTALL "install.sh rc=$rc (re-run: cd $WS_DIR && ./install.sh)"; fi
fi
finish
