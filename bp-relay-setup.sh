#!/usr/bin/env bash
# =============================================================================
#  bp-relay-setup.sh - HAProxy OpAMP relay + nginx file server
#  for the Bindplane gateway tier (Siyapatha Finance PLC, HLD v1.0)
#
#  DMZ collector  HAProxy <IP>:3001 -> app.bindplane.com:443 (TLS)   in: PA-10, PA-20, FG-01  out: PA-01
#                 nginx   <IP>:8080 (+ optional 443 HTTPS)           in: PA-10, PA-20, FG-03
#  LIVE collector HAProxy <IP>:3001 -> <DMZ_IP>:3001                 in: FG-10                out: FG-01
#                 nginx   <IP>:8080 (+ optional 443 HTTPS)           in: FG-10
#
#  * Every step ends with a checkpoint that shows the evidence and asks before continuing.
#  * Every change is recorded in a journal before it is made. If the run stops part-way
#    (failed check, "no" at a checkpoint, Ctrl+C, lost SSH session) the changes are rolled
#    back, so the server is left as it was. A finished run can be undone with --rollback.
#  * firewalld is never enabled or configured.
#
#  Usage:
#    sudo bash bp-relay-setup.sh [--role dmz|live] [--dry-run]   set up (or preview) a collector
#    sudo bash bp-relay-setup.sh --rollback [RUN_ID|all]          undo the last (or a given) run
#    sudo bash bp-relay-setup.sh --runs                           list previous runs
#    sudo bash bp-relay-setup.sh --diagnose                       collect a support bundle, no changes
# =============================================================================

VERSION="1.0"
SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")
SCRIPT_NAME=$(basename "$SCRIPT_PATH")
TS=$(date +%Y%m%d-%H%M%S)
CONF_FILE="${BP_CONF:-/root/.bp-relay-setup.conf}"
LOG_DIR="${BP_LOG_DIR:-/var/log/bp-relay-setup}"
STATE_DIR="${BP_STATE_DIR:-/var/lib/bp-relay-setup}"
OS_RELEASE="${BP_OS_RELEASE:-/etc/os-release}"     # override only for lab testing

BINDPLANE_HOST="app.bindplane.com"
OPAMP_PORT=3001
REPO_PORT=8080
HTTPS_PORT=443
OTLP_PORT=4317
URL_PATH="/repo/"
HAPROXY_CFG=/etc/haproxy/haproxy.cfg
NGINX_CONF=/etc/nginx/nginx.conf
NGINX_SITE=/etc/nginx/conf.d/bp-repo.conf
NGINX_PKI=/etc/pki/nginx
NGINX_CERT=$NGINX_PKI/bp-repo.crt
NGINX_KEY=$NGINX_PKI/private/bp-repo.key
CRON_FILE=/etc/cron.d/bp-haproxy-reload
SYSCTL_FILE=/etc/sysctl.d/90-bp-no-ip-forward.conf

MODE=setup
DRY_RUN=0
ROLE=""
ROLLBACK_ID=""
RUN_DIR=""
JOURNAL=""
LOG_FILE=""
BODY_FILE=""
RESULTS=()
STEP_FAILED=0
SELINUX_ACTIVE=0
ABORTING=0
NO_TTY=0
PKG_STEP=0
REPLY_LINE=""
CURL_CODE=""
CURL_EXIT=0

# Answers (saved for re-runs; no secrets)
REPO_DIR=""; LISTEN_IP=""; DMZ_IP=""; HTTPS_ENABLE="n"; CERT_FILE=""; KEY_FILE=""
CONF_VARS=(REPO_DIR LISTEN_IP DMZ_IP HTTPS_ENABLE CERT_FILE KEY_FILE)

OS_NAME=""; OS_MAJOR=""
declare -A RPM_BY_NAME=()

# ----------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_BOLD=$'\033[1m'; C_0=$'\033[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_BOLD=""; C_0=""
fi
info()    { printf '%s[INFO]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()      { printf '%s[ OK ]%s %s\n' "$C_G" "$C_0" "$*"; }
warn()    { printf '%s[WARN]%s %s\n' "$C_Y" "$C_0" "$*"; }
err()     { printf '%s[FAIL]%s %s\n' "$C_R" "$C_0" "$*"; }
explain() { local l; for l in "$@"; do printf '       %s\n' "$l"; done; }
hint()    { local l; for l in "$@"; do printf '       %s-> %s%s\n' "$C_Y" "$l" "$C_0"; done; }
section() { printf '\n%s===== %s =====%s\n' "$C_BOLD" "$*" "$C_0"; }

# record STATUS STEP DETAIL   STATUS: PASS | WARN | FAIL | INFO | SKIP | PLAN
record() {
  RESULTS+=("$1|$2|$3")
  case $1 in
    PASS) ok "$2: $3" ;;
    WARN) warn "$2: $3" ;;
    FAIL) err "$2: $3"; STEP_FAILED=1 ;;
    *)    info "$2: $3" ;;
  esac
}
# changed STEP DETAIL : a change that was made (or, in dry-run, only planned)
changed() {
  if [ "$DRY_RUN" = 1 ]; then record PLAN "$1" "would apply: $2"; else record PASS "$1" "$2"; fi
}

print_summary() {
  section "Summary"
  local r s step detail pass=0 warnc=0 fail=0 plan=0
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r s step detail <<< "$r"
    printf '  %-5s %-34s %s\n' "$s" "$step" "$detail"
    case $s in PASS) pass=$((pass+1));; WARN) warnc=$((warnc+1));; FAIL) fail=$((fail+1));; PLAN) plan=$((plan+1));; esac
  done
  printf '\n  %d passed, %d warnings, %d failed.\n' "$pass" "$warnc" "$fail"
  [ "$DRY_RUN" = 1 ] && printf '  DRY-RUN: %d planned changes listed as PLAN; nothing was changed.\n' "$plan"
  [ -n "$LOG_FILE" ] && printf '  Log: %s\n' "$LOG_FILE"
}

# ----------------------------------------------------------------------------
# Prompts
# ----------------------------------------------------------------------------
trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

prompt_line() {
  local rc
  printf '%s' "$1" >&2
  IFS= read -r REPLY_LINE; rc=$?
  if [ $rc -ne 0 ]; then
    printf '\n' >&2
    # A signal that arrives while waiting for an answer ends the read with 128 + signal number
    case $rc in
      129) on_hangup ;;
      130) abort_run "interrupted (Ctrl+C)" ;;
      143) abort_run "terminated" ;;
      *)   abort_run "no answer available (input closed)" ;;
    esac
  fi
  [ -t 0 ] || printf '%s\n' "$REPLY_LINE" >&2   # make piped answers visible in the log
}

# ask VAR "Question" "default" [validator]
ask() {
  local __var=$1 __q=$2 __def=$3 __val=${4:-} __ans
  while true; do
    if [ -n "$__def" ]; then prompt_line "  ? $__q [$__def]: "; else prompt_line "  ? $__q: "; fi
    __ans=$(trim "${REPLY_LINE:-$__def}")
    if [ -n "$__ans" ] && { [ -z "$__val" ] || "$__val" "$__ans"; }; then
      printf -v "$__var" '%s' "$__ans"
      return 0
    fi
    warn "'$__ans' is not valid here. Please try again."
  done
}

# confirm "Question" [y|n] -> 0 for yes
confirm() {
  local q=$1 def=${2:-n} hint_txt ans
  if [ "$def" = y ]; then hint_txt="Y/n"; else hint_txt="y/N"; fi
  prompt_line "  ? $q [$hint_txt]: "
  ans=$(trim "${REPLY_LINE:-$def}")
  [[ $ans =~ ^[Yy] ]]
}

