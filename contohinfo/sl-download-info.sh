#!/bin/bash

SSH_ONE_REPO_CONFIG=${SSH_ONE_REPO_CONFIG:-/etc/ssh-one/repository.conf}
if [ -r "$SSH_ONE_REPO_CONFIG" ]; then . "$SSH_ONE_REPO_CONFIG"; fi

cd /usr/bin

rm info-cek-tersedia
rm info-contoh-payload
rm info-contohws
rm info-exra-unli
rm info-tsel-opok
rm info-status-respon

wget -O info-cek-tersedia "${SSH_ONE_RAW_BASE}/contohinfo/info-cek-tersedia.sh"

wget -O info-contoh-payload "${SSH_ONE_RAW_BASE}/contohinfo/info-contoh-payload.sh"

wget -O info-contohws "${SSH_ONE_RAW_BASE}/contohinfo/info-contohws.sh"

wget -O info-exra-unli "${SSH_ONE_RAW_BASE}/contohinfo/info-exra-unli.sh"

wget -O info-status-respon "${SSH_ONE_RAW_BASE}/contohinfo/info-status-respon.sh"

wget -O info-tsel-opok "${SSH_ONE_RAW_BASE}/contohinfo/info-tsel-opok.sh"

chmod +x info-cek-tersedia
chmod +x info-contoh-payload
chmod +x info-contohws
chmod +x info-exra-unli
chmod +x info-tsel-opok
chmod +x info-status-respon

