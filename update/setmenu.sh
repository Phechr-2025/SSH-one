#!/usr/bin/env bash
set -Eeuo pipefail

setting_file=/etc/ssh-one/menu-after-action
setting=0
if [[ -r $setting_file ]]; then IFS= read -r setting < "$setting_file" || true
elif [[ -r /etc/ssh-one/menu-after-create ]]; then IFS= read -r setting < /etc/ssh-one/menu-after-create || true
fi
[[ $setting == 1 ]] || setting=0

printf '%s\n' 'SYSTEM SETTINGS'
printf '%s\n' '-------------------------------------------------------------'
printf '%s\n' ' 1. Add/change VPS host'
printf '%s\n' ' 2. Change service ports'
printf '%s\n' ' 3. Automatic backup'
printf '%s\n' ' 4. Backup data'
printf '%s\n' ' 5. Restore data'
printf '%s\n' ' 6. Webmin menu'
printf '%s\n' ' 7. Limit server bandwidth'
printf '%s\n' ' 8. Check RAM usage'
printf '%s\n' ' 9. Reboot VPS'
printf '%s\n' '10. VPS speed test'
printf '%s\n' '11. Restart VPN services'
printf '%s\n' '12. Installer information'
printf '%s\n' '13. Renew Xray certificate'
printf '%s\n' '14. Renew nameserver certificate'
printf '%s\n' '15. BBR manager'
printf '%s\n' '16. Change Xray core'
printf '%s\n' '17. Change SSH WebSocket banner'
printf '%s\n' '18. Restore SSH + SSL/TLS port 443'
printf '%s\n' '19. Swap RAM menu'
printf '%s\n' '20. Main menu'
if [[ $setting == 1 ]]; then
  printf '%s\n' '21. Return to main menu after every action [ON]'
else
  printf '%s\n' '21. Return to main menu after every action [OFF]'
fi
printf '%s\n' '-------------------------------------------------------------'
read -r -p 'Select an option [1-21]: ' choice || exit 0

case $choice in
  1) addhost ;;
  2) changeport ;;
  3) autobackup ;;
  4) backup ;;
  5) restore ;;
  6) wbmn ;;
  7) limitspeed ;;
  8) ram ;;
  9) reboot ;;
  10) speedtest ;;
  11) restart ;;
  12) about ;;
  13) certv2ray && restart ;;
  14) install-sldns && restart ;;
  15) ssh-one-bbr ;;
  16) wget -q -O /usr/bin/xraychanger 'https://raw.githubusercontent.com/NevermoreSSH/Xcore-custompath/main/xraychanger.sh' && chmod +x /usr/bin/xraychanger && xraychanger ;;
  17) nano /etc/issue.net ;;
  18) fssw ;;
  19) wget -q -O /usr/bin/swapram 'https://raw.githubusercontent.com/NevermoreSSH/swapram/main/swapram.sh' && chmod +x /usr/bin/swapram && swapram ;;
  20) exit 0 ;;
  21)
    tmp=$(mktemp /etc/ssh-one/.menu-after-action.XXXXXX)
    if [[ $setting == 1 ]]; then printf '0\n' > "$tmp"; else printf '1\n' > "$tmp"; fi
    chmod 0644 "$tmp"
    mv -fT -- "$tmp" "$setting_file"
    if [[ $setting == 1 ]]; then printf 'Return to main menu after every action: OFF\n'; else printf 'Return to main menu after every action: ON\n'; fi
    ;;
  *) printf 'Invalid option.\n' >&2 ;;
esac
