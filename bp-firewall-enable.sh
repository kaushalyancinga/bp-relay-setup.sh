#!/usr/bin/env bash
# =============================================================================
#  bp-firewall-enable.sh - Turn firewalld on safely on a Bindplane gateway
#  (Siyapatha Finance PLC, HLD v1.0)
#
#  1. Finds every port that is listening now (and the HLD ports for this role)
#  2. Asks which sources may reach each port (default: any, so nothing breaks)
#  3. Writes all rules BEFORE firewalld starts (firewall-offline-cmd)
#  4. Arms a safety timer, then starts firewalld
#  5. You confirm from a NEW SSH session. No confirmation in time (locked out,
#     session lost, script killed) = the timer switches firewalld off again.
#
#  Your current SSH session's IP is always kept allowed. Everything is backed up
#  and can be undone with --rollback.
#
#  Usage:
#    sudo bash bp-firewall-enable.sh [--dry-run] [--revert-after SECONDS]
#    sudo bash bp-firewall-enable.sh --keep              confirm from another session
#    sudo bash bp-firewall-enable.sh --rollback [RUN_ID] undo a run
#    sudo bash bp-firewall-enable.sh --runs              list runs
# =============================================================================

VERSION="1.0"
SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")
SCRIPT_NAME=$(basename "$SCRIPT_PATH")
TS=$(date +%Y%m%d-%H%M%S)
STATE_DIR="${BP_FW_STATE_DIR:-/var/lib/bp-firewall}"
LOG_DIR="${BP_FW_LOG_DIR:-/var/log/bp-firewall}"
OS_RELEASE="${BP_OS_RELEASE:-/etc/os-release}"
FW_ETC=/etc/firewalld

MODE=setup
DRY_RUN=0
REVERT_SECS=300
ROLLBACK_ID=""
RUN_DIR=""
LOG_FILE=""
RESULTS=()
STEP_FAILED=0
ABORTING=0
NO_TTY=0
CHANGED=0          # 1 once /etc/firewalld was backed up and may have been changed
REPLY_LINE=""
FW_MODE=offline    # offline: firewalld stopped (firewall-offline-cmd); online: running (firewall-cmd --permanent)
PREV_ACTIVE=""; PREV_ENABLED=""
ROLE=""
SSH_CLIENT_IP=""
SSH_PORTS=()
ZONES=()
declare -A PORT_PROC=() PORT_ADDR=() PORT_SRC=()
PORT_KEYS=()       # "3001/tcp" ...

# ----------------------------------------------------------------------------
# Output, prompts, validators
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

record() {
  RESULTS+=("$1|$2|$3")
  case $1 in
    PASS) ok "$2: $3" ;;
    WARN) warn "$2: $3" ;;
    FAIL) err "$2: $3"; STEP_FAILED=1 ;;
    *)    info "$2: $3" ;;
  esac
}

print_summary() {
  section "Summary"
  local r s step detail pass=0 warnc=0 fail=0
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r s step detail <<< "$r"
    printf '  %-5s %-30s %s\n' "$s" "$step" "$detail"
    case $s in PASS) pass=$((pass+1));; WARN) warnc=$((warnc+1));; FAIL) fail=$((fail+1));; esac
  done
  printf '\n  %d passed, %d warnings, %d failed.\n' "$pass" "$warnc" "$fail"
  [ -n "$LOG_FILE" ] && printf '  Log: %s\n' "$LOG_FILE"
}

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
    case $rc in
      129) on_hangup ;;
      130) abort_run "interrupted (Ctrl+C)" ;;
      143) abort_run "terminated" ;;
      *)   abort_run "no answer available (input closed)" ;;
    esac
  fi
  [ -t 0 ] || printf '%s\n' "$REPLY_LINE" >&2
}

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

confirm() {
  local q=$1 def=${2:-n} hint_txt ans
  if [ "$def" = y ]; then hint_txt="Y/n"; else hint_txt="y/N"; fi
  prompt_line "  ? $q [$hint_txt]: "
  ans=$(trim "${REPLY_LINE:-$def}")
  [[ $ans =~ ^[Yy] ]]
}

