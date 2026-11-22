#!/usr/bin/env bash
# =============================================================================
#  XDC Secure RPC & WSS  ·  xdc-rpc
#  Sets up and manages an XDC node with private RPC (HTTPS) and WebSocket (WSS)
#  endpoints that only the IP addresses you choose can reach.
#
#  Guide:   https://xdcoutpost.xyz/XDC-Secure-RPC-WSS-test/
#  Source:  https://github.com/s4njk4n/XDC-Secure-RPC-WSS-test
#  Licence: MIT. Provided as is, without warranty.
# =============================================================================

# ── Maintainer settings ───────────────────────────────────────────────────────
# To change any of these: edit, bump XDC_RPC_VERSION, then publish a new
# release (see MAINTAINING.md). Nodes pick the change up when they update.
XDC_RPC_VERSION="2.0.0"
XDC_RPC_REPO="s4njk4n/XDC-Secure-RPC-WSS-test"

# Plugin RPCaaS gateway address(es). Nodes that opt in to serving Plugin's
# RPCaaS are given exactly this list; they never edit it themselves.
PLUGIN_RPCAAS_IPS=(
  "194.163.189.137"
)

XINFIN_NODE_REPO="https://github.com/XinFinOrg/XinFin-Node.git"
SNAPSHOT_BASE_URL="https://rpc.xdc.network/snapshots"
# ──────────────────────────────────────────────────────────────────────────────

XDC_RPC_GUIDE_URL="https://xdcoutpost.xyz/XDC-Secure-RPC-WSS-test/"
XDC_RPC_RELEASES_URL="https://github.com/${XDC_RPC_REPO}/releases"
XDC_RPC_DOWNLOAD_BASE="$XDC_RPC_RELEASES_URL"

# Where things live
SELF_INSTALL_PATH=/usr/local/sbin/xdc-rpc
LIB_DIR=/usr/local/lib/xdc-rpc
CONF_DIR=/etc/xdc-rpc
CONF_FILE=$CONF_DIR/xdc-rpc.conf
ALLOW_FILE=$CONF_DIR/allowlist
BACKUP_PASS_FILE=$CONF_DIR/backup.pass
STATE_DIR=/var/lib/xdc-rpc
STATE_FILE=$STATE_DIR/state
JOB_DIR=$STATE_DIR/jobs
UNDO_DIR=$STATE_DIR/undo
LOG_DIR=/var/log/xdc-rpc
LOCK_FILE=$STATE_DIR/lock

ACME_ROOT=/var/www/xdc-rpc-acme
NGINX_SITE=/etc/nginx/sites-available/xdc-node
NGINX_SITE_LINK=/etc/nginx/sites-enabled/xdc-node
NGINX_DEFAULT_SITE=/etc/nginx/sites-available/xdc-rpc-default
NGINX_DEFAULT_LINK=/etc/nginx/sites-enabled/xdc-rpc-default
NGINX_ALLOW_RPC=/etc/nginx/snippets/xdc-rpc-allow-rpc.conf
NGINX_ALLOW_WSS=/etc/nginx/snippets/xdc-rpc-allow-wss.conf
NGINX_TLS_SNIPPET=/etc/nginx/snippets/xdc-rpc-tls.conf
NGINX_HTTP_CONF=/etc/nginx/conf.d/xdc-rpc.conf

SSHD_PORT_CONF=/etc/ssh/sshd_config.d/00-xdc-rpc-port.conf
SSHD_AUTH_CONF=/etc/ssh/sshd_config.d/00-xdc-rpc-auth.conf
F2B_JAIL=/etc/fail2ban/jail.d/xdc-rpc-sshd.local
F2B_JAIL_V1=/etc/fail2ban/jail.d/sshd-hardened.local

LE_DIR=/etc/letsencrypt
LE_HOOK_DIR=$LE_DIR/renewal-hooks
MOTD_SCRIPT=/etc/update-motd.d/90-xdc-rpc
DAILY_UNIT=xdc-rpc-daily

BACKUP_KEEP=10
UNDO_MINUTES=10

# =============================================================================
#  Basic helpers
# =============================================================================
set -o pipefail
umask 022
export LC_ALL=C.UTF-8 2>/dev/null || export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

if [[ -t 1 ]]; then
  C_RED=$'\e[0;31m'; C_GRN=$'\e[0;32m'; C_YLW=$'\e[0;33m'; C_BLU=$'\e[0;34m'
  C_BLD=$'\e[1m'; C_DIM=$'\e[2m'; C_OFF=$'\e[0m'
else
  C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_BLD=''; C_DIM=''; C_OFF=''
fi

