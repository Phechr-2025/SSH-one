#!/usr/bin/env bash

# Keep optional statistics tools from delaying or hiding the menu.
MENU_VERSION='v27'
if [[ -r /etc/ssh-one/installation-complete ]]; then
  installed_menu_version=''
  IFS= read -r installed_menu_version < /etc/ssh-one/installation-complete || true
  [[ $installed_menu_version =~ ^v[0-9]+$ ]] && MENU_VERSION=$installed_menu_version
fi
MENU_REFERENCE=$MENU_VERSION
if [[ -r /etc/ssh-one/source-commit ]]; then
  installed_source_commit=''
  IFS= read -r installed_source_commit < /etc/ssh-one/source-commit || true
  [[ $installed_source_commit =~ ^[a-f0-9]{40}$ ]] && MENU_REFERENCE=${installed_source_commit:0:7}
fi

if [[ ${1:-} == --check ]]; then
  printf 'SSH-one menu %s is ready.\n' "$MENU_VERSION"
  exit 0
fi

# Older installed updaters do not save the source commit. Resolve it once on
# the first menu launch, then use the local value on subsequent launches.
if [[ $MENU_REFERENCE == "$MENU_VERSION" && -r /etc/ssh-one/repository.conf ]] &&
   command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  source_owner=$(sed -n "s/^SSH_ONE_OWNER='\\([^']*\\)'$/\\1/p" /etc/ssh-one/repository.conf)
  source_name=$(sed -n "s/^SSH_ONE_NAME='\\([^']*\\)'$/\\1/p" /etc/ssh-one/repository.conf)
  source_branch=$(sed -n "s/^SSH_ONE_BRANCH='\\([^']*\\)'$/\\1/p" /etc/ssh-one/repository.conf)
  if [[ $source_owner =~ ^[A-Za-z0-9-]+$ && $source_name =~ ^[A-Za-z0-9._-]+$ &&
        $source_branch =~ ^[A-Za-z0-9._/-]+$ && $source_branch != *..* ]]; then
    source_response=$(curl --fail --location --silent --connect-timeout 2 --max-time 5 \
      --header 'Accept: application/vnd.github+json' --header 'User-Agent: SSH-one' --get \
      --data-urlencode "sha=$source_branch" --data-urlencode 'per_page=1' \
      "https://api.github.com/repos/$source_owner/$source_name/commits" 2>/dev/null) || source_response=''
    source_commit=$(jq -r 'if type == "array" and length > 0 then (.[0].sha // "") else "" end' \
      <<< "$source_response" 2>/dev/null || true)
    if [[ $source_commit =~ ^[a-f0-9]{40}$ ]]; then
      MENU_REFERENCE=${source_commit:0:7}
      if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        source_commit_tmp="/etc/ssh-one/.source-commit.new.$$"
        if printf '%s\n' "$source_commit" > "$source_commit_tmp" && chmod 0644 "$source_commit_tmp" &&
           mv -fT -- "$source_commit_tmp" /etc/ssh-one/source-commit; then
          :
        else
          rm -f -- "$source_commit_tmp"
        fi
      fi
    fi
  fi
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