is_ipv4() {
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local i
  for i in 1 2 3 4; do (( 10#${BASH_REMATCH[$i]} <= 255 )) || return 1; done
}
is_cidr4() {
  [[ $1 == */* ]] || return 1
  local b=${1#*/}
  is_ipv4 "${1%/*}" && [[ $b =~ ^[0-9]{1,2}$ ]] && (( 10#$b <= 32 ))
}
is_source()  { is_ipv4 "$1" || is_cidr4 "$1"; }
# "any", "skip", or a space/comma separated list of IPv4 addresses / CIDRs
is_src_answer() {
  local a=${1//,/ } x
  case $a in any|skip) return 0 ;; esac
  for x in $a; do is_source "$x" || return 1; done
}
is_src_answer_noskip() { [ "$1" != skip ] && is_src_answer "$1"; }
is_role()  { [[ $1 =~ ^(dmz|live|other)$ ]]; }

# ----------------------------------------------------------------------------
# Commands, firewalld wrappers
# ----------------------------------------------------------------------------
run() {
  if [ "$DRY_RUN" = 1 ]; then printf '       [dry-run] %s\n' "$*"; return 0; fi
  printf '       $ %s\n' "$*"
  "$@" 9>&-
}
# fw ARGS : change the permanent firewalld configuration (offline or online)
fw() {
  local -a cmd
  local out rc
  if [ "$FW_MODE" = offline ]; then
    # firewall-offline-cmd treats --remove-service as an old lokkit option that cannot be combined
    # with --zone; its zone-scoped form is --remove-service-from-zone
    local -a args=()
    local a
    for a in "$@"; do
      case $a in --remove-service=*) args+=("--remove-service-from-zone=${a#*=}") ;; *) args+=("$a") ;; esac
    done
    cmd=(firewall-offline-cmd "${args[@]}")
  else
    cmd=(firewall-cmd --permanent "$@")
  fi
  if [ "$DRY_RUN" = 1 ]; then printf '       [dry-run] %s\n' "${cmd[*]}"; return 0; fi
  printf '       $ %s\n' "${cmd[*]}"
  out=$("${cmd[@]}" 2>&1 9>&-); rc=$?
  [ $rc -ne 0 ] && printf '%s\n' "$out" | sed 's/^/       | /'
  return $rc
}
# fwq ARGS : read-only query of the permanent configuration (not printed)
fwq() {
  if [ "$FW_MODE" = offline ]; then firewall-offline-cmd "$@" 2>/dev/null; else firewall-cmd --permanent "$@" 2>/dev/null; fi
}
fw_running() { firewall-cmd --state >/dev/null 2>&1; }

# ----------------------------------------------------------------------------
# Rollback and the safety timer
# ----------------------------------------------------------------------------
# write_revert_script DIR : the action both the safety timer and --rollback rely on
write_revert_script() {
  local dir=$1
  cat > "$dir/revert.sh" <<EOF
#!/bin/sh
# Generated by $SCRIPT_NAME: puts firewalld back the way it was before run $(basename "$dir")
systemctl stop firewalld
if [ -f "$dir/etc-firewalld.tgz" ]; then
  rm -rf "$dir/firewalld-after"
  [ -d $FW_ETC ] && mv $FW_ETC "$dir/firewalld-after"
  tar -xzf "$dir/etc-firewalld.tgz" -C /etc
  command -v restorecon >/dev/null 2>&1 && restorecon -R $FW_ETC
fi
if [ "$PREV_ENABLED" = enabled ]; then systemctl enable firewalld; else systemctl disable firewalld; fi
if [ "$PREV_ACTIVE" = active ]; then systemctl start firewalld; fi
EOF
  chmod 0700 "$dir/revert.sh"
}

arm_timer() {
  local secs=$1 unit="bp-fw-revert-$TS"
  # The revert only happens if no "keep" flag exists, so cancelling can never trigger it by accident
  local action="[ -f '$RUN_DIR/keep' ] || { '$RUN_DIR/revert.sh' >> '$RUN_DIR/revert.out' 2>&1; echo reverted-by-safety-timer > '$RUN_DIR/status'; }"
  rm -f "$RUN_DIR/keep"
  if command -v systemd-run >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    run systemd-run --quiet --unit="$unit" --on-active="${secs}s" --timer-property=AccuracySec=1s \
        /bin/sh -c "$action" || return 1
    echo "systemd $unit" > "$RUN_DIR/timer"
  else
    # No systemd: a detached background job does the same
    ( setsid sh -c "sleep $secs; $action" </dev/null >/dev/null 2>&1 9>&- & echo "pid $!" > "$RUN_DIR/timer" )
  fi
  date -d "+${secs} seconds" '+%s' > "$RUN_DIR/timer-deadline" 2>/dev/null || echo $(( $(date +%s) + secs )) > "$RUN_DIR/timer-deadline"
}

cancel_timer() {
  local dir=$1 kind id kids
  [ -f "$dir/timer" ] || return 0
  touch "$dir/keep"                       # first: even if the timer fires now, it will not revert
  read -r kind id < "$dir/timer"
  case $kind in
    systemd) systemctl stop "$id.timer" >/dev/null 2>&1 ;;
    pid)     kids=$(pgrep -P "$id" 2>/dev/null); kill "$id" 2>/dev/null
             # shellcheck disable=SC2086  # several PIDs: splitting is intended
             [ -n "$kids" ] && kill $kids 2>/dev/null ;;   # the sleep it was waiting on
  esac
  rm -f "$dir/timer" "$dir/timer-deadline"
}

rollback_run() {
  local IFS=$' \t\n'
  local dir=$1 st
  st=$(cat "$dir/status" 2>/dev/null)
  if [ "$st" = rolled-back ]; then warn "Run $(basename "$dir") was already rolled back."; return 0; fi
  if [ ! -f "$dir/revert.sh" ]; then info "Run $(basename "$dir") changed nothing; nothing to roll back."; return 0; fi
  section "Rolling back run $(basename "$dir")"
  cancel_timer "$dir"
  explain "Stopping firewalld, restoring /etc/firewalld from the backup and its previous on/off state."
  if "$dir/revert.sh" >> "$dir/revert.out" 2>&1 9>&-; then
    echo rolled-back > "$dir/status"
    ok "Rollback complete: firewalld and its configuration are back to their state before this run."
  else
    warn "The rollback reported a problem; see $dir/revert.out"
  fi
}

abort_run() {
  [ "$ABORTING" = 1 ] && return 0
  ABORTING=1
  IFS=$' \t\n'
  trap 'warn "Rollback in progress, please wait."' INT TERM
  echo
  err "Run stopped: $1"
  if [ "$DRY_RUN" != 1 ] && [ "$CHANGED" = 1 ]; then
    echo aborted > "$RUN_DIR/status"
    local do_rb=1 ans=""
    if [ "$NO_TTY" = 0 ]; then
      printf '  ? Roll back to the previous firewall state? [Y/n] (yes automatically after 60s): ' >&2
      if IFS= read -r -t 60 ans; then
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
      [ -f "$RUN_DIR/timer" ] && warn "The safety timer is still armed and will switch firewalld off unless you run: sudo bash $SCRIPT_NAME --keep"
    fi
  else
    info "firewalld was not changed, so there is nothing to roll back."
  fi
  print_summary
  exit 1
}

on_hangup() {
  NO_TTY=1
  [ -n "$LOG_FILE" ] && exec >> "$LOG_FILE" 2>&1
  abort_run "SSH session lost (hang-up)"
}

checkpoint() {
  if [ "$DRY_RUN" = 1 ]; then STEP_FAILED=0; return 0; fi
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
# Discovery
# ----------------------------------------------------------------------------
hld_label() {   # hld_label PORT/PROTO
  case $1 in
    22/tcp)    echo "SSH administration (HLD 07: management network)" ;;
    3001/tcp)  echo "HAProxy OpAMP relay (PA-10, PA-20, FG-01 / FG-10)" ;;
    4317/tcp)  echo "Bindplane OTLP gRPC (PA-10, PA-20, FG-02 / FG-10)" ;;
    8080/tcp)  echo "nginx file server (PA-10, PA-20, FG-03 / FG-10)" ;;
    443/tcp)   echo "nginx file server HTTPS (PA-10, PA-20, FG-03 / FG-10)" ;;
    30002/tcp) echo "Panorama syslog (PA-11, PA-21)" ;;
    30004/udp) echo "FortiAnalyzer syslog (PA-12)" ;;
    30005/*)   echo "Panorama syslog (your setting; the HLD lists 30002)" ;;
    5514/tcp)  echo "Syslog (HLD 07)" ;;
    4318/tcp)  echo "Bindplane OTLP HTTP (not in the HLD)" ;;
    *)         echo "not in the HLD" ;;
  esac
}

role_ports() {
  case $ROLE in
    dmz)  echo "22/tcp 3001/tcp 4317/tcp 8080/tcp 30002/tcp 30004/udp" ;;
    live) echo "22/tcp 3001/tcp 4317/tcp 8080/tcp" ;;
    *)    echo "22/tcp" ;;
  esac
}

detect_ssh_client() {
  local p=$$ v n=0
  while [ -n "$p" ] && [ "$p" -gt 1 ] && [ $n -lt 15 ]; do
    v=$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | sed -n 's/^SSH_CONNECTION=//p' | head -1)
    if [ -n "$v" ]; then echo "${v%% *}"; return 0; fi
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    n=$((n+1))
  done
  # Fallback: the peer of an established connection to sshd
  ss -H -tnp state established 2>/dev/null | grep '"sshd' | awk '{print $4}' | sed -E 's/^\[?(::ffff:)?//; s/\]?:[0-9]+$//' | head -1
}

discover_ports() {
  local line proto local_addr addr port proc key
  PORT_KEYS=(); PORT_PROC=(); PORT_ADDR=()
  while IFS= read -r line; do
    proto=$(awk '{print $1}' <<< "$line")
    local_addr=$(awk '{print $5}' <<< "$line")
    port=${local_addr##*:}
    addr=${local_addr%:*}; addr=${addr%%%*}; addr=${addr#[}; addr=${addr%]}
    case $addr in 127.*|::1|::ffff:127.*|fe80:*) continue ;; esac   # loopback/link-local: no rule needed
    [[ $port =~ ^[0-9]+$ ]] || continue
    proc=$(grep -o 'users:(("[^"]*"' <<< "$line" | head -1 | cut -d'"' -f2)
    key="$port/$proto"
    if [ -z "${PORT_PROC[$key]+x}" ]; then PORT_KEYS+=("$key"); PORT_PROC[$key]=${proc:-?}; PORT_ADDR[$key]=$addr
    else [[ " ${PORT_ADDR[$key]} " == *" $addr "* ]] || PORT_ADDR[$key]+=" $addr"; fi
    [ "$proc" = sshd ] && [[ " ${SSH_PORTS[*]} " != *" $port "* ]] && SSH_PORTS+=("$port")
  done < <(ss -H -tulnp 2>/dev/null | awk '$1=="tcp" || $1=="udp"')
}

detect_zones() {
  local def dev name z
  ZONES=()
  def=$(if [ "$FW_MODE" = offline ]; then firewall-offline-cmd --get-default-zone; else firewall-cmd --get-default-zone; fi 2>/dev/null)
  def=${def:-public}
  if command -v nmcli >/dev/null 2>&1; then
    while IFS=: read -r dev name; do
      [ -z "$dev" ] || [ "$dev" = lo ] && continue
      z=$(nmcli -g connection.zone connection show "$name" 2>/dev/null)
      [ -z "$z" ] && z=$(fwq --get-zone-of-interface="$dev")
      z=${z:-$def}
      [[ " ${ZONES[*]} " == *" $z "* ]] || ZONES+=("$z")
    done < <(nmcli -t -f DEVICE,NAME connection show --active 2>/dev/null)
  fi
  [ ${#ZONES[@]} -eq 0 ] && ZONES=("$def")
}

# ----------------------------------------------------------------------------
# Steps
# ----------------------------------------------------------------------------
step1_prechecks() {
  section "Step 1 of 6 - Pre-checks"
  explain "Nothing is changed in this step."
  local missing=() c
  for c in ss awk systemctl tar ps; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if [ ${#missing[@]} -gt 0 ]; then record FAIL "Required tools" "missing: ${missing[*]}"; else record PASS "Required tools" "present"; fi
  if command -v firewall-offline-cmd >/dev/null 2>&1 && command -v firewall-cmd >/dev/null 2>&1; then
    record PASS "firewalld package" "installed"
  else
    record FAIL "firewalld package" "firewall-cmd / firewall-offline-cmd not found"
    hint "Install it from the repo folder or Satellite: dnf install firewalld"
    checkpoint "Step 1 - Pre-checks"; return
  fi
  PREV_ACTIVE=$(systemctl is-active firewalld 2>/dev/null); PREV_ACTIVE=${PREV_ACTIVE:-inactive}
  PREV_ENABLED=$(systemctl is-enabled firewalld 2>/dev/null); PREV_ENABLED=${PREV_ENABLED:-disabled}
  if [ "$PREV_ACTIVE" = active ]; then
    FW_MODE=online
    record INFO "firewalld" "already running ($PREV_ENABLED): missing rules will be added and reloaded"
  else
    FW_MODE=offline
    record PASS "firewalld" "currently $PREV_ACTIVE / $PREV_ENABLED: rules are prepared before it starts"
  fi
  local other
  for other in nftables iptables ip6tables; do
    if systemctl is-active --quiet "$other" 2>/dev/null; then
      record WARN "Other firewall" "$other.service is running; it conflicts with firewalld"
      hint "Stop it first: systemctl disable --now $other"
    fi
  done
  local id
  # shellcheck disable=SC1090
  id=$(. "$OS_RELEASE" 2>/dev/null; echo "${PRETTY_NAME:-unknown}")
  record INFO "Operating system" "$id"

  SSH_CLIENT_IP=$(detect_ssh_client)
  if is_ipv4 "${SSH_CLIENT_IP:-}"; then
    record PASS "Your SSH session" "comes from $SSH_CLIENT_IP: this IP is always kept allowed"
  else
    SSH_CLIENT_IP=""
    record WARN "Your SSH session" "could not detect your client IP"
    ask SSH_CLIENT_IP "IP address of the machine you are connected from" "" is_ipv4
    record INFO "Your SSH session" "$SSH_CLIENT_IP will always be kept allowed"
  fi
  ask ROLE "Role of this server (dmz / live / other)" "${ROLE:-$(case $(hostname) in *dmz*) echo dmz;; *live*) echo live;; *) echo other;; esac)}" is_role
  checkpoint "Step 1 - Pre-checks"
}

step2_ports() {
  section "Step 2 of 6 - Listening ports and who may reach them"
  explain "Ports that only listen on 127.0.0.1 are skipped: firewalld always allows local traffic."
  discover_ports
  if [ ${#SSH_PORTS[@]} -eq 0 ]; then
    SSH_PORTS=(22)
    record WARN "SSH port" "no sshd listener found; port 22 is kept open anyway"
  fi
  local k p
  for p in "${SSH_PORTS[@]}"; do
    [ -n "${PORT_PROC[$p/tcp]+x}" ] || { PORT_KEYS+=("$p/tcp"); PORT_PROC[$p/tcp]=sshd; PORT_ADDR[$p/tcp]="(expected)"; }
  done
  local missing=()
  for k in $(role_ports); do [ -n "${PORT_PROC[$k]+x}" ] || missing+=("$k"); done
  printf '\n  %-11s %-14s %-24s %s\n' "Port" "Process" "Listening on" "HLD"
  for k in "${PORT_KEYS[@]}"; do
    printf '  %-11s %-14s %-24s %s\n' "$k" "${PORT_PROC[$k]}" "${PORT_ADDR[$k]}" "$(hld_label "$k")"
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo
    explain "These HLD ports for a $ROLE collector are not listening right now: ${missing[*]}"
    if confirm "Allow them too, so their services work when they start?" y; then
      for k in "${missing[@]}"; do PORT_KEYS+=("$k"); PORT_PROC[$k]="(not running)"; PORT_ADDR[$k]="-"; done
    fi
  fi
  echo
  explain "For each port: Enter = any source (nothing breaks), or type IPs/CIDRs (e.g. 10.10.2.0/24 10.20.0.5)," \
          "or 'skip' to leave it closed. The HLD prefers specific sources once you know them."
  local ans
  for k in "${PORT_KEYS[@]}"; do
    if [[ " ${SSH_PORTS[*]} " == *" ${k%/*} "* ]] && [ "${k#*/}" = tcp ]; then
      ask ans "SSH $k: allow from (your $SSH_CLIENT_IP is always added)" "${PORT_SRC[$k]:-any}" is_src_answer_noskip
      ans=${ans//,/ }
      [ "$ans" != any ] && [[ " $ans " != *" $SSH_CLIENT_IP "* ]] && ans+=" $SSH_CLIENT_IP"
    else
      ask ans "$k (${PORT_PROC[$k]}): allow from" "any" is_src_answer
      ans=${ans//,/ }
      [ "$ans" = skip ] && warn "$k stays closed: ${PORT_PROC[$k]} will no longer be reachable from other machines."
    fi
    PORT_SRC[$k]=$(trim "$ans")
  done
  checkpoint "Step 2 - Ports"
}

step3_plan() {
  section "Step 3 of 6 - The plan"
  detect_zones
  record INFO "firewalld zone(s)" "${ZONES[*]} (the zone(s) your network interfaces use)"
  printf '\n  %-11s %-14s %s\n' "Port" "Process" "Allowed from"
  local k
  for k in "${PORT_KEYS[@]}"; do
    printf '  %-11s %-14s %s\n' "$k" "${PORT_PROC[$k]}" "${PORT_SRC[$k]}"
  done
  echo
  explain "Existing firewalld rules are kept. All other incoming connections will be refused." \
          "Outgoing traffic (HAProxy to Bindplane, LIVE to DMZ, collector to SecOps) is not affected."
  if [ "$DRY_RUN" = 1 ]; then
    explain "" "DRY-RUN: these are the commands a real run would use:"
    local z
    for z in "${ZONES[@]}"; do write_rules "$z"; done
    record INFO "Dry-run" "nothing was changed"
    return
  fi
  checkpoint "Step 3 - Plan"
}

# write_rules ZONE : adds the rules for every chosen port to one zone
write_rules() {
  local z=$1 k port proto src fam srcs
  for k in "${PORT_KEYS[@]}"; do
    port=${k%/*}; proto=${k#*/}; srcs=${PORT_SRC[$k]}
    [ "$srcs" = skip ] && continue
    if [ "$srcs" = any ]; then
      fw --zone="$z" --add-port="$port/$proto" || return 1
    else
      for src in $srcs; do
        fam=ipv4
        fw --zone="$z" --add-rich-rule="rule family=\"$fam\" source address=\"$src\" port port=\"$port\" protocol=\"$proto\" accept" || return 1
      done
      # A restricted SSH port must not stay open to everyone through the default "ssh" service
      if [[ " ${SSH_PORTS[*]} " == *" $port "* ]] && [ "$proto" = tcp ] && fwq --zone="$z" --query-service=ssh >/dev/null; then
        fw --zone="$z" --remove-service=ssh || return 1
      fi
    fi
  done
}

step4_write() {
  section "Step 4 of 6 - Write the rules (firewalld $([ "$FW_MODE" = offline ] && echo "still off" || echo "keeps running"))"
  # Backup and the revert action exist before anything is changed
  tar -czf "$RUN_DIR/etc-firewalld.tgz" -C /etc firewalld 2>/dev/null || { record FAIL "Backup" "could not back up $FW_ETC"; checkpoint "Step 4 - Rules"; return; }
  printf 'PREV_ACTIVE=%s\nPREV_ENABLED=%s\n' "$PREV_ACTIVE" "$PREV_ENABLED" > "$RUN_DIR/previous-state"
  write_revert_script "$RUN_DIR"
  CHANGED=1
  record PASS "Backup" "$FW_ETC saved; previous state: $PREV_ACTIVE / $PREV_ENABLED"
  local z ok_all=1
  for z in "${ZONES[@]}"; do
    if write_rules "$z"; then record PASS "Rules ($z)" "written"; else record FAIL "Rules ($z)" "a firewall command failed (shown above)"; ok_all=0; fi
  done
  local out
  if [ "$FW_MODE" = offline ]; then out=$(firewall-offline-cmd --check-config 2>&1); else out=$(firewall-cmd --check-config 2>&1); fi
  if [ $? -eq 0 ]; then record PASS "Config check" "firewalld accepts the configuration"; else
    printf '%s\n' "$out" | sed 's/^/       | /'; record FAIL "Config check" "firewalld rejected the configuration"; ok_all=0
  fi
  if [ $ok_all = 1 ]; then
    for z in "${ZONES[@]}"; do
      info "Zone $z will allow:"
      fwq --zone="$z" --list-all | sed 's/^/         /'
    done
  fi
  checkpoint "Step 4 - Rules"
}

count_estab() { ss -H -tn state established "( sport = :$1 )" 2>/dev/null | wc -l; }

step5_enable() {
  section "Step 5 of 6 - Turn firewalld on, with the safety timer armed"
  local k before=() after=() i port
  for k in "${PORT_KEYS[@]}"; do before+=("$(count_estab "${k%/*}")"); done
  if ! arm_timer "$REVERT_SECS"; then
    record FAIL "Safety timer" "could not be armed; not starting firewalld without it"
    return 1
  fi
  record PASS "Safety timer" "armed: firewalld goes back off in ${REVERT_SECS}s unless you confirm in step 6"
  run systemctl enable firewalld >/dev/null 2>&1      # on at boot too (rollback restores the old setting)
  if [ "$FW_MODE" = offline ]; then
    run systemctl start firewalld
  else
    run firewall-cmd --reload                        # keeps established connections
  fi
  for i in $(seq 1 30); do fw_running && break; sleep 0.5; done
  if fw_running; then record PASS "firewalld" "running"; else
    record FAIL "firewalld" "did not start"; hint "See why: journalctl -u firewalld -n 30 --no-pager"
    return 1
  fi
  local z
  for z in "${ZONES[@]}"; do
    for k in "${PORT_KEYS[@]}"; do
      [ "${PORT_SRC[$k]}" = any ] || continue
      firewall-cmd --zone="$z" --query-port="$k" >/dev/null 2>&1 \
        || record FAIL "Active rule $k" "not active in zone $z"
    done
  done
  record PASS "Active rules" "loaded in zone(s) ${ZONES[*]}"
  sleep 5
  printf '\n  %-11s %-14s %-10s %s\n' "Port" "Process" "Still up" "Connections before -> now"
  for i in "${!PORT_KEYS[@]}"; do
    k=${PORT_KEYS[$i]}; port=${k%/*}
    after[$i]=$(count_estab "$port")
    local up="yes"
    [ -n "$(ss -H -tuln "( sport = :$port )" 2>/dev/null)" ] || up="no"
    [ "${PORT_PROC[$k]}" = "(not running)" ] && up="-"
    printf '  %-11s %-14s %-10s %s -> %s\n' "$k" "${PORT_PROC[$k]}" "$up" "${before[$i]}" "${after[$i]}"
    if [ "${PORT_SRC[$k]}" != skip ] && [ "${after[$i]}" -lt "${before[$i]}" ]; then
      record WARN "Connections $k" "dropped from ${before[$i]} to ${after[$i]}; agents usually reconnect within a minute"
    fi
  done
  echo
  explain "Test from ANOTHER machine now (each should connect):"
  for k in "${PORT_KEYS[@]}"; do
    [ "${PORT_SRC[$k]}" = skip ] && continue
    case ${k#*/} in
      tcp) explain "  $k:  nc -zv <this server> ${k%/*}     (or: curl -v telnet://<this server>:${k%/*})" ;;
      udp) explain "  $k:  echo test | nc -u -w1 <this server> ${k%/*}   (then check the collector receives it)" ;;
    esac
  done
}