# ----------------------------------------------------------------------------
# Validators
# ----------------------------------------------------------------------------
is_ipv4() {
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local i
  for i in 1 2 3 4; do (( 10#${BASH_REMATCH[$i]} <= 255 )) || return 1; done
}
ip_on_host()  { ip -4 -o addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | grep -qxF "$1"; }
is_local_ip() {
  is_ipv4 "$1" || return 1
  ip_on_host "$1" && return 0
  warn "$1 is not configured on this server (see: ip -4 addr)."
  return 1
}
is_remote_ip() { is_ipv4 "$1" && [ "$1" != "$LISTEN_IP" ]; }
is_repo_dir() {
  [[ $1 == /* && $1 != / ]] || { warn "Use an absolute path, for example /srv/repo."; return 1; }
  case $1 in
    /home|/home/*|/root|/root/*|/tmp|/tmp/*)
      warn "SELinux does not let nginx serve files under /home, /root or /tmp. Use a folder such as /srv/repo."
      return 1 ;;
  esac
  [ -d "$1" ] || { warn "$1 does not exist."; return 1; }
}
is_file() { [ -f "$1" ] || { warn "$1 is not a file."; return 1; }; }
is_role() { [[ $1 =~ ^(1|2|dmz|live|DMZ|LIVE)$ ]]; }

# ----------------------------------------------------------------------------
# Commands, journal and rollback
# ----------------------------------------------------------------------------
run() {
  if [ "$DRY_RUN" = 1 ]; then printf '       [dry-run] %s\n' "$*"; return 0; fi
  printf '       $ %s\n' "$*"
  "$@" 9>&-        # fd 9 holds the run lock: never let started services inherit it
}

# journal_add "description" CMD ARGS...
# Records how to undo a change. Always called BEFORE the change, and every undo
# command is safe to run even if the change never happened.
journal_add() {
  [ "$DRY_RUN" = 1 ] && return 0
  local desc=$1; shift
  printf 'UNDO\t%s\t%s\n' "${desc//$'\t'/ }" "$(printf '%q ' "$@")" >> "$JOURNAL"
}
# journal_post: runs at the end of a rollback, in recorded order (e.g. restart a service with its old config)
journal_post() {
  [ "$DRY_RUN" = 1 ] && return 0
  local desc=$1; shift
  printf 'POST\t%s\t%s\n' "${desc//$'\t'/ }" "$(printf '%q ' "$@")" >> "$JOURNAL"
}

# backup_once FILE : first time a file is touched in this run, save it (or note it did not exist)
backup_once() {
  [ "$DRY_RUN" = 1 ] && return 0
  local f=$1 dest
  grep -qxF "$f" "$RUN_DIR/touched" 2>/dev/null && return 0
  echo "$f" >> "$RUN_DIR/touched"
  if [ -e "$f" ]; then
    dest="$RUN_DIR/backup$f"
    mkdir -p "$(dirname "$dest")"
    cp -a "$f" "$dest"
    journal_add "restore $f" cp -a "$dest" "$f"
  else
    journal_add "remove $f (created by this run)" rm -f "$f"
  fi
}

# write_file DEST [MODE] < content : backed up, written in place only when different
write_file() {
  local dest=$1 mode=${2:-} tmp
  tmp=$(mktemp)
  cat > "$tmp"
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
    info "$dest is already up to date"
    rm -f "$tmp"
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] would write $dest:"
    sed 's/^/       | /' "$tmp"
    rm -f "$tmp"
    return 0
  fi
  backup_once "$dest"
  mkdir -p "$(dirname "$dest")"
  cat "$tmp" > "$dest"
  [ -n "$mode" ] && chmod "$mode" "$dest"
  rm -f "$tmp"
  info "Wrote $dest"
}

# ensure_dir DIR : creates missing directories, each journaled for removal
ensure_dir() {
  local d=$1 parts=() p
  while [ ! -d "$d" ] && [ "$d" != / ]; do parts=("$d" "${parts[@]}"); d=$(dirname "$d"); done
  for p in "${parts[@]}"; do
    journal_add "remove directory $p (created by this run)" rmdir --ignore-fail-on-non-empty "$p"
    run mkdir -m 0755 "$p" || return 1
  done
}

pkg_snapshot() { rpm -qa --qf '%{NAME}\n' 2>/dev/null | sort -u; }

# Rollback helper: removes packages that were not installed when the snapshot was taken
bp_undo_packages() {
  local snap=$1
  local -a pkgs=()
  [ -f "$snap" ] || return 0
  mapfile -t pkgs < <(comm -13 "$snap" <(pkg_snapshot))   # one name per line: independent of IFS
  [ ${#pkgs[@]} -eq 0 ] && return 0
  echo "removing packages: ${pkgs[*]}"
  rpm -e "${pkgs[@]}"
}

# Rollback helper: restores file modes saved before a chmod
bp_restore_modes() {
  local list=$1 mode path
  [ -f "$list" ] || return 0
  while IFS=' ' read -r mode path; do
    [ -e "$path" ] && chmod "$mode" "$path"
  done < "$list"
}

pkg_guard() {
  [ "$DRY_RUN" = 1 ] && return 0
  PKG_STEP=$((PKG_STEP+1))
  local snap="$RUN_DIR/packages-before-$PKG_STEP"
  pkg_snapshot > "$snap"
  journal_add "remove packages installed by this run (install step $PKG_STEP)" bp_undo_packages "$snap"
}

rollback_run() {
  local IFS=$' \t\n'
  local dir=$1 journal="$1/journal" kind desc cmd okc=0 errc=0 p
  local -a posts=()
  if [ ! -s "$journal" ]; then
    info "Run $(basename "$dir") made no changes; nothing to roll back."
    return 0
  fi
  if [ "$(cat "$dir/status" 2>/dev/null)" = rolled-back ]; then
    warn "Run $(basename "$dir") was already rolled back."
    return 0
  fi
  section "Rolling back run $(basename "$dir")"
  explain "Undoing every recorded change, newest first. Command output: $dir/rollback.out"
  while IFS=$'\t' read -r kind desc cmd; do
    if [ "$kind" = POST ]; then posts+=("$desc"$'\t'"$cmd"); continue; fi
    printf '       undo: %s\n' "$desc"
    echo "### $desc" >> "$dir/rollback.out"
    if eval "$cmd" >> "$dir/rollback.out" 2>&1 9>&-; then okc=$((okc+1)); else errc=$((errc+1)); warn "could not undo: $desc"; fi
  done < <(tac "$journal")
  for p in "${posts[@]}"; do
    desc=${p%%$'\t'*}; cmd=${p#*$'\t'}
    printf '       then: %s\n' "$desc"
    echo "### $desc" >> "$dir/rollback.out"
    if eval "$cmd" >> "$dir/rollback.out" 2>&1 9>&-; then okc=$((okc+1)); else errc=$((errc+1)); warn "could not complete: $desc"; fi
  done
  echo rolled-back > "$dir/status"
  if [ $errc -eq 0 ]; then
    ok "Rollback complete: $okc changes undone. The server is back to its state before this run."
  else
    warn "Rollback finished with $errc problem(s) and $okc changes undone. See $dir/rollback.out"
  fi
}

# abort_run REASON : stop the run, offer (or automatically do) a rollback, collect diagnostics
abort_run() {
  [ "$ABORTING" = 1 ] && return 0
  ABORTING=1
  # This can run inside an interrupted "IFS= read": restore normal word splitting first
  IFS=$' \t\n'
  # A handler (not "ignore"): the rollback cannot be interrupted, yet programs it starts keep normal signals
  trap 'warn "Rollback in progress, please wait."' INT TERM
  echo
  err "Run stopped: $1"
  if [ "$DRY_RUN" != 1 ] && [ -n "$RUN_DIR" ]; then
    echo aborted > "$RUN_DIR/status"
    if grep -q '^UNDO' "$JOURNAL" 2>/dev/null; then
      local do_rb=1 ans=""
      if [ "$NO_TTY" = 0 ]; then
        printf '  ? Roll back every change this run made? [Y/n] (yes automatically after 120s): ' >&2
        if IFS= read -r -t 120 ans; then
          [ -t 0 ] || printf '%s\n' "$ans" >&2
          [[ $(trim "$ans") =~ ^[Nn] ]] && do_rb=0
        else
          printf '\n' >&2
        fi
      else
        info "No terminal to ask: rolling back automatically."
      fi
      if [ $do_rb = 1 ]; then
        rollback_run "$RUN_DIR"
      else
        warn "Changes kept. Undo them later with: sudo bash $SCRIPT_NAME --rollback $(basename "$RUN_DIR")"
      fi
    else
      info "No changes were made, so there is nothing to roll back."
    fi
  fi
  make_bundle "$1"
  print_summary
  exit 1
}

on_hangup() {
  NO_TTY=1
  # The terminal is gone: keep writing to the log file only
  [ -n "$LOG_FILE" ] && exec >> "$LOG_FILE" 2>&1
  abort_run "SSH session lost (hang-up)"
}

# checkpoint "Step N - name": show the result and ask before going on
checkpoint() {
  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] checkpoint after: $1"
    STEP_FAILED=0
    return 0
  fi
  echo
  if [ "$STEP_FAILED" = 1 ]; then
    err "$1: a check failed (see the hints above)."
    confirm "Continue anyway? Not recommended" n || abort_run "stopped after a failed check in: $1"
  else
    ok "$1: all checks passed."
    confirm "Continue to the next step?" y || abort_run "stopped by you after: $1"
  fi
  STEP_FAILED=0
}

# ----------------------------------------------------------------------------
# Support bundle (troubleshooting)
# ----------------------------------------------------------------------------
make_bundle() {
  local reason=$1 tmp out
  [ -d "$LOG_DIR" ] || return 0
  out="$LOG_DIR/support-$(hostname)-$TS.tar.gz"
  tmp=$(mktemp -d)
  {
    echo "reason: $reason"; date; uname -a
    cat /etc/redhat-release 2>/dev/null || grep PRETTY_NAME "$OS_RELEASE" 2>/dev/null
    echo "selinux: $(getenforce 2>/dev/null)"; echo "ip_forward: $(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
    echo "firewalld: $(systemctl is-active firewalld 2>/dev/null)/$(systemctl is-enabled firewalld 2>/dev/null)"
    echo "haproxy: $(systemctl is-active haproxy 2>/dev/null)  nginx: $(systemctl is-active nginx 2>/dev/null)"
    echo "answers: role=$ROLE repo=$REPO_DIR listen=$LISTEN_IP dmz=$DMZ_IP https=$HTTPS_ENABLE"
  } > "$tmp/system.txt" 2>&1
  ss -tlnp > "$tmp/listening-ports.txt" 2>&1
  rpm -qa 2>/dev/null | grep -iE 'haproxy|nginx|observiq|bindplane|policycoreutils' > "$tmp/packages.txt"
  cp "$HAPROXY_CFG" "$NGINX_CONF" "$NGINX_SITE" "$tmp/" 2>/dev/null
  command -v haproxy >/dev/null && haproxy -c -f "$HAPROXY_CFG" > "$tmp/haproxy-check.txt" 2>&1
  command -v nginx >/dev/null && nginx -t > "$tmp/nginx-check.txt" 2>&1
  command -v journalctl >/dev/null && journalctl -u haproxy -u nginx -n 300 --no-pager > "$tmp/service-journal.txt" 2>&1
  command -v journalctl >/dev/null && journalctl -t haproxy -n 100 --no-pager > "$tmp/haproxy-requests.txt" 2>&1
  tail -n 100 /var/log/nginx/bp-repo-error.log > "$tmp/nginx-error.txt" 2>/dev/null
  command -v ausearch >/dev/null && ausearch -m avc -ts recent > "$tmp/selinux-denials.txt" 2>&1
  { semanage port -l -C; getsebool haproxy_connect_any; } > "$tmp/selinux-settings.txt" 2>&1
  [ -n "$LOG_FILE" ] && cp "$LOG_FILE" "$tmp/" 2>/dev/null
  [ -n "$RUN_DIR" ] && cp "$RUN_DIR/journal" "$RUN_DIR/rollback.out" "$tmp/" 2>/dev/null
  tar czf "$out" -C "$tmp" . 2>/dev/null && info "Support bundle for troubleshooting: $out"
  rm -rf "$tmp"
}

# ----------------------------------------------------------------------------
# Network probes
# ----------------------------------------------------------------------------
# curl_probe URL [SOURCE_IP] [extra curl args...] -> sets CURL_CODE and CURL_EXIT, body in $BODY_FILE
curl_probe() {
  local url=$1 src=${2:-}; shift 2 2>/dev/null || shift $#
  local args=(-s -o "$BODY_FILE" -w '%{http_code}' --connect-timeout 5 --max-time 20 "$@")
  if [ -n "$src" ] && ip_on_host "$src"; then args+=(--interface "$src"); fi
  : > "$BODY_FILE"
  CURL_CODE=$(curl "${args[@]}" "$url" 2>/dev/null)
  CURL_EXIT=$?
}

# curl_reason : plain-English reason for the last curl failure
curl_reason() {
  case $CURL_EXIT in
    6)  echo "name not resolved (DNS)" ;;
    7)  echo "connection refused or no route" ;;
    28) echo "timed out (traffic dropped on the way)" ;;
    35) echo "TLS handshake failed" ;;
    52) echo "empty reply from the server" ;;
    56) echo "connection reset" ;;
    60) echo "certificate not trusted" ;;
    *)  echo "curl exit code $CURL_EXIT" ;;
  esac
}

# check_relay LABEL URL SOURCE_IP RULE : sends a request through an OpAMP relay and explains the answer
check_relay() {
  local label=$1 url=$2 src=$3 rule=$4
  curl_probe "$url" "$src"
  case $CURL_CODE in
    000)
      record FAIL "$label" "no HTTP answer from $url: $(curl_reason)"
      case $CURL_EXIT in
        28) hint "Timeouts point to a network firewall: check $rule." \
                 "Prove it: on the receiving server run  tcpdump -ni any host $src and port ${url##*:}" \
                 "           No packets there = the firewall drops them." ;;
        7)  hint "Nothing is listening at ${url#http://}, or a firewall rejects the connection ($rule)." \
                 "On the receiving server: ss -tlnp | grep ':$OPAMP_PORT'" ;;
        *)  hint "Check $rule and that HAProxy runs on the receiving server." ;;
      esac
      return 1 ;;
    502|503|504)
      record FAIL "$label" "HTTP $CURL_CODE: HAProxy answered but could not reach its next hop"
      hint "On the DMZ collector: is app.bindplane.com reachable? (PA-01, DNS)" \
           "Check the SELinux boolean: getsebool haproxy_connect_any  (must be on)" \
           "Look at the HAProxy log: journalctl -t haproxy -n 20" \
           "Collect everything: sudo bash $SCRIPT_NAME --diagnose"
      return 1 ;;
    4??)
      record PASS "$label" "HTTP $CURL_CODE returned by Bindplane: the relay path works" ;;
    *)
      record PASS "$label" "HTTP $CURL_CODE came back through the relay" ;;
  esac
  return 0
}

# Listeners on PORT that would clash with LISTEN_IP: the same IP, or a listener on all addresses.
# (A service bound to a different IP of this server does not clash.)
port_lines_on() {
  ss -H -tlnp "sport = :$1" 2>/dev/null | awk -v ip="$LISTEN_IP" -v p="$1" '
    { a = $4 } a == ip ":" p || a == "0.0.0.0:" p || a == "*:" p || a == "[::]:" p || a == "[::ffff:" ip "]:" p'
}
port_busy()  { [ -n "$(port_lines_on "$1")" ]; }
port_owner() { port_lines_on "$1" | grep -o 'users:(("[^"]*"' | head -1 | cut -d'"' -f2; }
wait_listen() {
  local i
  [ "$DRY_RUN" = 1 ] && return 0
  for i in $(seq 1 20); do port_busy "$1" && return 0; sleep 0.5; done
  return 1
}

detect_ip()  { hostname -I 2>/dev/null | awk '{print $1}'; }
detect_ca_bundle() {
  local f
  for f in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt; do
    [ -r "$f" ] && { echo "$f"; return; }
  done
  echo /etc/pki/tls/certs/ca-bundle.crt
}
# ver_ge A B : true when version A >= version B
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

# ----------------------------------------------------------------------------
# SELinux and services (all journaled)
# ----------------------------------------------------------------------------
selinux_port() {
  local port=$1 prev
  [ "$SELINUX_ACTIVE" = 1 ] || { record SKIP "SELinux port $port" "SELinux not active"; return 0; }
  if semanage port -l 2>/dev/null | awk '$1=="http_port_t" && $2=="tcp"' | grep -qw "$port"; then
    record PASS "SELinux port $port" "already allowed (http_port_t)"
    return 0
  fi
  prev=$(semanage port -l -C 2>/dev/null | awk -v p="$port" '$2=="tcp" { n=split($0,a,/[ ,]+/); for (i=3;i<=n;i++) if (a[i]==p) print $1 }' | head -1)
  if [ -n "$prev" ]; then
    journal_add "restore SELinux port $port to $prev" semanage port -m -t "$prev" -p tcp "$port"
  else
    journal_add "remove SELinux port $port rule" semanage port -d -t http_port_t -p tcp "$port"
  fi
  # 8080 is pre-assigned in the policy (http_cache_port_t): -a fails there and -m is used
  if run semanage port -a -t http_port_t -p tcp "$port" 2>/dev/null || run semanage port -m -t http_port_t -p tcp "$port"; then
    changed "SELinux port $port" "allowed for HAProxy/nginx (http_port_t)"
  else
    record FAIL "SELinux port $port" "could not be added to http_port_t"
    hint "Run by hand to see the error: semanage port -a -t http_port_t -p tcp $port"
    return 1
  fi
}

selinux_bool_on() {
  local b=$1 prev
  [ "$SELINUX_ACTIVE" = 1 ] || { record SKIP "SELinux $b" "SELinux not active"; return 0; }
  prev=$(getsebool "$b" 2>/dev/null | awk '{print $3}')
  if [ "$prev" = on ]; then record PASS "SELinux $b" "already on"; return 0; fi
  journal_add "restore SELinux boolean $b to ${prev:-off}" setsebool -P "$b" "${prev:-off}"
  if run setsebool -P "$b" on; then
    changed "SELinux $b" "set to on"
  else
    record FAIL "SELinux $b" "could not be set"
    return 1
  fi
}

selinux_label_dir() {
  local dir=$1 spec="$1(/.*)?" bad
  [ "$SELINUX_ACTIVE" = 1 ] || { record SKIP "SELinux label" "SELinux not active"; return 0; }
  if ! semanage fcontext -l 2>/dev/null | grep -F "$spec" | grep -q httpd_sys_content_t; then
    journal_add "relabel $dir to its previous SELinux type" restorecon -R "$dir"
    journal_add "remove SELinux label rule for $dir" semanage fcontext -d "$spec"
    run semanage fcontext -a -t httpd_sys_content_t "$spec" 2>/dev/null \
      || run semanage fcontext -m -t httpd_sys_content_t "$spec" || { record FAIL "SELinux label" "rule could not be added"; return 1; }
  fi
  run restorecon -R "$dir"
  [ "$DRY_RUN" = 1 ] && { changed "SELinux label" "$dir labelled httpd_sys_content_t"; return 0; }
  bad=$(find "$dir" ! -context '*httpd_sys_content_t*' 2>/dev/null | head -3 | tr '\n' ' ')
  if [ -n "$bad" ]; then
    record FAIL "SELinux label" "not labelled httpd_sys_content_t: $bad"
    hint "Check with: ls -lZ $dir"
    return 1
  fi
  changed "SELinux label" "$dir labelled httpd_sys_content_t (nginx may read it)"
}

# service_apply NAME reload|restart : enable + start, or reload/restart if already running (journaled)
service_apply() {
  local svc=$1 how=$2 was_enabled was_active
  was_enabled=$(systemctl is-enabled "$svc" 2>/dev/null)
  if systemctl is-active --quiet "$svc" 2>/dev/null; then was_active=1; else was_active=0; fi
  if [ "$was_enabled" != enabled ]; then
    journal_add "disable $svc" systemctl disable "$svc"
    run systemctl enable "$svc" >/dev/null 2>&1 || run systemctl enable "$svc" || return 1
  fi
  if [ $was_active = 1 ]; then
    journal_post "restart $svc with its previous configuration" systemctl restart "$svc"
    run systemctl "$how" "$svc"
  else
    journal_add "stop $svc" systemctl stop "$svc"
    run systemctl start "$svc"
  fi
}

# ----------------------------------------------------------------------------
# Packages from the repo folder
# ----------------------------------------------------------------------------
index_rpms() {
  local f n
  RPM_BY_NAME=()
  while IFS= read -r f; do
    n=$(rpm -qp --qf '%{NAME}' "$f" 2>/dev/null)
    [ -n "$n" ] && RPM_BY_NAME[$n]=$f
  done < <(find "$REPO_DIR" -maxdepth 1 -type f -name '*.rpm' ! -name '*.src.rpm' | sort -V)
}

nginx_names() {
  local n out="nginx"
  for n in "${!RPM_BY_NAME[@]}"; do
    case $n in nginx-core|nginx-filesystem|*logos-httpd) out+=" $n" ;; esac
  done
  echo "$out"
}

# install_pkgs LABEL NAME... : installs packages from the repo folder (journaled)
install_pkgs() {
  local label=$1; shift
  local -a need=() files=() extras=()
  local n f fname
  for n in "$@"; do rpm -q "$n" >/dev/null 2>&1 || need+=("$n"); done
  if [ ${#need[@]} -eq 0 ]; then
    record PASS "$label" "already installed: $(rpm -q "$@" 2>/dev/null | tr '\n' ' ')"
    return 0
  fi
  for n in "${need[@]}"; do
    if [ -z "${RPM_BY_NAME[$n]:-}" ]; then
      record FAIL "$label" "no RPM for '$n' in $REPO_DIR"
      hint "Download it (dnf download --resolve $n) on a server with the same RHEL version," \
           "copy it into $REPO_DIR and run the script again."
      return 1
    fi
    files+=("${RPM_BY_NAME[$n]}")
  done
  pkg_guard
  if run dnf install -y --disablerepo='*' "${files[@]}"; then
    changed "$label" "installed: ${need[*]}"
    return 0
  fi
  [ "$DRY_RUN" = 1 ] && return 0
  warn "dnf could not install from those files alone; the error above names the missing dependency."
  for fname in "${!RPM_BY_NAME[@]}"; do
    f=${RPM_BY_NAME[$fname]}
    [[ $fname =~ observiq|bindplane ]] && continue
    rpm -q "$fname" >/dev/null 2>&1 && continue
    [[ " ${files[*]} " == *" $f "* ]] && continue
    extras+=("$f")
  done
  if [ ${#extras[@]} -gt 0 ]; then
    explain "These other RPMs in $REPO_DIR are not installed yet and may be the missing dependencies:"
    printf '         %s\n' "${extras[@]##*/}"
    if confirm "Retry including these ${#extras[@]} RPMs?" y; then
      if run dnf install -y --disablerepo='*' "${files[@]}" "${extras[@]}"; then
        changed "$label" "installed: ${need[*]} (with dependencies from the folder)"
        return 0
      fi
    fi
  fi
  if confirm "Retry using this server's configured repositories (Satellite), if it has any?" n; then
    if run dnf install -y "${files[@]}"; then
      changed "$label" "installed: ${need[*]} (dependencies from configured repositories)"
      return 0
    fi
  fi
  record FAIL "$label" "installation failed"
  hint "Copy the RPM that dnf reports as missing into $REPO_DIR and run the script again."
  return 1
}

ensure_semanage() {
  [ "$SELINUX_ACTIVE" = 1 ] || return 0
  command -v semanage >/dev/null 2>&1 && return 0
  [ "$DRY_RUN" = 1 ] && { record PLAN "semanage" "would install policycoreutils-python-utils"; return 0; }
  install_pkgs "SELinux tools" policycoreutils-python-utils || return 1
  command -v semanage >/dev/null 2>&1 || { record FAIL "SELinux tools" "semanage still not available"; return 1; }
}

# ----------------------------------------------------------------------------
# Configuration generators
# ----------------------------------------------------------------------------
haproxy_version() {
  local v
  v=$(haproxy -v 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
  [ -z "$v" ] && [ -n "${RPM_BY_NAME[haproxy]:-}" ] && v=$(rpm -qp --qf '%{VERSION}' "${RPM_BY_NAME[haproxy]}" 2>/dev/null)
  echo "${v:-0}"
}

gen_haproxy_common() {
  cat <<EOF
# Managed by $SCRIPT_NAME v$VERSION (Siyapatha HLD v1.0). The previous file is kept for rollback.
global
    log /dev/log local0
    maxconn 4000
    user haproxy
    group haproxy
    daemon

defaults
    mode http
    log global
    option httplog
    timeout connect 10s
    timeout client  1h
    timeout server  1h
    timeout tunnel  24h          # OpAMP websockets stay open; short timeouts make agents flap
    timeout http-request 30s
EOF
}

# gen_haproxy_dmz HAPROXY_VERSION
gen_haproxy_dmz() {
  local ver=$1 opts=" init-addr libc,none"
  gen_haproxy_common
  if ver_ge "$ver" 1.9; then
    cat <<EOF

# Re-resolve $BINDPLANE_HOST every 60s using this server's own DNS settings
resolvers sysdns
    parse-resolv-conf
    hold valid 60s
EOF
    opts=" resolvers sysdns resolve-prefer ipv4 init-addr libc,none"
  fi
  cat <<EOF

# OpAMP in on $OPAMP_PORT from any source (PA-10, PA-20, FG-01)
frontend opamp_relay
    bind ${LISTEN_IP}:${OPAMP_PORT}
    default_backend bindplane_cloud

# Out to Bindplane Cloud over verified TLS (PA-01)
backend bindplane_cloud
    http-request set-header Host ${BINDPLANE_HOST}
    server bindplane ${BINDPLANE_HOST}:443 ssl verify required ca-file $(detect_ca_bundle) sni str(${BINDPLANE_HOST})${opts}
EOF
}

gen_haproxy_live() {
  gen_haproxy_common
  cat <<EOF

# OpAMP in on $OPAMP_PORT from any source (FG-10)
frontend opamp_relay
    bind ${LISTEN_IP}:${OPAMP_PORT}
    default_backend dmz_relay

# Out only to the DMZ HAProxy, from this server's own IP so FortiGate rule FG-01 matches
backend dmz_relay
    server dmz_gw ${DMZ_IP}:${OPAMP_PORT} source ${LISTEN_IP} check
EOF
}

gen_nginx_locations() {
  cat <<EOF
    location = / { return 302 ${URL_PATH}; }
    location ${URL_PATH} {
        alias ${REPO_DIR}/;
        autoindex on;
        autoindex_exact_size off;
    }
    location / { return 404; }
EOF
}

gen_nginx_site() {
  local rules="PA-10, PA-20, FG-03"
  [ "$ROLE" = live ] && rules="FG-10"
  cat <<EOF
# Managed by $SCRIPT_NAME v$VERSION (Siyapatha HLD v1.0)
# Package file server: $REPO_DIR at http://${LISTEN_IP}:${REPO_PORT}${URL_PATH}, any source ($rules)
server {
    listen ${LISTEN_IP}:${REPO_PORT};
    server_name _;
    access_log /var/log/nginx/bp-repo-access.log;
    error_log  /var/log/nginx/bp-repo-error.log;
$(gen_nginx_locations)
}
EOF
  if [ "$HTTPS_ENABLE" = y ]; then
    cat <<EOF

# Same files over HTTPS on ${HTTPS_PORT} (HLD: package repository on 8080 and 443)
server {
    listen ${LISTEN_IP}:${HTTPS_PORT} ssl;
    server_name _;
    ssl_certificate     ${NGINX_CERT};
    ssl_certificate_key ${NGINX_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;
    access_log /var/log/nginx/bp-repo-access.log;
    error_log  /var/log/nginx/bp-repo-error.log;
$(gen_nginx_locations)
}
EOF
  fi
}

# ----------------------------------------------------------------------------
# Step 1 - pre-checks and answers
# ----------------------------------------------------------------------------
require_cmds() {
  local missing=() c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if [ ${#missing[@]} -gt 0 ]; then record FAIL "Required tools" "missing: ${missing[*]}"; return 1; fi
  record PASS "Required tools" "present"
}

check_firewall() {
  local active enabled
  active=$(systemctl is-active firewalld 2>/dev/null); active=${active:-unknown}
  enabled=$(systemctl is-enabled firewalld 2>/dev/null); enabled=${enabled:-not-installed}
  if [ "$active" = active ]; then
    warn "firewalld is running and would block ports $OPAMP_PORT and $REPO_PORT on this server."
    if confirm "Stop firewalld for the implementation (it is never enabled by this script)?" n; then
      journal_add "start firewalld again" systemctl start firewalld
      [ "$enabled" = enabled ] && journal_add "enable firewalld again" systemctl enable firewalld
      if run systemctl disable --now firewalld; then
        changed "Host firewall" "firewalld stopped and disabled"
      else
        record FAIL "Host firewall" "could not stop firewalld"
      fi
    else
      record WARN "Host firewall" "firewalld left running: ports $OPAMP_PORT/$REPO_PORT may be blocked"
    fi
  else
    record PASS "Host firewall" "firewalld $active ($enabled), left as it is"
  fi
}

check_selinux() {
  local mode
  mode=$(getenforce 2>/dev/null); mode=${mode:-Unavailable}
  case $mode in
    Enforcing)  SELINUX_ACTIVE=1; record PASS "SELinux" "Enforcing" ;;
    Permissive) SELINUX_ACTIVE=1; record WARN "SELinux" "Permissive (the HLD requires Enforcing); settings are still applied" ;;
    *)          SELINUX_ACTIVE=0; record WARN "SELinux" "$mode; SELinux steps will be skipped" ;;
  esac
}

check_ip_forward() {
  local v
  v=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
  if [ "$v" = 0 ]; then record PASS "IP forwarding" "off"; return 0; fi
  warn "IP forwarding is on. A gateway that forwards packets routes between zones whatever the firewall policy says (HLD section 07)."
  if confirm "Turn IP forwarding off now and keep it off after reboots?" y; then
    journal_add "restore net.ipv4.ip_forward=$v" sysctl -w "net.ipv4.ip_forward=$v"
    echo 'net.ipv4.ip_forward = 0' | write_file "$SYSCTL_FILE"
    if run sysctl -w net.ipv4.ip_forward=0 >/dev/null; then
      changed "IP forwarding" "turned off (persisted in $SYSCTL_FILE)"
    else
      record FAIL "IP forwarding" "could not be changed"
    fi
  else
    record WARN "IP forwarding" "left on (HLD acceptance item)"
  fi
}

check_os() {
  # Read in subshells: os-release defines NAME and VERSION, which must not replace ours
  local id like
  # shellcheck disable=SC1090
  id=$(. "$OS_RELEASE" 2>/dev/null; echo "${ID:-unknown}")
  # shellcheck disable=SC1090
  like=$(. "$OS_RELEASE" 2>/dev/null; echo "${ID_LIKE:-}")
  # shellcheck disable=SC1090
  OS_NAME=$(. "$OS_RELEASE" 2>/dev/null; echo "${PRETTY_NAME:-unknown}")
  # shellcheck disable=SC1090
  OS_MAJOR=$(. "$OS_RELEASE" 2>/dev/null; v=${VERSION_ID:-0}; echo "${v%%.*}")
  if [[ " $id $like " == *" rhel "* || " $id $like " == *" fedora "* ]]; then
    record PASS "Operating system" "$OS_NAME"
  else
    record WARN "Operating system" "$OS_NAME is not RHEL; this script targets RHEL 8/9"
    confirm "Continue anyway?" n || abort_run "unsupported operating system"
  fi
}

choose_repo() {
  local n
  while true; do
    ask REPO_DIR "Folder that holds the RPMs and files" "${REPO_DIR:-/srv/repo}" is_repo_dir
    REPO_DIR=${REPO_DIR%/}
    n=$(find "$REPO_DIR" -maxdepth 1 -type f | wc -l)
    info "$REPO_DIR contains $n files:"
    find "$REPO_DIR" -maxdepth 1 -type f -printf '         %-60f %10s bytes\n' | sort | head -60
    [ "$n" -gt 60 ] && explain "... and $((n-60)) more"
    confirm "Is this the right folder?" y && break
  done
  record PASS "Repo folder" "$REPO_DIR ($n files)"
}

check_rpms() {
  index_rpms
  local n f
  for n in haproxy nginx; do
    f=${RPM_BY_NAME[$n]:-}
    if [ -n "$f" ]; then
      record PASS "RPM: $n" "$(basename "$f")"
      if [ -n "$OS_MAJOR" ] && [[ $(basename "$f") != *".el${OS_MAJOR}"* ]]; then
        record WARN "RPM: $n" "the file name does not contain .el${OS_MAJOR}; it may not match this RHEL version"
      fi
    elif rpm -q "$n" >/dev/null 2>&1; then
      record PASS "RPM: $n" "not in the folder, but already installed ($(rpm -q "$n"))"
    else
      record FAIL "RPM: $n" "not found in $REPO_DIR and not installed"
      hint "Copy the $n RPM (and its dependencies) into $REPO_DIR, then run the script again."
    fi
  done
  if [ "$SELINUX_ACTIVE" = 1 ] && ! command -v semanage >/dev/null 2>&1; then
    if [ -n "${RPM_BY_NAME[policycoreutils-python-utils]:-}" ]; then
      record PASS "RPM: SELinux tools" "semanage missing, policycoreutils-python-utils found in the folder"
    else
      record FAIL "RPM: SELinux tools" "semanage is missing and policycoreutils-python-utils is not in the folder"
    fi
  fi
}

# verify_sums STRICT : checks the folder against SHA256SUMS (strict = a mismatch is a failure)
verify_sums() {
  local strict=$1 out rc bad
  if [ ! -f "$REPO_DIR/SHA256SUMS" ]; then
    if [ "$strict" = 1 ]; then
      record WARN "Copied files check" "no SHA256SUMS in $REPO_DIR, so the copy cannot be verified"
    fi
    return 0
  fi
  out=$(cd "$REPO_DIR" && sha256sum -c --quiet SHA256SUMS 2>&1); rc=$?
  if [ $rc -eq 0 ]; then
    record PASS "Copied files check" "every file matches SHA256SUMS"
  else
    bad=$(grep -E 'FAILED|No such file' <<< "$out" | head -5 | tr '\n' ' ')
    if [ "$strict" = 1 ]; then
      record FAIL "Copied files check" "mismatch: $bad"
      hint "These files were damaged or changed during the copy. Copy them again from the DMZ collector."
    else
      record WARN "Copied files check" "SHA256SUMS is out of date ($bad); it will be regenerated"
    fi
  fi
}

ask_listen_and_peers() {
  ask LISTEN_IP "IP address of this server that HAProxy and nginx listen on" "${LISTEN_IP:-$(detect_ip)}" is_local_ip
  if [ "$ROLE" = live ]; then
    ask DMZ_IP "IP address of the DMZ collector (its HAProxy on $OPAMP_PORT)" "${DMZ_IP}" is_remote_ip
  fi
}

ask_https() {
  local def=n
  [ "$HTTPS_ENABLE" = y ] && def=y
  explain "The HLD allows the package repository on 8080 and 443. Port 443 means HTTPS and needs a" \
          "certificate and private key (PEM files), ideally from Siyapatha's internal CA."
  if confirm "Also serve the files over HTTPS on $HTTPS_PORT?" "$def"; then
    HTTPS_ENABLE=y
    while true; do
      ask CERT_FILE "Certificate file (PEM)" "$CERT_FILE" is_file
      ask KEY_FILE "Private key file (PEM)" "$KEY_FILE" is_file
      if ! command -v openssl >/dev/null 2>&1; then
        record INFO "HTTPS certificate" "openssl not found, so the certificate and key were not cross-checked"
        break
      fi
      if [ "$(openssl x509 -in "$CERT_FILE" -noout -pubkey 2>/dev/null)" = "$(openssl pkey -in "$KEY_FILE" -pubout 2>/dev/null)" ] \
         && [ -n "$(openssl pkey -in "$KEY_FILE" -pubout 2>/dev/null)" ]; then
        record PASS "HTTPS certificate" "the key matches the certificate"
        if ! openssl x509 -in "$CERT_FILE" -noout -ext subjectAltName 2>/dev/null | grep -qF "$LISTEN_IP"; then
          record WARN "HTTPS certificate" "$LISTEN_IP is not in the certificate's names; clients will need -k or the DNS name"
        fi
        if ! openssl x509 -in "$CERT_FILE" -noout -checkend 0 >/dev/null 2>&1; then
          record WARN "HTTPS certificate" "the certificate has expired"
        fi
        break
      fi
      warn "The private key does not match the certificate (or one of them is not valid PEM)."
      confirm "Try other files?" y || { HTTPS_ENABLE=n; record INFO "HTTPS" "skipped"; break; }
    done
  else
    HTTPS_ENABLE=n
    record INFO "HTTPS on $HTTPS_PORT" "not enabled; files are served on $REPO_PORT only"
  fi
}

save_answers() {
  [ "$DRY_RUN" = 1 ] && return 0
  local v
  {
    echo "# $SCRIPT_NAME answers ($(date '+%F %T')). No secrets are stored here."
    for v in "${CONF_VARS[@]}"; do printf '%s=%q\n' "$v" "${!v}"; done
  } > "$CONF_FILE" && chmod 600 "$CONF_FILE"
}

show_port_plan() {
  section "Ports and Siyapatha HLD firewall rules"
  printf '  %-6s %-38s %s\n' "Port" "Service on this server" "HLD rule"
  if [ "$ROLE" = dmz ]; then
    printf '  %-6s %-38s %s\n' "$OPAMP_PORT" "HAProxy OpAMP relay (in, any source)" "PA-10 DMZ VLANs, PA-20 Head Office, FG-01 from LIVE"
    printf '  %-6s %-38s %s\n' "443" "HAProxy -> $BINDPLANE_HOST (out)" "PA-01"
    printf '  %-6s %-38s %s\n' "$REPO_PORT" "nginx file server (in, any source)" "PA-10, PA-20, FG-03 from LIVE"
    [ "$HTTPS_ENABLE" = y ] && printf '  %-6s %-38s %s\n' "$HTTPS_PORT" "nginx file server HTTPS (in)" "PA-10, PA-20, FG-03"
    printf '  %-6s %-38s %s\n' "$OTLP_PORT" "Bindplane collector (not touched)" "PA-10, PA-20, FG-02"
  else
    printf '  %-6s %-38s %s\n' "$OPAMP_PORT" "HAProxy OpAMP relay (in, any source)" "FG-10 LIVE server VLANs"
    printf '  %-6s %-38s %s\n' "$OPAMP_PORT" "HAProxy -> $DMZ_IP:$OPAMP_PORT (out)" "FG-01"
    printf '  %-6s %-38s %s\n' "$REPO_PORT" "nginx file server (in, any source)" "FG-10"
    [ "$HTTPS_ENABLE" = y ] && printf '  %-6s %-38s %s\n' "$HTTPS_PORT" "nginx file server HTTPS (in)" "FG-10"
    printf '  %-6s %-38s %s\n' "$OTLP_PORT" "Bindplane collector (not touched)" "FG-10, FG-02 to DMZ"
  fi
}

check_ports() {
  local port owner ports=("$OPAMP_PORT" "$REPO_PORT")
  [ "$HTTPS_ENABLE" = y ] && ports+=("$HTTPS_PORT")
  for port in "${ports[@]}"; do
    if port_busy "$port"; then
      owner=$(port_owner "$port")
      case $owner in
        haproxy|nginx) record INFO "Port $port" "already used by $owner (expected on a re-run)" ;;
        *) record FAIL "Port $port" "in use by ${owner:-an unknown process}"
           hint "Find it with: ss -tlnp | grep ':$port'  and stop it, or free the port." ;;
      esac
    else
      record PASS "Port $port" "free"
    fi
  done
  owner=$(port_owner "$OTLP_PORT")
  case $owner in
    "") record INFO "Port $OTLP_PORT" "free (the Bindplane collector will use it)" ;;
    haproxy|nginx) record FAIL "Port $OTLP_PORT" "taken by $owner, but it belongs to the Bindplane collector" ;;
    *) record INFO "Port $OTLP_PORT" "used by $owner (the collector), left alone" ;;
  esac
}

