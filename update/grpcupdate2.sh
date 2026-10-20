#!/bin/bash

SSH_ONE_REPO_CONFIG=${SSH_ONE_REPO_CONFIG:-/etc/ssh-one/repository.conf}
if [ -r "$SSH_ONE_REPO_CONFIG" ]; then . "$SSH_ONE_REPO_CONFIG"; fi
# ==========================================
# ==========================================
# 
cd

cd /usr/bin


wget -O fb-addgrpc "${SSH_ONE_RAW_BASE}/grpc/fb-addgrpc.sh"
wget -O fb-delgrpc "${SSH_ONE_RAW_BASE}/grpc/fb-delgrpc.sh"
wget -O fb-renewgrpc "${SSH_ONE_RAW_BASE}/grpc/fb-renewgrpc.sh"
wget -O fb-cekgrpc "${SSH_ONE_RAW_BASE}/grpc/fb-cekgrpc.sh"

chmod +x fb-addgrpc
chmod +x fb-delgrpc
chmod +x fb-renewgrpc
chmod +x fb-cekgrpc

cd
