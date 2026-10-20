#!/bin/bash

SSH_ONE_REPO_CONFIG=${SSH_ONE_REPO_CONFIG:-/etc/ssh-one/repository.conf}
if [ -r "$SSH_ONE_REPO_CONFIG" ]; then . "$SSH_ONE_REPO_CONFIG"; fi
# ==========================================
# Color
# hapus menu
rm -rf menu
rm -rf ipsaya
rm -rf sl-fix
rm -rf sshovpnmenu
rm -rf l2tpmenu
rm -rf pptpmenu
rm -rf sstpmenu
rm -rf wgmenu
rm -rf ssmenu
rm -rf ssrmenu
rm -rf vmessmenu
rm -rf vlessmenu
rm -rf grpcmenu
rm -rf grpcupdate
rm -rf trmenu
rm -rf trgomenu
rm -rf setmenu
rm -rf slowdnsmenu
rm -rf running
rm -rf copyrepo

# download menu
cd /usr/bin
rm -rf ssh-one-udp
rm -rf menu
rm -rf menuinfo
rm -rf restart
rm -rf slhost
rm -rf install-sldns
rm -rf addssh
wget -O install-sldns "${SSH_ONE_RAW_BASE}/SLDNS/install-sldns"
wget -O restart "${SSH_ONE_RAW_BASE}/ssh/restart.sh"
wget -O addssh "${SSH_ONE_RAW_BASE}/ssh/addssh.sh"
wget -O menu "${SSH_ONE_RAW_BASE}/update/menu.sh"
wget -O ssh-one-udp "${SSH_ONE_RAW_BASE}/update/udp-menu.sh"
wget -O ipsaya "${SSH_ONE_RAW_BASE}/update/ipsaya.sh"
wget -O sl-fix "${SSH_ONE_RAW_BASE}/sslh-fix/sl-fix"
wget -O sshovpnmenu "${SSH_ONE_RAW_BASE}/update/sshovpn.sh"
wget -O l2tpmenu "${SSH_ONE_RAW_BASE}/update/l2tpmenu.sh"
wget -O pptpmenu "${SSH_ONE_RAW_BASE}/update/pptpmenu.sh"
wget -O sstpmenu "${SSH_ONE_RAW_BASE}/update/sstpmenu.sh"
wget -O wgmenu "${SSH_ONE_RAW_BASE}/update/wgmenu.sh"
wget -O ssmenu "${SSH_ONE_RAW_BASE}/update/ssmenu.sh"
wget -O ssrmenu "${SSH_ONE_RAW_BASE}/update/ssrmenu.sh"
wget -O vmessmenu "${SSH_ONE_RAW_BASE}/update/vmessmenu.sh"
wget -O vlessmenu "${SSH_ONE_RAW_BASE}/update/vlessmenu.sh"
wget -O xray-grpc "${SSH_ONE_RAW_BASE}/grpc/xray-grpc.sh"
wget -O grpcmenu "${SSH_ONE_RAW_BASE}/update/grpcmenu.sh"
wget -O grpcupdate "${SSH_ONE_RAW_BASE}/update/grpcupdate.sh"
wget -O trmenu "${SSH_ONE_RAW_BASE}/update/trmenu.sh"
wget -O trgomenu "${SSH_ONE_RAW_BASE}/update/trgomenu.sh"
wget -O setmenu "${SSH_ONE_RAW_BASE}/update/setmenu.sh"
wget -O slowdnsmenu "${SSH_ONE_RAW_BASE}/update/slowdnsmenu.sh"
wget -O running "${SSH_ONE_RAW_BASE}/update/running.sh"
wget -O updatemenu "${SSH_ONE_RAW_BASE}/update/updatemenu.sh"
wget -O copyrepo "${SSH_ONE_RAW_BASE}/salin/copyrepo.sh"
wget -O slhost "${SSH_ONE_RAW_BASE}/ssh/slhost.sh"
wget -O sl-download-info "${SSH_ONE_RAW_BASE}/contohinfo/sl-download-info.sh"
wget -O menuinfo "${SSH_ONE_RAW_BASE}/update/menuinfo.sh"
wget -O install-ss-plugin "${SSH_ONE_RAW_BASE}/shadowsocks-plugin/install-ss-plugin.sh"

chmod +x install-ss-plugin
chmod +x xray-grpc
chmod +x install-sldns
chmod +x restart
chmod +x addssh
chmod +x grpcmenu2
chmod +x grpc2
chmod +x grpcupdate2
chmod +x sl-download-info
chmod +x menuinfo
chmod +x slhost
chmod +x copyrepo
chmod +x menu
chmod +x ssh-one-udp
chmod +x ipsaya
chmod +x sl-fix
chmod +x sshovpnmenu
chmod +x l2tpmenu
chmod +x pptpmenu
chmod +x sstpmenu
chmod +x wgmenu
chmod +x ssmenu
chmod +x ssrmenu
chmod +x vmessmenu
chmod +x vlessmenu
chmod +x grpcmenu
chmod +x grpcupdate
chmod +x trmenu
chmod +x trgomenu
chmod +x setmenu
chmod +x slowdnsmenu
chmod +x running
chmod +x updatemenu
sl-download-info
#install-sldns
#install-ss-plugin
#xray-grpc
cd