step1_prechecks() {
  section "Step 1 of 6 - Pre-checks and your answers"
  explain "Nothing is changed in this step, except firewalld or IP forwarding if you agree to it."
  require_cmds curl ss ip awk sed grep find sha256sum systemctl rpm dnf tac comm || abort_run "required tools are missing"
  check_firewall
  check_selinux
  check_ip_forward
  check_os
  choose_repo
  check_rpms
  [ "$ROLE" = live ] && verify_sums 1
  ask_listen_and_peers
  ask_https
  save_answers
  show_port_plan
  check_ports
  checkpoint "Step 1 - Pre-checks"
}

# ----------------------------------------------------------------------------
# Step 2 - reach the next hop before installing anything
# ----------------------------------------------------------------------------
step2_dmz_reach_bindplane() {
  section "Step 2 of 6 - Reach $BINDPLANE_HOST directly (PA-01, PA-04)"
  explain "Proves this server can reach Bindplane Cloud before HAProxy is put in front of it."
  local addr verify
  addr=$(getent hosts "$BINDPLANE_HOST" | awk '{print $1; exit}')
  if [ -n "$addr" ]; then
    record PASS "DNS (PA-04)" "$BINDPLANE_HOST -> $addr"
  else
    record FAIL "DNS (PA-04)" "$BINDPLANE_HOST does not resolve"
    hint "Check /etc/resolv.conf and rule PA-04 (DNS from bp-gw-dmz-01)."
  fi
  : > "$BODY_FILE"
  verify=$(curl -s -o /dev/null -w '%{http_code} %{ssl_verify_result}' --connect-timeout 8 --max-time 20 "https://$BINDPLANE_HOST/" 2>/dev/null)
  CURL_EXIT=$?
  CURL_CODE=${verify%% *}
  if [ "$CURL_EXIT" = 0 ] && [ "${verify##* }" = 0 ]; then
    record PASS "HTTPS to Bindplane (PA-01)" "HTTP $CURL_CODE, certificate verified"
  else
    record FAIL "HTTPS to Bindplane (PA-01)" "$(curl_reason)"
    case $CURL_EXIT in
      60|35) hint "The certificate is not the real Bindplane one: the Palo Alto is probably decrypting TLS." \
                  "Ask the network team to exclude $BINDPLANE_HOST from decryption." ;;
      28|7)  hint "Rule PA-01 (bp-gw-dmz-01 -> $BINDPLANE_HOST TCP 443) is missing or not matching this IP." ;;
      6)     hint "DNS does not resolve $BINDPLANE_HOST (PA-04, /etc/resolv.conf)." ;;
    esac
  fi
  checkpoint "Step 2 - Reach Bindplane"
}