step6_confirm() {
  section "Step 6 of 6 - Confirm you can still get in"
  local deadline left ans
  deadline=$(cat "$RUN_DIR/timer-deadline" 2>/dev/null || echo $(( $(date +%s) + REVERT_SECS )))
  left=$(( deadline - $(date +%s) - 5 )); [ $left -lt 10 ] && left=10
  explain "1. Keep this session open." \
          "2. Open a NEW SSH session to this server." \
          "3. Check your services (the Bindplane console shows the collectors connected)." \
          "If the new session works, answer 'yes'. If you cannot get in, do nothing:" \
          "firewalld is switched off automatically in about ${left}s and the server is reachable again." \
          "(From another session you can also confirm with: sudo bash $SCRIPT_NAME --keep)"
  printf '  ? Does a NEW SSH session work, and are the services fine? [yes/no] (%ss): ' "$left" >&2
  if IFS= read -r -t "$left" ans; then
    [ -t 0 ] || printf '%s\n' "$ans" >&2
    ans=$(trim "$ans")
    if [[ $ans =~ ^[Yy] ]]; then
      if [ ! -f "$RUN_DIR/timer" ] && [ "$(cat "$RUN_DIR/status" 2>/dev/null)" = completed ]; then
        record PASS "Confirmed" "already confirmed with --keep"
      else
        cancel_timer "$RUN_DIR"
        echo completed > "$RUN_DIR/status"
        record PASS "Confirmed" "safety timer cancelled; firewalld stays on and starts at boot"
      fi
      return 0
    fi
    record WARN "Not confirmed" "you answered '$ans': rolling back now"
  else
    printf '\n' >&2
    if [ "$(cat "$RUN_DIR/status" 2>/dev/null)" = completed ]; then
      record PASS "Confirmed" "confirmed from another session with --keep"
      return 0
    fi
    record WARN "Not confirmed" "no answer in time: rolling back"
  fi
  rollback_run "$RUN_DIR"
  record INFO "Result" "firewalld is back to its previous state ($PREV_ACTIVE / $PREV_ENABLED)"
}