# XDC_LOG, when set, receives a copy of every message (background jobs).
XDC_LOG="${XDC_LOG:-}"
_logline() { [[ -n $XDC_LOG ]] && printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$XDC_LOG" 2>/dev/null; return 0; }
info() { printf '%s\n' "${C_BLU}•${C_OFF} $*"; _logline "INFO  $*"; }
ok()   { printf '%s\n' "${C_GRN}✓${C_OFF} $*"; _logline "OK    $*"; }
warn() { printf '%s\n' "${C_YLW}!${C_OFF} $*" >&2; _logline "WARN  $*"; }
err()  { printf '%s\n' "${C_RED}✗${C_OFF} $*" >&2; _logline "ERROR $*"; }
die()  { err "$*"; exit 1; }
log_to() {   # log_to FILE: keep a copy of every message in FILE (trimmed once it passes 1 MB)
  mkdir -p "$(dirname "$1")"; export XDC_LOG="$1"
  if [[ -f $XDC_LOG ]] && (( $(stat -c %s "$XDC_LOG") > 1048576 )); then
    tail -c 262144 "$XDC_LOG" >"$XDC_LOG.tmp" && mv -f "$XDC_LOG.tmp" "$XDC_LOG"
  fi
  ( umask 077; : >>"$XDC_LOG" ); chmod 600 "$XDC_LOG" 2>/dev/null
  return 0
}

have() { command -v "$1" >/dev/null 2>&1; }
is_root() { [[ ${EUID:-$(id -u)} -eq 0 ]]; }
trim() { local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
now() { date +%s; }
ts() { date +%Y%m%d-%H%M%S; }
systemd_ok() { [[ -d /run/systemd/system ]]; }

# run CMD...: run a command, sending its output to the job log when there is one
run() {
  _logline "RUN   $*"
  if [[ -n $XDC_LOG ]]; then "$@" >>"$XDC_LOG" 2>&1; else "$@"; fi
}

fmt_num() { printf '%s' "$1" | sed -E ':a;s/([0-9])([0-9]{3})($|,)/\1,\2\3/;ta'; }   # 1234567 -> 1,234,567

# version_gt A B: true if version A is newer than B (1.10.0 > 1.9.9)
version_gt() {
  [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]
}

# ── Validation ────────────────────────────────────────────────────────────────
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

valid_domain() {
  local d; d=$(lower "$1")
  [[ ${#d} -le 253 ]] && [[ "$d" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

valid_email() { [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]]; }

valid_username() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && [[ "$1" != root ]]
}

valid_node_name() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; }

# normalize_ipv4 INPUT -> prints "NORMALISED PREFIXLEN"
# exit 2 = not an address, 3 = IPv6 (not supported), 4 = too broad
normalize_ipv4() {
  python3 -I - "$1" <<'PY'
import ipaddress, sys
s = sys.argv[1].strip()
try:
    n = ipaddress.ip_network(s, strict=False)
except ValueError:
    sys.exit(2)
if n.version != 4:
    sys.exit(3)
if n.prefixlen < 8:
    sys.exit(4)
print((str(n.network_address) if n.prefixlen == 32 else str(n)), n.prefixlen)
PY
}

sanitize_label() {
  local l; l=$(printf '%s' "$1" | tr -cd 'A-Za-z0-9 ._()+-' | tr -s ' ' | cut -c1-40)
  l=$(trim "$l")
  printf '%s' "${l:-Unlabelled}"
}

# A strong, easy-to-type password: 5 groups of 4 (no look-alike characters)
gen_password() {
  local raw
  raw=$(LC_ALL=C tr -dc 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789' </dev/urandom | head -c 20)
  printf '%s-%s-%s-%s-%s' "${raw:0:4}" "${raw:4:4}" "${raw:8:4}" "${raw:12:4}" "${raw:16:4}"
}

password_problem() {   # prints a reason if the password is too weak; empty if fine
  local p="$1" user="$2"
  if (( ${#p} < 12 )); then echo "Use at least 12 characters."; return; fi
  if [[ -n $user && "$(lower "$p")" == *"$(lower "$user")"* ]]; then echo "Don't include the username."; return; fi
  case "$(lower "$p")" in
    *password*|*123456*|*qwerty*|*letmein*|*xdcnode*) echo "That's too easy to guess."; return ;;
  esac
}

# ── Network helpers ──────────────────────────────────────────────────────────
public_ipv4() {
  local u ip
  for u in https://checkip.amazonaws.com https://api.ipify.org https://ipv4.icanhazip.com; do
    ip=$(curl -4 -fsS --max-time 8 "$u" 2>/dev/null | tr -d '[:space:]')
    if [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then printf '%s' "$ip"; return 0; fi
  done
  return 1
}

resolve_a() {   # prints the IPv4 addresses DOMAIN resolves to
  local d="$1"
  if have dig; then
    dig +short +time=5 +tries=2 A "$d" 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$'
  else
    getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | grep -v '^127\.' | sort -u
  fi
}

# ── Key=value files (config and state) ───────────────────────────────────────
# Values are stored raw (one per line) and parsed, never sourced.
declare -gA CONF=()
declare -gA STATE=()

_kv_load() {   # _kv_load FILE ARRAYNAME
  local file="$1"
  # shellcheck disable=SC2178
  local -n arr="$2"
  local line k
  arr=()
  [[ -f $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == *=* ]] || continue
    k=${line%%=*}
    [[ $k =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
    arr[$k]="${line#*=}"
  done <"$file"
}

_kv_save() {   # _kv_save FILE ARRAYNAME MODE
  local file="$1" mode="${3:-600}"
  # shellcheck disable=SC2178
  local -n arr="$2"
  local tmp k
  mkdir -p "$(dirname "$file")"
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  for k in $(printf '%s\n' "${!arr[@]}" | sort); do
    printf '%s=%s\n' "$k" "${arr[$k]//$'\n'/ }" >>"$tmp"
  done
  chmod "$mode" "$tmp" && mv -f "$tmp" "$file"
}

conf_load()  { _kv_load "$CONF_FILE" CONF; }
conf_save()  { mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"; _kv_save "$CONF_FILE" CONF 600; }
conf_get()   { local v="${CONF[$1]:-}"; printf '%s' "${v:-${2:-}}"; }
conf_set()   { CONF[$1]="$2"; conf_save; }
conf_update() {   # conf_update KEY VALUE: change one saved setting, keeping changes another process saved meanwhile
  [[ ${CONF[$1]+set} && ${CONF[$1]} == "$2" ]] && return 0
  conf_load; CONF[$1]="$2"; conf_save
}
state_load() { _kv_load "$STATE_FILE" STATE; }
state_save() { mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"; _kv_save "$STATE_FILE" STATE 600; }
state_get()  { local v="${STATE[$1]:-}"; printf '%s' "${v:-${2:-}}"; }
state_set()  { state_load; STATE[$1]="$2"; state_save; }
configured() { [[ -f $CONF_FILE ]] && [[ -n "$(conf_get DOMAIN)" ]]; }

# ── Locking: only one change to the system at a time ─────────────────────────
lock_take() {
  mkdir -p "$STATE_DIR"
  exec 9>"$LOCK_FILE"
  if ! flock -w "${1:-600}" 9; then
    err "Another xdc-rpc task is still making changes. Try again in a few minutes."
    return 1
  fi
}
lock_drop() { flock -u 9 2>/dev/null; exec 9>&-; return 0; }   # (a redirection on this exec would stay for the rest of the script)

# ── Admin user helpers ───────────────────────────────────────────────────────
user_home() { getent passwd "$1" | cut -d: -f6; }
admin_home() {   # the admin user's home; their home-to-be if setup hasn't made the user yet (never "/")
  local u h; u=$(conf_get ADMIN_USER root); h=$(user_home "$u")
  if [[ -n $h && $h != / ]]; then printf '%s' "$h"
  elif [[ -n $u && $u != root ]] && ! user_exists "$u"; then printf '/home/%s' "$u"
  else printf '/root'; fi
}
user_exists() { getent passwd "$1" >/dev/null 2>&1; }
user_is_sudoer() { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx -e sudo -e admin; }

sudo_users() {   # login users (uid >= 1000) in the sudo group
  local u
  for u in $(getent group sudo | cut -d: -f4 | tr ',' ' '); do
    local uid shell
    uid=$(id -u "$u" 2>/dev/null) || continue
    shell=$(getent passwd "$u" | cut -d: -f7)
    (( uid >= 1000 )) && [[ $shell != */nologin && $shell != */false ]] && echo "$u"
  done
}

# =============================================================================
#  User interface: arrow-key dialogs with a plain-text fallback
#  dialog is used when it's there (installed with the tools the menus need):
#  every screen has its default button highlighted, ↑↓ scroll long pages, and
#  Enter presses the highlighted button. whiptail (part of Ubuntu) is the
#  fallback, then plain text.
# =============================================================================
UI_MODE=text
UI_BACKTITLE="XDC Secure RPC & WSS"
UI_H=20; UI_W=76
# Rows a box needs besides its text: message/yes-no, input, menu (set by ui_init)
UI_X_MSG=7; UI_X_INPUT=8; UI_X_MENU=7; UI_X_MSG_MIN=7   # (MIN: without the blank line under the text)
UI_SPARE=4   # screen rows kept free: the line at the top, and the shadow

ui_init() {
  UI_MODE=text
  # A terminal app this server has no description for (some newer ones): the common xterm one works
  if [[ -n ${TERM:-} && $TERM != dumb ]] && ! tput longname >/dev/null 2>&1 && TERM=xterm-256color tput longname >/dev/null 2>&1; then
    export TERM=xterm-256color
  fi
  if [[ ${XDC_RPC_UI:-} != text ]] && [[ -t 0 && -t 1 ]] && [[ ${TERM:-dumb} != dumb ]]; then
    if [[ ${XDC_RPC_UI:-} != whiptail ]] && have dialog && dialog --help 2>&1 | grep -q -- --no-nl-expand; then UI_MODE=dialog   # (a dialog new enough for the options used)
    elif have whiptail; then UI_MODE=whiptail; fi
  fi
  case $UI_MODE in
    dialog)   UI_X_MSG=5; UI_X_MSG_MIN=4; UI_X_INPUT=7; UI_X_MENU=6; UI_SPARE=5; ui_dialogrc ;;
    *)        UI_X_MSG=7; UI_X_MSG_MIN=7; UI_X_INPUT=8; UI_X_MENU=7; UI_SPARE=4 ;;
  esac
  # whiptail's colours (dialog's are in ui_dialogrc): calm, light dialogs.
  # Whatever has the focus (a list item, or a button once Tab moves there) is
  # white on blue; the list's current item turns grey while a button has focus.
  export NEWT_COLORS='root=white,black
border=black,lightgray
window=black,lightgray
shadow=black,black
title=blue,lightgray
button=white,blue
actbutton=white,blue
compactbutton=black,lightgray
checkbox=black,lightgray
actcheckbox=white,blue
entry=black,white
disentry=gray,lightgray
label=black,lightgray
listbox=black,lightgray
actlistbox=white,gray
sellistbox=white,gray
actsellistbox=white,blue
textbox=black,lightgray
acttextbox=black,lightgray
emptyscale=,gray
fullscale=,blue
helpline=white,black
roottext=lightgray,black'
  ui_backtitle
}

# dialog's colours: the same palette (the highlighted list item and button are
# white on blue, everything else black on light grey)
ui_dialogrc() {
  local f="$STATE_DIR/dialogrc"
  mkdir -p "$STATE_DIR" 2>/dev/null
  cat >"$f" 2>/dev/null <<'EOF' || return 0
use_shadow = ON
use_colors = ON
screen_color = (WHITE,BLACK,OFF)
shadow_color = (BLACK,BLACK,ON)
dialog_color = (BLACK,WHITE,OFF)
title_color = (BLUE,WHITE,ON)
border_color = (BLACK,WHITE,OFF)
border2_color = (BLACK,WHITE,OFF)
button_active_color = (WHITE,BLUE,ON)
button_inactive_color = (BLACK,WHITE,OFF)
button_key_active_color = (WHITE,BLUE,ON)
button_key_inactive_color = (BLACK,WHITE,OFF)
button_label_active_color = (WHITE,BLUE,ON)
button_label_inactive_color = (BLACK,WHITE,OFF)
inputbox_color = (BLACK,WHITE,OFF)
inputbox_border_color = (BLACK,WHITE,OFF)
inputbox_border2_color = (BLACK,WHITE,OFF)
searchbox_color = (BLACK,WHITE,OFF)
searchbox_title_color = (BLUE,WHITE,ON)
searchbox_border_color = (BLACK,WHITE,OFF)
searchbox_border2_color = (BLACK,WHITE,OFF)
position_indicator_color = (BLUE,WHITE,ON)
menubox_color = (BLACK,WHITE,OFF)
menubox_border_color = (BLACK,WHITE,OFF)
menubox_border2_color = (BLACK,WHITE,OFF)
item_color = (BLACK,WHITE,OFF)
item_selected_color = (WHITE,BLUE,ON)
tag_color = (BLACK,WHITE,OFF)
tag_selected_color = (WHITE,BLUE,ON)
tag_key_color = (BLACK,WHITE,OFF)
tag_key_selected_color = (WHITE,BLUE,ON)
check_color = (BLACK,WHITE,OFF)
check_selected_color = (WHITE,BLUE,ON)
uarrow_color = (BLUE,WHITE,ON)
darrow_color = (BLUE,WHITE,ON)
itemhelp_color = (WHITE,BLACK,OFF)
form_active_text_color = (WHITE,BLUE,ON)
form_text_color = (BLACK,WHITE,OFF)
form_item_readonly_color = (BLACK,WHITE,OFF)
gauge_color = (BLUE,WHITE,ON)
EOF
  export DIALOGRC="$f"
}

ui_backtitle() {
  UI_BACKTITLE="XDC Secure RPC & WSS · v${XDC_RPC_VERSION}"
  [[ -n "${CONF[DOMAIN]:-}" ]] && UI_BACKTITLE+=" · ${CONF[DOMAIN]}"
  return 0
}

# The terminal's size as "LINES COLS". Asked of the terminal itself, so it's right
# even inside a pipe or $(...), where tput falls back to 80x24.
ui_term_size() {
  local s; s=$(stty size 2>/dev/null </dev/tty)
  [[ $s =~ ^[0-9]+\ [0-9]+$ ]] || s="$(tput lines 2>/dev/null || echo 24) $(tput cols 2>/dev/null || echo 80)"
  printf '%s' "$s"
}
ui_term_cols()  { local s; s=$(ui_term_size); printf '%s' "${s#* }"; }
ui_term_lines() { local s; s=$(ui_term_size); printf '%s' "${s% *}"; }

_ui_dims() {
  local lines cols
  read -r lines cols <<<"$(ui_term_size)"
  UI_W=$(( cols - 6 )); (( UI_W > 92 )) && UI_W=92; (( UI_W < 60 )) && UI_W=60
  UI_H=$(( lines - UI_SPARE )); (( UI_H > 32 )) && UI_H=32; (( UI_H < 14 )) && UI_H=14
}

# Height needed to show TEXT in a box of width UI_W (plus room for buttons)
_ui_text_h() {
  local text="$1" extra="${2:-$UI_X_MSG}" n=0 line w=$(( UI_W - 6 ))
  [[ -n $text ]] && while IFS= read -r line; do
    n=$(( n + ( ${#line} / w ) + 1 ))
  done <<<"$text"
  n=$(( n + extra ))
  (( n > UI_H )) && n=$UI_H
  printf '%s' "$n"
}

UI_KEYS="↑↓ choose/scroll · Tab: buttons · Enter: confirm · Esc: back"
UI_KEYS_SHORT="↑↓ · Tab · Enter · Esc"
UI_SITE="xdcoutpost.xyz"   # who made this: shown at the top of every screen

# What the top line says, longest first (the first that fits is used). It
# always includes xdcoutpost.xyz; the node's domain when there's room.
_ui_brand_options() {
  local d="${CONF[DOMAIN]:-}"
  printf '%s\n' "XDC Secure RPC & WSS v${XDC_RPC_VERSION} by $UI_SITE${d:+ · $d}" \
                 "XDC Secure RPC & WSS by $UI_SITE${d:+ · $d}"
  [[ -n $d ]] && printf '%s\n' "$UI_SITE · $d"
  printf '%s\n' "$UI_SITE"
}
_ui_topline() {   # the line above the dialogs: name, xdcoutpost.xyz and domain on the left (as room allows), keys on the right
  local cols pad left keys; local -a opts
  cols=$(ui_term_cols); mapfile -t opts < <(_ui_brand_options)
  for keys in "$UI_KEYS" "$UI_KEYS_SHORT"; do
    for left in "${opts[@]}"; do
      pad=$(( cols - ${#left} - ${#keys} - 2 ))
      if (( pad >= 3 )); then printf '%s%*s%s' "$left" "$pad" '' "$keys"; return 0; fi
    done
  done
  printf '%s' "$UI_SITE"
}
# The same line, and a rule under it, at the top of plain-text screens
ui_plain_top() {
  local cols left rule; local -a opts
  cols=$(ui_term_cols); mapfile -t opts < <(_ui_brand_options)
  for left in "${opts[@]}"; do (( ${#left} <= cols - 1 )) && break; done
  printf -v rule '%*s' "$(( cols - 1 ))" ''
  printf '%s\n%s\n' "$left" "${C_DIM}${rule// /─}${C_OFF}"
}

# Show a box. Takes whiptail's options; for dialog they're translated, and
# --no-mouse keeps the mouse free for copying text, --cr-wrap/--no-collapse/
# --no-nl-expand keep the text exactly as written.
# Ctrl+C on a screen doesn't close the menus straight away (it's easy to press
# instead of Ctrl+Shift+C, the copy shortcut): it asks first, with Stay
# highlighted. Stay shows the same screen again; Close (or Ctrl+C a second
# time) closes the menus. Live views that need Ctrl+C say so on screen.
_wt() {
  local out rc prev
  while true; do
    UI_CTRL_C=""; prev=$(trap -p INT)
    trap 'UI_CTRL_C=1' INT
    out=$(_wt_draw "$@"); rc=$?
    if [[ -n $prev ]]; then eval "$prev"; else trap - INT; fi
    [[ -z $UI_CTRL_C ]] && break
    _ui_ctrl_c_confirm && continue
    kill -USR1 $$ 2>/dev/null   # (the menus' main process closes them: see ui_interrupted)
    exit 130
  done
  [[ -n $out ]] && printf '%s' "$out"
  return "$rc"
}
_ui_ctrl_c_confirm() {   # 0: stay, 1: close
  local again="" rc prev text
  text="Ctrl+C closes the menus. Close them now?

To copy text from a screen, select it with the mouse and press Ctrl+Shift+C (Cmd+C on a Mac).

Anything running in the background carries on either way."
  prev=$(trap -p INT); trap 'again=1' INT
  _wt_draw --title "Close the menus?" --yes-button "Stay" --no-button "Close" --yesno "$text" "$(_ui_text_h "$text")" "$UI_W" >/dev/null; rc=$?
  if [[ -n $prev ]]; then eval "$prev"; else trap - INT; fi
  [[ -n $again || $rc == 1 ]] && return 1   # (Ctrl+C again also closes)
  return 0
}
_wt_draw() {
  if [[ $UI_MODE != dialog ]]; then
    whiptail --backtitle "$(_ui_topline)" "$@" 3>&1 1>&2 2>&3
    return
  fi
  local -a dargs=()
  while (( $# )); do
    case $1 in
      --notags)        dargs+=(--no-tags) ;;
      --yes-button)    dargs+=(--yes-label "$2"); shift ;;
      --no-button)     dargs+=(--no-label "$2"); shift ;;
      --ok-button)     dargs+=(--ok-label "$2"); shift ;;
      --cancel-button) dargs+=(--cancel-label "$2"); shift ;;
      --scrolltext)    ;;
      --passwordbox)   dargs+=(--insecure --passwordbox) ;;   # (shows * for each character typed)
      --textbox)       dargs+=(--exit-label OK --textbox) ;;
      *)               dargs+=("$1") ;;
    esac
    shift
  done
  ESCDELAY=${ESCDELAY:-150} NCURSES_NO_UTF8_ACS=1 \
    dialog --backtitle "$(_ui_topline)" --no-mouse --cr-wrap --no-collapse --no-nl-expand "${dargs[@]}" 3>&1 1>&2 2>&3
}
ui_boxes() { [[ $UI_MODE == dialog || $UI_MODE == whiptail ]]; }   # arrow-key boxes (not plain text)?

_tty_read() {   # _tty_read VAR PROMPT [silent]
  local -n _out="$1"
  if [[ ${3:-} == silent && -t 0 ]]; then
    IFS= read -r -s -p "$2" _out; echo >&2
  else
    IFS= read -r -p "$2" _out
  fi
}

ui_header() {   # plain-text section heading
  printf '\n%s\n' "${C_BLD}$*${C_OFF}" >&2
}

ui_msg() {   # ui_msg TITLE TEXT
  local title="$1" text="$2"
  if ui_boxes; then
    _ui_dims
    local h need; h=$(_ui_text_h "$text"); need=$(UI_H=999 _ui_text_h "$text" "$UI_X_MSG_MIN")
    local -a extra=()
    (( h >= UI_H )) && extra=(--scrolltext)
    (( need > UI_H )) && title+="  (↓ more below)"
    _wt --title "$title" "${extra[@]}" --msgbox "$text" "$h" "$UI_W" >/dev/null
  else
    ui_header "$title"; printf '%s\n' "$text" >&2
    local _x; [[ -t 0 ]] && _tty_read _x "Press Enter to continue... "
  fi
  return 0
}

ui_info() {   # non-blocking notice (shown while work happens)
  local title="$1" text="$2"
  if ui_boxes; then
    _ui_dims
    _wt --title "$title" --infobox "$text" "$(_ui_text_h "$text" 3)" "$UI_W" >/dev/null
  else
    ui_header "$title"; printf '%s\n' "$text" >&2
  fi
}

ui_yesno() {   # ui_yesno TITLE TEXT [yes|no default] [YES-LABEL] [NO-LABEL]
  local title="$1" text="$2" def="${3:-yes}" yl="${4:-Yes}" nl="${5:-No}"
  if ui_boxes; then
    _ui_dims
    local -a o=(--title "$title" --yes-button "$yl" --no-button "$nl")
    [[ $def == no ]] && o+=(--defaultno)
    _wt "${o[@]}" --yesno "$text" "$(_ui_text_h "$text")" "$UI_W" >/dev/null
    return $?
  fi
  ui_header "$title"; printf '%s\n' "$text" >&2
  local hint="[Y/n]" ans; [[ $def == no ]] && hint="[y/N]"
  while true; do
    _tty_read ans "$yl / $nl $hint: " || return 1
    ans=$(lower "$(trim "$ans")"); [[ -z $ans ]] && ans=$([[ $def == no ]] && echo n || echo y)
    case "$ans" in y|yes) return 0 ;; n|no) return 1 ;; esac
  done
}

ui_input() {   # ui_input TITLE TEXT [DEFAULT] -> value on stdout; 1 = cancelled
  local title="$1" text="$2" def="${3:-}" out
  if ui_boxes; then
    _ui_dims
    out=$(_wt --title "$title" --ok-button "Next" --cancel-button "Back" --inputbox "$text" "$(_ui_text_h "$text" "$UI_X_INPUT")" "$UI_W" "$def") || return 1
  else
    ui_header "$title"; printf '%s\n' "$text" >&2
    _tty_read out "${def:+[$def] }> " || return 1
    [[ -z $out ]] && out="$def"
  fi
  printf '%s' "$(trim "$out")"
}

ui_password() {   # ui_password TITLE TEXT -> value on stdout
  local title="$1" text="$2" out
  if ui_boxes; then
    _ui_dims
    out=$(_wt --title "$title" --ok-button "Next" --cancel-button "Back" --passwordbox "$text" "$(_ui_text_h "$text" "$UI_X_INPUT")" "$UI_W") || return 1
  else
    ui_header "$title"; printf '%s\n' "$text" >&2
    _tty_read out "> " silent || return 1
  fi
  printf '%s' "$out"
}

# Sizes for a list box (menu, choice, checklist): sets _TH (rows of text) and
# _LH (rows of list). List boxes can't scroll their text, so a text too long to
# fit above even a short list on this screen is shown on its own (scrollable)
# page first, and the list box keeps just its first line.
_ui_list_fit() {   # _ui_list_fit TITLE TEXT-VARIABLE ITEMS MIN-ROWS
  local title="$1" items="$3" min="$4"; local -n _txt="$2"
  if (( $(UI_H=999 _ui_text_h "$_txt" 0) + ( items < min ? items : min ) + UI_X_MENU > UI_H )); then
    ui_msg "$title" "$_txt"
    _txt="${_txt%%$'\n'*}"$'\n'"(The rest was on the previous screen.)"
  fi
  (( items < min )) && min=$items
  _TH=$(_ui_text_h "$_txt" 0)
  _LH=$items; (( _LH > UI_H - _TH - UI_X_MENU )) && _LH=$(( UI_H - _TH - UI_X_MENU )); (( _LH < min )) && _LH=$min
}

ui_menu() {   # ui_menu TITLE TEXT TAG ITEM [TAG ITEM...] -> TAG on stdout; 1 = back
  local title="$1" text="$2"; shift 2
  if ui_boxes; then
    _ui_dims
    local _TH _LH; _ui_list_fit "$title" text $(( $# / 2 )) 3
    # The tags are only ids, so they're hidden, unless they're the data itself (an address, a file)
    local -a o=(); [[ -n ${UI_TAGS:-} ]] || o=(--notags)
    _wt --title "$title" "${o[@]}" --ok-button "Select" --cancel-button "${UI_CANCEL_LABEL:-Back}" \
        --menu "$text" "$(( _TH + _LH + UI_X_MENU ))" "$UI_W" "$_LH" "$@"
    return $?
  fi
  ui_header "$title"; [[ -n $text ]] && printf '%s\n' "$text" >&2
  local -a tags=(); local i
  for (( i = 1; i <= $#; i += 2 )); do
    local t="${!i}" j=$(( i + 1 )); tags+=("$t"); printf '  %s) %s\n' "$t" "${!j}" >&2
  done
  local choice
  while true; do
    _tty_read choice "Choose (Enter = back): " || return 1
    choice=$(trim "$choice"); [[ -z $choice ]] && return 1
    local t; for t in "${tags[@]}"; do [[ $t == "$choice" ]] && { printf '%s' "$t"; return 0; }; done
    printf 'Please choose one of: %s\n' "${tags[*]}" >&2
  done
}

ui_radio() {   # ui_radio TITLE TEXT DEFAULT TAG ITEM [TAG ITEM...] -> TAG (one choice; Enter picks the highlighted one)
  local title="$1" text="$2" def="$3"; shift 3
  if ui_boxes; then
    _ui_dims
    local _TH _LH; _ui_list_fit "$title" text $(( $# / 2 )) 2
    _wt --title "$title" --notags --ok-button "Select" --cancel-button "Back" --default-item "$def" \
        --menu "$text" "$(( _TH + _LH + UI_X_MENU ))" "$UI_W" "$_LH" "$@"
    return $?
  fi
  ui_header "$title"; [[ -n $text ]] && printf '%s\n' "$text" >&2
  local -a tags=(); local i
  for (( i = 1; i <= $#; i += 2 )); do
    local t="${!i}" j=$(( i + 1 )) mark=' '; [[ $t == "$def" ]] && mark='*'
    tags+=("$t"); printf '  %s %s) %s\n' "$mark" "$t" "${!j}" >&2
  done
  local choice
  while true; do
    _tty_read choice "Choose [$def]: " || return 1
    choice=$(trim "$choice"); [[ -z $choice ]] && choice="$def"
    local t; for t in "${tags[@]}"; do [[ $t == "$choice" ]] && { printf '%s' "$t"; return 0; }; done
    printf 'Please choose one of: %s\n' "${tags[*]}" >&2
  done
}

ui_check() {   # ui_check TITLE TEXT TAG ITEM ON|OFF ... -> chosen tags, one per line
  local title="$1" text="$2"; shift 2
  if ui_boxes; then
    _ui_dims
    local _TH _LH; _ui_list_fit "$title" text $(( $# / 3 )) 2
    _wt --title "$title" --separate-output --ok-button "OK" --cancel-button "Back" \
        --checklist "$text" "$(( _TH + _LH + UI_X_MENU ))" "$UI_W" "$_LH" "$@"
    return $?
  fi
  ui_header "$title"; [[ -n $text ]] && printf '%s\n' "$text" >&2
  local -a tags=() defs=(); local i
  for (( i = 1; i <= $#; i += 3 )); do
    local t="${!i}" j=$(( i + 1 )) k=$(( i + 2 )) mark=' '
    [[ ${!k} == ON ]] && { mark='x'; defs+=("$t"); }
    tags+=("$t"); printf '  [%s] %s) %s\n' "$mark" "$t" "${!j}" >&2
  done
  local choice
  _tty_read choice "Type the ones you want, separated by spaces [${defs[*]}]: " || return 1
  choice=$(trim "$choice")
  [[ -z $choice ]] && { printf '%s\n' "${defs[@]}"; return 0; }
  local c t
  for c in $choice; do for t in "${tags[@]}"; do [[ $t == "$c" ]] && echo "$t"; done; done
}

ui_textbox() {   # ui_textbox TITLE FILE
  local title="$1" file="$2"
  if ui_boxes; then
    # Up to the full screen, and wider than other dialogs (logs have long
    # lines). Long lines are wrapped: dialog would cut them off.
    local h bw lines cols n=0 longest wrapped
    read -r lines cols <<<"$(ui_term_size)"
    h=$(( lines - UI_SPARE )); [[ $UI_MODE == whiptail ]] && h=$(( h + 1 )); (( h < 10 )) && h=10
    _ui_dims
    longest=$(_ui_longest_line <"$file")
    bw=$(( longest + 4 )); (( bw < UI_W )) && bw=$UI_W
    (( bw > cols - 6 )) && bw=$(( cols - 6 )); (( bw > 120 )) && bw=120; (( bw < 60 )) && bw=60
    wrapped=$(mktemp); _ui_wrap $(( bw - 4 )) <"$file" >"$wrapped"
    n=$(grep -c '' "$wrapped")
    if [[ $UI_MODE == dialog ]] && (( n + 5 < h )); then h=$(( n + 5 )); fi   # (a short page gets a short box)
    (( n > h - 4 )) && title+="  (↓ PgDn: more below)"
    _wt --title "$title" --scrolltext --textbox "$wrapped" "$h" "$bw" >/dev/null
    rm -f "$wrapped"
  else
    ui_header "$title"; cat "$file" >&2
    local _x; [[ -t 0 ]] && _tty_read _x "Press Enter to continue... "
  fi
  return 0
}
_ui_longest_line() { python3 -c 'import sys; print(max((len(l.expandtabs(8)) for l in sys.stdin.buffer.read().decode("utf-8", "replace").splitlines()), default=0))' 2>/dev/null || echo 80; }
_ui_wrap() {   # _ui_wrap WIDTH: wrap long lines of stdin (continuations indented under their line)
  python3 -c '
import sys, textwrap
w = max(int(sys.argv[1]), 20)
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
for line in sys.stdin.buffer.read().decode("utf-8", "replace").splitlines():
    line = line.expandtabs(8).rstrip()
    if len(line) <= w:
        print(line); continue
    ind = " " * min(len(line) - len(line.lstrip(" ")) + 2, w // 3)
    print("\n".join(textwrap.wrap(line, width=w, subsequent_indent=ind, break_on_hyphens=False)))
' "$1" 2>/dev/null || cat
}

_ui_wrap_prose() {   # _ui_wrap_prose WIDTH: wrap long sentences only; commands (indented) and
                     # aligned "Label:   value" lines stay whole, so they copy as one line
  python3 -c '
import sys, textwrap
w = max(int(sys.argv[1]), 20)
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
for line in sys.stdin.buffer.read().decode("utf-8", "replace").splitlines():
    if len(line) <= w or line.startswith(" ") or "  " in line:
        print(line)
    else:
        print("\n".join(textwrap.wrap(line, width=w, break_long_words=False, break_on_hyphens=False)))
' "$1" 2>/dev/null || cat
}

# A page to copy from (commands, an address): plain terminal text instead of a
# box, so long lines wrap by themselves and copy cleanly. Any key goes back.
ui_page() {   # ui_page TITLE TEXT
  local title="$1" text="$2"
  if ui_boxes; then ui_clear; ui_plain_top >&2; fi
  text=$(_ui_wrap_prose $(( $(ui_term_cols) - 3 )) <<<"$text")
  printf '\n  %s\n\n%s\n\n' "${C_BLD}$title${C_OFF}" "$(sed 's/^/  /' <<<"$text")" >&2
  pause_key "  Press any key to go back... "
  return 0
}

ui_clear() { ui_boxes && clear; return 0; }

# Wait for a key in plain terminal mode (used after long-running tasks)
pause_key() { local _k; ui_drain_input; [[ -t 0 ]] && read -r -s -n1 -p "${1:-Press any key to continue...}" _k; echo >&2; }

# Throw away keys typed earlier (e.g. Enter pressed while a task was running),
# so they can't answer the next screen before it's been seen
ui_drain_input() { local _d; [[ -t 0 ]] || return 0; while read -r -s -t 0.05 -n 256 _d 2>/dev/null; do :; done; return 0; }

# =============================================================================
#  System: OS checks, packages, Docker
# =============================================================================
os_id()      { ( . /etc/os-release 2>/dev/null; printf '%s' "${ID:-unknown}" ); }
os_version() { ( . /etc/os-release 2>/dev/null; printf '%s' "${VERSION_ID:-unknown}" ); }
os_codename(){ ( . /etc/os-release 2>/dev/null; printf '%s' "${VERSION_CODENAME:-}" ); }

os_supported() { [[ "$(os_id)" == ubuntu ]] && [[ "$(os_version)" =~ ^(24\.04|26\.04)$ ]]; }

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

# apt-get, waiting (up to 15 minutes) while something else is using the package
# manager: usually Ubuntu's own automatic updates on a freshly started server
apt_get() {
  local out rc told="" deadline
  deadline=$(( $(now) + 900 ))
  while true; do
    _logline "RUN   apt-get $*"
    out=$(apt-get -o DPkg::Lock::Timeout=60 "$@" 2>&1); rc=$?
    if [[ -n $XDC_LOG ]]; then printf '%s\n' "$out" >>"$XDC_LOG"; else printf '%s\n' "$out"; fi
    (( rc == 0 )) && return 0
    grep -qiE 'could not get lock|unable to lock|unable to acquire the dpkg frontend lock' <<<"$out" || return "$rc"
    if (( $(now) >= deadline )); then
      err "The package manager stayed busy for 15 minutes (another update running?). Try again later."
      return "$rc"
    fi
    [[ -n $told ]] || { info "Ubuntu's automatic updates are using the package manager; waiting for them to finish"; told=1; }
    sleep 15
  done
}

_APT_UPDATED=""
apt_update_once() {
  [[ -n $_APT_UPDATED ]] && return 0
  apt_get update -y || apt_get update -y || return 1
  _APT_UPDATED=1
}

apt_install() {   # install only what's missing
  local -a missing=(); local p
  for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
  (( ${#missing[@]} )) || return 0
  info "Installing: ${missing[*]}"
  apt_update_once || return 1
  apt_get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "${missing[@]}"
}

BASE_PACKAGES=(ca-certificates curl git jq dialog whiptail ufw fail2ban nginx certbot python3-certbot-nginx
  aria2 pv lz4 zstd gnupg dnsutils openssl python3 unattended-upgrades iproute2 tar)

# Tools the menus themselves need (installed before the first dialog). The
# menus use dialog; if it can't be installed, whiptail (part of Ubuntu) does.
ensure_ui_tools() {
  local -a need=(); local p
  for p in curl jq python3; do have "$p" || need+=("$p"); done
  if (( ${#need[@]} )); then
    info "Installing a few tools the installer needs: ${need[*]}"
    apt_install "${need[@]}" || return 1
  fi
  have dialog || apt_install dialog || have whiptail || apt_install whiptail
}

docker_ok() { have docker && docker version >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; }

docker_install() {
  if docker_ok; then ok "Docker is installed"; return 0; fi
  info "Installing Docker from Docker's official repository"
  apt_install ca-certificates curl gnupg || return 1
  install -m 0755 -d /etc/apt/keyrings
  run curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc || return 1
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$(dpkg --print-architecture)" "$(os_codename)" >/etc/apt/sources.list.d/docker.list
  _APT_UPDATED=""
  apt_update_once || return 1
  apt_get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
  # Rootless mode isn't used; leave its helpers out
  pkg_installed docker-ce-rootless-extras && apt_get remove -y docker-ce-rootless-extras
  run apt-mark hold docker-ce-rootless-extras || true
  run systemctl enable --now docker || return 1
  docker_ok || { err "Docker was installed but isn't responding."; return 1; }
  ok "Docker installed"
}

df_path() { local p="$1"; while [[ ! -e $p && $p != / ]]; do p=$(dirname "$p"); done; printf '%s' "$p"; }   # nearest existing folder
disk_free_bytes()  { df -B1 --output=avail "$(df_path "$1")" 2>/dev/null | tail -n1 | tr -d ' '; }
disk_total_bytes() { df -B1 --output=size "$(df_path "$1")" 2>/dev/null | tail -n1 | tr -d ' '; }
mem_total_gb()    { awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo; }
human()           { numfmt --to=iec --suffix=B "$1" 2>/dev/null || printf '%s bytes' "$1"; }

# =============================================================================
#  SSH: ports, root login, key logins, fail2ban, and the safety undo timer
# =============================================================================
ssh_runtime() { mkdir -p /run/sshd && chmod 0755 /run/sshd; }

ssh_config_ports() {   # ports in the effective sshd configuration
  ssh_runtime
  sshd -T 2>/dev/null | awk '$1=="port" {print $2}' | sort -un
}

ssh_listening() { [[ -n "$(ss -Hltn "( sport = :$1 )" 2>/dev/null)" ]]; }

ssh_wait_listening() {
  local i; for i in $(seq 1 20); do ssh_listening "$1" && return 0; sleep 1; done; return 1
}

_addr_ip() { local a="${1%:*}"; a="${a#[}"; a="${a%]}"; a="${a#::ffff:}"; printf '%s' "$a"; }

# "CLIENT_IP SERVER_PORT" of the SSH session this script is running in
ssh_session_info() {
  local pid=$$ comm line i
  for (( i = 0; i < 25; i++ )); do
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -z $pid || $pid -le 1 ]] && break
    comm=$(ps -o comm= -p "$pid" 2>/dev/null)
    if [[ $comm == sshd* ]]; then
      line=$(ss -Htnp state established 2>/dev/null | grep -F "pid=$pid," | head -n1)
      if [[ -n $line ]]; then
        local laddr peer
        laddr=$(awk '{print $3}' <<<"$line"); peer=$(awk '{print $4}' <<<"$line")
        printf '%s %s\n' "$(_addr_ip "$peer")" "${laddr##*:}"
        return 0
      fi
    fi
  done
  return 1
}
session_ip()   { ssh_session_info 2>/dev/null | awk '{print $1}'; }
session_port() { ssh_session_info 2>/dev/null | awk '{print $2}'; }

login_user() {
  local u="${SUDO_USER:-}"
  [[ -z $u || $u == root ]] && u=$(logname 2>/dev/null)
  [[ -z $u ]] && u=$(who -m 2>/dev/null | awk '{print $1}')
  printf '%s' "${u:-root}"
}

# SSH ports the firewall must keep open: configured ports, plus the port of the
# current session while sshd still listens on it (belt and braces).
ssh_ports_for_firewall() {
  {
    ssh_config_ports
    local sp; sp=$(session_port)
    [[ -n $sp ]] && ssh_listening "$sp" && echo "$sp"
  } | grep -E '^[0-9]+$' | sort -un
}

ssh_effective() { ssh_runtime; sshd -T 2>/dev/null | awk -v k="$1" '$1==k {print $2; exit}'; }

ssh_restart() {
  ssh_runtime
  if ! sshd -t 2>>"${XDC_LOG:-/dev/null}"; then err "The SSH configuration check failed."; return 1; fi
  if systemctl is-enabled --quiet ssh.socket 2>/dev/null || systemctl is-active --quiet ssh.socket 2>/dev/null; then
    systemctl daemon-reload && systemctl restart ssh.socket || return 1
    systemctl is-active --quiet ssh.service && systemctl restart ssh.service
  else
    systemctl restart ssh.service 2>/dev/null || systemctl restart ssh || return 1
  fi
  return 0
}

# Make our drop-in the only place SSH ports are set (other Port lines are commented out)
ssh_takeover_ports() {
  local f
  mkdir -p "$UNDO_DIR/files"; chmod 700 "$UNDO_DIR"
  for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [[ -f $f && $f != "$SSHD_PORT_CONF" ]] || continue
    if grep -qiE '^[[:space:]]*Port[[:space:]]+[0-9]+' "$f"; then
      cp -a "$f" "$UNDO_DIR/files/$(basename "$f").$(ts)"
      sed -i -E 's/^([[:space:]]*)(Port[[:space:]]+[0-9]+.*)$/\1# xdc-rpc (SSH port is set in 00-xdc-rpc-port.conf): \2/I' "$f"
    fi
  done
}

ssh_write_ports() {
  mkdir -p /etc/ssh/sshd_config.d
  {
    echo "# Managed by xdc-rpc. To change the SSH port run: sudo xdc-rpc  (Security menu)"
    local p; for p in "$@"; do echo "Port $p"; done
  } >"$SSHD_PORT_CONF"
  chmod 644 "$SSHD_PORT_CONF"
}

ssh_write_auth() {
  local root pw
  root=$(conf_get SSH_ROOT_LOGIN default); pw=$(conf_get SSH_PASSWORDS default)
  mkdir -p /etc/ssh/sshd_config.d
  {
    echo "# Managed by xdc-rpc. Change these from: sudo xdc-rpc  (Security menu)"
    [[ $root == no ]] && echo "PermitRootLogin no"
    case $pw in
      no)  echo "PasswordAuthentication no"; echo "KbdInteractiveAuthentication no" ;;
      yes) echo "PasswordAuthentication yes" ;;
    esac
  } >"$SSHD_AUTH_CONF"
  chmod 644 "$SSHD_AUTH_CONF"
}

# ── Watching for a real login ────────────────────────────────────────────────
AUTH_LOG=/var/log/auth.log
auth_log_mark() { stat -c %s "$AUTH_LOG" 2>/dev/null || true; }   # where auth.log ends now (for _auth_new_lines)

_auth_new_lines() {   # sshd "Accepted ..." lines since epoch $1 (journal, plus auth.log after byte $2)
  local since="$1" off="${2:-}"
  if have journalctl; then
    journalctl --since "@$since" --no-pager -o cat SYSLOG_IDENTIFIER=sshd SYSLOG_IDENTIFIER=sshd-session 2>/dev/null \
      | grep -E '^Accepted [a-z/-]+ for '
  fi
  if [[ -n $off && -f $AUTH_LOG ]]; then
    tail -c +"$(( off + 1 ))" "$AUTH_LOG" 2>/dev/null | grep -E ' sshd(-session)?\[[0-9]+\]: Accepted [a-z/-]+ for '
  fi
  return 0
}

# ssh_login_seen USER PORT FINGERPRINT METHOD SINCE [OFF]
# Has USER logged in over SSH since epoch SINCE (and after byte OFF of auth.log),
# and is that session still connected? PORT, FINGERPRINT and METHOD may be ""
# (any). Prints the client IP.
ssh_login_seen() {
  local user="$1" port="$2" fp="$3" method="$4" since="$5" off="${6:-}" line m ip cport
  while IFS= read -r line; do
    [[ $line =~ Accepted\ ([a-z/-]+)\ for\ ([^ ]+)\ from\ ([0-9a-fA-F:.]+)\ port\ ([0-9]+) ]] || continue
    m="${BASH_REMATCH[1]}"; [[ "${BASH_REMATCH[2]}" == "$user" ]] || continue
    ip="${BASH_REMATCH[3]}"; cport="${BASH_REMATCH[4]}"
    [[ -n $method && $m != "$method" ]] && continue
    [[ -n $fp && $line != *"$fp"* ]] && continue
    if [[ -n $port ]]; then
      ss -Htn state established "( sport = :$port and dport = :$cport )" 2>/dev/null | grep -q . || continue
    fi
    printf '%s' "${ip#::ffff:}"
    return 0
  done < <(_auth_new_lines "$since" "$off")
  return 1
}

# ssh_wait_login USER PORT FINGERPRINT METHOD [TIMEOUT] [SINCE OFF]
# Waits (up to TIMEOUT seconds) for ssh_login_seen. Logins from SINCE on count
# (default: from now). Prints the client IP. Returns 1 on timeout, 2 if the
# person cancelled.
ssh_wait_login() {
  local user="$1" port="$2" fp="$3" method="$4" timeout="${5:-540}" since off start key
  if (( $# >= 6 )); then since="$6"; off="${7:-}"; else since=$(( $(now) - 2 )); off=$(auth_log_mark); fi
  start=$(now)
  printf '  %s\n' "${C_DIM}Waiting for the login (up to $(( (timeout + 59) / 60 )) minutes)... type c then Enter to cancel.${C_OFF}" >&2
  while true; do
    ssh_login_seen "$user" "$port" "$fp" "$method" "$since" "$off" && return 0
    (( $(now) - start < timeout )) || return 1
    if read -r -t 3 key 2>/dev/null; then
      case $(lower "$(trim "$key")") in c|cancel) return 2 ;; esac
    elif (( $? <= 128 )); then
      sleep 1   # (no keyboard to read from: don't spin)
    fi
  done
}

ssh_target_host() {   # what people should type after the @ when connecting
  local d; d=$(conf_get DOMAIN)
  local ip; ip=$(public_ipv4 2>/dev/null)
  if [[ -n $d && -n $ip ]] && resolve_a "$d" | grep -qxF -- "$ip"; then printf '%s' "$d"; else printf '%s' "${ip:-YOUR-SERVER-IP}"; fi
}

ssh_cmd_hint() {   # ssh_cmd_hint USER PORT [KEYPATH]
  local u="$1" p="$2" k="${3:-}" host; host=$(ssh_target_host)
  local cmd="ssh"; [[ -n $k ]] && cmd+=" -i $k"
  [[ $p != 22 ]] && cmd+=" -p $p"
  printf '%s %s@%s' "$cmd" "$u" "$host"
}

# ── Undo timer: changes are put back automatically unless confirmed ─────────
undo_prepare() {   # snapshot SSH settings and config; prints an id
  local id f; id=$(ts)-$RANDOM
  mkdir -p "$UNDO_DIR/$id"; chmod 700 "$UNDO_DIR" "$UNDO_DIR/$id"
  for f in "$SSHD_PORT_CONF" "$SSHD_AUTH_CONF"; do
    if [[ -f $f ]]; then cp -a "$f" "$UNDO_DIR/$id/"; else touch "$UNDO_DIR/$id/$(basename "$f").absent"; fi
  done
  [[ -f $CONF_FILE ]] && cp -a "$CONF_FILE" "$UNDO_DIR/$id/conf"
  printf '%s' "$id"
}

undo_schedule() {   # undo_schedule ID DESCRIPTION
  printf '%s\n' "$2" >"$UNDO_DIR/$1/desc"
  if systemd_ok; then
    systemd-run --unit="xdc-rpc-undo-$1" --description="xdc-rpc: undo '$2' unless confirmed" \
      --on-active="${UNDO_MINUTES}m" --timer-property=AccuracySec=5s \
      "$SELF_INSTALL_PATH" __undo "$1" >/dev/null 2>&1
  fi
}

undo_cancel() {
  systemctl stop "xdc-rpc-undo-$1.timer" >/dev/null 2>&1
  systemctl reset-failed "xdc-rpc-undo-$1.service" >/dev/null 2>&1
  rm -rf "${UNDO_DIR:?}/$1"
}

undo_run() {   # undo_run ID [quiet]: put SSH back exactly as it was ("quiet" = no login notice)
  local id="$1" d="$UNDO_DIR/$1" f b
  [[ -d $d ]] || return 0
  systemctl stop "xdc-rpc-undo-$id.timer" >/dev/null 2>&1
  for f in "$SSHD_PORT_CONF" "$SSHD_AUTH_CONF"; do
    b=$(basename "$f")
    if [[ -f $d/$b ]]; then cp -a "$d/$b" "$f"; elif [[ -f $d/$b.absent ]]; then rm -f "$f"; fi
  done
  [[ -f $d/conf ]] && cp -a "$d/conf" "$CONF_FILE" && conf_load
  ssh_restart
  ufw_sync >/dev/null 2>&1
  f2b_apply >/dev/null 2>&1
  if [[ ${2:-} != quiet ]]; then
    printf '%s  %s was undone automatically (no confirmed login).\n' "$(date '+%F %R')" "$(cat "$d/desc" 2>/dev/null || echo 'An SSH change')" \
      >>"$STATE_DIR/notices"
  fi
  rm -rf "${d:?}"
}

# ── Public keys ──────────────────────────────────────────────────────────────
pubkey_check() {   # prints "TYPE BITS FINGERPRINT"; 1 = not a public key, 2 = a private key
  local key; key=$(trim "$1")
  [[ $key == *"PRIVATE KEY"* ]] && return 2
  [[ $key =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\ [A-Za-z0-9+/=]+(\ .*)?$ ]] || return 1
  local tmp out; tmp=$(mktemp); printf '%s\n' "$key" >"$tmp"
  out=$(ssh-keygen -l -f "$tmp" 2>/dev/null); rm -f "$tmp"
  [[ -n $out ]] || return 1
  printf '%s %s %s' "$(sed -E 's/.*\(([^)]+)\)$/\1/' <<<"$out")" "$(awk '{print $1}' <<<"$out")" "$(awk '{print $2}' <<<"$out")"
}

_key_blob() { awk '{for (i = 1; i <= NF; i++) if ($i ~ /^(ssh-|ecdsa-|sk-)/) { print $(i+1); exit }}' <<<"$1"; }

authkeys_file() { printf '%s/.ssh/authorized_keys' "$(user_home "$1")"; }

authkeys_add() {   # authkeys_add USER "KEY LINE"
  local u="$1" key="$2" f g blob
  f=$(authkeys_file "$u"); g=$(id -gn "$u")
  install -d -m 700 -o "$u" -g "$g" "$(dirname "$f")"
  [[ -f $f ]] || install -m 600 -o "$u" -g "$g" /dev/null "$f"
  blob=$(_key_blob "$key"); [[ -n $blob ]] || return 1
  grep -qF -- "$blob" "$f" || printf '%s\n' "$key" >>"$f"
  chown "$u:$g" "$f"; chmod 600 "$f"
}

authkeys_count() {
  local f n; f=$(authkeys_file "$1")
  n=$(grep -cE '(^|[ ,])(ssh-(ed25519|rsa|dss)|ecdsa-sha2-|sk-)' "$f" 2>/dev/null)
  printf '%s' "${n:-0}"
}

authkeys_list() {   # "FINGERPRINT TYPE COMMENT" per key
  local f; f=$(authkeys_file "$1"); [[ -f $f ]] || return 0
  ssh-keygen -l -f "$f" 2>/dev/null | awk '{c=""; for (i=3;i<NF;i++) c=c $i " "; print $2, $NF, c}'
}

authkeys_remove() {   # authkeys_remove USER FINGERPRINT
  local u="$1" fp="$2" f tmp line tf
  f=$(authkeys_file "$u"); [[ -f $f ]] || return 1
  tmp=$(mktemp)
  while IFS= read -r line; do
    tf=$(mktemp); printf '%s\n' "$line" >"$tf"
    if [[ -n $line && $line != \#* ]] && ssh-keygen -l -f "$tf" 2>/dev/null | grep -qF " $fp "; then rm -f "$tf"; continue; fi
    rm -f "$tf"; printf '%s\n' "$line" >>"$tmp"
  done <"$f"
  cat "$tmp" >"$f"; rm -f "$tmp"
}

admin_copy_root_keys() {   # reuse root's keys for the admin user (skipping provider "please log in as" stubs)
  local u="$1" f=/root/.ssh/authorized_keys line n=0
  [[ -s $f ]] || return 0
  while IFS= read -r line; do
    [[ -z $line || $line == \#* || $line == *command=* ]] && continue
    authkeys_add "$u" "$line" && n=$(( n + 1 ))
  done <"$f"
  (( n )) && info "Copied $n SSH key(s) from root to $u, so you can log in as $u the same way."
  return 0
}

admin_create() {   # admin_create USER: a sudo user (its password is set separately)
  local u="$1"
  if ! user_exists "$u"; then
    useradd -m -s /bin/bash "$u" || return 1
  fi
  usermod -aG sudo "$u" || return 1
  admin_copy_root_keys "$u"
}

# ── fail2ban ─────────────────────────────────────────────────────────────────
f2b_apply() {
  have fail2ban-client || return 0
  local ports tmp backend=""
  ports=$(ssh_config_ports | paste -sd, -); [[ -z $ports ]] && ports=22
  [[ -f $AUTH_LOG ]] || backend="backend  = systemd"
  rm -f "$F2B_JAIL_V1"
  tmp=$(mktemp)
  cat >"$tmp" <<EOF
# Managed by xdc-rpc. Blocks addresses that keep failing to log in over SSH.
# Bans start at 1 hour and double for repeat offenders, up to 1 week.
[sshd]
enabled  = true
port     = $ports
maxretry = 5
findtime = 10m
bantime  = 1h
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 1w
$backend
EOF
  if cmp -s "$tmp" "$F2B_JAIL"; then
    rm -f "$tmp"
    systemctl is-active --quiet fail2ban || run systemctl enable --now fail2ban
  else
    install -m 644 "$tmp" "$F2B_JAIL"; rm -f "$tmp"
    run systemctl enable fail2ban
    run systemctl restart fail2ban || { err "fail2ban did not restart. Check: sudo fail2ban-client -t"; return 1; }
  fi
  return 0
}

f2b_banned() { fail2ban-client status sshd 2>/dev/null | sed -n 's/.*Banned IP list:[[:space:]]*//p' | tr ' ' '\n' | grep -v '^$'; }

docker_group_members() { getent group docker 2>/dev/null | cut -d: -f4 | tr ',' '\n' | grep -v '^$'; }

# =============================================================================
#  Firewall (UFW)
#  Rules this tool manages carry a comment starting "xdc-rpc:".
#    SSH port(s) ............ open to everyone (protected by fail2ban)
#    XDC P2P port (tcp+udp) . open to everyone (other nodes connect here)
#    443 (RPC/WSS) .......... only from addresses on your allowlist
#    80 ..................... closed, except while a certificate renews
# =============================================================================
_ufw_rules() {   # every added rule as "SPEC|COMMENT"
  ufw show added 2>/dev/null | sed -n 's/^ufw //p' | while IFS= read -r line; do
    if [[ $line =~ ^(.*)\ comment\ \'(.*)\'$ ]]; then
      printf '%s|%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
      printf '%s|\n' "$line"
    fi
  done
}

_ufw_desired() {   # "SPEC|COMMENT" for every rule we want
  local p p2p ip label
  for p in $(ssh_ports_for_firewall); do echo "allow $p/tcp|xdc-rpc: SSH"; done
  p2p=$(conf_get P2P_PORT)
  if [[ -n $p2p ]]; then
    echo "allow $p2p/tcp|xdc-rpc: XDC P2P"
    echo "allow $p2p/udp|xdc-rpc: XDC P2P"
  fi
  while IFS='|' read -r ip label; do
    [[ -n $ip ]] && echo "allow from $ip to any port 443 proto tcp|xdc-rpc: $label"
  done < <(allow_firewall_entries)
}

_ufw_words() {   # split a rule into words; app names like 'Nginx Full' stay together
  local spec="$1"; UFW_WORDS=()
  if [[ $spec =~ ^([a-z]+)(\ in)?\ \'(.+)\'$ ]]; then
    UFW_WORDS=("${BASH_REMATCH[1]}"); [[ -n ${BASH_REMATCH[2]} ]] && UFW_WORDS+=(in); UFW_WORDS+=("${BASH_REMATCH[3]}")
  else
    read -ra UFW_WORDS <<<"$spec"
  fi
}

_ufw_do() {   # _ufw_do add|delete SPEC [COMMENT]
  _ufw_words "$2"
  if [[ $1 == add ]]; then run ufw "${UFW_WORDS[@]}" comment "$3"; else run ufw delete "${UFW_WORDS[@]}"; fi
}

# A rule (not ours) that opens 80 or 443 to everyone would make the allowlist pointless
_ufw_opens_web() {
  local s="$1"
  [[ $s == *" from "* ]] && return 1
  [[ $s =~ ^allow(\ in)?\ ((80|443|80,443|443,80|80:443)(/tcp)?|https?|\'(Nginx|Apache|WWW)[^\']*\')$ ]] && return 0
  [[ $s =~ ^allow(\ in)?\ (proto\ tcp\ )?(to\ any\ )?port\ (80|443)(\ proto\ tcp)?$ ]]
}

ufw_apply() {
  have ufw || { err "ufw is not installed."; return 1; }
  local -A want=() cur=()
  local spec comment has_ssh=""
  while IFS='|' read -r spec comment; do [[ -n $spec ]] && want["$spec"]="$comment"; done < <(_ufw_desired)
  while IFS='|' read -r spec comment; do [[ -n $spec ]] && cur["$spec"]="$comment"; done < <(_ufw_rules)

  # Safety: never touch the firewall without knowing the SSH port
  for spec in "${!want[@]}"; do [[ ${want[$spec]} == "xdc-rpc: SSH" ]] && has_ssh=1; done
  [[ -n $has_ssh ]] || { err "Couldn't work out the SSH port, so the firewall was left unchanged."; return 1; }

  for spec in "${!want[@]}"; do
    if [[ -z ${cur[$spec]+x} ]]; then
      _ufw_do add "$spec" "${want[$spec]}"
    elif [[ ${cur[$spec]} != "${want[$spec]}" ]]; then
      _ufw_do add "$spec" "${want[$spec]}"   # same rule, new label: ufw updates it in place
    fi
  done
  for spec in "${!cur[@]}"; do
    [[ -n ${want[$spec]+x} ]] && continue
    case "${cur[$spec]}" in
      xdc-rpc-acme:*) continue ;;                                 # a certificate renewal in progress
      xdc-rpc:*|HTTP/HTTPS|"XDC P2P") _ufw_do delete "$spec"; continue ;;   # ours, or left by the previous installer
    esac
    if _ufw_opens_web "$spec"; then
      warn "Removed the firewall rule \"$spec\": it opened the RPC/WSS ports to everyone."
      _ufw_do delete "$spec"
    fi
  done

  run ufw default deny incoming
  run ufw default allow outgoing
  if ! ufw status | grep -q 'Status: active'; then
    run ufw --force enable || return 1
  fi
  return 0
}

ufw_active() { have ufw && ufw status 2>/dev/null | grep -q 'Status: active'; }
ufw_sync()   { ufw_active || return 0; ufw_apply; }   # update the rules only if the firewall is on

fw_port80_open()  { have ufw && ufw allow 80/tcp comment 'xdc-rpc-acme: temporary' >/dev/null 2>&1; return 0; }
fw_port80_close() { have ufw && ufw delete allow 80/tcp >/dev/null 2>&1; return 0; }
fw_port80_is_open() { have ufw && ufw show added 2>/dev/null | grep -q "^ufw allow 80/tcp comment 'xdc-rpc-acme"; }

# Certbot renewal hooks: open port 80 just for the renewal, then close it
le_hooks_install() {
  mkdir -p "$LE_HOOK_DIR/pre" "$LE_HOOK_DIR/post" "$LE_HOOK_DIR/deploy"
  cat >"$LE_HOOK_DIR/pre/xdc-rpc-open-port-80" <<'EOF'
#!/bin/sh
# xdc-rpc: let Let's Encrypt reach this server on port 80 while the certificate
# renews. The matching post hook closes it again, whether or not renewal worked.
command -v ufw >/dev/null 2>&1 || exit 0
ufw allow 80/tcp comment 'xdc-rpc-acme: temporary' >/dev/null 2>&1 || true
EOF
  cat >"$LE_HOOK_DIR/post/xdc-rpc-close-port-80" <<'EOF'
#!/bin/sh
# xdc-rpc: close port 80 again after a certificate renewal attempt.
command -v ufw >/dev/null 2>&1 || exit 0
ufw delete allow 80/tcp >/dev/null 2>&1 || true
EOF
  cat >"$LE_HOOK_DIR/deploy/xdc-rpc-reload-nginx" <<'EOF'
#!/bin/sh
# xdc-rpc: start using the renewed certificate.
systemctl reload nginx >/dev/null 2>&1 || true
EOF
  chmod 755 "$LE_HOOK_DIR/pre/xdc-rpc-open-port-80" "$LE_HOOK_DIR/post/xdc-rpc-close-port-80" \
            "$LE_HOOK_DIR/deploy/xdc-rpc-reload-nginx"
}

# =============================================================================
#  Allowlist: who may use the RPC and WSS endpoints
#  /etc/xdc-rpc/allowlist holds your own entries, one per line:  ADDRESS|SCOPE|LABEL
#  SCOPE is both, rpc or wss. Plugin's gateway is added on top when switched on.
# =============================================================================
PLUGIN_LABEL="Plugin RPCaaS gateway"

allow_user_entries() {   # your own entries as "ADDRESS|SCOPE|LABEL"
  [[ -f $ALLOW_FILE ]] || return 0
  grep -E '^[0-9]' "$ALLOW_FILE" 2>/dev/null
}

plugin_enabled() { [[ "$(conf_get ALLOW_PLUGIN no)" == yes ]]; }

allow_effective() {   # everything that is allowed right now
  allow_user_entries
  if plugin_enabled; then
    local ip; for ip in "${PLUGIN_RPCAAS_IPS[@]}"; do printf '%s|both|%s\n' "$ip" "$PLUGIN_LABEL"; done
  fi
}

allow_firewall_entries() {   # one "ADDRESS|LABEL" per address (port 443 doesn't know rpc from wss)
  allow_effective | awk -F'|' '!seen[$1]++ {print $1 "|" $3}'
}

allow_count() { allow_effective | awk -F'|' '!seen[$1]++' | wc -l | tr -d ' '; }

_allow_write() {   # replace the user list with lines from stdin
  local tmp; mkdir -p "$CONF_DIR"; tmp=$(mktemp "$ALLOW_FILE.XXXXXX")
  {
    echo "# Managed by xdc-rpc. Use: sudo xdc-rpc  (Allowlist menu)"
    echo "# ADDRESS|SCOPE|LABEL   (SCOPE: both, rpc or wss)"
    cat
  } >"$tmp"
  chmod 600 "$tmp" && mv -f "$tmp" "$ALLOW_FILE"
}

# allow_add ADDRESS SCOPE LABEL  -> 0 ok; prints the normalised address
# errors: 2 not an address, 3 IPv6, 4 too broad, 5 bad scope, 6 Plugin's own address
allow_add() {
  local raw="$1" scope="${2:-both}" label norm
  label=$(sanitize_label "${3:-}")
  [[ $scope =~ ^(both|rpc|wss)$ ]] || return 5
  local out rc
  out=$(normalize_ipv4 "$raw"); rc=$?
  (( rc == 0 )) || return "$rc"
  read -r norm _ <<<"$out"
  [[ -n $norm ]] || return 2
  local p; for p in "${PLUGIN_RPCAAS_IPS[@]}"; do [[ $p == "$norm" ]] && return 6; done
  { allow_user_entries | awk -F'|' -v a="$norm" '$1 != a'; printf '%s|%s|%s\n' "$norm" "$scope" "$label"; } | _allow_write
  printf '%s' "$norm"
}

allow_remove() {   # allow_remove ADDRESS
  local a="$1"
  allow_user_entries | grep -q "^${a//./\\.}|" || return 1
  allow_user_entries | awk -F'|' -v a="$a" '$1 != a' | _allow_write
}

allow_render_nginx() {   # write the include files used by the /xdcrpc and /xdcwss locations
  local which file ip scope label
  for which in rpc wss; do
    file=$NGINX_ALLOW_RPC; [[ $which == wss ]] && file=$NGINX_ALLOW_WSS
    mkdir -p "$(dirname "$file")"
    {
      echo "# Managed by xdc-rpc. Edit with: sudo xdc-rpc  (Allowlist menu)"
      echo "allow 127.0.0.1;  # this server (used by the status check)"
      while IFS='|' read -r ip scope label; do
        [[ -z $ip ]] && continue
        [[ $scope == both || $scope == "$which" ]] && printf 'allow %s;  # %s\n' "$ip" "$label"
      done < <(allow_effective)
    } >"$file.new"
  done
}

# Apply the allowlist everywhere: nginx (tested, rolled back on error) and the firewall
allow_apply() {
  allow_render_nginx
  local f ok_=1
  for f in "$NGINX_ALLOW_RPC" "$NGINX_ALLOW_WSS"; do
    [[ -f $f ]] && cp -a "$f" "$f.prev"
    mv -f "$f.new" "$f"
  done
  if [[ -f $NGINX_SITE ]] && have nginx; then
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || ok_=0
    else
      ok_=0
      for f in "$NGINX_ALLOW_RPC" "$NGINX_ALLOW_WSS"; do [[ -f $f.prev ]] && mv -f "$f.prev" "$f"; done
      err "nginx rejected the new allowlist, so the previous one was kept."
    fi
  fi
  rm -f "$NGINX_ALLOW_RPC.prev" "$NGINX_ALLOW_WSS.prev"
  ufw_apply >/dev/null 2>&1 || { ok_=0; err "The firewall rules could not be updated."; }
  (( ok_ ))
}

# Changing the list safely: keep a copy first; if applying the change fails,
# the copy is put back (and applied again), so the list always matches what
# nginx and the firewall really allow.
allow_copy() { local t; t=$(mktemp); allow_user_entries >"$t"; printf '%s' "$t"; }   # prints the copy's file name
allow_copy_restore() { [[ -f $1 ]] || return 0; _allow_write <"$1"; rm -f "$1"; }
allow_apply_or_undo() {   # allow_apply_or_undo COPY (run it holding the lock)
  if allow_apply; then rm -f "$1"; return 0; fi
  allow_copy_restore "$1"
  allow_apply >/dev/null 2>&1
  return 1
}

allow_describe() {   # allow_describe [MAX]: human-readable list for the menus (at most MAX+1 lines)
  local max="${1:-0}" ip scope label n=0 total
  total=$(allow_effective | grep -c .)
  while IFS='|' read -r ip scope label; do
    [[ -z $ip ]] && continue
    n=$(( n + 1 ))
    if (( max > 0 && total > max + 1 && n > max )); then
      printf '  … and %s more (Remove an address lists your own)\n' "$(( total - max ))"
      break
    fi
    case $scope in both) scope="RPC + WSS" ;; rpc) scope="RPC only" ;; wss) scope="WSS only" ;; esac
    printf '  %-18s  %-9s  %s\n' "$ip" "$scope" "$label"
  done < <(allow_effective)
  (( n )) || echo "  (nobody yet: the endpoints refuse every address)"
}

# =============================================================================
#  nginx (HTTPS front door) and the Let's Encrypt certificate
# =============================================================================
rpc_port() { conf_get RPC_PORT "$( [[ $(conf_get NETWORK mainnet) == testnet ]] && echo 8545 || echo 8989 )"; }
ws_port()  { conf_get WS_PORT  "$( [[ $(conf_get NETWORK mainnet) == testnet ]] && echo 8546 || echo 8888 )"; }

cert_dir()    { printf '%s/live/%s' "$LE_DIR" "$1"; }
cert_exists() { [[ -s "$(cert_dir "$1")/fullchain.pem" && -s "$(cert_dir "$1")/privkey.pem" ]]; }
cert_covers() { openssl x509 -noout -ext subjectAltName -in "$(cert_dir "$1")/fullchain.pem" 2>/dev/null | grep -qF "DNS:$1"; }
cert_days_left() {
  local f end; f="$(cert_dir "$1")/fullchain.pem"
  [[ -f $f ]] || { echo -1; return; }
  end=$(openssl x509 -enddate -noout -in "$f" 2>/dev/null | cut -d= -f2)
  echo $(( ( $(date -d "$end" +%s 2>/dev/null || now) - $(now) ) / 86400 ))
}

_nginx_tokens_set_elsewhere() {
  local f
  for f in /etc/nginx/nginx.conf /etc/nginx/conf.d/*.conf; do
    [[ -f $f && $f != "$NGINX_HTTP_CONF" ]] || continue
    grep -qE '^[[:space:]]*server_tokens[[:space:]]' "$f" && return 0
  done
  return 1
}

_nginx_write_static() {
  mkdir -p "$(dirname "$NGINX_TLS_SNIPPET")" "$ACME_ROOT/.well-known/acme-challenge"
  chmod 755 "$ACME_ROOT" "$ACME_ROOT/.well-known" "$ACME_ROOT/.well-known/acme-challenge"
  cat >"$NGINX_TLS_SNIPPET" <<'EOF'
# Managed by xdc-rpc. Modern TLS settings.
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers off;
ssl_session_cache shared:xdcrpc:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;
EOF
  # Don't advertise the nginx version (nginx refuses the setting twice, so only
  # if nothing else sets it already)
  if _nginx_tokens_set_elsewhere; then
    printf '# Managed by xdc-rpc. (server_tokens is already set elsewhere in the nginx configuration.)\n' >"$NGINX_HTTP_CONF"
  else
    printf "# Managed by xdc-rpc. Don't advertise the nginx version.\nserver_tokens off;\n" >"$NGINX_HTTP_CONF"
  fi
  cat >"$NGINX_DEFAULT_SITE" <<'EOF'
# Managed by xdc-rpc. Anything that doesn't ask for your node's domain
# (for example scanners connecting by IP address) gets nothing back.
server {
    listen 80 default_server;
    server_name _;
    return 444;
}
server {
    listen 443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}
EOF
}

_nginx_write_site() {   # _nginx_write_site http|full
  local mode="$1" d rpc ws
  d=$(conf_get DOMAIN); rpc=$(rpc_port); ws=$(ws_port)
  {
    cat <<EOF
# Managed by xdc-rpc. This file is rewritten by: sudo xdc-rpc
# RPC:  https://${d}/xdcrpc      WSS:  wss://${d}/xdcwss

# Port 80 only answers Let's Encrypt (and is closed by the firewall otherwise)
server {
    listen 80;
    server_name ${d};
    location ^~ /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
        default_type text/plain;
    }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
    [[ $mode == full ]] && cat <<EOF

server {
    listen 443 ssl;
    server_name ${d};
    ssl_certificate     ${LE_DIR}/live/${d}/fullchain.pem;
    ssl_certificate_key ${LE_DIR}/live/${d}/privkey.pem;
    include ${NGINX_TLS_SNIPPET};
    add_header Strict-Transport-Security "max-age=31536000" always;

    location = /xdcrpc {
        include ${NGINX_ALLOW_RPC};
        deny all;
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Content-Type, Authorization" always;
        if (\$request_method = OPTIONS) { return 204; }
        proxy_pass http://127.0.0.1:${rpc}/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
        proxy_send_timeout 300;
    }

    location = /xdcwss {
        include ${NGINX_ALLOW_WSS};
        deny all;
        proxy_pass http://127.0.0.1:${ws}/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
    }

    location / { return 404; }
}
EOF
  } >"$NGINX_SITE"
}

# Write every nginx file, test, reload. If the test fails, the previous files come back.
nginx_apply() {
  have nginx || { err "nginx is not installed."; return 1; }
  local d mode=http bak f i
  d=$(conf_get DOMAIN)
  cert_exists "$d" && cert_covers "$d" && mode=full
  # Everything this changes, so a rejected configuration can be put back exactly
  local -a paths=("$NGINX_SITE" "$NGINX_DEFAULT_SITE" "$NGINX_TLS_SNIPPET" "$NGINX_HTTP_CONF" "$NGINX_ALLOW_RPC"
                  "$NGINX_ALLOW_WSS" "$NGINX_SITE_LINK" "$NGINX_DEFAULT_LINK" /etc/nginx/sites-enabled/default)
  bak=$(mktemp -d)
  for i in "${!paths[@]}"; do
    f=${paths[$i]}; if [[ -e $f || -L $f ]]; then cp -a "$f" "$bak/$i"; fi
  done
  _nginx_write_static
  _nginx_write_site "$mode"
  allow_render_nginx
  mv -f "$NGINX_ALLOW_RPC.new" "$NGINX_ALLOW_RPC"; mv -f "$NGINX_ALLOW_WSS.new" "$NGINX_ALLOW_WSS"
  ln -sf "$NGINX_SITE" "$NGINX_SITE_LINK"
  ln -sf "$NGINX_DEFAULT_SITE" "$NGINX_DEFAULT_LINK"
  rm -f /etc/nginx/sites-enabled/default
  if ! nginx -t >>"${XDC_LOG:-/dev/null}" 2>&1; then
    err "nginx rejected the new configuration; putting the previous one back."
    for i in "${!paths[@]}"; do
      f=${paths[$i]}; rm -f "$f"
      if [[ -e $bak/$i || -L $bak/$i ]]; then cp -a "$bak/$i" "$f"; fi
    done
    rm -rf "$bak"; return 1
  fi
  rm -rf "$bak"
  run systemctl enable nginx
  if systemctl is-active --quiet nginx; then run systemctl reload nginx; else run systemctl restart nginx; fi
}

dns_check() {   # prints a problem description, empty when the domain points here
  local d="$1" ip addrs
  ip=$(public_ipv4) || { echo "Couldn't find this server's public IP address (no internet access?)."; return; }
  addrs=$(resolve_a "$d")
  if [[ -z $addrs ]]; then echo "$d doesn't resolve yet. Create an A record pointing to $ip."; return; fi
  grep -qxF -- "$ip" <<<"$addrs" || echo "$d points to $(paste -sd' ' - <<<"$addrs"), but this server is $ip. Update the A record to $ip."
}

cert_obtain() {
  local d e problem rc
  d=$(conf_get DOMAIN); e=$(conf_get EMAIL)
  if cert_exists "$d" && cert_covers "$d" && (( $(cert_days_left "$d") > 7 )); then
    ok "Certificate for $d is in place ($(cert_days_left "$d") days left)"
    cert_migrate_authenticator "$d"
    return 0
  fi
  problem=$(dns_check "$d")
  [[ -z $problem ]] || { err "$problem"; return 1; }
  nginx_apply || return 1
  info "Requesting a certificate for $d (port 80 opens briefly for the check)"
  fw_port80_open
  run certbot certonly --webroot -w "$ACME_ROOT" -d "$d" --cert-name "$d" \
      --non-interactive --agree-tos --no-eff-email -m "$e" --keep-until-expiring
  rc=$?
  fw_port80_close
  (( rc == 0 )) && cert_exists "$d" || { err "Let's Encrypt didn't issue the certificate. Check that $d points to this server and that port 80 is open at your VPS provider."; return 1; }
  ok "Certificate issued for $d"
}

# Certificates made by the previous scripts renew through the nginx plugin;
# switch them to the webroot method this tool uses (the old method still works if this can't).
cert_migrate_authenticator() {
  local d="$1" rc_file="$LE_DIR/renewal/$1.conf"
  [[ -f $rc_file ]] && grep -qE '^authenticator *= *nginx' "$rc_file" || return 0
  certbot reconfigure --help >/dev/null 2>&1 || return 0
  info "Switching certificate renewals for $d to the webroot method"
  fw_port80_open
  run certbot reconfigure --cert-name "$d" --webroot --webroot-path "$ACME_ROOT" --non-interactive \
    || warn "Couldn't switch the renewal method; renewals keep using the previous one."
  fw_port80_close
  return 0
}

# =============================================================================
#  The XDC node
#  XinFin's node files (github.com/XinFinOrg/XinFin-Node) are cloned to
#  ~ADMIN/XinFin-Node, but the node doesn't run from that folder. Each XinFin
#  release is checked first (node_upstream_check), then copied into xdc-rpc's
#  own folder, /var/lib/xdc-rpc/node, and run from there. Nothing XinFin
#  changes, and no "git pull" in their folder, can alter the running node until
#  an update has passed the checks. The previous release is kept for going back.
# =============================================================================
net()            { conf_get NETWORK mainnet; }
node_base()      { conf_get NODE_BASE "$(admin_home)/XinFin-Node"; }
net_dir()        { printf '%s/%s' "$(node_base)" "$(net)"; }
data_dir()       { if [[ $(net) == testnet ]]; then printf '%s/xdcchain-testnet' "$(net_dir)"; else printf '%s/xdcchain' "$(net_dir)"; fi; }
xdc_dir()        { printf '%s/XDC' "$(data_dir)"; }
container_name() { printf 'xdcnetwork-%s-node' "$(net)"; }
compose_project(){ printf 'xdc-%s' "$(net)"; }
default_p2p()    { [[ $1 == testnet ]] && echo 30312 || echo 30303; }
chain_id_dec()   { [[ $(net) == testnet ]] && echo 51 || echo 50; }
chain_id_hex()   { printf '0x%x' "$(chain_id_dec)"; }

node_rt()        { printf '%s/node' "$STATE_DIR"; }        # the release the node runs from
node_rt_prev()   { printf '%s/node.prev' "$STATE_DIR"; }   # the release before it (for going back)
node_rt_new()    { printf '%s/node.new' "$STATE_DIR"; }    # a release being prepared
compose_file()   { printf '%s/compose.yml' "$(node_rt)"; }
start_ours()     { printf '%s/start.sh' "$(node_rt)"; }
rt_get()         { grep -E "^$2=" "$1/release" 2>/dev/null | tail -n1 | cut -d= -f2-; }   # rt_get RELEASE-DIR KEY
node_release_ready() { [[ -f $(node_rt)/release && -f $(compose_file) ]]; }
node_image() {   # the node software the node runs (or will run)
  local i; i=$(rt_get "$(node_rt)" IMAGE)
  [[ -n $i ]] || { err "The node's files aren't set up yet (run setup)."; return 1; }
  printf '%s' "$i"
}
node_image_running() { docker inspect -f '{{.Config.Image}}' "$(container_name)" 2>/dev/null; }

_as_user() {   # _as_user USER CMD...: run a command as USER (root runs it directly)
  local u="$1"; shift
  if [[ $u == root ]] || ! user_exists "$u"; then "$@"; else runuser -u "$u" -- env HOME="$(user_home "$u")" "$@"; fi
}
_git() {   # git in XinFin's folder, as the folder's owner (keeps file ownership tidy)
  local base owner; base=$(node_base); owner=$(stat -c %U "$base" 2>/dev/null || echo root)
  if [[ $owner == root ]]; then git -c safe.directory='*' -C "$base" "$@"; else _as_user "$owner" git -C "$base" "$@"; fi
}
dc() { docker compose -p "$(compose_project)" -f "$(compose_file)" "$@"; }

# XinFin's folder usually belongs to the admin user, so files in it are read and
# written as that user (as git already is). Root never follows a link someone
# planted there to a file only root may read or change.
_node_owner() { stat -c %U "$(net_dir)" 2>/dev/null || stat -c %U "$(node_base)" 2>/dev/null || echo root; }
_owner_read() {   # _owner_read FILE: print FILE, read as the folder's owner
  _as_user "$(_node_owner)" cat -- "$1"
}
_owner_write() {   # _owner_write FILE < content: FILE replaced as the folder's owner (mode 640)
  _as_user "$(_node_owner)" sh -c 'cd / && umask 027 && t="$1.xdc-rpc-new" && rm -f -- "$t" && cat >"$t" && mv -f -- "$t" "$1"' sh "$1"
}
_user_env_read() {   # _user_env_read FILE: XinFin's .env, read safely
  _owner_read "$1" 2>/dev/null && return 0
  # (unreadable for its owner, e.g. written by root earlier: fine to read as root if it's a real file, not a link)
  [[ -f $1 && ! -L $1 ]] && cat -- "$1"
}

node_repo_ensure() {
  local base admin; base=$(node_base); admin=$(conf_get ADMIN_USER root)
  if [[ ! -d $base/.git ]]; then
    if [[ -e $base ]] && [[ -n "$(ls -A "$base" 2>/dev/null)" ]]; then
      err "$base exists but isn't a copy of XinFin's node files. Move it out of the way and run setup again."
      return 1
    fi
    info "Downloading XinFin's node files"
    rm -rf "$base"
    run _as_user "$admin" git clone --quiet "$XINFIN_NODE_REPO" "$base" || return 1
  fi
  mkdir -p "$(net_dir)"
}

# ── Checking a XinFin release ────────────────────────────────────────────────
# Everything xdc-rpc relies on in XinFin's files. If a release changes any of
# it, that release isn't used until xdc-rpc is updated to understand it, and
# the node keeps running as it is. NODE_CHECK_PROBLEM says what changed.
NODE_CHECK_PROBLEM=""
_ncp() { NODE_CHECK_PROBLEM="$*"; return 1; }
_uses_var() { grep -qE "\\\$\\{?$2([^A-Za-z0-9_]|\$)" "$1"; }   # does script $1 read variable $2?
_compose_src() { jq -r --arg t "$2" '.services | to_entries[0].value.volumes[]? | select(.target == $t) | .source // empty' <<<"$1" | head -n1; }

node_upstream_check() {   # node_upstream_check XINFIN-NETWORK-FOLDER DEST: check it; copy what was checked to DEST/upstream
  local src="$1" dest="$2" json tmpd img n f v start_f genesis_f boot_f name_var chain
  NODE_CHECK_PROBLEM=""
  [[ -d $src ]] || { _ncp "there's no '$(net)' folder any more"; return 1; }
  [[ -f $src/docker-compose.yml ]] || { _ncp "docker-compose.yml is missing"; return 1; }
  # Read it the way Docker Compose would in XinFin's folder, with XinFin's example settings as .env
  tmpd=$(mktemp -d)
  find "$src" -maxdepth 1 -type f -exec cp -t "$tmpd" {} +
  [[ -f $tmpd/.env ]] || cp "$tmpd/env.example" "$tmpd/.env" 2>/dev/null || : >"$tmpd/.env"
  json=$(cd "$tmpd" && docker compose -f docker-compose.yml config --format json 2>/dev/null); rm -rf "$tmpd"
  [[ -n $json ]] || { _ncp "docker-compose.yml can't be read"; return 1; }
  n=$(jq '.services | length' <<<"$json")
  [[ $n == 1 ]] || { _ncp "docker-compose.yml now has $n services instead of 1"; return 1; }
  img=$(jq -r '.services | to_entries[0].value.image // empty' <<<"$json")
  [[ $img =~ ^[a-z0-9][a-z0-9._/-]*:[A-Za-z0-9._-]+$ ]] || { _ncp "docker-compose.yml names no usable node image (${img:-none})"; return 1; }
  for f in /work/xdcchain /work/genesis.json /work/start.sh /work/bootnodes.list /work/.pwd; do
    [[ -n $(_compose_src "$json" "$f") ]] || { _ncp "docker-compose.yml no longer mounts $f"; return 1; }
  done
  start_f=$(basename "$(_compose_src "$json" /work/start.sh)")
  genesis_f=$(basename "$(_compose_src "$json" /work/genesis.json)")
  boot_f=$(basename "$(_compose_src "$json" /work/bootnodes.list)")
  for f in "$start_f" "$genesis_f" "$boot_f" env.example; do
    [[ -f $src/$f ]] || { _ncp "$f is missing"; return 1; }
  done
  f="$src/$start_f"
  bash -n "$f" 2>/dev/null || { _ncp "$start_f has a syntax error"; return 1; }
  [[ $(grep -cE '^[[:space:]]*--port[[:space:]]+[0-9]+[[:space:]]*$' "$f") == 1 ]] \
    || { _ncp "$start_f no longer sets the P2P port on a line of its own"; return 1; }
  for v in '--datadir /work/xdcchain' /work/genesis.json /work/bootnodes.list /work/.pwd; do
    grep -qF -- "$v" "$f" || { _ncp "$start_f no longer uses $v"; return 1; }
  done
  grep -qE -- '--http-addr[= ]+"?0\.0\.0\.0' "$f" && grep -qE -- '--ws-addr[= ]+"?0\.0\.0\.0' "$f" \
    || { _ncp "$start_f changed how the RPC and WebSocket servers listen"; return 1; }
  for v in ENABLE_RPC ENABLE_WS RPC_PORT WS_PORT API GC_MODE; do
    _uses_var "$f" "$v" || { _ncp "$start_f no longer reads the $v setting"; return 1; }
  done
  name_var=""
  for v in INSTANCE_NAME NODE_NAME; do _uses_var "$f" "$v" && { name_var=$v; break; }; done
  [[ -n $name_var ]] || { _ncp "$start_f no longer reads the node name from INSTANCE_NAME or NODE_NAME"; return 1; }
  for v in ENABLE_RPC ENABLE_WS RPC_PORT WS_PORT API GC_MODE CONTACT_DETAILS "$name_var"; do
    grep -qE "^$v=" "$src/env.example" || { _ncp "env.example no longer has the $v setting"; return 1; }
  done
  chain=$(jq -r '.config.chainId // empty' "$src/$genesis_f" 2>/dev/null)
  [[ $chain == "$(chain_id_dec)" ]] || { _ncp "$genesis_f is for chain id ${chain:-unknown}, not $(chain_id_dec)"; return 1; }
  grep -q '^enode://' "$src/$boot_f" || { _ncp "$boot_f lists no bootnodes"; return 1; }
  # Keep exact copies of what was checked
  mkdir -p "$dest/upstream"
  cp "$src/docker-compose.yml" "$src/env.example" "$dest/upstream/"
  cp "$f" "$dest/upstream/start.sh"
  cp "$src/$genesis_f" "$dest/upstream/genesis.json"
  cp "$src/$boot_f" "$dest/upstream/bootnodes.list"
  printf 'NETWORK=%s\nIMAGE=%s\nNAME_VAR=%s\nSTART_SOURCE=%s\n' "$(net)" "$img" "$name_var" "$start_f" >"$dest/release"
}

# A complete, checked release folder: XinFin's files plus what xdc-rpc generates
node_release_build() {   # node_release_build XINFIN-NETWORK-FOLDER DEST REF TREE
  local src="$1" dest="$2" ref="$3" tree="$4"
  rm -rf "$dest"; mkdir -p "$dest"; chmod 755 "$dest"
  node_upstream_check "$src" "$dest" || { rm -rf "$dest"; return 1; }
  printf 'REF=%s\nTREE=%s\nPREPARED=%s\n' "$ref" "$tree" "$(now)" >>"$dest/release"
  # The keystore's password file stays the same from release to release
  if [[ -f $(node_rt)/pwd ]]; then cp "$(node_rt)/pwd" "$dest/pwd"
  elif [[ -f $(net_dir)/.pwd ]]; then cp "$(net_dir)/.pwd" "$dest/pwd"   # the one this server's account was made with
  elif [[ -f $src/.pwd ]]; then cp "$src/.pwd" "$dest/pwd"
  else : >"$dest/pwd"; fi
  chmod 600 "$dest/pwd"
  node_release_generate "$dest" || { rm -rf "$dest"; return 1; }
}

node_upstream_ref() { _git rev-parse --verify -q '@{u}' 2>/dev/null || _git rev-parse --verify -q origin/HEAD 2>/dev/null; }

node_candidate_prepare() {   # node_candidate_prepare GIT-REF [DEST]: check XinFin's release at REF and build it
  local ref="$1" dest="${2:-$(node_rt_new)}" scratch tree sha rc
  NODE_CHECK_PROBLEM=""
  tree=$(_git rev-parse --verify -q "$ref:$(net)" 2>/dev/null) || { _ncp "there's no '$(net)' folder any more"; return 1; }
  sha=$(_git rev-parse --verify -q "$ref^{commit}" 2>/dev/null)
  scratch=$(mktemp -d)
  if ! _git archive "$ref" "$(net)" 2>/dev/null | tar -x -C "$scratch" 2>/dev/null; then
    rm -rf "$scratch"; _ncp "XinFin's files couldn't be read"; return 1
  fi
  node_release_build "$scratch/$(net)" "$dest" "$sha" "$tree"; rc=$?
  rm -rf "$scratch"
  return "$rc"
}

# ── Generating xdc-rpc's files for a release ────────────────────────────────
_env_set() {   # _env_set FILE KEY VALUE (adds the key if missing)
  local f="$1" tmp; tmp=$(mktemp)
  K="$2" V="$3" awk 'BEGIN {k = ENVIRON["K"]; v = ENVIRON["V"]; d = 0}
    index($0, k "=") == 1 {print k "=" v; d = 1; next} {print} END {if (!d) print k "=" v}' "$f" >"$tmp" \
    && cat "$tmp" >"$f"
  rm -f "$tmp"
}
_env_get() { grep -E "^$2=" "$1" 2>/dev/null | tail -n1 | cut -d= -f2-; }

_env_merge_missing() {   # copy settings XinFin added to env.example into an existing .env
  local env="$1" ex="$2" line k
  [[ -f $ex ]] || return 0
  while IFS= read -r line; do
    [[ $line =~ ^([A-Z][A-Z0-9_]*)= ]] || continue
    k="${BASH_REMATCH[1]}"
    grep -qE "^$k=" "$env" || printf '%s\n' "$line" >>"$env"
  done <"$ex"
}

node_contact() {   # the contact for XinFin's stats page: what you chose (even blank), else your email
  if [[ ${CONF[CONTACT]+set} ]]; then printf '%s' "${CONF[CONTACT]}"; else conf_get EMAIL; fi
}

# The node's settings live in XinFin's usual place (~/XinFin-Node/NETWORK/.env),
# where you can still change things such as LOG_LEVEL; they apply the next time
# the node is started or restarted from the menu. xdc-rpc sets the ones it
# manages, then gives the release its own copy (RELEASE-DIR/node.env). XinFin's
# .env itself is only written for the release the node runs from, never for a
# release that is only being checked or prepared.
node_env_apply() {   # node_env_apply [RELEASE-DIR]
  local d="${1:-$(node_rt)}" user_env ex name_var v tmp live=""
  user_env="$(net_dir)/.env"; ex="$d/upstream/env.example"; name_var=$(rt_get "$d" NAME_VAR)
  [[ $d == "$(node_rt)" ]] && live=1
  [[ -f $ex ]] || { err "The release folder has no env.example."; return 1; }
  tmp=$(mktemp)
  if [[ -e $user_env || -L $user_env ]]; then
    _user_env_read "$user_env" >"$tmp" || { rm -f "$tmp"; err "Couldn't read $user_env"; return 1; }
  else
    cat "$ex" >"$tmp"
  fi
  _env_merge_missing "$tmp" "$ex"
  for v in INSTANCE_NAME NODE_NAME; do
    if [[ $v == "$name_var" ]] || grep -q "^$v=" "$tmp"; then _env_set "$tmp" "$v" "$(conf_get NODE_NAME)"; fi
  done
  _env_set "$tmp" CONTACT_DETAILS "$(node_contact)"
  _env_set "$tmp" ENABLE_RPC true
  _env_set "$tmp" ENABLE_WS true
  _env_set "$tmp" GC_MODE "$(conf_get NODE_TYPE full)"
  _env_set "$tmp" API "$(conf_get APIS eth,net,web3)"
  if [[ -n $live ]]; then   # the RPC and WS ports in XinFin's .env are used (nginx follows them)
    v=$(_env_get "$tmp" RPC_PORT); valid_port "$v" && conf_update RPC_PORT "$(( 10#$v ))"
    v=$(_env_get "$tmp" WS_PORT);  valid_port "$v" && conf_update WS_PORT "$(( 10#$v ))"
  fi
  _env_set "$tmp" RPC_PORT "$(rpc_port)"
  _env_set "$tmp" WS_PORT "$(ws_port)"
  install -m 600 "$tmp" "$d/node.env" || { rm -f "$tmp"; err "Couldn't write the node's settings."; return 1; }
  if [[ -n $live ]]; then
    mkdir -p "$(net_dir)"
    _owner_read "$user_env" 2>/dev/null | cmp -s "$tmp" - \
      || _owner_write "$user_env" <"$tmp" || { rm -f "$tmp"; err "Couldn't write $user_env"; return 1; }   # (one its owner couldn't read is handed back too)
  fi
  rm -f "$tmp"
}

node_user_env_sync() {   # after switching releases: add settings that release's env.example has to XinFin's .env
  local env tmp; env="$(net_dir)/.env"
  [[ -f $env ]] || return 0
  tmp=$(mktemp)
  if _user_env_read "$env" >"$tmp"; then
    cp "$tmp" "$tmp.was"
    _env_merge_missing "$tmp" "$(node_rt)/upstream/env.example"
    cmp -s "$tmp" "$tmp.was" || _owner_write "$env" <"$tmp" || warn "Couldn't add new settings to $env"
  fi
  rm -f "$tmp" "$tmp.was"
}

# XinFin's start script with only the P2P port changed
node_write_start_script() {   # node_write_start_script RELEASE-DIR
  local d="$1" up p2p tmp
  up="$d/upstream/start.sh"; p2p=$(conf_get P2P_PORT "$(default_p2p "$(net)")")
  [[ -f $up ]] || { err "The release folder has no start script."; return 1; }
  tmp=$(mktemp)
  awk -v p="$p2p" -v src="$(rt_get "$d" START_SOURCE)" '
    NR == 1 { print; print "# Generated by xdc-rpc from XinFin'\''s " src ". Only the P2P port differs. Rewritten on setup and updates."; next }
    /^[[:space:]]*--port[[:space:]]+[0-9]+[[:space:]]*$/ { sub(/[0-9]+/, p) }
    { print }' "$up" >"$tmp"
  if ! grep -qE "^[[:space:]]*--port[[:space:]]+${p2p}[[:space:]]*$" "$tmp" || ! bash -n "$tmp"; then
    rm -f "$tmp"; err "Couldn't prepare the node's start script."; return 1
  fi
  install -m 755 "$tmp" "$d/start.sh"; rm -f "$tmp"
}

_compose_text() {   # _compose_text FILES-DIR ENV-FILE IMAGE
  local rt="$1" envf="$2" image="$3" p2p rpc ws
  p2p=$(conf_get P2P_PORT "$(default_p2p "$(net)")"); rpc=$(rpc_port); ws=$(ws_port)
  cat <<EOF
# Generated by xdc-rpc for XinFin's node release. Rewritten on setup and updates.
# Compared with XinFin's own file: RPC and WS listen only on this server
# (127.0.0.1; nginx serves them over HTTPS), P2P is published on IPv4 only and
# on your chosen port, XinFin's files are mounted read-only from a checked copy,
# the node gets up to 30 minutes to shut down cleanly, and logs are capped.
name: $(compose_project)
services:
  xinfinnetwork:
    container_name: $(container_name)
    image: ${image}
    pull_policy: missing
    restart: always
    stop_grace_period: 30m
    env_file:
      - "${envf}"
    ports:
      - "0.0.0.0:${p2p}:${p2p}/tcp"
      - "0.0.0.0:${p2p}:${p2p}/udp"
      - "127.0.0.1:${rpc}:${rpc}"
      - "127.0.0.1:${ws}:${ws}"
    volumes:
      - type: bind
        source: "$(data_dir)"
        target: /work/xdcchain
      - type: bind
        source: "${rt}/upstream/genesis.json"
        target: /work/genesis.json
        read_only: true
        bind: { create_host_path: false }
      - type: bind
        source: "${rt}/start.sh"
        target: /work/start.sh
        read_only: true
        bind: { create_host_path: false }
      - type: bind
        source: "${rt}/upstream/bootnodes.list"
        target: /work/bootnodes.list
        read_only: true
        bind: { create_host_path: false }
      - type: bind
        source: "${rt}/pwd"
        target: /work/.pwd
        read_only: true
        bind: { create_host_path: false }
      - type: bind
        source: /etc/localtime
        target: /etc/localtime
        read_only: true
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"
EOF
}

node_write_compose() {   # node_write_compose RELEASE-DIR: written for where the release runs from
  local d="$1" image tmp
  image=$(rt_get "$d" IMAGE); [[ -n $image ]] || { err "The release folder names no node software."; return 1; }
  tmp=$(mktemp -d)
  _compose_text "$d" "$d/node.env" "$image" >"$tmp/check.yml"
  if ! docker compose -f "$tmp/check.yml" config -q >>"${XDC_LOG:-/dev/null}" 2>&1; then
    rm -rf "$tmp"; err "The generated Docker Compose file didn't validate."; return 1
  fi
  rm -rf "$tmp"
  _compose_text "$(node_rt)" "$(node_rt)/node.env" "$image" >"$d/compose.yml"
  chmod 644 "$d/compose.yml"
  mkdir -p "$(data_dir)"
}

node_release_generate() {   # node_release_generate RELEASE-DIR: (re)write xdc-rpc's files from the current settings
  node_env_apply "$1" && node_write_start_script "$1" && node_write_compose "$1"
}

node_tree_sync() {   # keep XinFin's folder at the release the node runs (tidiness only: the node doesn't read it)
  local ref; ref=$(rt_get "$(node_rt)" REF); [[ -n $ref ]] || return 0
  _git diff --quiet -- "$(net)/docker-compose.yml" 2>/dev/null || _git checkout -- "$(net)/docker-compose.yml" 2>/dev/null
  if ! _git merge --ff-only --quiet "$ref" >>"${XDC_LOG:-/dev/null}" 2>&1; then
    warn "XinFin's folder ($(node_base)) has local changes, so it wasn't brought up to date. The node doesn't run from it, so that's fine."
  fi
  return 0
}

# ── Running the node ─────────────────────────────────────────────────────────
node_state() {   # running / exited / restarting / ... / not created
  local s; s=$(docker inspect -f '{{.State.Status}}' "$(container_name)" 2>/dev/null | head -n1)
  printf '%s' "${s:-not created}"
}

node_stop_legacy() {   # a container with our name that the previous scripts (or a person) started
  local c label; c=$(container_name)
  docker inspect "$c" >/dev/null 2>&1 || return 0
  label=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$c" 2>/dev/null)
  [[ $label == "$(compose_project)" ]] && return 0
  info "Handing over the running node to this tool (it's stopped cleanly first)"
  container_stop_clean "$c"; run docker rm "$c"
}

node_config_hash() { cat "$(compose_file)" "$(node_rt)/node.env" "$(start_ours)" 2>/dev/null | sha256sum | cut -c1-16; }

node_up() {
  node_release_ready || { err "The node's files aren't set up yet (run setup)."; return 1; }
  node_stop_legacy || return 1
  local h; h=$(node_config_hash)
  local -a extra=()
  if [[ $h != "$(state_get NODE_CONFIG_HASH)" ]]; then
    if [[ $(node_state) == running ]]; then
      info "The node's settings changed, so it's restarted with them (it stops cleanly first)"
      node_stop || return 1
    fi
    extra=(--force-recreate)
  fi
  run dc up -d --remove-orphans "${extra[@]}" || { err "The node container didn't start. See: sudo xdc-rpc → Status & logs"; return 1; }
  state_set NODE_CONFIG_HASH "$h"
  ok "Node container running"
}

# Stopping the node cleanly matters: the node keeps its latest state in memory
# and writes it out when it's told to stop. Killed half-way (Docker does that
# when its time limit runs out), the saved state is incomplete, and the node can
# get stuck at the next checkpoint with "missing trie node" errors.
NODE_STOP_MINUTES=30
container_stop_clean() {   # container_stop_clean CONTAINER: 0 = stopped cleanly, 2 = it had to be forced
  local c="$1" pid1 start sp code m last=0
  docker inspect "$c" >/dev/null 2>&1 || return 0
  [[ $(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null) =~ ^(running|restarting)$ ]] || return 0
  pid1=$(docker exec "$c" cat /proc/1/comm 2>/dev/null)
  start=$(now)
  _logline "RUN   docker stop -t $(( NODE_STOP_MINUTES * 60 )) $c"
  # docker stop asks the container's main process to stop, and marks it as
  # stopped so Docker doesn't start it again by itself.
  docker stop -t "$(( NODE_STOP_MINUTES * 60 ))" "$c" >>"${XDC_LOG:-/dev/null}" 2>&1 &
  sp=$!
  if [[ -n $pid1 && $pid1 != XDC ]]; then
    # Older XinFin start scripts run the node under bash, which doesn't pass
    # the request on (XinFin fixed this in October 2026): ask the node itself.
    sleep 2
    docker exec "$c" sh -c 'for p in /proc/[0-9]*; do [ "$(cat "$p/comm" 2>/dev/null)" = XDC ] && kill -TERM "${p#/proc/}"; done' >/dev/null 2>&1
  fi
  while kill -0 "$sp" 2>/dev/null; do
    sleep 3
    m=$(( ($(now) - start) / 60 ))
    (( m > last )) && { last=$m; info "Still saving its state ($m min so far; it's given up to $NODE_STOP_MINUTES)"; }
  done
  wait "$sp"
  code=$(docker inspect -f '{{.State.ExitCode}}' "$c" 2>/dev/null)
  if [[ $code == 137 ]]; then
    warn "The node didn't finish shutting down within $NODE_STOP_MINUTES minutes and had to be forced to stop."
    warn "When it starts again it carries on from its last saved block, which may be a little behind. If its block then stops moving, see \"Node stuck at a checkpoint\" in the guide: ${XDC_RPC_GUIDE_URL}#stuck"
    state_set NODE_FORCED_STOP "$(now)"
    return 2
  fi
  ok "Stopped cleanly after $(_fmt_dur $(( $(now) - start )))"
}

node_stop() {
  docker inspect "$(container_name)" >/dev/null 2>&1 || return 0
  [[ $(node_state) =~ ^(running|restarting)$ ]] || return 0
  info "Stopping the node. It saves its state first: usually a minute or two."
  container_stop_clean "$(container_name)"
  [[ $(node_state) =~ ^(running|restarting)$ ]] && { err "The node is still running."; return 1; }
  return 0
}

node_restart() { node_stop && node_up; }

node_docker_run() {   # run an XDC command in the node image with the chain folder mounted
  local image; image=$(node_image) || return 1
  docker image inspect "$image" >/dev/null 2>&1 || run docker pull "$image" || return 1
  docker run --rm --entrypoint XDC \
    -v "$(data_dir):/work/xdcchain" -v "$(node_rt)/pwd:/work/.pwd:ro" -v "$(node_rt)/upstream/genesis.json:/work/genesis.json:ro" \
    "$image" "$@"
}

node_has_account() { compgen -G "$(data_dir)/keystore/UTC--*" >/dev/null 2>&1; }

_put_coinbase_txt() {   # a fresh file (never written through a link left in its place)
  local f; f="$(data_dir)/coinbase.txt"
  rm -f -- "$f" && ( set -C; printf '%s\n' "$1" >"$f" ) 2>/dev/null
}

# XinFin's start script only creates the node's account on a brand-new chain folder,
# so make it first whenever chain data arrives from a snapshot.
ensure_coinbase_account() {
  node_has_account && return 0
  mkdir -p "$(data_dir)"
  local out addr
  out=$(node_docker_run account new --password /work/.pwd --datadir /work/xdcchain 2>&1) || { _logline "$out"; err "Couldn't create the node's account."; return 1; }
  _logline "$out"
  addr=$(_addr_hex "$(grep -oiE '\{[0-9a-f]{40}\}|(0x|xdc)[0-9a-f]{40}' <<<"$out" | head -n1)")
  [[ -n $addr ]] || addr=$(node_coinbase)
  [[ -n $addr ]] && _put_coinbase_txt "$addr"
  ok "Node account created"
}

# An account exists but no chain yet (e.g. restored keys, syncing from scratch):
# initialise the chain so XinFin's start script doesn't create a second account.
ensure_genesis_init() {
  node_has_account || return 0
  [[ -d $(xdc_dir)/chaindata ]] && return 0
  info "Initialising the chain from the genesis file"
  node_docker_run init --datadir /work/xdcchain /work/genesis.json >>"${XDC_LOG:-/dev/null}" 2>&1
}

_addr_hex() {   # the 40 hex digits of an address written as 0x…, xdc…, {…} or bare; nothing if it isn't one
  local a; a=$(printf '%s' "$1" | tr -d '[:space:]{}' | tr 'A-F' 'a-f'); a=${a#0x}; a=${a#xdc}
  [[ $a =~ ^[0-9a-f]{40}$ ]] && printf '%s' "$a"
  return 0
}

# The node's account. XinFin's start script writes it to coinbase.txt, but with
# newer node software that file can end up empty, so the keystore is the fallback
# (its file names end in the address).
node_coinbase() {
  local a f
  a=$(_addr_hex "$(head -n1 "$(data_dir)/coinbase.txt" 2>/dev/null)")
  if [[ -z $a ]]; then
    for f in "$(data_dir)"/keystore/UTC--*; do
      [[ -f $f ]] || continue
      a=$(_addr_hex "${f##*--}"); [[ -n $a ]] && break
    done
  fi
  printf '%s' "$a"
}

node_rpc() {   # node_rpc METHOD [PARAMS-JSON]
  curl -s --noproxy '*' --max-time 5 -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":${2:-[]}}" "http://127.0.0.1:$(rpc_port)" 2>/dev/null
}
_hexdec() { [[ $1 =~ ^0x[0-9a-fA-F]+$ ]] && printf '%d' "$1"; }
node_block() { _hexdec "$(node_rpc eth_blockNumber | jq -r '.result // empty' 2>/dev/null)"; }
node_peers() { _hexdec "$(node_rpc net_peerCount | jq -r '.result // empty' 2>/dev/null)"; }
node_syncing() { node_rpc eth_syncing | jq -c '.result' 2>/dev/null; }

public_rpc_url() { [[ $(net) == testnet ]] && echo https://erpc.apothem.network || echo https://erpc.xinfin.network; }
network_block() {
  _hexdec "$(curl -s --max-time 6 -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' "$(public_rpc_url)" 2>/dev/null | jq -r '.result // empty' 2>/dev/null)"
}

endpoint_selftest() {   # end-to-end: HTTPS + nginx + node, from this server
  local d; d=$(conf_get DOMAIN)
  curl -s --noproxy '*' --max-time 8 --resolve "$d:443:127.0.0.1" -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' "https://$d/xdcrpc" 2>/dev/null | jq -r '.result // empty' 2>/dev/null
}

node_crash_looping() {   # Docker has restarted it 3+ times, the latest within 10 minutes
  local rc started t
  read -r rc started < <(docker inspect -f '{{.RestartCount}} {{.State.StartedAt}}' "$(container_name)" 2>/dev/null) || return 1
  (( ${rc:-0} >= 3 )) || return 1
  t=$(date -d "$started" +%s 2>/dev/null) || return 1
  (( $(now) - t < 600 ))
}

# Is the node working? Prints the reason when it isn't.
node_health_wait() {   # node_health_wait SECONDS [BLOCK-BEFORE]
  local limit="$1" before="${2:-0}" start st restarts b
  start=$(now)
  while (( $(now) - start < limit )); do
    st=$(node_state)
    case $st in exited|dead|"not created") echo "the node stopped right after starting"; return 1 ;; esac
    restarts=$(docker inspect -f '{{.RestartCount}}' "$(container_name)" 2>/dev/null)
    (( ${restarts:-0} >= 3 )) && { echo "the node keeps crashing and restarting"; return 1; }
    if [[ $st == running ]]; then
      b=$(node_block)
      if [[ -n $b ]]; then
        if (( before > 0 && b + 10000 < before )); then
          echo "the node started from an empty or different chain database (block $b; it was at $before)"; return 1
        fi
        return 0
      fi
    fi
    sleep 10
  done
  echo "the node didn't answer within $(( limit / 60 )) minutes"
  return 1
}

node_log_file() { find "$(data_dir)" -maxdepth 1 -name 'xdc-*.log' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n1 | cut -d' ' -f2-; }

node_log_maintenance() {   # keep the node's own log files from filling the disk
  local d newest size; d=$(data_dir); [[ -d $d ]] || return 0
  newest=$(node_log_file)
  find "$d" -maxdepth 1 -name 'xdc-*.log' ! -path "$newest" -mtime +14 -delete 2>/dev/null
  [[ -n $newest ]] || return 0
  size=$(stat -c %s "$newest" 2>/dev/null || echo 0)
  if (( size > 1073741824 )); then
    tail -c 104857600 "$newest" >"${newest%.log}-trimmed.log" && truncate -s 0 "$newest"
  fi
}

# ── Updates from XinFin ──────────────────────────────────────────────────────
# Never automatic: the daily check only looks, and checks whether the new
# release could be installed. Installing is something the operator chooses.
node_update_pending() {   # has XinFin published something newer than the release the node runs?
  local latest; latest=$(state_get NODE_LATEST_TREE)
  [[ -n $latest && -n $(rt_get "$(node_rt)" TREE) && $latest != "$(rt_get "$(node_rt)" TREE)" ]]
}

node_update_check() {   # fetch XinFin's latest; record what's new and whether it can be installed
  [[ -d $(node_base)/.git ]] && node_release_ready || return 1
  _git fetch --quiet origin >>"${XDC_LOG:-/dev/null}" 2>&1 || return 1
  local ref tree img tmp
  ref=$(node_upstream_ref) || return 1
  tree=$(_git rev-parse --verify -q "$ref:$(net)" 2>/dev/null)
  img=$(_git show "$ref:$(net)/docker-compose.yml" 2>/dev/null | awk '/^[[:space:]]*image:/ {print $2; exit}')
  state_set NODE_LATEST_TREE "${tree:-missing}"
  state_set NODE_LATEST_IMAGE "$img"
  if node_update_pending; then
    tmp=$(mktemp -d)
    if node_candidate_prepare "$ref" "$tmp/check"; then state_set NODE_UPDATE_BLOCKED ""
    else state_set NODE_UPDATE_BLOCKED "$NODE_CHECK_PROBLEM"; fi
    rm -rf "$tmp"
  else
    state_set NODE_UPDATE_BLOCKED ""
  fi
  return 0
}

node_release_label() {   # "v2.7.1", or "v2.7.1, XinFin's files of 2026-10-27" when the node software is the same as now
  local d="$1" img day
  img=$(rt_get "$d" IMAGE)
  if [[ $d != "$(node_rt)" && $img == "$(rt_get "$(node_rt)" IMAGE)" ]]; then
    day=$(_git show -s --format=%cs "$(rt_get "$d" REF)" 2>/dev/null)
    [[ -n $day ]] || day=$(date -d "@$(rt_get "$d" PREPARED)" +%F 2>/dev/null)
    printf "%s, XinFin's files of %s" "${img##*:}" "${day:-an earlier date}"
  else
    printf '%s' "${img##*:}"
  fi
}

# Switch the node to another release folder: stop, swap, start
node_switch_to() {   # node_switch_to NEW-DIR: NEW-DIR becomes the running release, the old one "previous"
  # returns 1 if nothing was changed, 2 if it switched but the node didn't start
  local new="$1" cur prev hold
  cur=$(node_rt); prev=$(node_rt_prev); hold="$STATE_DIR/node.hold"
  node_stop || return 1
  rm -rf "$hold"
  if [[ -d $cur ]] && ! mv "$cur" "$hold"; then node_up; return 1; fi
  if ! mv "$new" "$cur"; then [[ -d $hold ]] && mv "$hold" "$cur"; node_up; return 1; fi
  rm -rf "$prev"; [[ -d $hold ]] && mv "$hold" "$prev"
  node_up || return 2
}

# Swap back to the previous release and check it works. NODE_WHY says why not.
# Returns 1 if it switched but that release isn't working, 2 if nothing was changed.
NODE_WHY=""
node_go_back() {
  local rc
  NODE_WHY=""
  [[ -d $(node_rt_prev) ]] || { NODE_WHY="there's no previous release"; return 2; }
  node_switch_to "$(node_rt_prev)"; rc=$?
  case $rc in
    1) NODE_WHY="the node couldn't be stopped, or its release folders couldn't be swapped"; return 2 ;;
    2) NODE_WHY="the previous release's container didn't start"; return 1 ;;
  esac
  NODE_WHY=$(node_health_wait 600 0) || return 1
  NODE_WHY=""
  node_tree_sync; node_user_env_sync
  return 0
}

# =============================================================================
#  Chain snapshot: skip most of the initial sync
#  download = saved to disk first, resumes if interrupted (needs more space)
#  stream   = unpacked as it arrives, less space (restarts if interrupted)
# =============================================================================
snapshot_url() {
  local t; t=$(conf_get NODE_TYPE full)
  printf '%s/%s/%s/%s_%s_latest.tar.lz4' "$SNAPSHOT_BASE_URL" "$(net)" "$t" "$(net)" "$t"
}

# A mainnet full node syncing from block 0 replays the chain's early years
# (v1 rules, up to block 80,370,000). A restart there can leave it stuck at a
# checkpoint: XDC keeps the masternode list chosen at each gap block only in
# memory, and its fallback needs gap-block state that only archive nodes keep.
EARLY_CHAIN_END=80370000
early_chain_risk() { [[ $(net) == mainnet && $(conf_get NODE_TYPE full) == full ]]; }

snapshot_size() {
  curl -sIL --max-time 30 "$1" 2>/dev/null | awk -F': ' 'tolower($1) == "content-length" {gsub(/\r/, "", $2); v = $2} END {print v}'
}

snapshot_sha256() {   # published checksum, if the snapshot server offers one
  curl -fsSL --max-time 20 "$1.sha256" 2>/dev/null | grep -oE '[0-9a-f]{64}' | head -n1
}

_progress_reader() { local p; while read -r p; do [[ $p =~ ^[0-9]+$ ]] && job_progress "$p"; done; }

snapshot_restore() {   # snapshot_restore [replace]: "replace" deletes the current chain data first
  local method url work file size need avail have_ old sha extract keep="" replace=""
  method=$(conf_get SNAPSHOT download); [[ $method == stream ]] || method=download
  url=$(snapshot_url); work="$(net_dir)/snapshot-download"; file="$work/$(basename "$url")"
  extract="$work/extract"
  [[ ${1:-} == replace && -d $(xdc_dir) ]] && replace=1
  mkdir -p "$work"
  info "Snapshot: $url"

  # Check the disk space before anything is deleted
  size=$(snapshot_size "$url")
  if [[ $size =~ ^[0-9]+$ ]] && (( size > 0 )); then
    if [[ $method == stream ]]; then need=$(( size * 3 / 2 + 100 * 1024**3 )); else need=$(( size * 2 + 200 * 1024**3 )); fi
    have_=$(du -B1 "$file" 2>/dev/null | cut -f1); have_=${have_:-0}
    need=$(( need - have_ )); avail=$(disk_free_bytes "$(net_dir)")
    if (( avail < need )) && [[ -n $replace ]]; then   # the chain data being replaced frees space too
      info "Measuring the chain data that will be replaced"
      old=$(du -sB1 "$(xdc_dir)" 2>/dev/null | cut -f1); avail=$(( avail + ${old:-0} ))
    fi
    info "Snapshot size $(human "$size"). Needs about $(human "$need") free; $(human "$avail") available."
    if (( avail < need )); then
      if [[ $method == download ]]; then
        err "Not enough free disk space for the snapshot. Add disk space, or choose the streaming method, which needs less (Setup & settings → Snapshot method), and try again."
      else
        err "Not enough free disk space for the snapshot. Add disk space and try again."
      fi
      return 1
    fi
  else
    warn "Couldn't read the snapshot size, so the disk space check was skipped."
    size=""
  fi

  if [[ -n $replace ]]; then
    node_stop || return 1
    info "Deleting the old chain data (the node's account and identity are kept)"
    [[ -f $(xdc_dir)/nodekey ]] && cp -a "$(xdc_dir)/nodekey" "$work/nodekey.keep"
    rm -rf "$(xdc_dir)"; mkdir -p "$(xdc_dir)"
    [[ -f $work/nodekey.keep ]] && mv -f "$work/nodekey.keep" "$(xdc_dir)/nodekey"
    state_set SNAPSHOT_DONE ""
  fi
  sha=$(snapshot_sha256 "$url")
  [[ -n $sha ]] && info "The snapshot server publishes a checksum; it will be verified."

  node_stop || return 1
  ensure_coinbase_account || return 1
  rm -rf "$extract"; mkdir -p "$extract"

  if [[ $method == stream ]]; then
    info "Streaming and unpacking (if this is interrupted it starts again from the beginning)"
    local sumf="$work/stream.sha256" i; rm -f "$sumf" "$sumf.part"
    if ! curl -fsSL --retry 3 "$url" \
        | pv -n -i 30 ${size:+-s "$size"} 2> >(_progress_reader) \
        | tee >(sha256sum | cut -d' ' -f1 >"$sumf.part" && mv -f "$sumf.part" "$sumf") \
        | lz4 -dc | tar -x --no-same-owner -C "$extract"; then
      err "Streaming the snapshot failed. Try again (setup, or Node → Replace the chain data)."
      return 1
    fi
    if [[ -n $sha ]]; then
      for i in $(seq 1 120); do [[ -s $sumf ]] && break; sleep 1; done   # the checksum finishes just after the stream
      if [[ "$(cat "$sumf" 2>/dev/null)" != "$sha" ]]; then
        err "The snapshot didn't match its published checksum, so it wasn't used."; rm -rf "$extract"; return 1
      fi
      ok "Checksum matches"
    fi
  else
    info "Downloading (it resumes where it left off if interrupted)"
    aria2c -x 8 -s 8 -k 1M --continue=true --auto-file-renaming=false --allow-overwrite=true \
      --file-allocation=none --show-console-readout=false --summary-interval=120 --console-log-level=warn \
      --dir="$work" -o "$(basename "$file")" "$url" >>"${XDC_LOG:-/dev/null}" 2>&1 &
    local apid=$!
    while kill -0 "$apid" 2>/dev/null; do
      if [[ -n $size ]]; then
        have_=$(du -B1 "$file" 2>/dev/null | cut -f1)
        [[ -n $have_ ]] && job_progress "$(( have_ * 100 / size ))"
      fi
      sleep 20
    done
    wait "$apid" || { err "The download stopped. Try again (setup, or Node → Replace the chain data) and it continues from where it got to."; return 1; }
    [[ -s $file ]] || { err "The download finished but the file is missing."; return 1; }
    if [[ -n $sha ]]; then
      info "Checking the download against the published checksum"
      [[ "$(sha256sum "$file" | cut -d' ' -f1)" == "$sha" ]] || {
        err "The download didn't match its published checksum, so it was deleted. Try again to download it again."
        rm -f "$file"; return 1; }
      ok "Checksum matches"
    fi
    info "Unpacking (this takes a while)"
    job_progress 0
    if ! pv -n -i 30 "$file" 2> >(_progress_reader) | lz4 -dc | tar -x --no-same-owner -C "$extract"; then
      err "Unpacking the snapshot failed (out of disk space?)."; return 1
    fi
  fi

  [[ -d $extract/XDC/chaindata ]] || { err "The snapshot didn't contain the expected XDC/chaindata folder."; return 1; }
  [[ -f $(xdc_dir)/nodekey ]] && { keep=$(mktemp); cp -a "$(xdc_dir)/nodekey" "$keep"; }
  rm -rf "$(xdc_dir)"
  mv "$extract/XDC" "$(xdc_dir)"
  rm -f "$(xdc_dir)/nodekey" "$(xdc_dir)/transactions.rlp"
  if [[ -n $keep ]]; then mv -f "$keep" "$(xdc_dir)/nodekey"; chmod 600 "$(xdc_dir)/nodekey"; fi
  rm -rf "$work"
  state_set SNAPSHOT_DONE yes
  ok "Snapshot installed; the node now only needs to catch up from the snapshot's date"
}

# =============================================================================
#  Background tasks
#  Long work runs as its own systemd task, so it keeps going if your SSH
#  connection drops. Each task has a folder in /var/lib/xdc-rpc/jobs with its
#  steps, progress and log, which the menu (or "sudo xdc-rpc") can show again.
# =============================================================================
JOB_ID=""
JOB_STEP=""
STEP_NOTE=""

job_dir()   { printf '%s/%s' "$JOB_DIR" "$1"; }
job_get()   { cat "$(job_dir "$1")/$2" 2>/dev/null; }
job_put()   { printf '%s\n' "$3" >"$(job_dir "$1")/$2"; }
job_title() { job_get "$1" title; }

job_progress() {   # job_progress PERCENT (for the current step)
  [[ -n $JOB_ID ]] || return 0
  local p="$1"; (( p > 100 )) && p=100; (( p < 0 )) && p=0
  job_put "$JOB_ID" progress "$p"
}

job_alive() {   # is the task's process still running?
  local pid; pid=$(job_get "$1" pid)
  [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null && [[ "$(job_get "$1" status)" == running ]]
}

job_gone() {   # did the task stop without saying so (or never start)? Then it's marked failed.
  local id="$1"
  case "$(job_get "$id" status)" in
    running) job_alive "$id" && return 1 ;;
    queued)  (( $(now) - $(stat -c %Y "$(job_dir "$id")" 2>/dev/null || now) < 60 )) && return 1 ;;   # a minute to start
    *)       return 1 ;;
  esac
  job_put "$id" status failed
  return 0
}

job_active() {   # prints the id of a task that is running now, if any
  local d id
  for d in $(ls -1d "$JOB_DIR"/*/ 2>/dev/null | sort -r); do
    id=$(basename "$d")
    [[ "$(job_get "$id" status)" =~ ^(queued|running)$ ]] || continue
    job_gone "$id" || { echo "$id"; return 0; }
  done
  return 1
}

job_latest() {   # job_latest [KIND] -> newest task id
  local d id
  for d in $(ls -1d "$JOB_DIR"/*/ 2>/dev/null | sort -r); do
    id=$(basename "$d")
    [[ -z ${1:-} || "$(job_get "$id" kind)" == "$1" ]] && { echo "$id"; return 0; }
  done
  return 1
}

job_create() {   # job_create KIND TITLE -> id
  local id d
  id="$(ts)-$1"
  d=$(job_dir "$id"); mkdir -p "$d"; chmod 700 "$STATE_DIR" "$JOB_DIR" "$d"
  job_put "$id" kind "$1"; job_put "$id" title "$2"; job_put "$id" status queued
  : >"$d/steps"; : >"$d/log"; chmod 600 "$d/log"
  printf '%s' "$id"
}

job_launch() {   # job_launch ID: start the task in the background
  local id="$1" self
  self=$(readlink -f "$SELF_INSTALL_PATH" 2>/dev/null)
  [[ -x $self ]] || self=$(readlink -f "$0")
  if systemd_ok; then
    systemd-run --unit="xdc-rpc-job-$id" --description="xdc-rpc: $(job_title "$id")" --collect --quiet \
      --setenv=XDC_RPC_UI=text "$self" __job "$id" >/dev/null 2>&1 && return 0
  fi
  setsid nohup "$self" __job "$id" </dev/null >/dev/null 2>&1 &
  return 0
}

# Steps are given as "function|Title". A step function returns 0 when done,
# 3 when there was nothing to do (skipped), anything else when it failed.
# It can put a short remark for the summary in STEP_NOTE.
_job_steps_write() { local id="$1"; shift; printf '%s\n' "$@" >"$(job_dir "$id")/steps"; }

job_run_steps() {   # job_run_steps "fn|Title" ...
  local -a steps=("$@") lines=()
  local i n=${#steps[@]} fn title rc lock_needed
  for (( i = 0; i < n; i++ )); do lines+=("pending|${steps[$i]#*|}|"); done
  _job_steps_write "$JOB_ID" "${lines[@]}"
  for (( i = 0; i < n; i++ )); do
    fn="${steps[$i]%%|*}"; title="${steps[$i]#*|}"
    JOB_STEP="$title"; STEP_NOTE=""
    lines[$i]="running|$title|"; _job_steps_write "$JOB_ID" "${lines[@]}"
    job_put "$JOB_ID" progress ""
    info "── $title"
    # Changes to the firewall, nginx and SSH happen one at a time. Long
    # downloads don't hold the lock, so the menus stay usable meanwhile.
    lock_needed=1
    case $fn in step_snapshot|step_snapshot_forced|step_node_update_pull|step_node_update_verify|step_node_go_back|step_system_update) lock_needed=0 ;; esac
    if (( lock_needed )); then lock_take 1800 || { lines[$i]="failed|$title|Another task kept the system busy"; _job_steps_write "$JOB_ID" "${lines[@]}"; return 1; }; fi
    "$fn"; rc=$?
    (( lock_needed )) && lock_drop
    case $rc in
      0) lines[$i]="done|$title|$STEP_NOTE" ;;
      3) lines[$i]="skipped|$title|$STEP_NOTE" ;;
      *) lines[$i]="failed|$title|$STEP_NOTE"; _job_steps_write "$JOB_ID" "${lines[@]}"
         err "Stopped at: $title"; return 1 ;;
    esac
    _job_steps_write "$JOB_ID" "${lines[@]}"
  done
  return 0
}

job_steps_for() {   # the steps of each kind of task, as "function|Title"
  case $1 in
    setup)         printf '%s\n' "${SETUP_STEPS[@]}" ;;
    node-update)   printf '%s\n' "step_node_update_check|Checking XinFin's new release" \
                                  "step_node_update_pull|Downloading the new node software" \
                                  "step_node_update_switch|Switching to the new release" \
                                  "step_node_update_verify|Checking the new release works" ;;
    node-back)     printf '%s\n' "step_node_go_back|Going back to the previous release" ;;
    node-restart)  printf '%s\n' "step_node_restart|Restarting the node" ;;
    node-stop)     printf '%s\n' "step_node_stop|Stopping the node" ;;
    node-start)    printf '%s\n' "step_node_start|Starting the node" ;;
    snapshot)      printf '%s\n' "step_snapshot_forced|Chain snapshot" "step_node_start|Starting the node" ;;
    chain-reset)   printf '%s\n' "step_chain_reset|Deleting the chain data" "step_node_start|Starting the node" ;;
    system-update) printf '%s\n' "step_system_update|Updating Ubuntu packages" ;;
    *) return 1 ;;
  esac
}

# Entry point inside the background task
job_main() {
  local id="$1" d rc=0 kind
  d=$(job_dir "$id"); [[ -d $d ]] || exit 1
  JOB_ID="$id"; export XDC_LOG="$d/log"
  echo $$ >"$d/pid"; now >"$d/start"
  job_put "$id" status running
  conf_load; state_load
  kind=$(job_get "$id" kind)
  local -a steps=()
  mapfile -t steps < <(job_steps_for "$kind")
  if (( ${#steps[@]} )); then job_run_steps "${steps[@]}"; else err "Unknown task: $kind"; false; fi
  rc=$?
  now >"$d/end"
  if (( rc == 0 )); then
    job_put "$id" status "done"
    [[ $kind == setup ]] && { state_set SETUP_DONE yes; state_set SETUP_FAILED_STEP ""; }
  else
    job_put "$id" status failed
    [[ $kind == setup ]] && state_set SETUP_FAILED_STEP "$JOB_STEP"
  fi
  job_prune
  exit "$rc"
}

job_prune() {   # keep the 30 newest task folders
  ls -1d "$JOB_DIR"/*/ 2>/dev/null | sort -r | tail -n +31 | while read -r d; do rm -rf "${d:?}"; done
}

_fmt_dur() { local s=$1; printf '%02d:%02d:%02d' $(( s / 3600 )) $(( s % 3600 / 60 )) $(( s % 60 )); }

_job_render() {   # the progress screen
  local id="$1" st start end dur line state title note prog out=""
  st=$(job_get "$id" status); start=$(job_get "$id" start); end=$(job_get "$id" end)
  [[ -z $start ]] && start=$(now)
  dur=$(( ${end:-$(now)} - start ))
  [[ -t 1 ]] && out+="$(ui_plain_top)"$'\n'   # (on screen, not in the saved log view)
  out+=$'\n'"  ${C_BLD}$(job_title "$id")${C_OFF}   ${C_DIM}${st} · $(_fmt_dur "$dur")${C_OFF}"$'\n\n'
  prog=$(job_get "$id" progress)
  while IFS='|' read -r state title note; do
    [[ -z $title ]] && continue
    case $state in
      done)    out+="  ${C_GRN}✓${C_OFF} $title${note:+  ${C_DIM}($note)${C_OFF}}"$'\n' ;;
      skipped) out+="  ${C_DIM}–${C_OFF} $title  ${C_DIM}${note:-not needed}${C_OFF}"$'\n' ;;
      running) out+="  ${C_BLU}•${C_OFF} ${C_BLD}$title${C_OFF}${prog:+  ${C_BLU}${prog}%${C_OFF}}"$'\n' ;;
      failed)  out+="  ${C_RED}✗ $title${C_OFF}${note:+  ($note)}"$'\n' ;;
      *)       out+="    ${C_DIM}$title${C_OFF}"$'\n' ;;
    esac
  done <"$(job_dir "$id")/steps"
  # As much recent activity as fits on the screen (2 to 6 lines)
  local act; act=$(( $(ui_term_lines) - $(grep -c '|' "$(job_dir "$id")/steps" 2>/dev/null) - 10 ))
  (( act > 6 )) && act=6; (( act < 2 )) && act=2
  out+=$'\n'"  ${C_BLD}Latest activity${C_OFF}"$'\n'
  while IFS= read -r line; do
    out+="  ${C_DIM}${line}${C_OFF}"$'\n'
  done < <(grep -E '^[0-9-]+ [0-9:]+ (INFO|OK|WARN|ERROR) ' "$(job_dir "$id")/log" 2>/dev/null | tail -n "$act" | cut -c21- | cut -c1-$(( $(ui_term_cols) - 4 )))
  printf '\e[H\e[2J%s' "$out"
}

# Show a task's progress until it finishes (q goes back; the task keeps running)
job_watch() {
  local id="$1" key st
  [[ -t 1 ]] || { job_wait_quiet "$id"; return $?; }
  ui_clear
  while true; do
    _job_render "$id"
    st=$(job_get "$id" status)
    if [[ $st == "done" || $st == failed ]]; then break; fi
    job_gone "$id" && continue
    printf '\n  %s\n' "${C_DIM}This keeps running if you disconnect. Press q to go back to the menu.${C_OFF}"
    if read -r -s -n1 -t 2 key 2>/dev/null && [[ $key == [qQ] ]]; then
      printf '\n'; return 2
    fi
  done
  _job_render "$id"
  ui_drain_input
  if [[ $st == "done" ]]; then
    printf '\n  %s\n\n' "${C_GRN}✓ Finished.${C_OFF}"
    return 0
  fi
  printf '\n  %s\n' "${C_RED}✗ This didn't finish.${C_OFF} The full log is in $(job_dir "$id")/log"
  local e; e=$(grep -E ' ERROR ' "$(job_dir "$id")/log" 2>/dev/null | tail -n 3 | cut -c27-)
  [[ -n $e ]] && printf '\n%s\n' "$(sed 's/^/  /' <<<"$e")"
  printf '\n  %s\n\n' "Fix the problem above, then run it again. Finished steps are checked quickly and skipped."
  return 1
}

job_wait_quiet() {   # for non-interactive use: wait and print the result
  local id="$1" st
  while true; do
    st=$(job_get "$id" status)
    [[ $st == "done" || $st == failed ]] && break
    job_gone "$id" && { st=failed; break; }
    sleep 3
  done
  grep -E ' (OK|WARN|ERROR) ' "$(job_dir "$id")/log" | cut -c21-
  [[ $st == "done" ]]
}

# Start a task and follow it. Refuses if another one is running.
JOB_LAST_ID=""
job_start() {   # job_start KIND TITLE [--no-watch]
  local cur id
  JOB_LAST_ID=""
  if cur=$(job_active); then
    ui_msg "Busy" "Another task is running: $(job_title "$cur").

Wait for it to finish first. You can follow it from the main menu (Running task)."
    return 1
  fi
  id=$(job_create "$1" "$2")
  JOB_LAST_ID=$id
  job_launch "$id"
  [[ ${3:-} == --no-watch ]] && return 0
  sleep 1
  job_watch "$id"; local rc=$?
  conf_load; state_load   # the task may have changed settings and state
  return "$rc"
}

# Run a change that must not overlap with a background step
with_lock() {
  lock_take 30 || { ui_msg "Busy" "A background task is changing the system right now. Try again in a minute."; return 1; }
  "$@"; local rc=$?
  lock_drop
  return "$rc"
}

# =============================================================================
#  Setup steps. Each one checks how things really are and only does what's
#  missing, so running setup again is always safe and continues where a
#  previous run stopped.
# =============================================================================
SETUP_STEPS=(
  "step_check|Checking the server"
  "step_packages|Installing system packages"
  "step_docker|Installing Docker"
  "step_firewall|Firewall"
  "step_fail2ban|SSH protection (fail2ban)"
  "step_nginx|Web server (nginx)"
  "step_cert|TLS certificate"
  "step_node_files|XDC node files"
  "step_snapshot|Chain snapshot"
  "step_node_start|Starting the node"
  "step_maint|Daily checks and login notices"
  "step_backup|Backup"
)

step_check() {
  configured || { err "No settings found. Run: sudo xdc-rpc setup"; return 1; }
  os_supported || { err "This tool supports Ubuntu 24.04 and 26.04 LTS. This server runs $(os_id) $(os_version)."; return 1; }
  systemd_ok || { err "systemd isn't running here. A full virtual server (VPS) is needed."; return 1; }
  local mem; mem=$(mem_total_gb)
  (( mem < 15 )) && warn "This server has ${mem} GB of memory. XinFin recommends at least 16 GB for a node."
  if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != yes ]]; then
    timedatectl set-ntp true >/dev/null 2>&1
    warn "The clock wasn't synchronised; automatic time sync has been switched on."
  fi
  STEP_NOTE="Ubuntu $(os_version), ${mem} GB memory, $(human "$(disk_free_bytes "$(node_base)")") free disk"
}

step_packages() {
  # On a server whose kernel has IPv6 switched off, nginx can't start with
  # Ubuntu's default site (it listens on [::]:80), so installing nginx fails.
  # That site is never used here, so an empty one takes its place first.
  if [[ ! -e /proc/net/if_inet6 ]] && ! pkg_installed nginx; then
    mkdir -p /etc/nginx/sites-enabled
    if [[ ! -e /etc/nginx/sites-enabled/default || -L /etc/nginx/sites-enabled/default ]]; then
      rm -f /etc/nginx/sites-enabled/default; : >/etc/nginx/sites-enabled/default
    fi
  fi
  apt_install "${BASE_PACKAGES[@]}" || return 1
  # Ubuntu's security updates install themselves (Ubuntu's usual setting)
  if [[ ! -f /etc/apt/apt.conf.d/20auto-upgrades ]]; then
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' >/etc/apt/apt.conf.d/20auto-upgrades
  fi
  systemctl enable --now unattended-upgrades >/dev/null 2>&1
  return 0
}

step_docker() { docker_install; }

step_firewall() {
  ufw_apply || return 1
  STEP_NOTE="SSH $(ssh_config_ports | paste -sd, -), P2P $(conf_get P2P_PORT); 443 for $(allow_count) allowed address(es)"
}

step_fail2ban() { f2b_apply; }

step_nginx() { nginx_apply; }

step_cert() {
  le_hooks_install
  cert_obtain || return 1
  nginx_apply || return 1
  fw_port80_close
  systemctl enable --now certbot.timer >/dev/null 2>&1
  STEP_NOTE="valid for $(cert_days_left "$(conf_get DOMAIN)") days; renews automatically"
}

step_node_files() {
  node_repo_ensure || return 1
  local was; was=$(rt_get "$(node_rt)" NETWORK)
  if [[ -n $was && $was != "$(net)" ]]; then
    # The network was changed: the other network's node stops; its chain data stays in its own folder
    info "Switching this server's node from $was to $(net)"
    if docker inspect "xdcnetwork-$was-node" >/dev/null 2>&1; then
      container_stop_clean "xdcnetwork-$was-node"; run docker rm "xdcnetwork-$was-node"
    fi
    rm -rf "$(node_rt)" "$(node_rt_prev)" "$(node_rt_new)"
    local k; for k in NODE_CONFIG_HASH NODE_LATEST_TREE NODE_LATEST_IMAGE NODE_UPDATE_BLOCKED SNAPSHOT_DONE; do state_set "$k" ""; done
  fi
  if ! node_release_ready; then
    # First time: check the XinFin release that's checked out here and run from a copy of it
    if ! node_candidate_prepare HEAD; then
      err "XinFin's node files in $(node_base) aren't laid out the way this version of xdc-rpc expects: $NODE_CHECK_PROBLEM."
      err "Check for a newer xdc-rpc (sudo xdc-rpc update), then run setup again."
      return 1
    fi
    rm -rf "$(node_rt)"   # anything half-made (its keystore password was carried into the new copy)
    mv "$(node_rt_new)" "$(node_rt)"
  fi
  restore_apply_node_files || return 1
  node_files_refresh || return 1
  local img; img=$(node_image) || return 1
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    info "Downloading the node software ($img)"
    run docker pull "$img" || { err "Couldn't download $img from Docker Hub."; return 1; }
  fi
  STEP_NOTE="$img"
}

step_snapshot() {
  if [[ $(conf_get SNAPSHOT none) == none ]]; then STEP_NOTE="not chosen; the node syncs from the network"; return 3; fi
  if [[ $(state_get SNAPSHOT_DONE) == yes ]]; then STEP_NOTE="already installed"; return 3; fi
  if [[ -d $(xdc_dir)/chaindata ]]; then
    state_set SNAPSHOT_DONE yes
    STEP_NOTE="chain data already here, so it was kept"; return 3
  fi
  snapshot_restore
}

step_snapshot_forced() { snapshot_restore replace; }

# Delete the chain database so the node syncs again from block 0. Its account
# (keystore/) and identity (nodekey) stay; starting writes the first block.
# XDCx/ (the exchange data) is rebuilt from the chain, so it goes too.
step_chain_reset() {
  local keep=""
  node_stop || return 1
  info "Deleting the chain data (the node's account and identity are kept)"
  if [[ -f $(xdc_dir)/nodekey ]]; then keep=$(mktemp); cp -a "$(xdc_dir)/nodekey" "$keep"; fi
  rm -rf "$(xdc_dir)" "$(data_dir)/XDCx"; mkdir -p "$(xdc_dir)"
  if [[ -n $keep ]]; then mv -f "$keep" "$(xdc_dir)/nodekey"; chmod 600 "$(xdc_dir)/nodekey"; fi
  state_set SNAPSHOT_DONE ""
  STEP_NOTE="it syncs again from block 0"
}

# Rewrite the running release's generated files from the current settings
# (including any change made in XinFin's .env)
node_files_refresh() {
  local before; before="$(rpc_port) $(ws_port)"
  node_release_generate "$(node_rt)" || return 1
  if [[ "$(rpc_port) $(ws_port)" != "$before" && -f $NGINX_SITE ]]; then
    info "The node's RPC/WS ports changed in XinFin's .env, so the web server is updated to match"
    nginx_apply || return 1
  fi
}

step_node_start() {
  node_release_ready || { err "The node's files aren't set up yet. Run setup first."; return 1; }
  node_files_refresh || return 1
  ensure_genesis_init || return 1
  node_up || return 1
  local i b=""
  for i in $(seq 1 24); do b=$(node_block); [[ -n $b ]] && break; sleep 5; done
  if [[ -z $b ]]; then
    warn "The node has started but isn't answering yet. That's normal for the first few minutes, especially after a snapshot."
    STEP_NOTE="starting up"; return 0
  fi
  ok "The node is answering (block $b)"
  if [[ "$(endpoint_selftest)" == "$(chain_id_hex)" ]]; then
    ok "Endpoint check passed: https://$(conf_get DOMAIN)/xdcrpc"
    STEP_NOTE="block $b; endpoint answering"
  else
    warn "The node answers, but the HTTPS endpoint check didn't. See: sudo xdc-rpc → Status & logs"
    STEP_NOTE="block $b"
  fi
}

step_node_stop()    { node_stop; }
step_node_restart() { node_stop && step_node_start; }

# ── Updating the node software (see node_upstream_check for what's checked) ──
step_node_update_check() {
  node_release_ready || { err "Finish setup first."; return 1; }
  rm -rf "$(node_rt_new)"; state_set NODE_SWITCHED ""
  info "Fetching XinFin's latest node files"
  _git fetch --quiet origin >>"${XDC_LOG:-/dev/null}" 2>&1 || { err "Couldn't reach XinFin's repository on GitHub. Nothing was changed."; return 1; }
  local ref tree
  ref=$(node_upstream_ref) || { err "Couldn't find XinFin's latest release. Nothing was changed."; return 1; }
  tree=$(_git rev-parse --verify -q "$ref:$(net)" 2>/dev/null)
  state_set NODE_LATEST_TREE "${tree:-missing}"
  if [[ -n $tree && $tree == "$(rt_get "$(node_rt)" TREE)" ]]; then
    state_set NODE_UPDATE_BLOCKED ""
    ok "Your node already runs XinFin's latest release ($(node_image))"
    STEP_NOTE="already up to date"; return 0
  fi
  info "Checking XinFin's new release"
  if ! node_candidate_prepare "$ref"; then
    state_set NODE_UPDATE_BLOCKED "$NODE_CHECK_PROBLEM"
    err "XinFin's new release changes something this version of xdc-rpc relies on: $NODE_CHECK_PROBLEM."
    err "Nothing was changed: your node keeps running as it is. Update xdc-rpc (Updates menu) and try again. If there's no newer xdc-rpc yet, check again later."
    return 1
  fi
  state_set NODE_UPDATE_BLOCKED ""
  state_set NODE_LATEST_IMAGE "$(rt_get "$(node_rt_new)" IMAGE)"
  ok "XinFin's new release passed the checks ($(rt_get "$(node_rt_new)" IMAGE))"
  STEP_NOTE=$(rt_get "$(node_rt_new)" IMAGE)
}

step_node_update_pull() {
  [[ -d $(node_rt_new) ]] || { STEP_NOTE="nothing to download"; return 3; }
  local img; img=$(rt_get "$(node_rt_new)" IMAGE)
  if docker image inspect "$img" >/dev/null 2>&1; then STEP_NOTE="already downloaded"; return 0; fi
  info "Downloading $img (your node keeps running meanwhile)"
  run docker pull "$img" || { rm -rf "$(node_rt_new)"; err "Couldn't download $img. Nothing was changed."; return 1; }
  STEP_NOTE="$img"
}

step_node_update_switch() {
  [[ -d $(node_rt_new) ]] || { STEP_NOTE="nothing to change"; return 3; }
  local b rc; b=$(node_block)
  state_set NODE_BLOCK_BEFORE "${b:-0}"
  node_switch_to "$(node_rt_new)"; rc=$?
  if (( rc == 1 )); then err "The node couldn't be stopped, so nothing was changed."; return 1; fi
  state_set NODE_SWITCHED yes
  (( rc == 0 )) || warn "The new release's container didn't start; the next step checks it and goes back if needed."
  STEP_NOTE="now on $(node_image)"
  return 0
}

step_node_update_verify() {
  [[ $(state_get NODE_SWITCHED) == yes ]] || { STEP_NOTE="nothing to check"; return 3; }
  state_set NODE_SWITCHED ""
  local why failed
  info "Waiting for the new release to answer (up to 10 minutes)"
  if why=$(node_health_wait 600 "$(state_get NODE_BLOCK_BEFORE 0)"); then
    node_tree_sync; node_user_env_sync
    ok "The new release is working (block $(fmt_num "$(node_block)"))"
    STEP_NOTE="working"; return 0
  fi
  failed=$(node_image)
  err "The new release didn't work: $why."
  info "Going back to the previous release"
  if node_go_back; then
    rm -rf "$(node_rt_prev)"   # don't offer to switch to the broken release again
    notice_add "The node update to ${failed##*:} didn't work, so the previous release was put back. Details: Status & logs → Background tasks."
    err "The previous release was put back and is working again."
  else
    notice_add "The node update to ${failed##*:} didn't work, and going back to the previous release didn't either ($NODE_WHY). See Status & logs → Background tasks."
    err "Going back didn't work either: $NODE_WHY. See Status & logs → Background tasks."
  fi
  return 1
}

step_node_go_back() {
  local rc
  [[ -d $(node_rt_prev) ]] || { err "There's no previous release to go back to."; return 1; }
  node_go_back; rc=$?
  if (( rc == 0 )); then STEP_NOTE="now on $(node_image)"; return 0; fi
  if (( rc == 2 )); then err "Nothing was changed: $NODE_WHY."; return 1; fi
  err "The previous release didn't work: $NODE_WHY."
  info "Switching back to the release you were on"
  if node_go_back; then err "You're back on the release you were on, and it's working."
  else err "That didn't work either: $NODE_WHY. See Status & logs → Background tasks."; fi
  return 1
}

step_maint() { maint_install || return 1; STEP_NOTE="update check, log clean-up and backups once a day"; }

step_backup() { backup_create force || return 1; STEP_NOTE="saved in $(backup_dir)"; }

step_system_update() { system_update; }

# =============================================================================
#  Backups: everything needed to rebuild this node on this or another server,
#  encrypted with your backup password. The newest BACKUP_KEEP are kept in the
#  admin user's ~/XDC-Backups. A new one is made after setup, after changes,
#  and daily when anything has changed.
# =============================================================================
RESTORE_DIR=$STATE_DIR/restore

backup_dir() { printf '%s/XDC-Backups' "$(admin_home)"; }

backup_pass_ensure() {
  [[ -s $BACKUP_PASS_FILE ]] && return 0
  mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
  ( umask 077; gen_password >"$BACKUP_PASS_FILE" )
}
backup_pass_set() { mkdir -p "$CONF_DIR"; ( umask 077; printf '%s' "$1" >"$BACKUP_PASS_FILE" ); }
backup_pass() { cat "$BACKUP_PASS_FILE" 2>/dev/null; }

_backup_stage() {   # copy everything worth keeping into DIR
  local s="$1" nd dd admin f h
  nd=$(net_dir); dd=$(data_dir); admin=$(conf_get ADMIN_USER root)
  mkdir -p "$s/xdc-rpc" "$s/node" "$s/nginx" "$s/ssh"
  cp -a "$CONF_FILE" "$s/xdc-rpc/xdc-rpc.conf"
  [[ -f $ALLOW_FILE ]] && cp -a "$ALLOW_FILE" "$s/xdc-rpc/allowlist"
  # The node's identity and account
  [[ -f $nd/.env ]] && cp -a "$nd/.env" "$s/node/env"
  if [[ -f $(node_rt)/pwd ]]; then cp -a "$(node_rt)/pwd" "$s/node/pwd"; elif [[ -f $nd/.pwd ]]; then cp -a "$nd/.pwd" "$s/node/pwd"; fi
  [[ -f $(node_rt)/release ]] && cp -a "$(node_rt)/release" "$s/node/release"
  [[ -d $dd/keystore ]] && cp -a "$dd/keystore" "$s/node/keystore"
  [[ -f $dd/XDC/nodekey ]] && cp -a "$dd/XDC/nodekey" "$s/node/nodekey"
  [[ -f $dd/coinbase.txt ]] && cp -a "$dd/coinbase.txt" "$s/node/coinbase.txt"
  for f in "$(compose_file)" "$(start_ours)"; do [[ -f $f ]] && cp -a "$f" "$s/node/"; done   # for reference
  # Web server and certificate
  for f in "$NGINX_SITE" "$NGINX_ALLOW_RPC" "$NGINX_ALLOW_WSS"; do [[ -f $f ]] && cp -a "$f" "$s/nginx/"; done
  [[ -d $LE_DIR ]] && tar -C / -cf "$s/letsencrypt.tar" etc/letsencrypt 2>/dev/null
  # SSH settings and the admin user's login keys
  for f in "$SSHD_PORT_CONF" "$SSHD_AUTH_CONF"; do [[ -f $f ]] && cp -a "$f" "$s/ssh/"; done
  h=$(user_home "$admin"); [[ -f $h/.ssh/authorized_keys ]] && cp -a "$h/.ssh/authorized_keys" "$s/ssh/authorized_keys"
  {
    echo "format=1"
    echo "tool_version=$XDC_RPC_VERSION"
    echo "created=$(date -u '+%F %T UTC')"
    echo "domain=$(conf_get DOMAIN)"
    echo "network=$(net)"
    echo "node_type=$(conf_get NODE_TYPE full)"
    echo "admin_user=$admin"
    echo "coinbase=$(node_coinbase)"
    echo "server=$(hostname)"
  } >"$s/manifest.txt"
}

_gpg() { gpg --batch --yes --quiet --no-tty --pinentry-mode loopback "$@"; }

backup_create() {   # backup_create [force] [quiet]
  local force="" quiet="" a
  for a in "$@"; do [[ $a == force ]] && force=1; [[ $a == quiet ]] && quiet=1; done
  configured || return 1
  have gpg || { err "gpg isn't installed (run setup again)."; return 1; }
  backup_pass_ensure
  local tmpd stage hash dir name admin
  tmpd=$(mktemp -d); stage="$tmpd/xdc-rpc-backup"; mkdir -p "$stage"
  _backup_stage "$stage"
  hash=$(cd "$stage" && find . -type f ! -name manifest.txt ! -name letsencrypt.tar -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
  hash+=$(tar -tvf "$stage/letsencrypt.tar" 2>/dev/null | sha256sum | cut -c1-16)
  if [[ -z $force && $hash == "$(state_get BACKUP_HASH)" && -f "$(backup_dir)/$(state_get BACKUP_LAST)" ]]; then
    rm -rf "$tmpd"; [[ -z $quiet ]] && info "Nothing has changed since the last backup."
    return 0
  fi
  admin=$(conf_get ADMIN_USER root)
  dir=$(backup_dir)
  name="xdc-rpc-backup_$(conf_get DOMAIN)_$(ts).tar.gz.gpg"
  export GNUPGHOME="$tmpd/gnupg"; mkdir -m 700 "$GNUPGHOME"
  if ! tar -C "$tmpd" -czf - xdc-rpc-backup | _gpg --passphrase-file "$BACKUP_PASS_FILE" --symmetric --cipher-algo AES256 -o "$tmpd/$name"; then
    gpgconf --kill gpg-agent >/dev/null 2>&1; unset GNUPGHOME; rm -rf "$tmpd"
    err "The backup couldn't be written."; return 1
  fi
  gpgconf --kill gpg-agent >/dev/null 2>&1; unset GNUPGHOME
  # The folder is in the admin's home, so the file is put there (and old ones
  # removed) as the admin: root never writes through a link left in that folder.
  if ! _as_user "$admin" sh -c 'cd / && umask 077 && mkdir -p -- "$1" && cat >"$1/$2.part" && mv -f -- "$1/$2.part" "$1/$2"' sh "$dir" "$name" <"$tmpd/$name"; then
    rm -rf "$tmpd"; err "The backup couldn't be saved in $dir."; return 1
  fi
  rm -rf "$tmpd"
  state_set BACKUP_HASH "$hash"; state_set BACKUP_LAST "$name"; state_set BACKUP_LAST_TIME "$(now)"
  # keep the newest BACKUP_KEEP
  _as_user "$admin" sh -c 'cd / && ls -1t -- "$1"/xdc-rpc-backup_*.tar.gz.gpg 2>/dev/null | tail -n +"$2" | while IFS= read -r a; do rm -f -- "$a"; done' sh "$dir" "$(( BACKUP_KEEP + 1 ))"
  [[ -z $quiet ]] && ok "Backup saved: $dir/$name"
  _logline "Backup saved: $dir/$name"
  return 0
}

backup_list() {   # newest first: "PATH|SIZE|DATE"
  local f
  ls -1t "$(backup_dir)"/xdc-rpc-backup_*.tar.gz.gpg 2>/dev/null | while read -r f; do
    printf '%s|%s|%s\n' "$f" "$(numfmt --to=iec --suffix=B "$(stat -c %s "$f")")" "$(date -d "@$(stat -c %Y "$f")" '+%F %R')"
  done
}

# A backup file, readably: "2026-11-21 05:58 · rpc.example.com · in /root/XDC-Backups"
backup_file_label() {   # backup_file_label PATH
  local f="$1" b d
  b=$(basename "$f"); d=${b#xdc-rpc-backup_}; d=${d%_*}
  [[ $d == "$b" || -z $d ]] && d=$b
  printf '%s · %s · in %s' "$(date -d "@$(stat -c %Y "$f" 2>/dev/null || echo 0)" '+%F %R')" "$d" "$(dirname "$f")"
}

backup_download_text() {   # backup_download_text FILE
  local f="$1" admin port host rel cmd
  admin=$(conf_get ADMIN_USER root); port=$(ssh_config_ports | head -n1); host=$(ssh_target_host)
  rel="${f#"$(user_home "$admin")"/}"
  cmd="scp"; [[ $port != 22 ]] && cmd+=" -P $port"
  cat <<EOF
To keep a copy on your own computer, run this ON YOUR COMPUTER (not on the
server), in Terminal on macOS/Linux or PowerShell on Windows:

  $cmd $admin@$host:$rel .

The file is saved in the folder you ran the command from. It's encrypted:
you'll need your backup password to restore it (Backups → Show the backup password).
EOF
}

# ── Restore ──────────────────────────────────────────────────────────────────
backup_find_files() {   # backups lying around on this server (e.g. uploaded with scp)
  { ls -1t /root/*.gpg /root/XDC-Backups/*.gpg /home/*/*.gpg /home/*/XDC-Backups/*.gpg 2>/dev/null; } | grep -E 'xdc-rpc-backup_.*\.tar\.gz\.gpg$' | awk '!seen[$0]++'
}

# backup_open FILE PASSWORD -> prints the folder with the unpacked backup
# returns 2 for a wrong password, 1 for other problems
backup_open() {
  local f="$1" pass="$2" tmpd rc
  tmpd=$(mktemp -d); chmod 700 "$tmpd"
  export GNUPGHOME="$tmpd/gnupg"; mkdir -m 700 "$GNUPGHOME"
  printf '%s' "$pass" | _gpg --passphrase-fd 0 -d "$f" 2>"$tmpd/gpg.err" | tar -xzf - -C "$tmpd" 2>/dev/null
  rc=$?
  gpgconf --kill gpg-agent >/dev/null 2>&1; unset GNUPGHOME
  if (( rc != 0 )) || [[ ! -f $tmpd/xdc-rpc-backup/manifest.txt ]]; then
    if grep -qiE 'bad (session key|passphrase)|decryption failed' "$tmpd/gpg.err"; then rm -rf "$tmpd"; return 2; fi
    rm -rf "$tmpd"; return 1
  fi
  printf '%s' "$tmpd/xdc-rpc-backup"
}

backup_manifest() { grep -E "^$2=" "$1/manifest.txt" 2>/dev/null | head -n1 | cut -d= -f2-; }

# Bring settings, allowlist and certificate back now; the node's account and
# identity are put in place by the "XDC node files" setup step.
restore_from() {   # restore_from UNPACKED-DIR
  local b="$1" k v
  [[ -f $b/xdc-rpc/xdc-rpc.conf ]] || { err "This backup has no settings in it."; return 1; }
  local -A old=(); _kv_load "$b/xdc-rpc/xdc-rpc.conf" old
  for k in "${!old[@]}"; do
    case $k in SSH_*|NODE_BASE) continue ;; esac   # SSH settings are chosen again on this server
    v=${old[$k]}; CONF[$k]="$v"
  done
  conf_save
  if [[ -f $b/xdc-rpc/allowlist ]]; then mkdir -p "$CONF_DIR"; install -m 600 "$b/xdc-rpc/allowlist" "$ALLOW_FILE"; fi
  # certificate: only if this server doesn't already have one for the domain
  if [[ -f $b/letsencrypt.tar ]] && ! cert_exists "$(conf_get DOMAIN)"; then
    tar -C / -xf "$b/letsencrypt.tar" 2>/dev/null && info "Certificate restored."
  fi
  rm -rf "$RESTORE_DIR"; mkdir -p "$RESTORE_DIR"; chmod 700 "$RESTORE_DIR"
  [[ -d $b/node ]] && cp -a "$b/node" "$RESTORE_DIR/node"
  [[ -f $b/ssh/authorized_keys ]] && cp -a "$b/ssh/authorized_keys" "$RESTORE_DIR/authorized_keys"
  state_set SNAPSHOT_DONE ""
  return 0
}

restore_apply_keys() {   # add the backed-up login keys to the admin user
  local f="$RESTORE_DIR/authorized_keys" line u; u=$(conf_get ADMIN_USER)
  [[ -f $f && -n $u ]] && user_exists "$u" || return 0
  while IFS= read -r line; do
    [[ -z $line || $line == \#* ]] && continue
    authkeys_add "$u" "$line"
  done <"$f"
  rm -f "$f"
}

restore_apply_node_files() {   # called by setup once XinFin's files are in place
  local r="$RESTORE_DIR/node" dd xd nd
  [[ -d $r ]] || return 0
  dd=$(data_dir); xd=$(xdc_dir); nd=$(net_dir)
  info "Putting the node's account and identity back from your backup"
  node_stop || return 1
  mkdir -p "$dd" "$xd"
  if [[ -d $r/keystore ]]; then
    if [[ -d $dd/keystore ]] && ! diff -rq "$dd/keystore" "$r/keystore" >/dev/null 2>&1; then
      mv "$dd/keystore" "$dd/keystore.before-restore-$(ts)"
    fi
    rm -rf "$dd/keystore"; cp -a "$r/keystore" "$dd/keystore"
  fi
  [[ -f $r/nodekey ]] && install -m 600 "$r/nodekey" "$xd/nodekey"
  [[ -f $r/coinbase.txt ]] && cp -a --remove-destination "$r/coinbase.txt" "$dd/coinbase.txt"
  [[ -f $r/pwd && -d $(node_rt) ]] && install -m 600 "$r/pwd" "$(node_rt)/pwd"
  [[ -f $r/env && ! -e $nd/.env ]] && _owner_write "$nd/.env" <"$r/env"
  rm -rf "$RESTORE_DIR/node"
  local cb_; cb_=$(node_coinbase)
  ok "Node account${cb_:+ 0x$cb_} restored"
}

# =============================================================================
#  Updates (this tool, the XDC node, Ubuntu), daily checks, login notices
# =============================================================================
notice_add() { mkdir -p "$STATE_DIR"; printf '%s  %s\n' "$(date '+%F %R')" "$*" >>"$STATE_DIR/notices"; }
notices()    { cat "$STATE_DIR/notices" 2>/dev/null; }
notices_clear() { rm -f "$STATE_DIR/notices"; }

# ── This tool ────────────────────────────────────────────────────────────────
tool_latest_version() {   # newest published release, e.g. 2.1.0
  local loc v
  loc=$(curl -fsSI --max-time 15 "$XDC_RPC_DOWNLOAD_BASE/latest" 2>/dev/null \
        | awk -F': ' 'tolower($1) == "location" {print $2}' | tr -d '\r')
  if [[ $loc =~ /tag/v?([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then printf '%s' "${BASH_REMATCH[1]}"; return 0; fi
  v=$(curl -fsSL --max-time 15 "https://api.github.com/repos/${XDC_RPC_REPO}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)
  v=${v#v}
  [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && { printf '%s' "$v"; return 0; }
  return 1
}

tool_download() {   # tool_download VERSION DIR -> a checked copy in DIR/xdc-rpc.sh
  local v="$1" d="$2" base="$XDC_RPC_DOWNLOAD_BASE/download/v$1"
  curl -fsSL --max-time 120 -o "$d/xdc-rpc.sh" "$base/xdc-rpc.sh" \
    && curl -fsSL --max-time 30 -o "$d/xdc-rpc.sh.sha256" "$base/xdc-rpc.sh.sha256" \
    || { err "Couldn't download version $v from GitHub."; return 1; }
  ( cd "$d" && sha256sum -c --status xdc-rpc.sh.sha256 ) || { err "The download didn't match its published checksum, so it wasn't used."; return 1; }
  bash -n "$d/xdc-rpc.sh" 2>/dev/null || { err "The download is damaged."; return 1; }
  grep -qxF "XDC_RPC_VERSION=\"$v\"" "$d/xdc-rpc.sh" || { err "The download isn't version $v."; return 1; }
}

_tool_put() {   # install FILE as the xdc-rpc command
  install -m 755 "$1" "$SELF_INSTALL_PATH.new" && mv -f "$SELF_INSTALL_PATH.new" "$SELF_INSTALL_PATH"
}

tool_update_install() {   # tool_update_install VERSION
  local v="$1" tmp prev="$LIB_DIR/xdc-rpc.previous"
  tmp=$(mktemp -d)
  tool_download "$v" "$tmp" || { rm -rf "$tmp"; return 1; }
  mkdir -p "$LIB_DIR"
  [[ -f $SELF_INSTALL_PATH ]] && cp -a "$SELF_INSTALL_PATH" "$prev"
  if ! _tool_put "$tmp/xdc-rpc.sh"; then rm -rf "$tmp"; err "Couldn't install version $v (disk full?)."; return 1; fi
  rm -rf "$tmp"
  if "$SELF_INSTALL_PATH" __post-update "$XDC_RPC_VERSION" >>"${XDC_LOG:-/dev/null}" 2>&1; then
    state_set TOOL_LATEST "$v"
    ok "xdc-rpc is now version $v"
    return 0
  fi
  err "Version $v didn't apply cleanly, so version $XDC_RPC_VERSION was put back."
  _tool_put "$prev"
  "$SELF_INSTALL_PATH" __post-update "$v" >>"${XDC_LOG:-/dev/null}" 2>&1
  return 1
}

tool_rollback() {   # go back to the version that was installed before the last update
  local prev="$LIB_DIR/xdc-rpc.previous" pv
  [[ -f $prev ]] || { err "No previous version is stored."; return 1; }
  pv=$(grep -m1 -oE '^XDC_RPC_VERSION="[0-9.]+"' "$prev" | cut -d'"' -f2)
  cp -a "$SELF_INSTALL_PATH" "$LIB_DIR/xdc-rpc.rolled-back"
  _tool_put "$prev" || { err "Couldn't put version $pv back."; return 1; }
  state_set TOOL_SKIP "$XDC_RPC_VERSION"   # automatic updates won't install this version again
  "$SELF_INSTALL_PATH" __post-update "$XDC_RPC_VERSION" >>"${XDC_LOG:-/dev/null}" 2>&1
  ok "Back on version $pv"
}

# Runs in the NEW version straight after an update: re-applies everything that
# depends on settings inside this script (for example Plugin's gateway list).
post_update_main() {
  conf_load; state_load
  configured || return 0
  [[ $(state_get SETUP_DONE) == yes ]] || return 0
  maint_install || return 1
  allow_apply || return 1
  state_set TOOL_VERSION "$XDC_RPC_VERSION"
  notice_add "xdc-rpc updated to version $XDC_RPC_VERSION."
  return 0
}

# ── Ubuntu packages ──────────────────────────────────────────────────────────
system_update() {
  _APT_UPDATED=""; apt_update_once || return 1
  local docker_too=""
  apt list --upgradable 2>/dev/null | grep -qE '^(docker-ce|docker-ce-cli|containerd\.io)/' && docker_too=1
  if [[ -n $docker_too && $(node_state) == running ]]; then
    info "Docker itself is being updated, so the node is stopped cleanly first"
    node_stop || return 1
  fi
  apt_get -y --with-new-pkgs -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade || return 1
  apt_get -y autoremove
  if [[ -n $docker_too ]] && configured && [[ -f $(compose_file) ]]; then node_up || return 1; fi
  if [[ -f /var/run/reboot-required ]]; then
    STEP_NOTE="restart the server to finish (Updates → Restart the server)"
    warn "Some updates need a server restart to finish: Updates → Restart the server."
  fi
  return 0
}

reboot_needed() { [[ -f /var/run/reboot-required ]]; }

# ── Daily checks ─────────────────────────────────────────────────────────────
maint_install() {
  cat >"/etc/systemd/system/$DAILY_UNIT.service" <<EOF
[Unit]
Description=xdc-rpc daily checks (updates, log clean-up, backup)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SELF_INSTALL_PATH __daily
Nice=10
IOSchedulingClass=idle
EOF
  cat >"/etc/systemd/system/$DAILY_UNIT.timer" <<'EOF'
[Unit]
Description=xdc-rpc daily checks

[Timer]
OnCalendar=daily
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload && systemctl enable --now "$DAILY_UNIT.timer" >/dev/null 2>&1 || return 1
  cat >"$MOTD_SCRIPT" <<EOF
#!/bin/sh
# xdc-rpc: node status and notices when you log in
[ -x $SELF_INSTALL_PATH ] && $SELF_INSTALL_PATH __motd 2>/dev/null
exit 0
EOF
  chmod 755 "$MOTD_SCRIPT"
  files_links_sync
  return 0
}

daily_main() {
  conf_load; state_load
  configured || return 0
  log_to "$LOG_DIR/daily.log"
  _logline "Daily checks started"
  local latest
  if latest=$(tool_latest_version); then
    state_set TOOL_LATEST "$latest"
    if version_gt "$latest" "$XDC_RPC_VERSION" && [[ $(conf_get AUTO_UPDATE no) == yes ]] \
       && [[ $latest != "$(state_get TOOL_SKIP)" ]] && ! job_active >/dev/null; then
      if lock_take 120; then
        tool_update_install "$latest" || notice_add "Automatic update to xdc-rpc $latest failed; see $XDC_LOG"
        lock_drop
      fi
    fi
  fi
  if ! job_active >/dev/null && lock_take 120; then node_update_check >/dev/null 2>&1; lock_drop; fi
  node_log_maintenance
  if lock_take 120; then backup_create quiet; lock_drop; fi
  # Port 80 should only ever be open while a certificate renews
  if fw_port80_is_open && ! pgrep -x certbot >/dev/null; then fw_port80_close; _logline "Closed port 80 (left open by an interrupted renewal)"; fi
  job_prune
  files_links_sync
  state_set LAST_DAILY "$(now)"
  _logline "Daily checks finished"
}

# ── Login message ────────────────────────────────────────────────────────────
motd_main() {
  conf_load; state_load
  configured || return 0
  local st blk="" peers="" line latest img_now img_new
  st=$(node_state)
  if [[ $st == running ]]; then
    blk=$(curl -s --noproxy '*' --max-time 1 -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
          "http://127.0.0.1:$(rpc_port)" 2>/dev/null | jq -r '.result // empty' 2>/dev/null)
    [[ $blk =~ ^0x[0-9a-fA-F]+$ ]] && blk=$(printf "%'d" "$blk" 2>/dev/null || printf '%d' "$blk")
  fi
  printf '\n XDC node · %s · %s%s\n' "$(conf_get DOMAIN)" "$st" "${blk:+ · block $blk}"
  printf ' Manage it with: sudo xdc-rpc\n'
  [[ -d $(files_links_dir) ]] && printf ' Shortcuts to its files: %s\n' "$(files_links_dir)"
  latest=$(state_get TOOL_LATEST)
  [[ -n $latest ]] && version_gt "$latest" "$XDC_RPC_VERSION" && printf ' ! xdc-rpc %s is available: sudo xdc-rpc → Updates\n' "$latest"
  if node_update_pending; then
    img_now=$(rt_get "$(node_rt)" IMAGE); img_new=$(state_get NODE_LATEST_IMAGE)
    if [[ -n $(state_get NODE_UPDATE_BLOCKED) ]]; then
      printf " ! XinFin has a new node release that this xdc-rpc can't install yet: sudo xdc-rpc → Updates\n"
    else
      printf ' ! New XDC node release from XinFin%s: sudo xdc-rpc → Updates\n' "$( [[ -n $img_new && $img_new != "$img_now" ]] && echo " (${img_new##*:})")"
    fi
  fi
  [[ $(state_get SETUP_DONE) == yes ]] || printf " ! Setup hasn't finished: sudo xdc-rpc\n"
  reboot_needed && printf ' ! Some updates need a server restart: sudo xdc-rpc → Updates\n'
  if [[ -s $STATE_DIR/notices ]]; then
    while IFS= read -r line; do printf ' • %s\n' "$line"; done < <(tail -n 3 "$STATE_DIR/notices")
  fi
  printf '\n'
}

# =============================================================================
#  Setup wizard: a few questions (nothing changes until you confirm), then the
#  SSH steps that need you, then the rest runs as a background task.
# =============================================================================
declare -gA WIZ=()

# ── Taking over an installation made by the previous installer (v1) ─────────
v1_present() {
  [[ ! -f $CONF_FILE && -f $NGINX_SITE ]] && grep -q 'location = /xdcrpc' "$NGINX_SITE" 2>/dev/null \
    && ! grep -q 'Managed by xdc-rpc' "$NGINX_SITE" 2>/dev/null
}

_v1_allows() {   # _v1_allows /xdcrpc -> "ADDRESS|LABEL" lines
  awk -v loc="$1" '
    index($0, "location = " loc " ") || index($0, "location = " loc "{") { inb = 1; next }
    inb && /deny all;/ { inb = 0 }
    inb && $1 == "allow" {
      ip = $2; sub(/;.*$/, "", ip); lab = ""
      p = index($0, "#"); if (p) { lab = substr($0, p + 1); gsub(/^ +| +$/, "", lab) }
      print ip "|" lab
    }' "$NGINX_SITE"
}

v1_import() {
  local d net="" base="" env c u ip lab scope cf=0 skipped="" p e api keep
  d=$(awk '/listen 443/ {s = 1} s && $1 == "server_name" {gsub(/;/, "", $2); print $2; exit}' "$NGINX_SITE")
  [[ -z $d ]] && d=$(awk '$1 == "server_name" {gsub(/;/, "", $2); print $2; exit}' "$NGINX_SITE")
  for c in mainnet testnet; do
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "xdcnetwork-$c-node" && { net=$c; break; }
  done
  if [[ -n $net ]]; then
    base=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/work/xdcchain"}}{{.Source}}{{end}}{{end}}' "xdcnetwork-$net-node" 2>/dev/null)
    base=${base%/*}; base=${base%/*}
  fi
  if [[ -z $base || ! -d $base/.git ]]; then
    for c in /home/*/XinFin-Node /root/XinFin-Node; do [[ -d $c/.git ]] && { base=$c; break; }; done
  fi
  if [[ -z $net && -n $base ]]; then
    if [[ -d $base/testnet/xdcchain-testnet/XDC/chaindata && ! -d $base/mainnet/xdcchain/XDC/chaindata ]]; then net=testnet; else net=mainnet; fi
  fi
  net=${net:-mainnet}
  u=$(stat -c %U "$base" 2>/dev/null); [[ -z $u || $u == root ]] && u=$(login_user)
  CONF[DOMAIN]=$d; CONF[NETWORK]=$net; CONF[ADMIN_USER]=$u
  # The node's files and chain data stay where they are, whichever admin user is chosen
  [[ -n $base ]] && CONF[NODE_BASE]=$base
  env="${base:-$(user_home "$u")/XinFin-Node}/$net/.env"
  CONF[NODE_TYPE]=$(_env_get "$env" GC_MODE); [[ ${CONF[NODE_TYPE]} == archive ]] || CONF[NODE_TYPE]=full
  CONF[NODE_NAME]=$(_env_get "$env" INSTANCE_NAME); [[ -z ${CONF[NODE_NAME]} ]] && CONF[NODE_NAME]=$(_env_get "$env" NODE_NAME)
  valid_node_name "${CONF[NODE_NAME]}" || CONF[NODE_NAME]=$d
  p=$(_env_get "$env" CONTACT_DETAILS)
  [[ -n $p && $p != YOUR_EMAIL_ADDRESS ]] && CONF[CONTACT]=$(printf '%s' "$p" | tr -cd 'A-Za-z0-9@._+ -' | cut -c1-80)
  e=$(jq -r '.body.contact[0] // empty' "$LE_DIR"/accounts/*/directory/*/regr.json 2>/dev/null | head -n1); e=${e#mailto:}
  valid_email "$e" || e=${CONF[CONTACT]:-}
  valid_email "$e" && CONF[EMAIL]=$e
  keep=""
  for api in $(_env_get "$env" API | tr ',' ' '); do
    case $api in eth|net|web3|XDPoS|debug) [[ ,$keep, == *",$api,"* ]] || keep+="${keep:+,}$api" ;; *) skipped+=" $api" ;; esac
  done
  [[ ,$keep, == *,eth,* ]] || keep="eth${keep:+,$keep}"
  CONF[APIS]=$keep
  p=$(_env_get "$env" RPC_PORT); [[ -n $p ]] && CONF[RPC_PORT]=$p
  p=$(_env_get "$env" WS_PORT);  [[ -n $p ]] && CONF[WS_PORT]=$p
  CONF[P2P_PORT]=$(default_p2p "$net")
  CONF[SNAPSHOT]=none
  CONF[ALLOW_PLUGIN]=no
  # The allowlist, from both locations of the old nginx file
  local -A sc=() lb=()
  while IFS='|' read -r ip lab; do [[ -n $ip ]] && { sc[$ip]=rpc; lb[$ip]=$lab; }; done < <(_v1_allows /xdcrpc)
  while IFS='|' read -r ip lab; do
    [[ -n $ip ]] || continue
    if [[ ${sc[$ip]:-} == rpc ]]; then sc[$ip]=both; else sc[$ip]=wss; lb[$ip]=$lab; fi
  done < <(_v1_allows /xdcwss)
  for ip in "${!sc[@]}"; do
    [[ $ip == 127.0.0.1 ]] && continue
    [[ ${lb[$ip]} == Cloudflare ]] && { cf=$(( cf + 1 )); continue; }
    for p in "${PLUGIN_RPCAAS_IPS[@]}"; do [[ $p == "$ip" ]] && { CONF[ALLOW_PLUGIN]=yes; continue 2; }; done
    [[ ${lb[$ip]} == "Plugin RPCaaS" ]] && { CONF[ALLOW_PLUGIN]=yes; continue; }
    allow_add "$ip" "${sc[$ip]}" "${lb[$ip]}" >/dev/null || skipped+=" $ip"
  done
  WIZ[V1_NOTES]=""
  (( cf )) && WIZ[V1_NOTES]+="• $cf Cloudflare address ranges were dropped: Cloudflare proxying isn't used any more. If your domain's DNS record is proxied (orange cloud), switch it to \"DNS only\"."$'\n'
  [[ -n $skipped ]] && WIZ[V1_NOTES]+="• Not carried over:$skipped"$'\n'
  return 0
}

# ── Restoring from a backup on a new (or rebuilt) server ─────────────────────
restore_upload_help() {
  local ip; ip=$(public_ipv4 2>/dev/null || echo SERVER-IP)
  ui_msg "Copy a backup to this server" "On YOUR COMPUTER, in the folder where the backup file is, run (PowerShell on Windows, Terminal on macOS / Linux):

    scp -P $(ssh_config_ports | head -n1) xdc-rpc-backup_NAME.tar.gz.gpg $(login_user)@$ip:

(Use the real file name. If you log in as root, it lands in /root.)

Then come back here and choose it from the list."
}

restore_pick_and_open() {   # interactive; leaves the backup's settings loaded
  local c f pass b rc
  while true; do
    local -a items=() files=(); local x
    while read -r x; do
      [[ -n $x ]] || continue
      files+=("$x"); items+=("${#files[@]}" "$(backup_file_label "$x")")
    done < <(backup_find_files)
    items+=(path "Type the file's location" help "How to copy a backup to this server")
    c=$(ui_menu "Restore from a backup" "Choose the backup to restore$( (( ${#files[@]} )) || echo ". (None found in /root, /home/* or their XDC-Backups folders yet.)"):" "${items[@]}") || return 1
    case $c in
      help) restore_upload_help; continue ;;
      path) f=$(ui_input "Restore from a backup" "Type the full path of the backup file, for example /root/xdc-rpc-backup_rpc.example.com_20261121-055800.tar.gz.gpg:") || continue ;;
      *) f=${files[c - 1]} ;;
    esac
    [[ -f $f ]] || { ui_msg "Restore from a backup" "There's no file at $f."; continue; }
    pass=$(ui_password "Backup password" "Backup password for $(basename "$f"):") || continue
    ui_info "Restore from a backup" "Opening the backup…"
    b=$(backup_open "$f" "$pass"); rc=$?
    if (( rc == 2 )); then ui_msg "Restore from a backup" "That password didn't open the backup."; continue; fi
    if (( rc != 0 )); then ui_msg "Restore from a backup" "That file couldn't be opened as an xdc-rpc backup."; continue; fi
    if ! ui_yesno "Restore from a backup" "This backup contains:

  Domain:        $(backup_manifest "$b" domain)
  Network:       $(backup_manifest "$b" network) · $(backup_manifest "$b" node_type) node
  Node account:  $(backup_manifest "$b" coinbase)
  Made:          $(backup_manifest "$b" created) on $(backup_manifest "$b" server)

Restore it? Your settings, allowlist, certificate and the node's account and identity come back. You'll review the settings next." yes "Restore" "Back"; then
      rm -rf "$(dirname "$b")"; continue
    fi
    restore_from "$b"; rc=$?
    rm -rf "$(dirname "$b")"
    (( rc == 0 )) || { ui_msg "Restore from a backup" "The backup couldn't be restored."; return 1; }
    WIZ[BACKUP_PASS]=$pass; WIZ[RESTORED_PASS]=$pass
    conf_load; ui_backtitle
    return 0
  done
}

# ── Questions. Each returns 0 = next, 1 = back, 3 = not needed here ─────────
_yn_rc() { case $1 in 0) echo yes ;; 1) echo no ;; *) echo back ;; esac; }

wiz_network() {
  local v; v=$(ui_radio "Network" "Which XDC network should this node join?" "$(conf_get NETWORK mainnet)" \
      mainnet "XDC mainnet (chain id 50)" \
      testnet "Apothem testnet (chain id 51)") || return 1
  if [[ $v != "$(conf_get NETWORK mainnet)" && -f $(node_rt)/release ]]; then
    ui_yesno "Network" "This server's node runs on $(net). Switch it to $v?

When setup runs, the $(net) node is stopped. Its chain data is kept in $(data_dir) (delete that folder later if you need the space). The $v node gets its own chain data." no "Switch to $v" "Keep $(net)" \
      || v=$(conf_get NETWORK mainnet)
  fi
  if [[ $v != "$(conf_get NETWORK mainnet)" ]]; then unset 'CONF[P2P_PORT]' 'CONF[RPC_PORT]' 'CONF[WS_PORT]'; fi
  CONF[NETWORK]=$v
}

wiz_nodetype() {
  local v; v=$(ui_radio "Node type" "full: keeps recent state and answers almost every RPC call. Needs much less disk. (Recommended)

archive: also keeps every historical state, for queries about old blocks and for tracing. Needs several times more disk." \
      "$(conf_get NODE_TYPE full)" full "Full node (recommended)" archive "Archive node") || return 1
  CONF[NODE_TYPE]=$v
}

wiz_domain() {
  local d ip prob warn6
  ip=$(public_ipv4 2>/dev/null)
  while true; do
    d=$(ui_input "Domain" "Your endpoints need their own domain name, such as rpc.yourdomain.com (a subdomain of a domain you own is fine).

1. At your DNS provider, create an A record for that name, pointing to this server's IP address: ${ip:-(unknown)}
2. Type the name in the box below: just the name, without https:// or a /path." "$(conf_get DOMAIN)") || return 1
    d=$(lower "$(trim "$d")"); d=${d#*://}; d=${d%%/*}
    valid_domain "$d" || { ui_msg "Domain" "\"$d\" doesn't look like a domain name."; continue; }
    while true; do
      ui_info "Domain" "Checking $d…"
      prob=$(dns_check "$d")
      [[ -z $prob ]] && break
      ui_yesno "Domain" "$prob

DNS changes can take a few minutes to show. You can carry on: the certificate step waits until it's fixed (run setup again then)." yes "Check again" "Carry on" || break
    done
    warn6=$(dig +short AAAA "$d" 2>/dev/null | head -n1)
    [[ -n $warn6 ]] && ui_msg "Domain" "$d also has an IPv6 (AAAA) record ($warn6). The endpoints work over IPv4 only, so delete the AAAA record at your DNS provider."
    CONF[DOMAIN]=$d; ui_backtitle
    return 0
  done
}

wiz_email() {
  local e
  while true; do
    e=$(ui_input "Email" "Type your email address in the box below. Let's Encrypt uses it only for notices about your certificate (rarely)." "$(conf_get EMAIL)") || return 1
    e=$(trim "$e"); valid_email "$e" && break
    ui_msg "Email" "\"$e\" doesn't look like an email address."
  done
  CONF[EMAIL]=$e
}

wiz_nodename() {
  local n
  while true; do
    n=$(ui_input "Node name" "A name for your node, shown on XinFin's public network stats page. Keep the one in the box below, or type another (letters, digits, dots, - and _ only)." "$(conf_get NODE_NAME "$(conf_get DOMAIN)")") || return 1
    n=$(trim "$n"); valid_node_name "$n" && break
    ui_msg "Node name" "Use 1 to 64 letters, digits, dots, - or _."
  done
  CONF[NODE_NAME]=$n
}

wiz_contact() {
  local c
  c=$(ui_input "Contact on the stats page" "XinFin's public stats page also shows a contact for each node. The box below has your email: keep it, type something else, or clear the box to show no contact." "$(node_contact)") || return 1
  CONF[CONTACT]=$(printf '%s' "$c" | tr -cd 'A-Za-z0-9@._+ -' | cut -c1-80)
}

wiz_p2p() {
  local def p n
  n=$(conf_get NETWORK mainnet); def=$(default_p2p "$n")
  while true; do
    p=$(ui_input "P2P port" "Other XDC nodes connect to yours on this port (TCP and UDP). The usual port for $( [[ $n == testnet ]] && echo Apothem || echo mainnet ) is $def. Keep the number in the box below unless you have a reason to change it.

If your VPS provider has a firewall in its control panel, allow this port there (TCP and UDP)." "$(conf_get P2P_PORT "$def")") || return 1
    p=$(trim "$p")
    if ! valid_port "$p" || (( 10#$p < 1024 )); then ui_msg "P2P port" "Use a port from 1024 to 65535."; continue; fi
    p=$(( 10#$p ))
    if ssh_config_ports | grep -qx "$p" || [[ $p == "${WIZ[SSH_NEW_PORT]:-}" ]]; then ui_msg "P2P port" "That's the SSH port."; continue; fi
    if [[ $p == "$(rpc_port)" || $p == "$(ws_port)" ]]; then ui_msg "P2P port" "That port is used by the node's RPC."; continue; fi
    CONF[P2P_PORT]=$p; return 0
  done
}

_api_on() { [[ ,$1, == *",$2,"* ]] && echo ON || echo OFF; }

wiz_apis() {
  local cur sel list a
  cur=$(conf_get APIS eth,net,web3)
  sel=$(ui_check "APIs" "Which groups of RPC methods should the endpoints offer? The first three are what wallets, dapps and Plugin need. (Space selects, Enter confirms.)" \
      eth   "Standard calls: balances, blocks, transactions, logs" ON \
      net   "Network info, e.g. net_version" "$(_api_on "$cur" net)" \
      web3  "Client info, e.g. web3_clientVersion" "$(_api_on "$cur" web3)" \
      XDPoS "XDC consensus info: masternodes, epochs" "$(_api_on "$cur" XDPoS)" \
      debug "Tracing (debug_trace...). Heavy: trusted callers only" "$(_api_on "$cur" debug)") || return 1
  list=eth
  for a in net web3 XDPoS debug; do grep -qx "$a" <<<"$sel" && list+=",$a"; done
  if [[ ,$list, == *,debug,* && ,$cur, != *,debug,* ]]; then
    ui_yesno "debug API" "debug lets callers run traces that can keep the server's CPU busy for a long time, and a few debug methods write files inside the node's container.

Only turn it on if every address on your allowlist is fully trusted. Turn it on?" no "Turn it on" "Leave it off" || list=${list/,debug/}
  fi
  CONF[APIS]=$list
}

wiz_plugin() {
  local rc
  ui_yesno "Plugin RPCaaS" "Will this node serve Plugin's RPCaaS (plugin.global)?

If yes, Plugin's gateway is allowed to use your endpoints. Its address is kept up to date by this tool's updates, so you never need to edit it.

If you're not a Plugin RPCaaS operator, choose No." "$( [[ $(conf_get ALLOW_PLUGIN no) == yes ]] && echo yes || echo no )" "Yes, allow Plugin" "No"
  rc=$?
  case $(_yn_rc $rc) in yes) CONF[ALLOW_PLUGIN]=yes ;; no) CONF[ALLOW_PLUGIN]=no ;; *) return 1 ;; esac
}

allow_flow_add() {   # allow_flow_add [apply]
  local apply="${1:-}" ip scope label norm rc copy
  ip=$(ui_input "Add an address" "Type the IPv4 address to allow in the box below, for example 203.0.113.7.
(A range works too, for example 203.0.113.0/24.)") || return 1
  ip=$(trim "$ip")
  scope=$(ui_radio "Add an address" "What may $ip use?" both both "RPC and WSS" rpc "RPC (https) only" wss "WSS (websocket) only") || return 1
  label=$(ui_input "Add an address" "Type a label to recognise it by, such as Home, Office or Monitoring:") || return 1
  copy=$(allow_copy)
  norm=$(allow_add "$ip" "$scope" "$label"); rc=$?
  case $rc in
    0) ;;
    3) ui_msg "Add an address" "IPv6 addresses aren't supported. Use the IPv4 address." ;;
    4) ui_msg "Add an address" "That range is far too large. Use /8 or narrower (a single address is best)." ;;
    6) ui_msg "Add an address" "That's Plugin's gateway address, which is managed for you. Use the Plugin RPCaaS option instead." ;;
    *) ui_msg "Add an address" "\"$ip\" isn't a valid IPv4 address." ;;
  esac
  (( rc == 0 )) || { rm -f "$copy"; return 1; }
  [[ -n $apply ]] || { rm -f "$copy"; return 0; }
  if with_lock allow_apply_or_undo "$copy"; then
    ui_msg "Add an address" "$norm can now use the endpoints."
    return 0
  fi
  allow_copy_restore "$copy"   # (only still there if the change never ran)
  ui_msg "Add an address" "The change couldn't be applied, so $norm wasn't added. Details: $LOG_DIR/menu.log"
  return 1
}

allow_flow_remove() {   # allow_flow_remove [apply]
  local apply="${1:-}" c ip scope label copy
  local -a items=()
  while IFS='|' read -r ip scope label; do
    [[ -n $ip ]] || continue
    case $scope in both) scope="RPC + WSS" ;; rpc) scope="RPC only" ;; wss) scope="WSS only" ;; esac
    items+=("$ip" "$(printf '%-18s  %s (%s)' "$ip" "$label" "$scope")")
  done < <(allow_user_entries)
  (( ${#items[@]} )) || { ui_msg "Remove an address" "There are no addresses of your own to remove."; return 1; }
  c=$(ui_menu "Remove an address" "Which address should lose access?" "${items[@]}") || return 1
  copy=$(allow_copy)
  allow_remove "$c" || { rm -f "$copy"; return 1; }
  [[ -n $apply ]] || { rm -f "$copy"; return 0; }
  if with_lock allow_apply_or_undo "$copy"; then
    ui_msg "Remove an address" "$c can no longer use the endpoints."
    return 0
  fi
  allow_copy_restore "$copy"
  ui_msg "Remove an address" "The change couldn't be applied, so $c still has access. Details: $LOG_DIR/menu.log"
  return 1
}

wiz_allowlist() {
  local my c
  my=$(session_ip)
  if [[ -n $my && ${WIZ[ASKED_MYIP]:-} != yes ]] && ! allow_user_entries | grep -q "^${my//./\\.}|"; then
    WIZ[ASKED_MYIP]=yes
    if [[ $my == *:* ]]; then
      ui_msg "Your addresses" "You're connected over IPv6 ($my). The endpoints work over IPv4 only, so add your computer's IPv4 address on the next screen if you want to test from it."
    elif ui_yesno "Your addresses" "Only addresses on your allowlist can use the endpoints.

You're connected from $my. Add it, so you can test the endpoints from this computer?

(Home internet addresses can change; you can update the list any time.)" yes "Add it" "Don't add"; then
      allow_add "$my" both "My computer (added at setup)" >/dev/null
    fi
  fi
  local max
  while true; do
    max=0; if ui_boxes; then _ui_dims; max=$(( UI_H - UI_X_MENU - 5 )); (( max < 3 )) && max=3; fi   # (room for the list and 3 choices)
    c=$(ui_menu "Your addresses" "These addresses can use your endpoints:
$(allow_describe "$max")" "done" "Done: continue" add "Add an address" remove "Remove an address") || return 1
    case $c in add) allow_flow_add ;; remove) allow_flow_remove ;; done) return 0 ;; esac
  done
}

wiz_admin() {
  local me u name rc
  me=$(login_user); u=$(conf_get ADMIN_USER)
  [[ -z $u && $me != root ]] && user_is_sudoer "$me" && u=$me
  if [[ -n $u && $u != root ]] && user_exists "$u"; then
    ui_yesno "Admin user" "You'll manage the node as the user $u (log in as $u and use sudo).

Use $u?" yes "Use $u" "Choose another"; rc=$?
    case $(_yn_rc $rc) in
      yes) CONF[ADMIN_USER]=$u; WIZ[ADMIN_CREATE]=no; WIZ[ADMIN_SETPASS]=no; return 0 ;;
      back) return 1 ;;
    esac
  fi
  while true; do
    [[ $u == root ]] && u=""
    name=$(ui_input "Admin user" "Day to day you log in as a normal user and use sudo, rather than as root. Keep the username in the box below, or type another (lowercase letters and digits):" "${u:-xdcadmin}") || return 1
    name=$(lower "$(trim "$name")")
    valid_username "$name" && break
    ui_msg "Admin user" "Use lowercase letters, digits, - or _, starting with a letter (and not root)."
  done
  CONF[ADMIN_USER]=$name
  if user_exists "$name"; then
    WIZ[ADMIN_CREATE]=no
    ui_yesno "Admin user" "$name already exists. Set a new password for $name now?" no "Set a new password" "Keep its password"; rc=$?
    case $(_yn_rc $rc) in yes) WIZ[ADMIN_SETPASS]=yes ;; no) WIZ[ADMIN_SETPASS]=no ;; *) return 1 ;; esac
  else
    WIZ[ADMIN_CREATE]=yes; WIZ[ADMIN_SETPASS]=yes
  fi
}

wiz_ssh_port() {
  local cur p prob rc
  cur=$(ssh_config_ports | paste -sd, -)
  ui_yesno "SSH port" "SSH listens on port ${cur:-22}. Every server gets constant automated login attempts there; moving SSH to another port cuts most of that noise. (fail2ban blocks repeat offenders either way.)

Change the SSH port? You'll test the new port from a second window before the old one closes." "$( [[ -n ${WIZ[SSH_NEW_PORT]:-} ]] && echo yes || echo no )" "Change it" "Keep ${cur:-22}"
  rc=$?
  case $(_yn_rc $rc) in no) WIZ[SSH_NEW_PORT]=""; return 0 ;; back) return 1 ;; esac
  while true; do
    p=$(ui_input "SSH port" "The new SSH port (1024 to 65535). The box below has a free one picked at random; keep it or type another.

If your VPS provider has a firewall in its control panel, allow this port there before continuing." "${WIZ[SSH_NEW_PORT]:-$(_random_free_port)}") || return 1
    p=$(trim "$p")
    [[ $p == "$cur" ]] && { WIZ[SSH_NEW_PORT]=""; return 0; }
    prob=$(port_problem "$p"); [[ -z $prob ]] && break
    ui_msg "SSH port" "$prob"
  done
  WIZ[SSH_NEW_PORT]=$(( 10#$p ))
}

wiz_root_login() {
  local rc a; a=$(conf_get ADMIN_USER)
  if [[ $(ssh_root_login_state) == off ]]; then WIZ[ROOT_OFF]=no; CONF[SSH_ROOT_LOGIN]=no; return 3; fi
  ui_yesno "Root login" "Turn off logging in as root over SSH? (Recommended)

You'll log in as $a and use sudo. It's only switched off after you've shown that logging in as $a works." "$( [[ ${WIZ[ROOT_OFF]:-yes} == yes ]] && echo yes || echo no )" "Turn it off" "Leave it on"
  rc=$?
  case $(_yn_rc $rc) in yes) WIZ[ROOT_OFF]=yes ;; no) WIZ[ROOT_OFF]=no ;; *) return 1 ;; esac
}

wiz_docker_group() {
  local a rc; a=$(conf_get ADMIN_USER)
  docker_group_members | grep -qx "$a" || { WIZ[DOCKER_REMOVE]=no; return 3; }
  ui_yesno "Docker group" "$a is in the docker group. Members can control Docker, which gives them full root access without a password.

Remove $a from the docker group? (Recommended: use sudo for Docker commands instead.)" yes "Remove" "Keep"
  rc=$?
  case $(_yn_rc $rc) in yes) WIZ[DOCKER_REMOVE]=yes ;; no) WIZ[DOCKER_REMOVE]=no ;; *) return 1 ;; esac
}

wiz_snapshot() {   # wiz_snapshot [menu]: from the menu it also asks when chain data is already here
  local size free v def note="" sizes
  if [[ -d $(xdc_dir)/chaindata ]]; then
    [[ ${1:-} == menu ]] || { CONF[SNAPSHOT]=none; return 3; }
    def=$(conf_get SNAPSHOT download); [[ $def == none ]] && def=download
    v=$(ui_radio "Chain snapshot" "This node already has its chain data. This method is used if you replace it with a fresh snapshot (Node → Replace the chain data)." "$def" \
        download "Download, then unpack: resumes if interrupted (recommended)" \
        stream   "Unpack while downloading: less disk, but restarts if interrupted") || return 1
    CONF[SNAPSHOT]=$v; return 0
  fi
  ui_info "Chain snapshot" "Checking the snapshot size…"
  size=$(snapshot_size "$(snapshot_url)"); free=$(disk_free_bytes "$(node_base)")
  def=$(conf_get SNAPSHOT download)
  if [[ $size =~ ^[0-9]+$ ]] && (( size > 0 )) && (( ${free:-0} < size * 3 / 2 + 100 * 1024**3 )); then
    note="

This server doesn't have enough free disk for the snapshot, or for the chain as it grows. Add disk space (or choose a bigger server) first."
  fi
  sizes="Snapshot size: $( [[ $size =~ ^[0-9]+$ ]] && human "$size" || echo unknown) · Free disk: $(human "${free:-0}")"
  while true; do
    v=$(ui_radio "Chain snapshot" "A snapshot is a recent copy of the blockchain. It saves days or weeks of syncing.

$sizes$note" "$def" \
        download "Download, then unpack: resumes if interrupted (recommended)" \
        stream   "Unpack while downloading: less disk, but restarts if interrupted" \
        none     "No snapshot: sync from the network (slowest)") || return 1
    [[ $v != none ]] && break
    _wiz_no_snapshot_ok && break
    def=download
  done
  CONF[SNAPSHOT]=$v
}

_wiz_no_snapshot_ok() {   # 0 = sync from block 0 anyway (only mainnet full nodes are asked)
  early_chain_risk || return 0
  ui_yesno "Sync from block 0?" "Without a snapshot, the node replays the whole chain from block 0. On mainnet that takes weeks.

While it replays the chain's early years (up to block $(fmt_num "$EARLY_CHAIN_END")), a restart can leave it stuck at a checkpoint, because of a bug in XDC. The fix is then to replace the chain data from the Node menu.

A snapshot starts after those years, so it avoids this." no "Sync from block 0" "Choose a snapshot"
}

wiz_backup_pass() {
  local p p2 prob rc
  if [[ -n ${WIZ[RESTORED_PASS]:-} ]]; then
    ui_yesno "Backup password" "Backups are encrypted with a password. Keep using the password of the backup you restored?" yes "Keep it" "Choose a new one"
    rc=$?; case $(_yn_rc $rc) in yes) WIZ[BACKUP_PASS]=${WIZ[RESTORED_PASS]}; return 0 ;; back) return 1 ;; esac
  elif [[ -s $BACKUP_PASS_FILE ]]; then
    WIZ[BACKUP_PASS]=$(backup_pass); return 3
  fi
  ui_yesno "Backup password" "Backups of your settings and the node's keys are encrypted with a password of their own. It's separate from your login password, and you'll need it to restore a backup, on this server or a new one.

Generate a strong one? (Recommended. You'll see it at the end of setup.)" yes "Generate" "Choose my own"
  rc=$?
  case $(_yn_rc $rc) in
    yes) WIZ[BACKUP_PASS]=$(gen_password); return 0 ;;
    back) return 1 ;;
  esac
  while true; do
    p=$(ui_password "Backup password" "Choose the backup password (at least 12 characters):") || return 1
    prob=$(password_problem "$p" ""); [[ -n $prob ]] && { ui_msg "Backup password" "$prob"; continue; }
    p2=$(ui_password "Backup password" "Type it again:") || return 1
    [[ $p == "$p2" ]] && break
    ui_msg "Backup password" "The two didn't match."
  done
  WIZ[BACKUP_PASS]=$p
}

wiz_auto_update() {
  local rc
  ui_yesno "Updates to this tool" "New versions of this tool are checked daily and you're told about them when you log in.

Install them automatically too? (Updates never touch your node's data.)" "$( [[ $(conf_get AUTO_UPDATE no) == yes ]] && echo yes || echo no )" "Yes, automatically" "No, I'll update myself"
  rc=$?
  case $(_yn_rc $rc) in yes) CONF[AUTO_UPDATE]=yes ;; no) CONF[AUTO_UPDATE]=no ;; *) return 1 ;; esac
}

wiz_summary() {
  local d ssh_line admin_line snap plugin n
  d=$(conf_get DOMAIN); n=$(allow_user_entries | wc -l | tr -d ' ')
  plugin=""; [[ $(conf_get ALLOW_PLUGIN) == yes ]] && plugin=" + Plugin RPCaaS gateway"
  admin_line=$(conf_get ADMIN_USER); [[ ${WIZ[ADMIN_CREATE]:-} == yes ]] && admin_line+=" (new: you'll get its password next)"
  ssh_line="port $(ssh_config_ports | paste -sd, -)"
  [[ -n ${WIZ[SSH_NEW_PORT]:-} ]] && ssh_line+=" → ${WIZ[SSH_NEW_PORT]} (tested before switching)"
  [[ ${WIZ[ROOT_OFF]:-} == yes ]] && ssh_line+="; root login off"
  case $(conf_get SNAPSHOT none) in download) snap="download, then unpack" ;; stream) snap="unpack while downloading" ;; *) snap="none" ;; esac
  [[ -d $(xdc_dir)/chaindata ]] && snap="not needed (chain data already here)"
  ui_yesno "Ready to set up" "Network:     $( [[ $(net) == testnet ]] && echo 'Apothem testnet' || echo 'XDC mainnet' ) · $(conf_get NODE_TYPE full) node
RPC:         https://$d/xdcrpc
WSS:         wss://$d/xdcwss
APIs:        $(conf_get APIS | sed 's/,/, /g')
Allowed:     $n address(es)$plugin
P2P port:    $(conf_get P2P_PORT) (TCP + UDP)
Snapshot:    $snap
Admin user:  $admin_line
SSH:         $ssh_line
Backups:     encrypted, in ~$(conf_get ADMIN_USER)/XDC-Backups
Updates:     $( [[ $(conf_get AUTO_UPDATE no) == yes ]] && echo 'this tool updates itself' || echo 'you choose (notice at login)' )

Nothing has been changed yet. Start?" yes "Start" "Back"
  case $(_yn_rc $?) in yes) return 0 ;; *) return 1 ;; esac
}

wizard_questions() {
  local -a qs=(wiz_network wiz_nodetype wiz_domain wiz_email wiz_nodename wiz_contact wiz_p2p wiz_apis
               wiz_plugin wiz_allowlist wiz_admin wiz_ssh_port wiz_root_login wiz_docker_group
               wiz_snapshot wiz_backup_pass wiz_auto_update wiz_summary)
  local i=0 dir=1 rc
  while (( i < ${#qs[@]} )); do
    if (( i < 0 )); then
      ui_yesno "Setup" "Leave setup? Nothing has been changed on the server." no "Leave" "Stay" && return 1
      i=0; dir=1; continue
    fi
    "${qs[$i]}"; rc=$?
    case $rc in
      0) dir=1; i=$(( i + 1 )) ;;
      3) i=$(( i + dir )) ;;
      *) dir=-1; i=$(( i - 1 )) ;;
    esac
  done
  return 0
}

# ── Doing it ─────────────────────────────────────────────────────────────────
wizard_apply() {
  local admin port
  admin=$(conf_get ADMIN_USER)
  CONF[SSH_ROOT_LOGIN]=${CONF[SSH_ROOT_LOGIN]:-default}
  CONF[SSH_PASSWORDS]=${CONF[SSH_PASSWORDS]:-default}
  conf_save
  state_set SETUP_DONE no
  ui_backtitle

  # 1. Admin user
  if [[ ${WIZ[ADMIN_CREATE]:-no} == yes ]]; then
    admin_create "$admin" || { ui_msg "Admin user" "The user $admin couldn't be created."; return 1; }
    admin_password_flow "$admin" || return 1
  elif [[ ${WIZ[ADMIN_SETPASS]:-no} == yes ]]; then
    admin_password_flow "$admin" || return 1
  fi
  restore_apply_keys

  # 2. SSH changes that need a test login
  port=$(ssh_config_ports | head -n1)
  if [[ -n ${WIZ[SSH_NEW_PORT]:-} ]]; then
    if ! ssh_change_port_tested "$admin" "${WIZ[SSH_NEW_PORT]}" "$( [[ ${WIZ[ROOT_OFF]:-} == yes ]] && echo rootoff )"; then
      ui_msg "SSH" "The SSH port wasn't changed$( [[ ${WIZ[ROOT_OFF]:-} == yes ]] && echo ' and root login was left on' ). You can do this later from: sudo xdc-rpc → Security.

Setup carries on now."
    fi
  elif [[ ${WIZ[ROOT_OFF]:-} == yes ]]; then
    if [[ $(login_user) == "$admin" && -n $(session_port) ]] \
       || ssh_prove_login "$admin" "$port" "" "" "Check you can log in as $admin" "$(ssh_admin_test_text "$admin" "$port")" "$(ssh_admin_test_question "$admin")"; then
      ssh_apply_root_off
    else
      ui_msg "Root login" "Root login was left on. You can turn it off later from: sudo xdc-rpc → Security.

Setup carries on now."
    fi
  fi

  # 3. Docker group
  [[ ${WIZ[DOCKER_REMOVE]:-no} == yes ]] && gpasswd -d "$admin" docker >/dev/null 2>&1

  # 4. Backup password
  if [[ -n ${WIZ[BACKUP_PASS]:-} ]]; then backup_pass_set "${WIZ[BACKUP_PASS]}"; else backup_pass_ensure; fi

  setup_run
}

setup_run() {   # start (or continue) setup in the background and follow it
  local rc
  ui_clear
  state_set SETUP_SCREEN_DUE yes   # cleared once the summary has been shown
  job_start setup "Setting up your XDC node"; rc=$?
  [[ -n $JOB_LAST_ID ]] && state_set LAST_SETUP_JOB "$JOB_LAST_ID"
  case $rc in
    0) pause_key "  Press any key to see your endpoints..."; setup_done_screen ;;
    2) ui_msg "Setup" "Setup carries on in the background, even if you disconnect.

To follow it again later, run: sudo xdc-rpc" ;;
    *) pause_key "  Press any key to go to the menu..." ;;
  esac
  return "$rc"
}

setup_done_screen() {
  local d admin port b login progress
  d=$(conf_get DOMAIN); admin=$(conf_get ADMIN_USER root); port=$(ssh_config_ports | head -n1)
  b=$(node_block)
  progress="The node keeps catching up with the network"
  [[ -n $b ]] && progress="The node is at block $(fmt_num "$b") and keeps catching up with the network"
  if [[ $(ssh_effective passwordauthentication) == no ]]; then login="with your SSH key"
  else login="with $admin's own login password (or SSH key)"; fi
  ui_msg "Setup is finished" "SAVE THIS NOW: your backup password

    $(backup_pass)

It unlocks your backups: without it, a backup can't be restored. It isn't a login password. (Backups → Show the backup password shows it again.)

Your endpoints, for the addresses on your allowlist:
  RPC:  https://$d/xdcrpc
  WSS:  wss://$d/xdcwss

$progress; Status & logs shows its progress. Test commands: Allowlist → How to test the endpoints (they're also printed in your terminal when you leave the menu).

To log in to this server:  $(ssh_cmd_hint "$admin" "$port")
$login, not the backup password.

Manage everything with:  sudo xdc-rpc
Shortcuts to all its files:  $(files_links_dir)"
  state_set SETUP_SCREEN_DUE ""
}

wizard_main() {
  local c
  WIZ=()
  if v1_present; then
    ui_msg "Previous installation found" "This server was set up with the previous version of this installer. Your node, chain data, domain, certificate and allowlist are kept and taken over.

You'll review the settings that were found. The node keeps running until near the end, when it's restarted with the new setup."
    v1_import
    [[ -n ${WIZ[V1_NOTES]} ]] && ui_msg "Previous installation found" "${WIZ[V1_NOTES]}"
  elif ! configured; then
    c=$(ui_menu "XDC Secure RPC & WSS" "Sets up an XDC node with private RPC (HTTPS) and WSS endpoints for the addresses you choose. Nothing changes until you confirm.

You'll need:
  • a domain name with an A record pointing to this server
  • if your VPS provider has a firewall, open there: 443 TCP, 80 TCP (certificate renewals), 30303 TCP+UDP (P2P) and your SSH port
  • well over 1 TB of disk for a full node

Keys: ↑↓ choose (or scroll a long page), Enter presses the highlighted button, Tab or ←→ picks another button, Esc goes back." \
        new "Set up a new node" \
        restore "Restore from a backup (new or rebuilt server)") || return 1
    if [[ $c == restore ]]; then restore_pick_and_open || return 1; fi
  fi
  wizard_questions || { ui_msg "Setup" "Setup was cancelled. Nothing was changed on the server."; return 1; }
  wizard_apply
}

# =============================================================================
#  SSH changes, step by step, with a safety net
#  Every change is proven with a real login from a second window. If that
#  doesn't happen, the change is undone; if this window disconnects, a timer
#  undoes it after UNDO_MINUTES anyway.
# =============================================================================
ssh_normalize_ports() {   # move the SSH port setting into our drop-in (no change in behaviour)
  local before after
  before=$(ssh_config_ports | paste -sd' ' -)
  [[ -n $before ]] || { err "Couldn't read the SSH settings (sshd -T failed)."; return 1; }
  local -a ports; read -ra ports <<<"$before"
  ssh_takeover_ports
  ssh_write_ports "${ports[@]}"
  after=$(ssh_config_ports | paste -sd' ' -)
  if [[ $after != "$before" ]]; then
    err "This server's SSH configuration doesn't read /etc/ssh/sshd_config.d/ (the Include line is missing), so its SSH settings can't be managed here."
    return 1
  fi
}

_random_free_port() {
  local p i
  for i in $(seq 1 50); do
    p=$(shuf -i 20000-60999 -n 1)
    [[ -z $(port_problem "$p") ]] && { printf '%s' "$p"; return 0; }
  done
  printf '2222'
}

port_problem() {   # reason why PORT can't be the SSH port (empty if it can)
  local p="$1"
  valid_port "$p" || { echo "That isn't a port number (1 to 65535)."; return; }
  p=$((10#$p))
  if (( p < 1024 && p != 22 )); then echo "Use 22, or a port from 1024 to 65535."; return; fi
  case $p in 80|443) echo "Port $p is needed by the web server."; return ;; esac
  [[ $p == "$(conf_get P2P_PORT "$(default_p2p "$(net)")")" ]] && { echo "Port $p is the node's P2P port."; return; }
  [[ $p == "$(rpc_port)" || $p == "$(ws_port)" ]] && { echo "Port $p is used by the node."; return; }
  if ssh_listening "$p" && ! ssh_config_ports | grep -qx "$p"; then echo "Something else is already using port $p."; return; fi
}

ssh_admin_test_text() {   # ssh_admin_test_text USER PORT (the steps, for ssh_prove_login)
  cat <<EOF
 1. On your computer, open a NEW terminal window
    (keep this one open) and log in as $1:

        $(ssh_cmd_hint "$1" "$2")

 2. In the new window, type  sudo -v
    and enter $1's password.
    That checks $1 can run admin commands.
EOF
}
ssh_admin_test_question() {   # what to ask once the login has been seen
  printf "Did sudo -v accept %s's password? (When it works, it prints nothing and you're back at the prompt.)" "$1"
}

# ssh_prove_login USER PORT METHOD FINGERPRINT TITLE STEPS [QUESTION] -> 0 when confirmed
# STEPS are numbered " 1. ..." (anything before step 1 is shown first). Logins
# made while the steps are on screen count, so people can follow them top to
# bottom and press OK at the end, or press OK first and then log in.
ssh_prove_login() {
  local user="$1" port="$2" method="$3" fp="$4" title="$5" todo="$6"
  local question="${7:-Did it work: is the new window at a command prompt?}"
  local since off n last ip rc
  since=$(( $(now) - 2 )); off=$(auth_log_mark)
  n=$(grep -cE '^ *[0-9]+\. ' <<<"$todo"); last=" $(( n + 1 )). "; (( n )) || last=""
  ui_msg "$title" "$(_ssh_steps_screen "$todo")

${last}Stay logged in there, come back to this window and press OK.

(If you press OK before logging in, this window waits up to 9 minutes for the login.)"
  if ! ip=$(ssh_login_seen "$user" "$port" "$fp" "$method" "$since" "$off"); then
    if ui_boxes; then ui_clear; ui_plain_top; fi
    printf '\n  %s\n\n%s\n\n%s\n\n' "${C_BLD}$title${C_OFF}" "$(sed 's/^/  /' <<<"$todo")" \
      "  ${last}Stay logged in there. This window carries on once it sees the login."
    ip=$(ssh_wait_login "$user" "$port" "$fp" "$method" 540 "$since" "$off"); rc=$?
    case $rc in
      0) ;;
      2) return 1 ;;
      *) ui_msg "$title" "No login was seen within 9 minutes."; return 1 ;;
    esac
  fi
  ui_yesno "$title" "A login as $user from $ip was seen.

$question" yes "Yes, it works" "No"
}
_ssh_steps_screen() {   # the steps, with "Do this now" just before step 1
  local line seen="" out=""
  while IFS= read -r line; do
    if [[ -z $seen && $line =~ ^\ *1\.\  ]]; then out+="Do this now, while this message is showing:"$'\n\n'; seen=1; fi
    out+="$line"$'\n'
  done <<<"$1"
  [[ -n $seen ]] || out="Do this now, while this message is showing:"$'\n\n'"$out"
  printf '%s' "${out%$'\n'}"
}

ssh_apply_root_off() {
  CONF[SSH_ROOT_LOGIN]=no; conf_save; ssh_write_auth
  ssh_restart || return 1
  [[ $(ssh_effective permitrootlogin) == no ]] || { err "Root login couldn't be turned off (another SSH setting overrides it)."; return 1; }
  ok "Root login over SSH is off"
}

ssh_root_login_state() {   # on / off / keys-only
  case "$(ssh_effective permitrootlogin)" in
    no) echo off ;; yes) echo on ;; *) echo keys-only ;;
  esac
}

# Change the SSH port: both ports work while you test the new one
ssh_change_port_tested() {   # ssh_change_port_tested USER NEWPORT [rootoff]
  local admin="$1" new="$2" rootoff="${3:-}" id
  local -a old; read -ra old <<<"$(ssh_config_ports | paste -sd' ' -)"
  ssh_normalize_ports || return 1
  id=$(undo_prepare)
  ssh_write_ports "${old[@]}" "$new"
  if ! ssh_restart || ! ssh_wait_listening "$new"; then
    undo_run "$id" quiet; ui_msg "SSH port" "SSH didn't start listening on port $new, so nothing was changed."; return 1
  fi
  ufw_sync >/dev/null 2>&1; f2b_apply >/dev/null 2>&1
  undo_schedule "$id" "SSH port change to $new"
  if ssh_prove_login "$admin" "$new" "" "" "Test the new SSH port" "$(ssh_admin_test_text "$admin" "$new")" "$(ssh_admin_test_question "$admin")"; then
    ssh_write_ports "$new"; ssh_restart; ufw_sync >/dev/null 2>&1; f2b_apply >/dev/null 2>&1
    [[ -n $rootoff ]] && ssh_apply_root_off
    undo_cancel "$id"
    ok "SSH now uses port $new"
    return 0
  fi
  undo_run "$id" quiet
  return 1
}

ssh_flow_port() {
  local admin cur new prob
  admin=$(conf_get ADMIN_USER "$(login_user)")
  cur=$(ssh_config_ports | paste -sd, -)
  [[ -n $cur ]] || { ui_msg "SSH port" "Couldn't read the SSH settings, so nothing was changed."; return 1; }
  while true; do
    new=$(ui_input "SSH port" "SSH listens on port $cur.

The box below has a free port picked at random (1024 to 65535); keep it or type another. If your VPS provider has a firewall in its control panel, allow the new port there FIRST.

You'll test the new port from a second window before the old one closes." "$(_random_free_port)") || return 1
    new=$(trim "$new")
    [[ $new == "$cur" ]] && { ui_msg "SSH port" "SSH already uses port $new."; return 0; }
    prob=$(port_problem "$new"); [[ -z $prob ]] && break
    ui_msg "SSH port" "$prob"
  done
  if ssh_change_port_tested "$admin" "$new"; then
    ui_msg "SSH port" "Done. From now on connect with:

    $(ssh_cmd_hint "$admin" "$new")"
    backup_create quiet >/dev/null 2>&1
  else
    ui_msg "SSH port" "Nothing was changed: SSH still uses port $cur."
  fi
}

ssh_flow_root_off() {
  local admin port; admin=$(conf_get ADMIN_USER); port=$(ssh_config_ports | head -n1)
  if [[ -z $admin || $admin == root ]] || ! user_exists "$admin"; then
    ui_msg "Root login" "Create an admin user first (Security → Admin user)."; return 1
  fi
  ui_yesno "Root login" "Turn off logging in as root over SSH?

You'll log in as $admin and use sudo for admin work. Attackers constantly try to log in as root, so this blocks most of them." yes "Turn it off" "Cancel" || return 1
  if [[ $(login_user) != "$admin" || -z $(session_port) ]]; then
    ssh_prove_login "$admin" "$port" "" "" "Check you can log in as $admin" "$(ssh_admin_test_text "$admin" "$port")" "$(ssh_admin_test_question "$admin")" \
      || { ui_msg "Root login" "Root login was left on."; return 1; }
  fi
  if ssh_apply_root_off; then ui_msg "Root login" "Done. Log in as $admin from now on."; backup_create quiet >/dev/null 2>&1
  else ui_msg "Root login" "Root login couldn't be turned off. Details: $LOG_DIR/menu.log"; fi
}

ssh_flow_root_on() {
  ui_yesno "Root login" "Allow root to log in over SSH again (as this server had it before)?" no "Allow it" "Cancel" || return 1
  CONF[SSH_ROOT_LOGIN]=default; conf_save; ssh_write_auth; ssh_restart
  ui_msg "Root login" "Root login is back to this server's original setting."
}

ssh_passwords_on() {   # recovery: turn SSH password logins back on (no questions)
  CONF[SSH_PASSWORDS]=yes; conf_save; ssh_write_auth
  if ssh_restart; then ok "SSH password logins are on again."; else err "SSH didn't restart; check: sudo sshd -t"; return 1; fi
}

# The Security menu's "Password logins" item: back on in one step; off only
# through the guided key steps (they test a key first).
ssh_flow_passwords() {
  local admin; admin=$(conf_get ADMIN_USER root)
  if [[ $(ssh_effective passwordauthentication) == no ]]; then
    ui_yesno "Password logins" "Password logins over SSH are off: only SSH keys can log in.

Turn them back on? Then $admin can log in over SSH with their password again. SSH keys keep working, and addresses that keep failing to log in are still blocked." no "Turn them on" "Cancel" || return 0
    if with_lock ssh_passwords_on >/dev/null 2>&1; then
      backup_create quiet >/dev/null 2>&1
      ui_msg "Password logins" "Password logins over SSH are on again."
    else
      ui_msg "Password logins" "SSH didn't restart, so nothing changed. Details: $LOG_DIR/menu.log"
    fi
  else
    ui_yesno "Password logins" "Password logins over SSH are on.

Turning them off needs an SSH key that works. The guided steps set one up and test it first, and put password logins back on by themselves if the test doesn't finish." yes "Continue" "Cancel" && ssh_flow_keys
  fi
}

# Guided switch to SSH keys (optional)
ssh_flow_keys() {
  local admin port key kinfo rc fp id
  admin=$(conf_get ADMIN_USER); port=$(ssh_config_ports | head -n1)
  [[ -n $admin && $admin != root ]] && user_exists "$admin" || { ui_msg "SSH keys" "Create an admin user first (Security → Admin user)."; return 1; }
  ui_yesno "SSH keys" "Logging in with an SSH key instead of a password is safer: there's no password for anyone to guess.

The catch: the key is a file on your computer. Lose it and you can't log in over SSH. (You could still log in through your VPS provider's web console with $admin's password, run sudo xdc-rpc and choose Security → Password logins.)

This guide takes about 5 minutes:
  1. make a key on your computer
  2. add it to this server
  3. test it
  4. back it up
  5. turn password logins off (tested, with automatic undo)" no "Continue" "Cancel" || return 1

  ui_msg "Step 1 of 5: make a key" "On YOUR COMPUTER (not this server), open PowerShell (Windows) or Terminal (macOS / Linux) and run:

    ssh-keygen -t ed25519 -C xdc-node

Press Enter to accept the suggested file name. When asked for a passphrase, choose one: it protects the key if someone copies the file.

If it says the file already exists, you already have a key: answer n and use that one."

  ui_msg "Step 2 of 5: copy the PUBLIC key" "Still on your computer, show your public key:

    Windows:       type \$env:USERPROFILE\\.ssh\\id_ed25519.pub
    macOS / Linux: cat ~/.ssh/id_ed25519.pub

Copy the one line it prints (it starts with ssh-ed25519). That's the public half of the key and is safe to share.

Never copy the file without .pub at the end: that's your private key."
  while true; do
    key=$(ui_input "Step 2 of 5: paste the public key" "Paste the line that starts with ssh-ed25519:") || return 1
    kinfo=$(pubkey_check "$key"); rc=$?
    (( rc == 0 )) && break
    if (( rc == 2 )); then
      ui_msg "Careful: that's a private key" "That's your PRIVATE key. Don't paste it anywhere: it's what proves who you are. Paste the line from the .pub file instead."
    else
      ui_msg "Not a public key" "That doesn't look like an SSH public key. It's one line starting with ssh-ed25519 (or ssh-rsa / ecdsa-sha2-)."
    fi
  done
  fp=${kinfo##* }
  authkeys_add "$admin" "$(trim "$key")" || { ui_msg "SSH keys" "The key couldn't be added."; return 1; }
  ok "Key $fp added for $admin"

  if ! ssh_prove_login "$admin" "$port" publickey "$fp" "Step 3 of 5: test the key" \
       " 1. On your computer, open a NEW terminal window
    (keep this one open) and run:

        $(ssh_cmd_hint "$admin" "$port")

    It should log you in without asking for $admin's password
    (it may ask for the key's passphrase)."; then
    ui_msg "SSH keys" "The key was added, but the test didn't complete, so password logins stay on. You can run this guide again any time."
    return 1
  fi

  while ! ui_yesno "Step 4 of 5: back up your key" "Copy your PRIVATE key file somewhere safe that isn't this server, such as a USB stick or your password manager. It's on your computer at:

    Windows:       %USERPROFILE%\\.ssh\\id_ed25519
    macOS / Linux: ~/.ssh/id_ed25519

Without it you can't log in over SSH once passwords are off.

Have you saved a copy?" no "Yes, it's saved" "Not yet"; do
    ui_yesno "SSH keys" "Stop here and keep password logins on for now? Your key keeps working either way." no "Stop here" "Back" && return 1
  done

  id=$(undo_prepare)
  CONF[SSH_PASSWORDS]=no; conf_save; ssh_write_auth
  if ! ssh_restart; then undo_run "$id" quiet; ui_msg "SSH keys" "SSH didn't restart, so nothing was changed."; return 1; fi
  undo_schedule "$id" "Turning off SSH password logins"
  if ssh_prove_login "$admin" "$port" publickey "$fp" "Step 5 of 5: final test" \
       "Password logins are now off. They turn back on by themselves in $UNDO_MINUTES minutes unless this test works.

 1. Open ANOTHER new terminal window and log in with your key:

        $(ssh_cmd_hint "$admin" "$port")"; then
    undo_cancel "$id"
    backup_create quiet >/dev/null 2>&1
    ui_msg "SSH keys" "Done. $admin logs in with the key from now on; password logins are off.

If you ever lose the key: log in through your VPS provider's web console (it asks for $admin's password, so keep that safe too), run sudo xdc-rpc and choose Security → Password logins to turn them back on.

(Or, at the console: sudo xdc-rpc ssh passwords-on)"
    return 0
  fi
  undo_run "$id" quiet
  ui_msg "SSH keys" "The final test didn't complete, so password logins were turned back on. Your key works as well."
  return 1
}

ssh_keys_menu() {
  local admin c fp t cm
  admin=$(conf_get ADMIN_USER)
  while true; do
    local -a items=(add "Add a key (guided; can turn password logins off)") fps=() names=()
    while read -r fp t cm; do
      [[ -n $fp ]] || continue
      fps+=("$fp"); names+=("$(key_label "$fp" "$t" "$cm")")
      items+=("${#fps[@]}" "Remove: ${names[-1]}")
    done < <(authkeys_list "$admin")
    c=$(ui_menu "SSH keys for $admin" "Password logins: $( [[ $(conf_get SSH_PASSWORDS) == no ]] && echo off || echo on ). $( (( ${#fps[@]} )) && echo "Keys that can log in as $admin are listed below: choose one to remove it." || echo "No keys can log in as $admin yet.")" "${items[@]}") || return 0
    if [[ $c == add ]]; then ssh_flow_keys; continue; fi
    if [[ $(conf_get SSH_PASSWORDS) == no && $(authkeys_count "$admin") -le 1 ]]; then
      ui_msg "SSH keys" "That's the only key and password logins are off, so removing it would lock you out. Turn password logins on first."
      continue
    fi
    ui_yesno "SSH keys" "Remove this key?

  ${names[c - 1]}

Logins with it stop working." no "Remove" "Cancel" && authkeys_remove "$admin" "${fps[c - 1]}" && backup_create quiet >/dev/null 2>&1
  done
}

# A key, readably: "ED25519 key anon@laptop (SHA256:S5lQvb…KcVbi)"
key_label() {   # key_label FINGERPRINT TYPE COMMENT
  local fp="$1" t="${2//[()]/}" cm; cm=$(trim "$3")
  local h="${fp#SHA256:}"; (( ${#h} > 14 )) && h="${h:0:6}…${h: -5}"
  printf '%s key%s (SHA256:%s)' "${t:-SSH}" "${cm:+ $cm}" "$h"
}

admin_password_flow() {   # admin_password_flow USER -> sets a password (generated or chosen)
  local u="$1" p p2 prob
  if ui_yesno "Password for $u" "Generate a strong password for $u? (Recommended. You'll see it once, so have somewhere ready to save it.)" yes "Generate" "Choose my own"; then
    p=$(gen_password)
  else
    while true; do
      p=$(ui_password "Password for $u" "Choose a password (at least 12 characters):") || return 1
      prob=$(password_problem "$p" "$u"); [[ -n $prob ]] && { ui_msg "Password" "$prob"; continue; }
      p2=$(ui_password "Password for $u" "Type it again:") || return 1
      [[ $p == "$p2" ]] && break
      ui_msg "Password" "The two passwords didn't match."
    done
  fi
  printf '%s:%s\n' "$u" "$p" | chpasswd || return 1
  ui_msg "Save this password now" "Username:  $u
Password:  $p

This is $u's login password. Save it in your password manager now: it's needed to log in and for sudo, and it isn't shown again.

(It isn't the backup password: backups have a separate password of their own.)"
  return 0
}

f2b_menu() {
  local c
  while true; do
    local -a items=(); local ip
    while read -r ip; do [[ -n $ip ]] && items+=("$ip" "Unblock $ip"); done < <(f2b_banned)
    if (( ${#items[@]} == 0 )); then ui_msg "Blocked addresses" "No addresses are blocked right now.

Addresses are blocked for an hour after 5 failed SSH logins, and for longer each time they come back."; return 0; fi
    c=$(ui_menu "Blocked addresses" "Blocked after repeated failed SSH logins. Choose one to unblock it:" "${items[@]}") || return 0
    fail2ban-client set sshd unbanip "$c" >/dev/null 2>&1 && ui_msg "Blocked addresses" "$c is unblocked."
  done
}

docker_group_flow() {
  local u any=""
  for u in $(docker_group_members); do
    any=1
    ui_yesno "Docker group" "$u is in the docker group. Members can control Docker, which gives them full root access without a password.

Remove $u from the docker group? (Use sudo for Docker commands instead.)" yes "Remove" "Keep" \
      && gpasswd -d "$u" docker >/dev/null 2>&1 && ok "$u removed from the docker group"
  done
  [[ -n $any ]] || ui_msg "Docker group" "Nobody is in the docker group. Good: Docker commands need sudo."
}

# =============================================================================
#  Menus
# =============================================================================
node_sync_text() {   # in sync / syncing 42% / looking for peers / starting
  local s cur hi peers
  [[ $(node_state) == running ]] || { echo "not running"; return; }
  s=$(node_syncing)
  [[ -z $s ]] && { echo "starting up"; return; }
  if [[ $s == false ]]; then
    peers=$(node_peers)
    if [[ ${peers:-0} -eq 0 ]]; then echo "looking for peers"; else echo "in sync"; fi
    return
  fi
  cur=$(_hexdec "$(jq -r '.currentBlock // empty' <<<"$s" 2>/dev/null)")
  hi=$(_hexdec "$(jq -r '.highestBlock // empty' <<<"$s" 2>/dev/null)")
  if [[ -n $cur && -n $hi ]] && (( hi > 0 )); then echo "syncing $(( cur * 100 / hi ))%"; else echo "syncing"; fi
}

status_header() {   # a few lines for the top of the main menu
  local st b p line
  st=$(node_state)
  if node_crash_looping; then
    line="Node: keeps crashing and restarting (see Status & logs → Node log)"
  elif [[ $st == running ]]; then
    b=$(node_block); p=$(node_peers)
    line="Node: running · $(node_sync_text)${b:+ · block $(fmt_num "$b")}${p:+ · $p peers}"
  else
    line="Node: $st"
  fi
  printf '%s\nRPC:  https://%s/xdcrpc\nWSS:  wss://%s/xdcwss\nAllowed: %s address(es)%s' \
    "$line" "$(conf_get DOMAIN)" "$(conf_get DOMAIN)" "$(allow_count)" "$( [[ $(conf_get ALLOW_PLUGIN) == yes ]] && echo ', including Plugin RPCaaS')"
}

status_report() {   # the full status, as text
  local d st b nb p days cb img img_new latest f2b bans fw rl pw last lt ports free total
  d=$(conf_get DOMAIN); st=$(node_state)
  b=$(node_block); p=$(node_peers); nb=$(network_block)
  cb=$(node_coinbase); img=$(node_image 2>/dev/null)
  img_new=$(state_get NODE_LATEST_IMAGE); latest=$(state_get TOOL_LATEST)
  days=$(cert_days_left "$d")
  ports=$(ssh_config_ports | paste -sd, -)
  rl=$(ssh_root_login_state); pw=$(ssh_effective passwordauthentication)
  if ufw_active; then fw="on"; else fw="OFF"; fi
  if systemctl is-active --quiet fail2ban; then
    bans=$(f2b_banned | wc -l | tr -d ' '); f2b="on, $bans address(es) blocked"
  else f2b="not running"; fi
  last=$(state_get BACKUP_LAST); lt=$(state_get BACKUP_LAST_TIME)
  free=$(disk_free_bytes "$(net_dir)"); total=$(disk_total_bytes "$(net_dir)")
  local acct="none yet (created when the node first starts)" blk="unknown"
  [[ -n $cb ]] && acct="0x$cb
                  (never send funds to it)"
  if [[ -n $b ]]; then   # "263,465 of 109,576,167" while catching up
    blk=$(fmt_num "$b"); [[ -n $nb ]] && (( nb > b )) && blk+=" of $(fmt_num "$nb")"
  fi
  node_crash_looping && st="keeps crashing and restarting
                  (Status & logs → Node log shows why, near the end)"
  cat <<EOF
NODE
  State:          $st${img:+ ($img)}
  Network:        $( [[ $(net) == testnet ]] && echo 'Apothem testnet' || echo 'XDC mainnet' ) · $(conf_get NODE_TYPE full) node
  Block:          $blk · $(node_sync_text)
  Peers:          ${p:-?}
  P2P port:       $(conf_get P2P_PORT) TCP + UDP
  Node account:   $acct

ENDPOINTS
  RPC:            https://$d/xdcrpc
  WSS:            wss://$d/xdcwss
  Answering:      $( [[ "$(endpoint_selftest)" == "$(chain_id_hex)" ]] && echo '✓ yes (checked from this server just now)' || echo "✗ no (Allowlist → How to test the endpoints)" )
  APIs:           $(conf_get APIS | sed 's/,/, /g')
  Certificate:    $( (( days >= 0 )) && echo "valid for $days more days (renews automatically)" || echo 'none yet' )

ACCESS
  Allowlist:      $(allow_count) address(es)$( [[ $(conf_get ALLOW_PLUGIN) == yes ]] && echo ', including Plugin RPCaaS' )
$(allow_describe | sed 's/^/  /')
  Firewall:       $fw · 443 allowlist only · 80 $(fw_port80_is_open && echo 'open (renewal running)' || echo closed)
  SSH:            port $ports · root login $rl · password logins $( [[ $pw == no ]] && echo off || echo on )
  fail2ban:       $f2b

SERVER
  Disk:           $(human "${free:-0}") free of $(human "${total:-0}")
  Memory:         $(mem_total_gb) GB
  Ubuntu:         $(os_version)$(reboot_needed && echo ' · restart needed to finish updates')

MAINTENANCE
  Last backup:    $( [[ -n $last ]] && echo "$(date -d "@$lt" '+%F %R') in $(backup_dir)" || echo none )
  xdc-rpc:        $XDC_RPC_VERSION$( [[ -n $latest ]] && version_gt "$latest" "$XDC_RPC_VERSION" && echo " (version $latest available)" )
  Node software:  $( [[ -n $img ]] && echo "${img##*:} · $(node_software_status)" || echo 'not set up yet' )
EOF
}

node_software_status() {   # one line about XinFin's releases
  if ! node_update_pending; then echo "XinFin's latest release"
  elif [[ -n $(state_get NODE_UPDATE_BLOCKED) ]]; then echo "XinFin has a newer release, which needs a newer xdc-rpc"
  else echo "XinFin has a newer release (Updates)"; fi
}

show_text() {   # show_text TITLE: page stdin
  local f; f=$(mktemp); cat >"$f"
  ui_textbox "$1" "$f"; rm -f "$f"
}

show_status() {
  ui_info "Status" "Checking…"
  status_report | show_text "Status"
}

follow_node_log() {   # the live log, until q (or Ctrl+C)
  local prev pid k rc
  prev=$(trap -p INT)
  if ui_boxes; then ui_clear; ui_plain_top; fi
  printf '\n  %s   %s\n\n' "${C_BLD}Live node log${C_OFF}" "Press q to go back to the menu."
  FOLLOW_STOP=""; trap 'FOLLOW_STOP=1' INT
  { docker logs -f --tail 40 "$(container_name)" 2>&1 | _log_with_reminder; } &
  pid=$!
  # (read keeps waiting through Ctrl+C, so it's asked for a key once a second)
  while [[ -z $FOLLOW_STOP ]]; do
    read -rsn1 -t 1 k; rc=$?
    (( rc == 0 )) && [[ $k == [qQ] ]] && break
    (( rc == 1 )) && break          # (no keyboard to read from)
  done
  pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  if [[ -n $prev ]]; then eval "$prev"; else trap - INT; fi
  return 0
}
_log_with_reminder() {   # pass the log through; every 25 lines, say how to leave
  local line n=0
  while IFS= read -r line; do
    printf '%s\n' "$line"
    (( ++n % 25 == 0 )) && printf '%s\n' "${C_DIM}  ── press q to go back to the menu ──${C_OFF}"
  done
  return 0
}

job_when() {   # "21 Nov 05:55" from a task id (20261121-055544-setup)
  local id="$1"
  date -d "${id:0:4}-${id:4:2}-${id:6:2} ${id:9:2}:${id:11:2}" '+%-d %b %H:%M' 2>/dev/null || printf '%s' "${id:0:15}"
}

job_status_word() {
  case "$1" in done) echo "finished" ;; failed) echo "didn't finish" ;; running|queued) echo "running now" ;; *) echo "$1" ;; esac
}

job_list_menu() {
  local c id
  local -a items=()
  while read -r id; do
    [[ -n $id ]] && items+=("$id" "$(job_when "$id")   $(job_title "$id") · $(job_status_word "$(job_get "$id" status)")")
  done < <(ls -1 "$JOB_DIR" 2>/dev/null | sort -r | head -n 15)
  (( ${#items[@]} )) || { ui_msg "Background tasks" "No tasks have run yet."; return; }
  c=$(ui_menu "Background tasks" "Setup, updates and restarts run as background tasks, so they carry on if you disconnect. Each one stops by itself when it's done; the list just keeps a record so you can read what happened. Times are the server's ($(date +%Z)).

Choose one to see its log:" "${items[@]}") || return
  if job_alive "$c"; then job_watch "$c"; pause_key; else
    { sed -n 's/^/  /p' <(_job_render "$c" 2>/dev/null | sed 's/\x1b\[[0-9;]*[A-Za-z]//g'); echo; echo "FULL LOG"; cat "$(job_dir "$c")/log"; } | show_text "$(job_title "$c")"
  fi
}

menu_status() {
  local c
  while true; do
    c=$(ui_menu "Status & logs" "" \
        status "Full status" \
        nodelog "Node log (latest lines)" \
        follow "Follow the node log live" \
        tasks "Background tasks and their logs" \
        nginx "Web server errors" \
        firewall "Firewall rules" \
        files "Where everything is kept") || return
    case $c in
      status) show_status ;;
      nodelog) docker logs --tail 300 "$(container_name)" 2>&1 | show_text "Node log" ;;
      follow) follow_node_log ;;
      tasks) job_list_menu ;;
      nginx) tail -n 200 /var/log/nginx/error.log 2>/dev/null | show_text "Web server errors" ;;
      firewall) { ufw status verbose; echo; echo "fail2ban:"; fail2ban-client status sshd 2>/dev/null; } | show_text "Firewall" ;;
      files) ui_page "Where everything is kept" "$(files_map_text)" ;;
    esac
  done
}

files_map_text() {   # every place xdc-rpc keeps or changes something
  local f='%-30s %s\n'
  # shellcheck disable=SC2059
  {
    printf "$f" "xdc-rpc settings, allowlist" "/etc/xdc-rpc/"
    printf "$f" "xdc-rpc logs" "/var/log/xdc-rpc/  (menu.log, daily.log)"
    printf "$f" "Tasks, node start-up files" "/var/lib/xdc-rpc/  (jobs/, node/)"
    printf "$f" "Node settings (XinFin's .env)" "$(net_dir)/.env"
    printf "$f" "Chain data" "$(data_dir)/"
    printf "$f" "Backups (encrypted)" "$(backup_dir)/"
    printf "$f" "Web server site (nginx)" "/etc/nginx/sites-available/xdc-node"
    printf "$f" "TLS certificate" "/etc/letsencrypt/live/$(conf_get DOMAIN)/"
    printf "$f" "SSH settings" "/etc/ssh/sshd_config.d/00-xdc-rpc-*.conf"
    printf "$f" "fail2ban (SSH protection)" "/etc/fail2ban/jail.d/xdc-rpc-sshd.local"
    printf "$f" "Daily checks" "systemctl status xdc-rpc-daily.timer"
    printf "$f" "Firewall rules" "sudo ufw status  (labelled xdc-rpc)"
    printf '\n%s\n' "Most of these need sudo to open. The node runs in the Docker container $(container_name)."
    printf '%s\n' "Shortcuts to all of them: $(files_links_dir)"
  }
}

# ── The shortcuts folder ─────────────────────────────────────────────────────
# ~ADMIN/XDC-RPC-Files: shortcuts to everything xdc-rpc uses, so it's all easy to
# find. It's only a map: xdc-rpc never reads anything through it. It's made as
# the admin user (it's in their home), and kept up to date by the daily checks.
FILES_LINKS_NAME=XDC-RPC-Files
files_links_dir() { printf '%s/%s' "$(admin_home)" "$FILES_LINKS_NAME"; }
files_links_list() {   # NAME|TARGET for every shortcut (whether or not the target exists yet)
  printf '%s|%s\n' \
    backups "$(backup_dir)" \
    chain-data "$(data_dir)" \
    node-settings.env "$(net_dir)/.env" \
    node-start-up-files "$(node_rt)" \
    xdc-rpc-settings "$CONF_DIR" \
    xdc-rpc-logs "$LOG_DIR" \
    xdc-rpc-background-tasks "$JOB_DIR" \
    nginx-site.conf "$NGINX_SITE" \
    nginx-allowlist-rpc.conf "$NGINX_ALLOW_RPC" \
    nginx-allowlist-wss.conf "$NGINX_ALLOW_WSS" \
    nginx-error.log /var/log/nginx/error.log \
    tls-certificate "$LE_DIR/live/$(conf_get DOMAIN)" \
    ssh-port.conf "$SSHD_PORT_CONF" \
    ssh-logins.conf "$SSHD_AUTH_CONF" \
    fail2ban-ssh.local "$F2B_JAIL" \
    daily-checks.timer "/etc/systemd/system/$DAILY_UNIT.timer" \
    daily-checks.service "/etc/systemd/system/$DAILY_UNIT.service"
}
files_links_readme() {
  local dir; dir=$(files_links_dir)
  cat <<EOF
XDC Secure RPC & WSS, by xdcoutpost.xyz: where everything is

These are shortcuts to the files and folders xdc-rpc uses. The real ones stay
where the programs using them expect them, and most can only be opened with
sudo. For example:

    sudo ls -l $dir/xdc-rpc-logs/
    sudo less $dir/xdc-rpc-logs/menu.log

Change settings from the menus (sudo xdc-rpc) rather than in these files:
xdc-rpc writes several of them itself, and changes made by hand can be
overwritten. The node's own settings (node-settings.env) are the exception.

This folder is only a map: xdc-rpc never reads anything through it. The
daily checks put back anything that goes missing. Deleting it does no harm.

  backups                    Encrypted backups (the newest $BACKUP_KEEP are kept)
  chain-data                 The chain data (the node's account: keystore/)
  node-settings.env          The node's settings (XinFin's .env). Restart the
                             node from the menu to apply changes.
  node-start-up-files        What Docker starts the node with: compose.yml,
                             start.sh, node.env (rewritten on restarts)
  xdc-rpc-settings           xdc-rpc's settings, allowlist and backup password
  xdc-rpc-logs               menu.log: what was done from the menus
                             daily.log: the daily checks
  xdc-rpc-background-tasks   Setup, updates and restarts, each with its log
  nginx-site.conf            The web server's site for your endpoints
  nginx-allowlist-*.conf     The allowlist, as the web server reads it
  nginx-error.log            Web server errors
  tls-certificate            The TLS certificate (renewed automatically)
  ssh-port.conf              The SSH port
  ssh-logins.conf            Root login, password logins
  fail2ban-ssh.local         Blocks addresses after repeated failed SSH logins
  daily-checks.timer/service The daily checks

Also useful:
  sudo xdc-rpc                  the menus
  sudo ufw status verbose       the firewall rules
  sudo docker logs --tail 100 $(container_name)
                                the node's latest log lines

Guide: $XDC_RPC_GUIDE_URL
EOF
}
files_links_sync() {   # (re)make the shortcuts folder; never fatal
  configured || return 0
  local admin dir n t; local -a links=() names=()
  admin=$(conf_get ADMIN_USER root); dir=$(files_links_dir)
  [[ $admin == root ]] || user_exists "$admin" || return 0   # (no folder for a user that doesn't exist)
  while IFS='|' read -r n t; do
    names+=("$n"); [[ -e $t ]] && links+=("$n" "$t")
  done < <(files_links_list)
  # As the admin: our old shortcuts are removed (anything else in the folder is
  # left alone), then made again for whatever exists now.
  files_links_readme | _as_user "$admin" sh -c '
    cd / && umask 022 && dir=$1 && shift && mkdir -p -- "$dir" || exit 1
    cat >"$dir/README.txt.new" && mv -f -- "$dir/README.txt.new" "$dir/README.txt" || exit 1
    while [ "$1" != -- ]; do [ -L "$dir/$1" ] && rm -f -- "$dir/$1"; shift; done; shift
    while [ $# -ge 2 ]; do ln -s -- "$2" "$dir/$1" 2>/dev/null; shift 2; done
    exit 0' sh "$dir" "${names[@]}" -- "${links[@]}" >/dev/null 2>&1 || return 0
}

endpoint_test_text() {
  local d; d=$(conf_get DOMAIN)
  cat <<EOF
From a computer whose address is on the allowlist:

RPC (should print the latest block number in hex):

  curl -s -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' https://$d/xdcrpc

WSS (needs Node.js; install wscat once with: npm install -g wscat):

  wscat -c wss://$d/xdcwss

  then paste:  {"jsonrpc":"2.0","method":"net_version","params":[],"id":1}
  and expect "$( [[ $(net) == testnet ]] && echo 51 || echo 50 )". Ctrl+C quits.

From any other address the connection simply times out: that's the
firewall doing its job.
EOF
}

menu_allowlist() {
  local c max
  while true; do
    max=0; if ui_boxes; then _ui_dims; max=$(( UI_H - UI_X_MENU - 6 )); (( max < 3 )) && max=3; fi   # (room for the list and 4 choices)
    c=$(ui_menu "Allowlist" "Only these addresses can use your endpoints:
$(allow_describe "$max")" \
        add "Add an address" \
        remove "Remove an address" \
        plugin "Plugin RPCaaS gateway: $( [[ $(conf_get ALLOW_PLUGIN) == yes ]] && echo allowed || echo 'not allowed' )" \
        test "How to test the endpoints") || return
    case $c in
      add) allow_flow_add apply && backup_create quiet >/dev/null 2>&1 ;;
      remove) allow_flow_remove apply && backup_create quiet >/dev/null 2>&1 ;;
      plugin)
        local was; was=$(conf_get ALLOW_PLUGIN no)
        if [[ $was == yes ]]; then
          ui_yesno "Plugin RPCaaS" "Stop allowing Plugin's RPCaaS gateway?" no "Stop allowing" "Cancel" || continue
          conf_set ALLOW_PLUGIN no
        else
          ui_yesno "Plugin RPCaaS" "Allow Plugin's RPCaaS gateway (${PLUGIN_RPCAAS_IPS[*]})? Its address is kept up to date by this tool's updates." yes "Allow" "Cancel" || continue
          conf_set ALLOW_PLUGIN yes
        fi
        if with_lock allow_apply; then
          backup_create quiet >/dev/null 2>&1
        else
          conf_set ALLOW_PLUGIN "$was"; with_lock allow_apply >/dev/null 2>&1
          ui_msg "Plugin RPCaaS" "The change couldn't be applied, so nothing was changed. Details: $LOG_DIR/menu.log"
        fi ;;
      test) ui_page "Testing the endpoints" "$(endpoint_test_text)" ;;
    esac
  done
}

node_info_text() {
  local cb enode
  cb=$(node_coinbase)
  enode=$(docker exec "$(container_name)" XDC --exec 'admin.nodeInfo.enode' attach /work/xdcchain/XDC.ipc 2>/dev/null | tr -d '"')
  cat <<EOF
Network:        $( [[ $(net) == testnet ]] && echo 'Apothem testnet (51)' || echo 'XDC mainnet (50)' ) · $(conf_get NODE_TYPE full) node
Node name:      $(conf_get NODE_NAME) (on XinFin's stats page)
Software:       $(node_image 2>/dev/null) (XinFin's release)
Container:      $(container_name) · $(node_state) (the node runs in here)
Start-up files: $(node_rt) (what Docker starts the container with)
Settings:       $(net_dir)/.env (applies at the next restart from the menu)
Chain data:     $(data_dir)
P2P port:       $(conf_get P2P_PORT) TCP + UDP
Local RPC:      http://127.0.0.1:$(rpc_port) (this server only)
Local WS:       ws://127.0.0.1:$(ws_port) (this server only)
Enode:          ${enode:-(available while the node runs)}

Node account:   $( [[ -n $cb ]] && echo "0x$cb" || echo "none yet (XinFin's node software creates it when the node first starts)" )
  XinFin's node software creates this account and keeps it unlocked while
  the node runs. It holds no funds and needs none. Never send funds to it.
EOF
}

chain_reset_text() {   # what "Sync again from block 0" asks
  printf '%s\n\n' "This deletes the chain data and makes the node sync again from the first block. Use it if the node is stuck and the disk has no room for a snapshot. The node's account and identity are kept."
  if early_chain_risk; then
    printf '%s\n\n' "From block 0, catching up can take weeks. While the node replays the chain's early years (up to block $(fmt_num "$EARLY_CHAIN_END")), a restart can leave it stuck at a checkpoint again, because of a bug in XDC. A fresh snapshot is much faster and starts after those years."
  else
    printf '%s\n\n' "From block 0, catching up with the whole chain takes a long time. A fresh snapshot is much faster if your disk has room for one."
  fi
  printf '%s' "Delete the chain data and sync from block 0?"
}

menu_node() {
  local c
  while true; do
    c=$(ui_menu "Node" "$(node_state) · $(node_sync_text)" \
        info "Node details" \
        restart "Restart the node" \
        stop "Stop the node" \
        start "Start the node" \
        follow "Follow the node log live" \
        snapshot "Replace the chain data with a fresh snapshot" \
        resync "Sync again from block 0 (deletes the chain data)" \
        console "Open the node console (advanced)") || return
    case $c in
      info) ui_page "Node details" "$(node_info_text)" ;;
      restart) ui_yesno "Restart" "Restart the node? It saves its state and stops cleanly first (usually a minute or two)." yes "Restart" "Cancel" && { job_start node-restart "Restarting the node"; pause_key; } ;;
      stop) ui_yesno "Stop" "Stop the node? The endpoints stop answering until you start it again. (If the server restarts, the node starts again by itself.)" no "Stop it" "Cancel" && { job_start node-stop "Stopping the node"; pause_key; } ;;
      start) job_start node-start "Starting the node"; pause_key ;;
      follow) follow_node_log ;;
      snapshot)
        local m; m=$(conf_get SNAPSHOT download); [[ $m == stream ]] || m=download
        ui_yesno "Fresh snapshot" "This deletes the current chain data and replaces it with the latest snapshot. The node is offline until it's done, which can take hours. The node's account and identity are kept.

Method: $( [[ $m == stream ]] && echo 'unpack while downloading' || echo 'download, then unpack' ) (change it in Setup & settings → Snapshot method). The free disk space is checked before anything is deleted.

Use it if the node is far behind or its data is damaged. Continue?" no "Replace the chain data" "Cancel" \
          && { conf_set SNAPSHOT "$m"; job_start snapshot "Installing a fresh chain snapshot"; pause_key; } ;;
      resync)
        ui_yesno "Sync again from block 0" "$(chain_reset_text)" no "Delete and sync from 0" "Cancel" \
          && { job_start chain-reset "Syncing again from block 0"; pause_key; } ;;
      console)
        ui_yesno "Node console" "This opens XDC's own console, where you type commands to the node. For example:

    eth.blockNumber     the latest block it has
    net.peerCount       how many other nodes it's connected to
    eth.syncing         how far it has left to go (false: caught up)

To go back to the menu, type  exit  and press Enter (or Ctrl+D).
In the console, Ctrl+C only clears what you were typing.

These examples only read. Commands that change the node, such as debug.setHead, can break it in ways that can't be undone." yes "Open the console" "Back" || continue
        if ui_boxes; then ui_clear; ui_plain_top; fi
        printf '\n  %s   %s\n\n' "${C_BLD}XDC console${C_OFF}" "Type exit (or press Ctrl+D) to go back to the menu."
        docker exec -it "$(container_name)" XDC attach /work/xdcchain/XDC.ipc ;;
    esac
  done
}

menu_admin_user() {
  local a; a=$(conf_get ADMIN_USER)
  if [[ -n $a && $a != root ]] && user_exists "$a"; then
    ui_yesno "Admin user" "The admin user is $a. Set a new password for $a?" no "Set a new password" "Cancel" && admin_password_flow "$a"
  else
    local name
    name=$(ui_input "Admin user" "Create an admin user (you'll log in as it and use sudo). Username:" xdcadmin) || return
    valid_username "$name" || { ui_msg "Admin user" "Use lowercase letters, digits, - or _."; return; }
    admin_create "$name" && admin_password_flow "$name" && conf_set ADMIN_USER "$name" && files_links_sync
  fi
}

menu_security() {
  local c
  while true; do
    c=$(ui_menu "Security" "SSH port $(ssh_config_ports | paste -sd, -) · root login $(ssh_root_login_state) · password logins $( [[ $(ssh_effective passwordauthentication) == no ]] && echo off || echo on )" \
        port "Change the SSH port" \
        root "Root login over SSH: $(ssh_root_login_state)" \
        passwords "Password logins over SSH: $( [[ $(ssh_effective passwordauthentication) == no ]] && echo "off (keys only)" || echo on )" \
        keys "SSH keys (optional: key-only logins)" \
        admin "Admin user ($(conf_get ADMIN_USER none))" \
        bans "Blocked addresses (fail2ban)" \
        docker "Docker group" \
        firewall "Re-apply the firewall rules") || return
    case $c in
      port) ssh_flow_port ;;
      root) if [[ $(ssh_root_login_state) == off ]]; then ssh_flow_root_on; else ssh_flow_root_off; fi ;;
      passwords) ssh_flow_passwords ;;
      keys) ssh_keys_menu ;;
      admin) menu_admin_user ;;
      bans) f2b_menu ;;
      docker) docker_group_flow ;;
      firewall) with_lock ufw_apply && ui_msg "Firewall" "Firewall rules are up to date." ;;
    esac
  done
}

menu_backups() {
  local c f
  while true; do
    c=$(ui_menu "Backups" "Encrypted backups of your settings, allowlist, certificate and the node's keys. The newest $BACKUP_KEEP are kept in $(backup_dir)." \
        now "Back up now" \
        list "Your backups (and how to download one)" \
        pass "Show the backup password" \
        newpass "Change the backup password" \
        restore "Restore from a backup") || return
    case $c in
      now)
        if with_lock backup_create force >/dev/null 2>&1; then
          ui_page "Backup saved" "Saved: $(backup_dir)/$(state_get BACKUP_LAST)

$(backup_download_text "$(backup_dir)/$(state_get BACKUP_LAST)")"
        else
          ui_msg "Backups" "The backup couldn't be made. Details: $LOG_DIR/menu.log"
        fi ;;
      list)
        local -a items=() files=(); local p s t
        while IFS='|' read -r p s t; do
          [[ -n $p ]] || continue
          files+=("$p"); items+=("${#files[@]}" "$t · $s")
        done < <(backup_list)
        (( ${#items[@]} )) || { ui_msg "Backups" "No backups yet."; continue; }
        f=$(ui_menu "Your backups" "Newest first. Choose one to see how to download it:" "${items[@]}") || continue
        ui_page "Download a backup" "$(backup_download_text "${files[f - 1]}")" ;;
      pass) ui_msg "Backup password" "$(backup_pass)

You need it to restore any backup. Keep a copy somewhere other than this server." ;;
      newpass)
        ui_yesno "Backup password" "New backups will use the new password. Backups already made keep the old one, so keep that too." no "Change it" "Cancel" || continue
        local np made; np=$(gen_password)
        backup_pass_set "$np"
        if with_lock backup_create force >/dev/null 2>&1; then made="A fresh backup was made with it."
        else made="The next backup (made daily when anything changes, or Back up now) uses it."; fi
        ui_msg "Backup password" "New backup password:

  $np

Save it now. $made" ;;
      restore) menu_restore ;;
    esac
  done
}

menu_restore() {
  ui_yesno "Restore" "This puts back the settings, allowlist, certificate and the node's account and identity from a backup, then runs setup again to apply them. The node restarts.

SSH settings aren't changed. Continue?" no "Continue" "Cancel" || return
  restore_pick_and_open || return
  setup_run
}

menu_updates() {
  local c latest img img_new
  while true; do
    latest=$(state_get TOOL_LATEST); img=$(node_image 2>/dev/null)
    local -a items=(
      tool "xdc-rpc $XDC_RPC_VERSION$( [[ -n $latest ]] && version_gt "$latest" "$XDC_RPC_VERSION" && echo " → $latest available" || echo ': check for a new version' )"
      node "XDC node software: ${img##*:}$( node_update_pending && echo ' → XinFin has a newer release' || echo ': check for a new release' )"
      system "Ubuntu packages"
      auto "Automatic xdc-rpc updates: $( [[ $(conf_get AUTO_UPDATE no) == yes ]] && echo on || echo off )"
    )
    [[ -d $(node_rt_prev) ]] && items+=(back "Switch the node back to its previous release ($(node_release_label "$(node_rt_prev)"))")
    reboot_needed && items+=(reboot "Restart the server (needed to finish updates)")
    [[ -f $LIB_DIR/xdc-rpc.previous ]] && items+=(rollback "Go back to the previous xdc-rpc version")
    c=$(ui_menu "Updates" "" "${items[@]}") || return
    case $c in
      tool) menu_tool_update ;;
      node) menu_node_update ;;
      back)
        ui_yesno "Previous node release" "Switch the node back to its previous release ($(node_release_label "$(node_rt_prev)"))? The node restarts, so the endpoints pause for a few minutes.

Only do this if the current release misbehaves. Once a release has run for a while, an older one can't always read the chain database it leaves behind." no "Switch back" "Cancel" \
          && { job_start node-back "Switching to the previous node release"; pause_key; } ;;
      system) ui_yesno "Ubuntu packages" "Install all waiting Ubuntu updates now? (Security updates already install themselves daily.)" yes "Update" "Cancel" \
                && { job_start system-update "Updating Ubuntu packages"; pause_key; } ;;
      auto) if [[ $(conf_get AUTO_UPDATE no) == yes ]]; then conf_set AUTO_UPDATE no; else conf_set AUTO_UPDATE yes; fi ;;
      reboot)
        ui_yesno "Restart" "Restart the server now? The node is stopped cleanly first and starts again by itself. You'll be disconnected; log back in after a minute or two." no "Restart" "Cancel" || continue
        job_start node-stop "Stopping the node before restarting"
        [[ -n $JOB_LAST_ID ]] || continue
        job_wait_quiet "$JOB_LAST_ID" >/dev/null || { ui_msg "Restart" "The node didn't stop cleanly, so the server wasn't restarted."; continue; }
        ui_clear; echo "Restarting the server…"; systemctl reboot; exit 0 ;;
      rollback)
        ui_yesno "Previous version" "Go back to the previous version of xdc-rpc?$( [[ $(conf_get AUTO_UPDATE no) == yes ]] && echo "

Automatic updates won't install version $XDC_RPC_VERSION again; they resume with the version after it." )" no "Go back" "Cancel" || continue
        if with_lock tool_rollback >/dev/null 2>&1; then exec "$SELF_INSTALL_PATH"; fi
        ui_msg "Previous version" "That didn't work. Details: $LOG_DIR/menu.log" ;;
    esac
  done
}

menu_tool_update() {
  local latest
  ui_info "Updates" "Checking GitHub for a new version…"
  latest=$(tool_latest_version) || { ui_msg "Updates" "Couldn't reach GitHub. Try again later."; return; }
  state_set TOOL_LATEST "$latest"
  if ! version_gt "$latest" "$XDC_RPC_VERSION"; then ui_msg "Updates" "You have the latest version ($XDC_RPC_VERSION)."; return; fi
  ui_yesno "Updates" "Version $latest is available (you have $XDC_RPC_VERSION). What changed: $XDC_RPC_RELEASES_URL

Update now? Your node keeps running." yes "Update" "Later" || return
  ui_info "Updates" "Downloading and checking version $latest…"
  if with_lock tool_update_install "$latest" >/dev/null 2>&1; then
    ui_msg "Updates" "Updated to version $latest."
    exec "$SELF_INSTALL_PATH"
  else
    ui_msg "Updates" "The update didn't complete, so you're still on version $XDC_RPC_VERSION. Details: $LOG_DIR/menu.log"
  fi
}

menu_node_update() {
  local blocked new
  ui_info "Updates" "Checking XinFin's repository…"
  if ! node_update_check; then ui_msg "Node software" "Couldn't reach XinFin's repository on GitHub. Try again later."; return; fi
  if ! node_update_pending; then
    ui_msg "Node software" "Your node runs XinFin's latest release ($(node_image))."
    return
  fi
  blocked=$(state_get NODE_UPDATE_BLOCKED)
  if [[ -n $blocked ]]; then
    ui_msg "Node software" "XinFin has published a new release, but it changes something this version of xdc-rpc relies on:

  $blocked

Nothing has been changed, and your node keeps running as it is. Check for a newer xdc-rpc (Updates → xdc-rpc). If there isn't one yet, check again later."
    return
  fi
  new=$(state_get NODE_LATEST_IMAGE)
  ui_yesno "Node software" "XinFin has published a new release${new:+ ($new)}, and it passed xdc-rpc's checks.

Update now? The new software downloads while your node keeps running. Then the node restarts, so the endpoints pause for a few minutes. If the new release isn't working within 10 minutes, the previous one is put back automatically." yes "Update" "Later" || return
  job_start node-update "Updating the XDC node software"; pause_key
}

menu_settings() {
  local c
  while true; do
    c=$(ui_menu "Setup & settings" "" \
        rerun "Run setup again (checks everything, fixes what's missing)" \
        all "Go through all the setup questions again" \
        apis "APIs offered: $(conf_get APIS | sed 's/,/, /g')" \
        name "Node name and contact" \
        p2p "P2P port: $(conf_get P2P_PORT)" \
        domain "Domain: $(conf_get DOMAIN)" \
        snapshot "Snapshot method: $(conf_get SNAPSHOT none)" \
        show "Show the settings file") || return
    case $c in
      rerun) setup_run ;;
      all) WIZ=(); wizard_questions && wizard_apply ;;
      apis) wiz_apis && conf_save && settings_apply ;;
      name) wiz_nodename && wiz_contact && conf_save && settings_apply ;;
      p2p) wiz_p2p && conf_save && settings_apply ;;
      domain) wiz_domain && conf_save && settings_apply ;;
      snapshot) wiz_snapshot menu && conf_save ;;
      show) cat "$CONF_FILE" | show_text "$CONF_FILE" ;;
    esac
  done
}

settings_apply() {
  ui_yesno "Apply the change" "Apply it now? Setup runs again and restarts the node if needed." yes "Apply now" "Later" && setup_run
}

main_menu() {
  local c cur notes
  [[ $(state_get SETUP_DONE) == yes ]] && files_links_sync   # (the shortcuts folder: there and current)
  if [[ -s $STATE_DIR/notices ]]; then
    notes=$(notices)
    ui_msg "Since you last looked" "$notes"
    notices_clear
  fi
  while true; do
    conf_load; state_load   # background tasks change these while the menu is open
    # Setup finished while you were elsewhere (or a stray key skipped it): show its summary once
    [[ $(state_get SETUP_DONE) == yes && $(state_get SETUP_SCREEN_DUE) == yes ]] && setup_done_screen
    ui_backtitle
    local -a items=()
    if cur=$(job_active); then items+=(task "Running task: $(job_title "$cur") (watch it)"); fi
    if [[ $(state_get SETUP_DONE) != yes && $(job_get "${cur:-none}" kind) != setup ]]; then
      items+=(finish "Finish setup$( [[ -n $(state_get SETUP_FAILED_STEP) ]] && echo " (stopped at: $(state_get SETUP_FAILED_STEP))" )")
    fi
    items+=(
      status "Status & logs"
      allow "Allowlist: who can use your endpoints"
      node "Node: restart, logs, details"
      security "Security: SSH, root login, keys"
      backups "Backups"
      updates "Updates$( { [[ -n $(state_get TOOL_LATEST) ]] && version_gt "$(state_get TOOL_LATEST)" "$XDC_RPC_VERSION"; } && echo ' (new version available)' )"
      settings "Setup & settings"
      quit "Exit"
    )
    ui_info "XDC Secure RPC & WSS" "Checking the node…"
    c=$(UI_CANCEL_LABEL=Exit ui_menu "XDC Secure RPC & WSS" "$(status_header)" "${items[@]}") || c=quit
    case $c in
      task) job_watch "$cur"; pause_key ;;
      finish) setup_run ;;
      status) menu_status ;;
      allow) menu_allowlist ;;
      node) menu_node ;;
      security) menu_security ;;
      backups) menu_backups ;;
      updates) menu_updates ;;
      settings) menu_settings ;;
      quit) ui_clear; quick_reference; return 0 ;;
    esac
  done
}

# Printed in the terminal on leaving the menu, where it can be copied cleanly
# (copying from inside a dialog picks up its borders)
quick_reference() {
  local d; d=$(conf_get DOMAIN)
  [[ -n $d && $(state_get SETUP_DONE) == yes ]] || return 0
  printf '\n  %s · %s\n\n' "${C_BLD}XDC Secure RPC & WSS${C_OFF}" "$d"
  printf '  RPC:   https://%s/xdcrpc\n' "$d"
  printf '  WSS:   wss://%s/xdcwss\n\n' "$d"
  printf '  Test from an address on your allowlist:\n'
  printf "    curl -s -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":[],\"id\":1}' https://%s/xdcrpc\n" "$d"
  printf '    wscat -c wss://%s/xdcwss\n\n' "$d"
  printf '  Menu:  sudo xdc-rpc\n'
  printf '  Guide: %s\n\n' "$XDC_RPC_GUIDE_URL"
}

# =============================================================================
#  Command line
# =============================================================================
usage() {
  cat <<EOF
xdc-rpc $XDC_RPC_VERSION: set up and manage an XDC node with private RPC and WSS endpoints

  sudo xdc-rpc                       open the menu (the first time: setup)
  sudo xdc-rpc status                show the node's status
  sudo xdc-rpc setup                 run setup again (fixes anything missing)
  sudo xdc-rpc allow list            show who can use the endpoints
  sudo xdc-rpc allow add ADDRESS [both|rpc|wss] [LABEL]
  sudo xdc-rpc allow remove ADDRESS
  sudo xdc-rpc backup                make an encrypted backup now
  sudo xdc-rpc restore               restore from a backup
  sudo xdc-rpc update                update this tool
  sudo xdc-rpc update-node           update the XDC node software
  sudo xdc-rpc update-system         install Ubuntu updates
  sudo xdc-rpc restart               restart the node
  sudo xdc-rpc logs                  follow the node log (Ctrl+C stops)
  sudo xdc-rpc ssh passwords-on      turn SSH password logins back on (recovery)
  xdc-rpc version

Guide: $XDC_RPC_GUIDE_URL
EOF
}

self_install() {   # install this file as the xdc-rpc command (unless it already is)
  local me inst=""
  me=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)
  [[ -f $me ]] || die "Save the script to a file first, then run it: sudo bash xdc-rpc.sh"
  [[ $me == "$(readlink -f "$SELF_INSTALL_PATH" 2>/dev/null)" ]] && return 0
  if [[ -f $SELF_INSTALL_PATH ]]; then
    inst=$(grep -m1 -oE '^XDC_RPC_VERSION="[0-9.]+"' "$SELF_INSTALL_PATH" | cut -d'"' -f2)
    if [[ -n $inst ]] && version_gt "$inst" "$XDC_RPC_VERSION"; then
      info "A newer version of xdc-rpc ($inst) is already installed, so that one is used."
      exec "$SELF_INSTALL_PATH" "$@"
    fi
  fi
  bash -n "$me" 2>/dev/null || die "This copy of the script is damaged. Download it again."
  mkdir -p "$(dirname "$SELF_INSTALL_PATH")"
  _tool_put "$me" || die "Couldn't install the xdc-rpc command."
  [[ $inst == "$XDC_RPC_VERSION" ]] || ok "Installed the xdc-rpc command (version $XDC_RPC_VERSION). From now on just run: sudo xdc-rpc"
  if [[ -n $inst ]] && version_gt "$XDC_RPC_VERSION" "$inst"; then
    if lock_take 120; then
      "$SELF_INSTALL_PATH" __post-update "$inst" >/dev/null 2>&1; lock_drop
    else
      warn "Once the running task has finished, run: sudo xdc-rpc setup  (it applies this version's settings)"
    fi
  fi
  return 0
}

need_setup() { configured || die "This server isn't set up yet. Run: sudo xdc-rpc"; }

cli_allow() {
  need_setup
  local n rc copy
  case ${1:-list} in
    list) allow_describe ;;
    add)
      [[ -n ${2:-} ]] || die "Usage: sudo xdc-rpc allow add ADDRESS [both|rpc|wss] [LABEL]"
      copy=$(allow_copy)
      n=$(allow_add "$2" "${3:-both}" "${*:4}"); rc=$?
      (( rc == 0 )) || rm -f "$copy"
      case $rc in
        0) ;;
        3) die "IPv6 addresses aren't supported; use the IPv4 address." ;;
        4) die "That range is far too large (use /8 or narrower)." ;;
        5) die "The second value must be both, rpc or wss." ;;
        6) die "That's Plugin's gateway address, which is managed for you (Allowlist menu)." ;;
        *) die "Not a valid IPv4 address: $2" ;;
      esac
      _cli_allow_apply "$copy" || die "The change couldn't be applied, so $n wasn't added."
      backup_create quiet; ok "$n can now use the endpoints" ;;
    remove)
      copy=$(allow_copy)
      allow_remove "${2:-}" || { rm -f "$copy"; die "${2:-That address} isn't on your allowlist."; }
      _cli_allow_apply "$copy" || die "The change couldn't be applied, so $2 still has access."
      backup_create quiet; ok "$2 can no longer use the endpoints" ;;
    *) usage; exit 1 ;;
  esac
}

_cli_allow_apply() {   # _cli_allow_apply COPY: apply the changed list, or put COPY back
  local rc
  lock_take 60 || { allow_copy_restore "$1"; return 1; }
  allow_apply_or_undo "$1"; rc=$?
  lock_drop
  return "$rc"
}

cli_job() {   # cli_job KIND TITLE
  need_setup
  local cur
  if cur=$(job_active); then die "Another task is running: $(job_title "$cur"). Watch it with: sudo xdc-rpc"; fi
  JOB_LAST_ID=$(job_create "$1" "$2"); job_launch "$JOB_LAST_ID"
  sleep 1
  if [[ -t 1 ]]; then job_watch "$JOB_LAST_ID"; else job_wait_quiet "$JOB_LAST_ID"; fi
}

cli_tool_update() {
  local latest rc
  latest=$(tool_latest_version) || die "Couldn't reach GitHub. Try again later."
  state_set TOOL_LATEST "$latest"
  version_gt "$latest" "$XDC_RPC_VERSION" || { ok "You have the latest version ($XDC_RPC_VERSION)."; return 0; }
  lock_take 60 || exit 1
  tool_update_install "$latest"; rc=$?
  lock_drop
  return "$rc"
}

# Leaving the menus after Ctrl+C (when the person chose Close): screen
# cleared, terminal back to normal
ui_interrupted() {
  if ui_boxes; then clear >/dev/tty 2>/dev/null || clear >&2; fi   # (stdout may be redirected mid-dialog)
  printf '\n  %s\n  %s\n\n' "Menus closed (anything running in the background carries on)." "To open them again: sudo xdc-rpc" >&2
  exit 130
}

interactive() {   # interactive [setup|restore]
  local id
  [[ -t 0 ]] || die "The menus need an interactive terminal: log in with SSH and run: sudo xdc-rpc"
  log_to "$LOG_DIR/menu.log"   # what's done from the menus (background tasks have their own logs)
  _logline "Menu opened by $(login_user)"
  ensure_ui_tools || warn "Some tools couldn't be installed; using plain text menus."
  have jq && have curl && have python3 || die "jq, curl and python3 are needed. Install them with: sudo apt-get install -y jq curl python3"
  ui_init
  trap ':' INT                 # Ctrl+C alone never closes the menus: a screen asks first (see _wt)
  trap ui_interrupted USR1     # ...and this is how it closes them
  if ! configured; then
    if ! os_supported; then
      ui_yesno "Unsupported system" "This tool is made for Ubuntu 24.04 and 26.04 LTS. This server runs $(os_id) $(os_version).

Continue anyway?" no "Continue" "Exit" || return 1
    fi
    wizard_main || { ui_clear; return 1; }
  else
    if id=$(job_active); then job_watch "$id"; pause_key; fi
    case ${1:-} in
      setup) setup_run ;;
      restore) menu_restore ;;
    esac
  fi
  main_menu
}

main() {
  local cmd="${1:-}"
  case $cmd in
    -h|--help|help) usage; return 0 ;;
    version|--version) echo "xdc-rpc $XDC_RPC_VERSION"; return 0 ;;
  esac
  if ! is_root; then
    have sudo && exec sudo bash "$(readlink -f "${BASH_SOURCE[0]}")" "$@"
    die "Please run this as root: sudo xdc-rpc"
  fi
  mkdir -p "$STATE_DIR" "$JOB_DIR" "$LOG_DIR" "$CONF_DIR"
  chmod 700 "$STATE_DIR" "$CONF_DIR"
  conf_load; state_load
  case $cmd in
    __job)         job_main "${2:-}" ;;
    __undo)        undo_run "${2:-}"; exit 0 ;;
    __daily)       daily_main; exit 0 ;;
    __motd)        motd_main; exit 0 ;;
    __post-update) post_update_main "${2:-}"; exit $? ;;
  esac
  self_install "$@"
  case $cmd in
    ""|menu)       interactive ;;
    setup)         interactive setup ;;
    restore)       interactive restore ;;
    status)        need_setup; status_report ;;
    allow)         cli_allow "${@:2}" ;;
    backup)        need_setup; backup_create force ;;
    update)        cli_tool_update ;;
    update-node)   cli_job node-update "Updating the XDC node software" ;;
    update-system) cli_job system-update "Updating Ubuntu packages" ;;
    restart)       cli_job node-restart "Restarting the node" ;;
    logs)          need_setup; docker logs -f --tail 100 "$(container_name)" ;;
    ssh)           [[ ${2:-} == passwords-on ]] || { usage; exit 1; }; ssh_passwords_on ;;
    *)             usage; exit 1 ;;
  esac
}

# Run only when executed (the test suite sources this file)
if [[ ${BASH_SOURCE[0]} == "$0" || -n ${XDC_RPC_MAIN:-} ]]; then
  main "$@"
fi