step2_live_reach_dmz() {
  section "Step 2 of 6 - Reach the DMZ HAProxy (FG-01) before installing anything"
  explain "Sends a test request from $LISTEN_IP to the DMZ relay. A 4xx answer from Bindplane proves" \
          "FG-01, the DMZ HAProxy and the DMZ's own path to Bindplane in one go."
  check_relay "DMZ relay via FG-01" "http://$DMZ_IP:$OPAMP_PORT/v1/opamp" "$LISTEN_IP" "FG-01 (bp-gw-live-01 -> bp-gw-dmz-01 TCP $OPAMP_PORT)"
  curl_probe "http://$DMZ_IP:$REPO_PORT$URL_PATH" "$LISTEN_IP"
  if [ "$CURL_CODE" = 200 ]; then
    record PASS "DMZ file server via FG-03" "http://$DMZ_IP:$REPO_PORT$URL_PATH answers"
  else
    record WARN "DMZ file server via FG-03" "no answer ($(curl_reason)); not needed for this run because the files were copied by hand"
  fi
  checkpoint "Step 2 - Reach the DMZ relay"
}

# ----------------------------------------------------------------------------
# Step 3 - HAProxy
# ----------------------------------------------------------------------------
step3_haproxy() {
  section "Step 3 of 6 - Install and configure HAProxy on $LISTEN_IP:$OPAMP_PORT"
  if [ "$ROLE" = dmz ]; then
    explain "OpAMP from any source on $OPAMP_PORT is forwarded to $BINDPLANE_HOST:443 over verified TLS."
  else
    explain "OpAMP from any source on $OPAMP_PORT is forwarded only to the DMZ HAProxy at $DMZ_IP:$OPAMP_PORT."
  fi
  install_pkgs "HAProxy package" haproxy || { checkpoint "Step 3 - HAProxy"; return; }
  ensure_semanage || { checkpoint "Step 3 - HAProxy"; return; }
  selinux_bool_on haproxy_connect_any
  selinux_port "$OPAMP_PORT"

  local ver tmp out
  ver=$(haproxy_version)
  tmp=$(mktemp)
  if [ "$ROLE" = dmz ]; then
    gen_haproxy_dmz "$ver" > "$tmp"
    if ver_ge "$ver" 1.9; then
      record INFO "HAProxy DNS" "HAProxy $ver re-resolves $BINDPLANE_HOST every 60s from /etc/resolv.conf"
    else
      record INFO "HAProxy DNS" "HAProxy $ver resolves at start only; a daily reload keeps the IP fresh"
      echo "0 3 * * * root /usr/bin/systemctl reload haproxy" | write_file "$CRON_FILE" 0644
    fi
  else
    gen_haproxy_live > "$tmp"
  fi
  if command -v haproxy >/dev/null 2>&1; then
    if out=$(haproxy -c -f "$tmp" 2>&1); then
      record PASS "HAProxy config check" "the generated configuration is valid"
    else
      printf '%s\n' "$out" | sed 's/^/       | /'
      record FAIL "HAProxy config check" "haproxy -c rejected the generated configuration (shown above)"
      rm -f "$tmp"
      checkpoint "Step 3 - HAProxy"
      return
    fi
  else
    record INFO "HAProxy config check" "haproxy not installed yet (dry-run)"
  fi
  write_file "$HAPROXY_CFG" < "$tmp"
  rm -f "$tmp"
  if ! service_apply haproxy reload; then
    record FAIL "HAProxy service" "did not start"
    hint "See why: journalctl -u haproxy -n 30 --no-pager" "SELinux denials: ausearch -m avc -ts recent"
  elif [ "$DRY_RUN" = 1 ]; then
    record PLAN "HAProxy service" "would be enabled and started on $LISTEN_IP:$OPAMP_PORT"
  elif wait_listen "$OPAMP_PORT"; then
    record PASS "HAProxy service" "running and listening on $LISTEN_IP:$OPAMP_PORT"
  else
    record FAIL "HAProxy service" "not listening on $OPAMP_PORT"
    hint "See why: journalctl -u haproxy -n 30 --no-pager" \
         "If it says 'cannot bind socket': port $OPAMP_PORT is not in http_port_t, or $LISTEN_IP is wrong."
  fi
  checkpoint "Step 3 - HAProxy"
}