# ----------------------------------------------------------------------------
# Modes
# ----------------------------------------------------------------------------
last_run() { find "$STATE_DIR/runs" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r | head -1; }

do_keep() {
  local id d
  id=$(last_run); d="$STATE_DIR/runs/$id"
  if [ -z "$id" ] || [ ! -f "$d/timer" ]; then info "No armed safety timer found; nothing to confirm."; return 0; fi
  cancel_timer "$d"
  echo completed > "$d/status"
  ok "Confirmed: the safety timer of run $id is cancelled. firewalld stays on."
}

list_runs() {
  local d
  section "Runs (newest first)"
  printf '  %-17s %s\n' "Run ID" "Status"
  for d in $(find "$STATE_DIR/runs" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r); do
    printf '  %-17s %s\n' "$d" "$(cat "$STATE_DIR/runs/$d/status" 2>/dev/null)"
  done
}

do_rollback() {
  local id=${1:-$(last_run)} d
  d="$STATE_DIR/runs/$id"
  if [ -z "$id" ] || [ ! -d "$d" ]; then err "No run found${1:+ with ID $1}."; exit 1; fi
  confirm "Roll back run $id (status: $(cat "$d/status" 2>/dev/null))?" y || return 0
  rollback_run "$d"
}

usage() {
  cat <<EOF
$SCRIPT_NAME v$VERSION - turn firewalld on safely (Siyapatha HLD v1.0)

  sudo bash $SCRIPT_NAME [--dry-run] [--revert-after SECONDS]   (default safety window: 300s)
  sudo bash $SCRIPT_NAME --keep                confirm from another session (cancels the safety timer)
  sudo bash $SCRIPT_NAME --rollback [RUN_ID]   undo a run
  sudo bash $SCRIPT_NAME --runs                list runs
EOF
}

