#!/usr/bin/env bash
# init.sh -- plan 01 G.2: turn a bare WSL distro into a workspace box.  Runs as ROOT inside WSL.
#   bash init.sh            dry-run (DEFAULT): prints KEY=ok|WOULD <action>|FAIL <why>, changes nothing
#   bash init.sh --apply    (or INIT_APPLY=1) does the work; acted steps print KEY=did <action>
# Steps: ROOT, OS (ubuntu 26.04), WS (refuse a foreign /workspace -- checked first, before anything changes), APT (git git-lfs
#   docker.io ca-certificates curl), DOCKERD (systemd -> enable --now; WSL without systemd -> [boot]
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
PKGS="git git-lfs docker.io ca-certificates curl"
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
  for g in "$MNT/Program Files/Git/mingw64/bin/git-credential-manager.exe" \
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
sub_do() { git -C "$WS_DIR" submodule update $SUB_ARGS $(sub_paths); }
lfs_do() {
  [ "${INIT_SKIP_LFS:-0}" = 1 ] && return 0
  git -C "$WS_DIR" config lfs.concurrenttransfers 8 && git -C "$WS_DIR" lfs pull
}
clone_do() {
  if [ "$ws_state" = empty ]; then rmdir "$WS_DIR" || return 1; fi
  (cd "$(dirname "$WS_DIR")" && GIT_TERMINAL_PROMPT=0 GIT_LFS_SKIP_SMUDGE=1 git clone --progress "$WS_URL" "$(basename "$WS_DIR")") || return 1
  git -C "$WS_DIR" config lfs.concurrenttransfers 8 || return 1
  # Q.5: the public OA base (4.2 GB from mcr) downloads CONCURRENT with the LFS fetch; install.sh stage 9 awaits it
  [ "${INIT_SKIP_LFS:-0}" = 1 ] || (cd "$WS_DIR" && ./install.sh --pull-base) >/dev/null 2>&1
  if [ "${INIT_SKIP_SUBMODULES:-0}" != 1 ]; then sub_do || return 1; fi
  lfs_do
}
sub_missing() { [ "${INIT_SKIP_SUBMODULES:-0}" != 1 ] && git -C "$WS_DIR" submodule status $(sub_paths) 2>/dev/null | grep -q '^-'; }
SUB_WHAT="$([ "${INIT_SUBMODULES:-0}" = 1 ] && echo "git submodule update $SUB_ARGS" || echo "git submodule update $SUB_ARGS ssg_agent")"
if [ "$ws_state" = clone ]; then
  if sub_missing; then resume_do() { sub_do && lfs_do; }
  act CLONE "$SUB_WHAT (resume) + git lfs pull" resume_do || finish
  else say CLONE ok; fi
else act CLONE "cd $(dirname "$WS_DIR") && git clone $WS_URL + $SUB_WHAT + git lfs pull (lfs.concurrenttransfers=8)" clone_do || finish; fi

# INSTALL
if [ "${INIT_SKIP_INSTALL:-0}" = 1 ]; then say INSTALL "skip (INIT_SKIP_INSTALL=1)"
elif [ "$restart" = 1 ]; then say INSTALL "WOULD $WS_DIR/install.sh after the distro restart (re-run init.sh --apply)"
elif [ "$APPLY" != 1 ]; then say INSTALL "WOULD cd $WS_DIR && ./install.sh"
else
  (cd "$WS_DIR" && ./install.sh); rc=$?
  if [ $rc = 0 ]; then say INSTALL ok; else bad INSTALL "install.sh rc=$rc (re-run: cd $WS_DIR && ./install.sh)"; fi
fi
finish