# ----------------------------------------------------------------------------
# Step 4 - test through HAProxy
# ----------------------------------------------------------------------------
step4_test_relay() {
  if [ "$ROLE" = dmz ]; then
    section "Step 4 of 6 - Test: this HAProxy -> $BINDPLANE_HOST"
  else
    section "Step 4 of 6 - Test both hops: this HAProxy -> DMZ HAProxy -> $BINDPLANE_HOST"
  fi
  if [ "$DRY_RUN" = 1 ]; then
    record PLAN "Relay test" "would send a test request to http://$LISTEN_IP:$OPAMP_PORT/v1/opamp"
    checkpoint "Step 4 - Relay test"
    return
  fi
  explain "A 4xx answer (such as 401) is created by Bindplane, never by HAProxy: it proves the whole path."
  check_relay "Relay test" "http://$LISTEN_IP:$OPAMP_PORT/v1/opamp" "$LISTEN_IP" \
    "$([ "$ROLE" = dmz ] && echo "PA-01" || echo "FG-01")"
  local line=""
  if command -v journalctl >/dev/null 2>&1; then
    line=$(journalctl -t haproxy -n 20 --no-pager 2>/dev/null | grep 'opamp_relay' | tail -1)
  fi
  if [ -n "$line" ]; then
    record PASS "HAProxy log" "request logged"
    explain "${line:0:200}"
  else
    record INFO "HAProxy log" "no log line found here; check by hand: journalctl -t haproxy -n 20"
  fi
  checkpoint "Step 4 - Relay test"
}

