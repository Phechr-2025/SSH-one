#!/usr/bin/env bash

# Keep optional statistics tools from delaying or hiding the menu.
MENU_VERSION='v18'

if [[ ${1:-} == --check ]]; then
  printf 'SSH-one menu %s is ready.\n' "$MENU_VERSION"
  exit 0
fi

if [[ -t 1 ]]; then
  cyan=$'\033[1;36m'
  yellow=$'\033[1;33m'
  white=$'\033[1;37m'
  reset=$'\033[0m'
else
  cyan='' yellow='' white='' reset=''
fi

read_value() {
  local file=$1 value=''
  if [[ -r $file ]]; then IFS= read -r value < "$file" || true; fi
  printf '%s' "${value:-N/A}"
}

count_matches() {
  local pattern=$1 file=$2 count
  if [[ -r $file ]]; then
    count=$(grep -cE "$pattern" "$file" 2>/dev/null) || count=0
    printf '%s' "$count"
  else
    printf '0'
  fi
}

server_summary() {
  local os='Linux' uptime='N/A' cores='N/A' load='N/A' ram='N/A'
  if [[ -r /etc/os-release ]]; then
    os=$( . /etc/os-release; printf '%s' "${PRETTY_NAME:-Linux}" ) 2>/dev/null || os='Linux'
  fi
  command -v uptime >/dev/null 2>&1 && uptime -p >/dev/null 2>&1 && uptime=$(uptime -p 2>/dev/null) || true
  command -v getconf >/dev/null 2>&1 && cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || true
  [[ -r /proc/loadavg ]] && load=$(awk '{print $1}' /proc/loadavg 2>/dev/null) || true
  command -v free >/dev/null 2>&1 && ram=$(free -m 2>/dev/null | awk 'NR==2 {printf "%s/%s MB", $3, $2}') || true
  printf '%s  OS: %s\n' "$cyan" "${os:-Linux}"
  printf '  Kernel: %s | Uptime: %s\n' "$(uname -r 2>/dev/null || printf 'N/A')" "${uptime:-N/A}"
  printf '  CPU cores: %s | Load: %s | RAM: %s\n' "${cores:-N/A}" "${load:-N/A}" "${ram:-N/A}"
  printf '  Host: %s | DNS domain: %s\n' \
    "$(read_value /etc/ssh-one/host)" "$(read_value /etc/xray/domain)"
  printf '  Accounts: SSH %s | VMess %s | VLESS %s | Trojan %s | Trojan-Go %s\n' \
    "$(awk -F: '$3 >= 1000 && $1 != "nobody" {n++} END {print n+0}' /etc/passwd 2>/dev/null)" \
    "$(count_matches '^### ' /etc/xray/config.json)" \
    "$(count_matches '^#### ' /etc/xray/config.json)" \
    "$(count_matches '^#&# ' /etc/xray/config.json)" \
    "$(count_matches '^### ' /etc/trojan-go/akun.conf)"
  printf '%s\n' "$reset"
}

show_menu() {
  printf '%s\n' "${cyan}============================================================${reset}"
  printf '%sSSH-one MAIN MENU (%s)%s\n' "$white" "$MENU_VERSION" "$reset"
  server_summary
  printf '%s\n' "${cyan}============================================================${reset}"
  printf '%s 1%s. UDP Custom & firewall menu\n' "$yellow" "$reset"
  printf '%s 2%s. SSH WebSocket menu\n' "$yellow" "$reset"
  printf '%s 3%s. L2TP menu\n' "$yellow" "$reset"
  printf '%s 4%s. PPTP menu\n' "$yellow" "$reset"
  printf '%s 5%s. SSTP menu\n' "$yellow" "$reset"
  printf '%s 6%s. WireGuard menu\n' "$yellow" "$reset"
  printf '%s 7%s. Shadowsocks menu\n' "$yellow" "$reset"
  printf '%s 8%s. ShadowsocksR menu\n' "$yellow" "$reset"
  printf '%s 9%s. Xray VMess menu\n' "$yellow" "$reset"
  printf '%s10%s. Xray VLESS menu\n' "$yellow" "$reset"
  printf '%s11%s. Xray Trojan menu\n' "$yellow" "$reset"
  printf '%s12%s. Trojan-Go menu\n' "$yellow" "$reset"
  printf '%s13%s. Show service ports\n' "$yellow" "$reset"
  printf '%s14%s. Check IP and ports\n' "$yellow" "$reset"
  printf '%s15%s. Check VPN services\n' "$yellow" "$reset"
  printf '%s16%s. Check CPU and RAM\n' "$yellow" "$reset"
  printf '%s17%s. Check bandwidth\n' "$yellow" "$reset"
  printf '%s18%s. DNS changer\n' "$yellow" "$reset"
  printf '%s19%s. Netflix checker\n' "$yellow" "$reset"
  printf '%s20%s. Delete expired users\n' "$yellow" "$reset"
  printf '%s21%s. Update SSH-one\n' "$yellow" "$reset"
  printf '%s22%s. Settings\n' "$yellow" "$reset"
  printf '%s23%s. Xray version\n' "$yellow" "$reset"
  printf '%s24%s. Fix SSLH/WebSocket after reboot\n' "$yellow" "$reset"
  printf '%s26%s. Uninstall SSH-one\n' "$yellow" "$reset"
  printf '%s 0%s. Exit\n' "$yellow" "$reset"
  printf '%s\n' "${cyan}============================================================${reset}"
}

run_action() {
  local command_name=$1
  shift
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Menu item unavailable: command "%s" is not installed.\n' "$command_name" >&2
    return 127
  fi
  "$command_name" "$@"
}

pause_if_interactive() {
  if [[ -t 0 ]]; then IFS= read -r -p 'Press Enter to return to the main menu...' _ || true; fi
}

while :; do
  if [[ -t 1 && -n ${TERM:-} ]] && command -v clear >/dev/null 2>&1; then
    clear >/dev/null 2>&1 || true
  fi
  show_menu
  if ! IFS= read -r -p 'Select an option [0-26]: ' choice; then
    printf '\nNo menu selection was received.\n' >&2
    exit 1
  fi
  case $choice in
    1) run_action ssh-one-udp ;;
    2) run_action sshovpnmenu ;;
    3) run_action l2tpmenu ;;
    4) run_action pptpmenu ;;
    5) run_action sstpmenu ;;
    6) run_action wgmenu ;;
    7) run_action ssmenu ;;
    8) run_action ssrmenu ;;
    9) run_action vmessmenu ;;
    10) run_action vlessmenu ;;
    11) run_action trmenu ;;
    12) run_action trgomenu ;;
    13) run_action info ;;
    14) run_action ipsaya ;;
    15) run_action running ;;
    16) run_action htop ;;
    17) run_action vnstat ;;
    18) run_action dns ;;
    19) run_action netf ;;
    20)
      run_action delexp && run_action xp && run_action restart
      ;;
    21) run_action updatemenu ;;
    22) run_action setmenu ;;
    23) run_action xray version ;;
    24) run_action sl-fix ;;
    26)
      run_action ssh-one-uninstall
      if [[ ! -e /etc/ssh-one/installation-complete && ! -e /etc/ssh-one/install-in-progress ]]; then
        exit 0
      fi
      ;;
    0|25) exit 0 ;;
    *) printf 'Invalid selection: %s\n' "$choice" >&2 ;;
  esac
  pause_if_interactive
done