main() {
  while [ $# -gt 0 ]; do
    case $1 in
      --dry-run)      DRY_RUN=1; shift ;;
      --revert-after) REVERT_SECS=${2:-}; shift 2 ;;
      --keep)         MODE=keep; shift ;;
      --rollback)     MODE=rollback; if [ -n "${2:-}" ] && [[ $2 != --* ]]; then ROLLBACK_ID=$2; shift; fi; shift ;;
      --runs)         MODE=runs; shift ;;
      -h|--help)      usage; exit 0 ;;
      *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
  done
  if ! [[ $REVERT_SECS =~ ^[0-9]+$ ]] || [ "$REVERT_SECS" -lt 30 ]; then
    echo "--revert-after needs a number of seconds, at least 30"; exit 1
  fi
  [ "$(id -u)" -eq 0 ] || { echo "Please run as root: sudo bash $SCRIPT_NAME"; exit 1; }
  mkdir -p "$LOG_DIR" "$STATE_DIR/runs" || exit 1

  case $MODE in
    keep)     do_keep; exit 0 ;;
    runs)     list_runs; exit 0 ;;
  esac
  exec 9> "$STATE_DIR/lock"
  flock -n 9 || { echo "Another run of $SCRIPT_NAME is in progress."; exit 1; }
  LOG_FILE="$LOG_DIR/$MODE-$(hostname)-$TS.log"
  exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1
  trap 'sleep 0.3' EXIT
  trap ':' PIPE
  [ "$MODE" = rollback ] && { do_rollback "$ROLLBACK_ID"; exit 0; }

  section "$SCRIPT_NAME v$VERSION"
  explain "Turns firewalld on without interrupting the services listening on this server." \
          "Your SSH session's IP is always kept allowed, and a safety timer switches the firewall" \
          "off again if you cannot confirm access from a new session. Log: $LOG_FILE"
  [ "$DRY_RUN" = 1 ] && warn "DRY-RUN: nothing will be changed."
  if [ "$DRY_RUN" != 1 ]; then
    RUN_DIR="$STATE_DIR/runs/$TS"; mkdir -p "$RUN_DIR"; echo running > "$RUN_DIR/status"
  fi
  trap 'abort_run "interrupted (Ctrl+C)"' INT
  trap 'abort_run "terminated"' TERM
  trap 'on_hangup' HUP

  step1_prechecks
  step2_ports
  step3_plan
  if [ "$DRY_RUN" = 1 ]; then print_summary; exit 0; fi
  step4_write
  step5_enable
  # Step 6 is the confirmation itself; only stop here if step 5 found a problem
  [ "$STEP_FAILED" = 1 ] && checkpoint "Step 5 - Enable"
  step6_confirm
  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