# ----------------------------------------------------------------------------
# Step 5 - nginx file server
# ----------------------------------------------------------------------------
disable_nginx_default_server() {
  local tmp
  if [ ! -f "$NGINX_CONF" ]; then
    [ "$DRY_RUN" = 1 ] && { record PLAN "nginx default site" "would be disabled in $NGINX_CONF"; return 0; }
    record FAIL "nginx default site" "$NGINX_CONF not found"
    return 1
  fi
  if ! grep -qE '^[[:space:]]*server[[:space:]]*\{' "$NGINX_CONF"; then
    record PASS "nginx default site" "no active server block in nginx.conf (port 80 not used)"
    return 0
  fi
  tmp=$(mktemp)
  awk '
    !c && /^[[:space:]]*server[[:space:]]*\{/ { c = 1; d = 0 }
    c {
      line = $0; o = gsub(/\{/, "{", line); cl = gsub(/\}/, "}", line); d += o - cl
      print "#bp# " $0
      if (d <= 0) c = 0
      next
    }
    { print }' "$NGINX_CONF" > "$tmp"
  write_file "$NGINX_CONF" < "$tmp"
  rm -f "$tmp"
  changed "nginx default site" "port 80 server block in nginx.conf commented out (#bp#), port 80 not in the HLD"
}

install_https_files() {
  [ "$HTTPS_ENABLE" = y ] || return 0
  ensure_dir "$NGINX_PKI/private" || return 1
  backup_once "$NGINX_CERT"
  backup_once "$NGINX_KEY"
  run install -m 0644 "$CERT_FILE" "$NGINX_CERT" || return 1
  run install -m 0600 "$KEY_FILE" "$NGINX_KEY" || return 1
  [ "$SELINUX_ACTIVE" = 1 ] && run restorecon -R "$NGINX_PKI"
  changed "HTTPS files" "certificate and key installed in $NGINX_PKI"
}

publish_folder() {
  local modes
  if [ "$DRY_RUN" != 1 ]; then
    modes="$RUN_DIR/modes-before"
    find "$REPO_DIR" -printf '%m %p\n' > "$modes"
    journal_add "restore file permissions in $REPO_DIR" bp_restore_modes "$modes"
  fi
  run chmod -R a+rX "$REPO_DIR"
  # SHA256SUMS: written via a temp file in the same folder, so it keeps the folder's SELinux label
  if [ "$DRY_RUN" = 1 ]; then
    record PLAN "SHA256SUMS" "would list every file in $REPO_DIR"
  else
    backup_once "$REPO_DIR/SHA256SUMS"
    # find excludes both names, so neither file is read while being written
    # shellcheck disable=SC2094
    (cd "$REPO_DIR" && find . -maxdepth 1 -type f ! -name SHA256SUMS ! -name .SHA256SUMS.tmp -printf '%f\0' \
      | sort -z | xargs -0 -r sha256sum > .SHA256SUMS.tmp && mv -f .SHA256SUMS.tmp SHA256SUMS)
    chmod 0644 "$REPO_DIR/SHA256SUMS"
    record PASS "SHA256SUMS" "$(wc -l < "$REPO_DIR/SHA256SUMS") files listed, so downloads can be verified"
  fi
}

test_file_server() {
  local scheme=$1 port=$2 n
  local -a extra=()
  [ "$scheme" = https ] && extra=(-k)
  curl_probe "$scheme://$LISTEN_IP:$port$URL_PATH" "$LISTEN_IP" "${extra[@]}"
  case $CURL_CODE in
    200) n=$(grep -oE 'href="[^"?/]+"' "$BODY_FILE" | sort -u | wc -l)
         record PASS "File server test ($scheme $port)" "$scheme://$LISTEN_IP:$port$URL_PATH lists $n files" ;;
    403) record FAIL "File server test ($scheme $port)" "HTTP 403: nginx may not read $REPO_DIR"
         hint "SELinux label: ls -lZ $REPO_DIR (must show httpd_sys_content_t)" \
              "Permissions on every parent folder: namei -l $REPO_DIR (others need x)" \
              "Error log: tail /var/log/nginx/bp-repo-error.log" ;;
    000) record FAIL "File server test ($scheme $port)" "no answer: $(curl_reason)"
         hint "Is nginx running? systemctl status nginx" ;;
    *)   record FAIL "File server test ($scheme $port)" "HTTP $CURL_CODE"
         hint "Error log: tail /var/log/nginx/bp-repo-error.log" ;;
  esac
}