count_unique_users() {
  local marker=$1 file
  shift
  local -a readable_files=()
  for file in "$@"; do [[ -r $file ]] && readable_files+=("$file"); done
  if ((${#readable_files[@]})); then
    awk -v marker="$marker" 'index($0, marker) == 1 { user=$2; if (user != "") users[user]=1 } END { for (user in users) count++; print count+0 }' "${readable_files[@]}" 2>/dev/null
  else
    printf '0'
  fi
}

cpu_usage() {
  local label user1 nice1 system1 idle1 iowait1 irq1 softirq1 steal1
  local user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2
  [[ -r /proc/stat ]] || { printf 'N/A'; return; }
  read -r label user1 nice1 system1 idle1 iowait1 irq1 softirq1 steal1 _ < /proc/stat || { printf 'N/A'; return; }
  sleep 0.5
  read -r label user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2 _ < /proc/stat || { printf 'N/A'; return; }
  LC_ALL=C awk -v u1="$user1" -v n1="$nice1" -v s1="$system1" -v i1="$idle1" -v w1="$iowait1" -v q1="$irq1" -v r1="$softirq1" -v t1="$steal1" \
      -v u2="$user2" -v n2="$nice2" -v s2="$system2" -v i2="$idle2" -v w2="$iowait2" -v q2="$irq2" -v r2="$softirq2" -v t2="$steal2" \
      'BEGIN { total1=u1+n1+s1+i1+w1+q1+r1+t1; total2=u2+n2+s2+i2+w2+q2+r2+t2; delta=total2-total1; idle=(i2+w2)-(i1+w1); if (delta <= 0) print "N/A"; else printf "%.1f", 100*(delta-idle)/delta }' 2>/dev/null || printf 'N/A'
}

traffic_value() {
  local json=$1 period=$2 year=$3 month=$4 day=${5:-0}
  [[ -n $json ]] || { printf 'N/A'; return; }
  jq -r --arg period "$period" --argjson year "$year" --argjson month "$month" --argjson day "$day" '
    def human:
      if . >= 1099511627776 then ((. / 1099511627776 * 100 | floor) / 100 | tostring) + " TiB"
      elif . >= 1073741824 then ((. / 1073741824 * 100 | floor) / 100 | tostring) + " GiB"
      elif . >= 1048576 then ((. / 1048576 * 100 | floor) / 100 | tostring) + " MiB"
      elif . >= 1024 then ((. / 1024 * 100 | floor) / 100 | tostring) + " KiB"
      else (tostring) + " B" end;
    .interfaces[0].traffic as $traffic
    | (if $period == "day" then
         [($traffic.days // $traffic.day // [])[]? | select(.date.year == $year and .date.month == $month and .date.day == $day) | ((.rx // 0) + (.tx // 0))]
       else
         [($traffic.months // $traffic.month // [])[]? | select(.date.year == $year and .date.month == $month) | ((.rx // 0) + (.tx // 0))]
       end) as $values
    | if ($values | length) == 0 then "N/A" else ($values | add | human) end
  ' 2>/dev/null || printf 'N/A'
}

bandwidth_summary() {
  local interface='' data='' today yesterday today_y today_m today_d yesterday_y yesterday_m yesterday_d current_y current_m
  local daily='N/A' yesterday_usage='N/A' monthly='N/A'
  if command -v vnstat >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v date >/dev/null 2>&1; then
    interface=$(ip -4 route show default 2>/dev/null | awk 'NR == 1 { for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit } }')
    if [[ -n $interface ]]; then
      data=$(vnstat --iface "$interface" --json s 2>/dev/null) || data=''
    fi
    [[ -n $data ]] || data=$(vnstat --json s 2>/dev/null) || data=''
    read -r today_y today_m today_d < <(date +'%Y %m %d' 2>/dev/null) || true
    read -r yesterday_y yesterday_m yesterday_d < <(date -d yesterday +'%Y %m %d' 2>/dev/null) || true
    read -r current_y current_m < <(date +'%Y %m' 2>/dev/null) || true
    if [[ $today_y =~ ^[0-9]+$ && $today_m =~ ^[0-9]+$ && $today_d =~ ^[0-9]+$ ]]; then
      daily=$(traffic_value "$data" day "$((10#$today_y))" "$((10#$today_m))" "$((10#$today_d))")
    fi
    if [[ $yesterday_y =~ ^[0-9]+$ && $yesterday_m =~ ^[0-9]+$ && $yesterday_d =~ ^[0-9]+$ ]]; then
      yesterday_usage=$(traffic_value "$data" day "$((10#$yesterday_y))" "$((10#$yesterday_m))" "$((10#$yesterday_d))")
    fi
    if [[ $current_y =~ ^[0-9]+$ && $current_m =~ ^[0-9]+$ ]]; then
      monthly=$(traffic_value "$data" month "$((10#$current_y))" "$((10#$current_m))")
    fi
  fi
  printf '%s♦️ Daily Usage     : %s%s\n' "$white" "$daily" "$reset"
  printf '%s♦️ Yesterday Usage : %s%s\n' "$white" "$yesterday_usage" "$reset"
  printf '%s♦️ Monthly Usage   : %s%s\n' "$white" "$monthly" "$reset"
}

server_summary() {
  local os='Linux' uptime='N/A' cores='N/A' cpu='N/A' ram='N/A' domain='N/A' dnstt='N/A' public_ip='N/A'
  local ssh_accounts udp_accounts vmess_accounts vless_accounts
  if [[ -r /etc/os-release ]]; then
    os=$( . /etc/os-release; printf '%s' "${PRETTY_NAME:-Linux}" ) 2>/dev/null || os='Linux'
  fi
  command -v uptime >/dev/null 2>&1 && uptime=$(uptime -p 2>/dev/null | sed 's/^up //') || true
  command -v getconf >/dev/null 2>&1 && cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || true
  cpu=$(cpu_usage)
  if [[ -r /proc/meminfo ]]; then
    ram=$(awk '/^MemTotal:/ {total=$2} /^MemAvailable:/ {available=$2} END {if (total > 0 && available >= 0) printf "%d/%d", (total-available)/1024, total/1024}' /proc/meminfo 2>/dev/null) || ram=''
  fi
  [[ -n $ram ]] || ram='N/A'
  domain=$(read_value /etc/xray/domain)
  [[ $domain != N/A ]] || domain=$(read_value /etc/ssh-one/host)
  dnstt=$(read_value /root/nsdomain)
  public_ip=$(read_value /etc/ssh-one/public-ip)
  if [[ $public_ip == N/A && $domain != N/A ]] && command -v getent >/dev/null 2>&1; then
    public_ip=$(timeout 2 getent ahostsv4 "$domain" 2>/dev/null | awk 'NR == 1 {print $1}')
    [[ -n $public_ip ]] || public_ip='N/A'
  fi
  ssh_accounts=0
  udp_accounts=0
  if command -v ssh-one-account-tools >/dev/null 2>&1; then
    ssh_accounts=$(ssh-one-account-tools count 2>/dev/null) || ssh_accounts=0
    udp_accounts=$(ssh-one-account-tools count-udp 2>/dev/null) || udp_accounts=0
  fi
  vmess_accounts=$(count_unique_users '### ' /etc/xray/config.json /etc/xray/sl-vmessgrpc.json)
  vless_accounts=$(count_unique_users '#### ' /etc/xray/config.json /etc/xray/sl-vlessgrpc.json)
  printf '%s\n' "${cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"
  printf '%s♦️ Server Information ♦️%s\n' "$white" "$reset"
  printf '%s♦️ OS       : %s%s\n' "$white" "${os:-Linux}" "$reset"
  printf '%s♦️ KERNEL   : %s%s\n' "$white" "$(uname -r 2>/dev/null || printf 'N/A')" "$reset"
  printf '%s♦️ UPTIME   : %s%s\n' "$white" "${uptime:-N/A}" "$reset"
  printf '%s♦️ CPU      : %s core (%s%%)%s\n' "$white" "${cores:-N/A}" "$cpu" "$reset"
  printf '%s♦️ RAM      : %s MB / %s MB%s\n' "$white" "${ram%%/*}" "${ram#*/}" "$reset"
  printf '%s♦️ DOMAIN   : %s%s\n' "$white" "$domain" "$reset"
  printf '%s♦️ DNSTT    : %s%s\n' "$white" "$dnstt" "$reset"
  printf '%s♦️ IPVPS    : %s%s\n' "$white" "$public_ip" "$reset"
  printf '%s\n' "${cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"
  printf '%s♦️ Total Bandwidth ♦️%s\n' "$white" "$reset"
  bandwidth_summary
  printf '%s\n' "${cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${reset}"
  printf '%s♦️ Accounts ♦️%s\n' "$white" "$reset"
  printf '%-6s %-7s %-8s %-7s %-8s %-9s\n' 'UDP' 'SSH' 'VMESS' 'VLESS' 'TROJAN' 'TROJANGO'
  printf '%-6s %-7s %-8s %-7s %-8s %-9s\n' "$udp_accounts" "${ssh_accounts:-0}" \
    "$vmess_accounts" \
    "$vless_accounts" \
    "$(count_unique_users '#&# ' /etc/xray/config.json)" \
    "$(count_unique_users '### ' /etc/trojan-go/akun.conf)"
  printf '%s\n' "$reset"
}

show_service_ports() {
  local line='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  printf '%s\n' "$cyan$line$reset"
  printf '%s♦️ Service Ports ♦️%s\n' "$white" "$reset"
  printf '%s\n' "$cyan$line$reset"
  printf '%-30s %s\n' 'Service' 'Port / Protocol'
  printf '%-30s %s\n' 'OpenSSH' 'TCP 22, 2253'
  printf '%-30s %s\n' 'Dropbear' 'TCP 109, 143, 1153'
  printf '%-30s %s\n' 'OpenVPN' 'TCP 1194, UDP 2200, TLS/TCP 990'
  printf '%-30s %s\n' 'SSLH / SSH WebSocket' 'TCP 443 (TLS multiplex), HTTP 8880'
  printf '%-30s %s\n' 'Stunnel5' 'TCP 445, 777, 990'
  printf '%-30s %s\n' 'BadVPN UDPGW' 'Loopback TCP 7100, 7200, 7300 (SSH apps)'
  printf '%-30s %s\n' 'WireGuard' 'UDP 7070 (IPv4 game tunnel)'
  printf '%-30s %s\n' 'L2TP/IPsec, PPTP' 'UDP 500, 1701, 4500; TCP 1732'
  printf '%-30s %s\n' 'SSTP' 'TCP 444'
  printf '%-30s %s\n' 'Shadowsocks-R' 'TCP 1443-1543'
  printf '%-30s %s\n' 'Shadowsocks OBFS' 'TCP/TLS 2443-2543, TCP/HTTP 3443-3543'
  printf '%-30s %s\n' 'Xray VMess' 'TCP/TLS 8443, TCP 80'
  printf '%-30s %s\n' 'Xray VLESS' 'TCP/TLS 8444, TCP 81'
  printf '%-30s %s\n' 'Xray Trojan, TrojanGo' 'TCP 2083, 2087'
  printf '%-30s %s\n' 'OHP' 'TCP 8181, 8282, 8383'
  printf '%-30s %s\n' 'UDP Custom' 'UDP 1-65535 (listener :36712 by default)'
  printf '%s\n' "$cyan$line$reset"
}

show_menu() {
  printf '%s\n' "${cyan}============================================================${reset}"
  printf '%sSSH-one MAIN MENU (%s)%s\n' "$white" "$MENU_REFERENCE" "$reset"
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
  printf '%s27%s. API token management\n' "$yellow" "$reset"
  printf '%s 0%s. Exit\n' "$yellow" "$reset"
  printf '%s\n' "${cyan}============================================================${reset}"
}

run_action() {
  local command_name=$1 status
  shift
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Menu item unavailable: command "%s" is not installed.\n' "$command_name" >&2
    return 127
  fi
  if SSH_ONE_MENU_ACTIVE=1 "$command_name" "$@"; then status=0; else status=$?; fi
  return "$status"
}

show_menu_after_action() {
  local setting=0
  if [[ -r /etc/ssh-one/menu-after-action ]]; then
    IFS= read -r setting < /etc/ssh-one/menu-after-action || true
  elif [[ -r /etc/ssh-one/menu-after-create ]]; then
    # Keep v25's preference when the first v26 menu is opened.
    IFS= read -r setting < /etc/ssh-one/menu-after-create || true
  fi
  [[ $setting == 1 ]]
}

first_menu_iteration=1
while :; do
  if (( first_menu_iteration )) && [[ -t 1 && -n ${TERM:-} ]] && command -v clear >/dev/null 2>&1; then
    clear >/dev/null 2>&1 || true
  fi
  first_menu_iteration=0
  show_menu
  if ! IFS= read -r -p 'Select an option [0-27]: ' choice; then
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
    13) show_service_ports ;;
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
    27) run_action ssh-one-api-tokens ;;
    0|25) exit 0 ;;
    *) printf 'Invalid selection: %s\n' "$choice" >&2 ;;
  esac
  action_status=$?
  if (( action_status == 99 )); then continue; fi
  case $choice in
    1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|26|27)
      show_menu_after_action || exit 0
      ;;
  esac
done
