#!/bin/bash

SSH_ONE_REPO_CONFIG=${SSH_ONE_REPO_CONFIG:-/etc/ssh-one/repository.conf}
if [ -r "$SSH_ONE_REPO_CONFIG" ]; then . "$SSH_ONE_REPO_CONFIG"; fi
# ==========================================
# ==========================================
# 
cd

cd /usr/bin

wget -O addgrpc "${SSH_ONE_RAW_BASE}/xray/addgrpc.sh"
wget -O cekgrpc "${SSH_ONE_RAW_BASE}/xray/cekgrpc.sh"
wget -O delgrpc "${SSH_ONE_RAW_BASE}/xray/delgrpc.sh"
wget -O renewgrpc "${SSH_ONE_RAW_BASE}/xray/renewgrpc.sh"


chmod +x addgrpc
chmod +x delgrpc
chmod +x cekgrpc
chmod +x renewgrpc

cd