step5_nginx() {
  section "Step 5 of 6 - nginx file server on $LISTEN_IP:$REPO_PORT$([ "$HTTPS_ENABLE" = y ] && echo " and $HTTPS_PORT")"
  explain "Anyone who reaches port $REPO_PORT can list and download every file in $REPO_DIR." \
          "Keep secrets (keys, passwords, config backups) out of that folder."
  local names out
  names=$(nginx_names)
  # shellcheck disable=SC2086
  install_pkgs "nginx package" $names || { checkpoint "Step 5 - nginx"; return; }
  ensure_semanage || { checkpoint "Step 5 - nginx"; return; }
  disable_nginx_default_server
  install_https_files || record FAIL "HTTPS files" "could not install the certificate and key"
  gen_nginx_site | write_file "$NGINX_SITE" 0644
  publish_folder
  selinux_label_dir "$REPO_DIR"
  selinux_port "$REPO_PORT"
  [ "$HTTPS_ENABLE" = y ] && selinux_port "$HTTPS_PORT"
  if [ "$DRY_RUN" != 1 ]; then
    if out=$(nginx -t 2>&1); then
      record PASS "nginx config check" "nginx -t: syntax is ok"
    else
      printf '%s\n' "$out" | sed 's/^/       | /'
      record FAIL "nginx config check" "nginx -t failed (shown above)"
      checkpoint "Step 5 - nginx"
      return
    fi
  fi
  if ! service_apply nginx reload; then
    record FAIL "nginx service" "did not start"
    hint "See why: journalctl -u nginx -n 30 --no-pager" "SELinux denials: ausearch -m avc -ts recent"
  elif [ "$DRY_RUN" = 1 ]; then
    record PLAN "nginx service" "would be enabled and started on $LISTEN_IP:$REPO_PORT"
  elif wait_listen "$REPO_PORT"; then
    record PASS "nginx service" "running and listening on $LISTEN_IP:$REPO_PORT"
    test_file_server http "$REPO_PORT"
    [ "$HTTPS_ENABLE" = y ] && test_file_server https "$HTTPS_PORT"
  else
    record FAIL "nginx service" "not listening on $REPO_PORT"
    hint "See why: journalctl -u nginx -n 30 --no-pager" \
         "If it says 'Permission denied' on the port: port $REPO_PORT is not in http_port_t."
  fi
  checkpoint "Step 5 - nginx"
}

