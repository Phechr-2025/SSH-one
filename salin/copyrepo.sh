#!/bin/bash

SSH_ONE_REPO_CONFIG=${SSH_ONE_REPO_CONFIG:-/etc/ssh-one/repository.conf}
if [ -r "$SSH_ONE_REPO_CONFIG" ]; then . "$SSH_ONE_REPO_CONFIG"; fi

cd
sudo apt update -y
apt update -y
sudo apt install git -y
apt install git -y
cd
cd /root/
git clone ${SSH_ONE_REPO_URL}

cd