# ----------------------------------------------------------------------------
# Step 6 - final port check
# ----------------------------------------------------------------------------
step6_final() {
  section "Step 6 of 6 - Final check: listening ports against the HLD"
  if [ "$DRY_RUN" = 1 ]; then
    record PLAN "Port check" "would compare HAProxy/nginx listening ports with the HLD rules"
    return
  fi
  local line proc addr port allowed rule found=0
  allowed=" $OPAMP_PORT $REPO_PORT "
  [ "$HTTPS_ENABLE" = y ] && allowed+="$HTTPS_PORT "
  while IFS= read -r line; do
    proc=$(grep -o 'users:(("[^"]*"' <<< "$line" | cut -d'"' -f2)
    addr=$(awk '{print $4}' <<< "$line")
    port=${addr##*:}
    # Only this server's chosen IP and all-address listeners belong to this setup
    case ${addr%:*} in "$LISTEN_IP"|0.0.0.0|"*"|"[::]") ;; *) continue ;; esac
    found=1
    case $port in
      "$OPAMP_PORT") rule=$([ "$ROLE" = dmz ] && echo "PA-10, PA-20, FG-01" || echo "FG-10") ;;
      "$REPO_PORT"|"$HTTPS_PORT") rule=$([ "$ROLE" = dmz ] && echo "PA-10, PA-20, FG-03" || echo "FG-10") ;;
      *) rule="" ;;
    esac
    if [[ $allowed == *" $port "* ]]; then
      record PASS "Port $port ($proc)" "listening on $addr, HLD rule: $rule"
    else
      record WARN "Port $port ($proc)" "listening on $addr, which is not in the HLD rule set"
    fi
  done < <(ss -H -tlnp 2>/dev/null | grep -E 'users:\(\("(haproxy|nginx)"' | sort -u)
  [ $found = 0 ] && record FAIL "Port check" "neither HAProxy nor nginx is listening"
}

finish_run() {
  if [ "$DRY_RUN" != 1 ]; then
    echo completed > "$RUN_DIR/status"
    section "Done"
    explain "Run ID: $(basename "$RUN_DIR")" \
            "To undo everything this run changed:  sudo bash $SCRIPT_NAME --rollback $(basename "$RUN_DIR")"
    if [ "$ROLE" = dmz ]; then
      explain "" "Next: copy $REPO_DIR to the LIVE collector, then run there:" \
              "  sudo bash $REPO_DIR/$SCRIPT_NAME --role live" \
              "(Copy this script into $REPO_DIR first if it is not there yet.)"
    else
      explain "" "LIVE agents use OpAMP endpoint  ws://$LISTEN_IP:$OPAMP_PORT/v1/opamp" \
              "LIVE servers download files from http://$LISTEN_IP:$REPO_PORT$URL_PATH"
    fi
  fi
  print_summary
}

# ----------------------------------------------------------------------------
# Modes
# ----------------------------------------------------------------------------
list_runs() {
  local d
  section "Previous runs (newest first)"
  [ -d "$STATE_DIR/runs" ] || { info "No runs recorded yet."; return 0; }
  printf '  %-17s %-6s %-12s %s\n' "Run ID" "Role" "Status" "Changes recorded"
  for d in $(find "$STATE_DIR/runs" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r); do
    printf '  %-17s %-6s %-12s %s\n' "$d" "$(cat "$STATE_DIR/runs/$d/role" 2>/dev/null)" \
      "$(cat "$STATE_DIR/runs/$d/status" 2>/dev/null)" "$(grep -c '' "$STATE_DIR/runs/$d/journal" 2>/dev/null || echo 0)"
  done
}

do_rollback() {
  local id=$1 d
  [ -d "$STATE_DIR/runs" ] || { info "No runs recorded, nothing to roll back."; return 0; }
  if [ "$id" = all ]; then
    warn "This rolls back every run that has not been rolled back yet, newest first."
    confirm "Continue?" n || return 0
    for d in $(find "$STATE_DIR/runs" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r); do
      rollback_run "$STATE_DIR/runs/$d"
    done
    return 0
  fi
  if [ -z "$id" ]; then
    id=$(find "$STATE_DIR/runs" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r | head -1)
  fi
  d="$STATE_DIR/runs/$id"
  [ -d "$d" ] || { err "No run with ID $id. See: sudo bash $SCRIPT_NAME --runs"; exit 1; }
  info "Run $id ($(cat "$d/role" 2>/dev/null) collector, status: $(cat "$d/status" 2>/dev/null))"
  if [ "$(cat "$d/status" 2>/dev/null)" = running ]; then
    warn "This run is marked as running: either it is still in progress or it was killed."
  fi
  confirm "Roll back run $id?" y || return 0
  rollback_run "$d"
}

usage() {
  cat <<EOF
$SCRIPT_NAME v$VERSION - HAProxy OpAMP relay + nginx file server (Siyapatha HLD v1.0)

  sudo bash $SCRIPT_NAME [--role dmz|live] [--dry-run]
        Set up this collector. --dry-run runs the checks and shows the changes without making them.
  sudo bash $SCRIPT_NAME --rollback [RUN_ID|all]
        Undo every change of the last run (or of RUN_ID, or of all runs).
  sudo bash $SCRIPT_NAME --runs
        List previous runs and their status.
  sudo bash $SCRIPT_NAME --diagnose
        Collect a support bundle for troubleshooting. Changes nothing.

Tip: run it inside tmux or screen. If the SSH session drops, the run is rolled back automatically.
Logs: $LOG_DIR   Runs and backups: $STATE_DIR/runs
EOF
}

main() {
  while [ $# -gt 0 ]; do
    case $1 in
      --role)     ROLE=${2:-}; shift 2 ;;
      --role=*)   ROLE=${1#*=}; shift ;;
      --dry-run)  DRY_RUN=1; shift ;;
      --rollback) MODE=rollback; if [ -n "${2:-}" ] && [[ $2 != --* ]]; then ROLLBACK_ID=$2; shift; fi; shift ;;
      --runs)     MODE=runs; shift ;;
      --diagnose) MODE=diagnose; shift ;;
      -h|--help)  usage; exit 0 ;;
      *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
  done
  if [ -n "$ROLE" ] && ! is_role "$ROLE"; then echo "Unknown role: $ROLE (use dmz or live)"; exit 1; fi
  if [ "$(id -u)" -ne 0 ]; then echo "Please run as root: sudo bash $SCRIPT_NAME"; exit 1; fi

  mkdir -p "$LOG_DIR" "$STATE_DIR/runs" 2>/dev/null || { echo "Cannot create $LOG_DIR or $STATE_DIR"; exit 1; }
  exec 9> "$STATE_DIR/lock"
  if ! flock -n 9; then echo "Another run of $SCRIPT_NAME is in progress on this server."; exit 1; fi

  LOG_FILE="$LOG_DIR/$MODE-$(hostname)-$TS.log"
  exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1
  BODY_FILE=$(mktemp)
  trap '[ -n "$BODY_FILE" ] && rm -f "$BODY_FILE"; sleep 0.3' EXIT
  trap ':' PIPE      # a handler, not "ignore", so started programs keep the default SIGPIPE

  case $MODE in
    runs)     list_runs; exit 0 ;;
    rollback) do_rollback "$ROLLBACK_ID"; exit 0 ;;
    diagnose)
      # shellcheck disable=SC1090
      [ -r "$CONF_FILE" ] && . "$CONF_FILE"
      make_bundle "manual diagnose"; exit 0 ;;
  esac

  section "$SCRIPT_NAME v$VERSION"
  explain "Sets up the HAProxy OpAMP relay and the nginx file server, following the Siyapatha HLD." \
          "Each step ends with a checkpoint. Every change is recorded and is rolled back if the run" \
          "stops part-way. firewalld is never enabled. Log: $LOG_FILE"
  [ "$DRY_RUN" = 1 ] && warn "DRY-RUN: checks run normally; changes are only shown, never made."
  if [ -r "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONF_FILE"
    info "Your previous answers are shown as defaults (from $CONF_FILE)."
  fi

  if [ "$DRY_RUN" != 1 ]; then
    RUN_DIR="$STATE_DIR/runs/$TS"
    mkdir -p "$RUN_DIR"
    JOURNAL="$RUN_DIR/journal"
    : > "$JOURNAL"
    echo running > "$RUN_DIR/status"
    ln -sfn "$RUN_DIR" "$STATE_DIR/last"
  fi
  trap 'abort_run "interrupted (Ctrl+C)"' INT
  trap 'abort_run "terminated"' TERM
  trap 'on_hangup' HUP

  if [ -z "$ROLE" ]; then
    local def=""
    case $(hostname) in *dmz*|*DMZ*) def=1 ;; *live*|*LIVE*) def=2 ;; esac
    echo
    echo "  1) DMZ collector  - HAProxy -> $BINDPLANE_HOST, nginx file server"
    echo "  2) LIVE collector - HAProxy -> DMZ HAProxy, nginx file server"
    ask ROLE "Which collector is this?" "$def" is_role
  fi
  case $ROLE in 1|dmz|DMZ) ROLE=dmz ;; *) ROLE=live ;; esac
  [ -n "$RUN_DIR" ] && echo "$ROLE" > "$RUN_DIR/role"
  info "Role: $ROLE collector"

  step1_prechecks
  if [ "$ROLE" = dmz ]; then step2_dmz_reach_bindplane; else step2_live_reach_dmz; fi
  step3_haproxy
  step4_test_relay
  step5_nginx
  step6_final
  finish_run
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
