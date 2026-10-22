#!/usr/bin/env bash
set -Ee -o pipefail
export LC_ALL=C
umask 022

fail() {
  printf 'SSTP setup: %s\n' "$*" >&2
  exit 1
}
trap 'printf "SSTP setup failed at line %s (exit %s): %s\n" "$LINENO" "$?" "$BASH_COMMAND" >&2' ERR

SSH_ONE_REPO_CONFIG=${SSH_ONE_REPO_CONFIG:-/etc/ssh-one/repository.conf}
[[ -r $SSH_ONE_REPO_CONFIG ]] || fail "repository configuration is missing: $SSH_ONE_REPO_CONFIG"
# shellcheck source=/etc/ssh-one/repository.conf
. "$SSH_ONE_REPO_CONFIG"
: "${SSH_ONE_RAW_HOST:?SSH_ONE_RAW_HOST is missing from the repository configuration}"
sstp_raw_base="${SSH_ONE_RAW_HOST%/}/sstp"

MYIP=$(curl --ipv4 --fail --silent --show-error --connect-timeout 10 --max-time 20 https://api.ipify.org) \
  || fail 'could not detect this VPS public IPv4 address.'
[[ $MYIP =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || fail 'public IP lookup returned an invalid IPv4 address.'
[[ -r /etc/os-release ]] || fail 'cannot identify this Linux distribution.'
. /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
  ubuntu:18.04) yoi=Ubuntu18 ;;
  ubuntu:20.04) yoi=Ubuntu20 ;;
  debian:9|debian:9.*) yoi=Debian9 ;;
  debian:10|debian:10.*) yoi=Debian10 ;;
  *) fail "SSTP build does not support ${PRETTY_NAME:-${ID:-unknown} ${VERSION_ID:-unknown}}." ;;
esac

install -d -m 0755 /home/sstp /var/lib/crot
touch /home/sstp/sstp_account /var/lib/crot/data-user-sstp

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y build-essential cmake git libpcre2-dev libssl-dev liblua5.1-0-dev ppp curl wget iptables iptables-persistent

source_dir=/opt/accel-ppp-code
build_dir="$source_dir/build"
if [[ -d $source_dir/.git ]]; then
  printf 'Reusing the existing Accel-PPP source checkout.\n'
elif [[ -e $source_dir ]]; then
  fail "$source_dir exists but is not an Accel-PPP Git checkout; preserve or inspect it before retrying."
else
  git clone https://github.com/accel-ppp/accel-ppp.git "$source_dir" || fail 'could not clone the official Accel-PPP source.'
fi
mkdir -p "$build_dir"
cmake -S "$source_dir" -B "$build_dir" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DLUA=TRUE \
  -DCPACK_TYPE="$yoi" \
  -DBUILD_IPOE_DRIVER=FALSE \
  -DBUILD_VLAN_MON_DRIVER=FALSE || fail 'Accel-PPP configuration failed; see the CMake error above.'
cmake --build "$build_dir" --parallel "$(nproc)" || fail 'Accel-PPP compilation failed.'
(cd "$build_dir" && cpack -G DEB) || fail 'Accel-PPP Debian package creation failed.'

shopt -s nullglob
packages=("$build_dir"/accel-ppp*.deb)
if (( ${#packages[@]} != 1 )); then
  fail "expected one Accel-PPP .deb package, found ${#packages[@]}."
fi

# Keep valid credentials when recovering a partially completed installation.
cert_files=(/home/sstp/ca.key /home/sstp/ca.crt /home/sstp/server.key /home/sstp/server.crt)
certificates_ready=1
for cert_file in "${cert_files[@]}"; do
  [[ -s $cert_file ]] || certificates_ready=0
done
cert_work=''
cleanup_sstp() {
  [[ -z $cert_work ]] || rm -rf -- "$cert_work"
}
trap cleanup_sstp EXIT
if (( certificates_ready == 0 )); then
  cert_work=$(mktemp -d /home/sstp/.ssh-one-certificates.XXXXXX) || fail 'could not create a temporary certificate directory.'
  openssl genrsa -out "$cert_work/ca.key" 4096
  openssl req -new -x509 -sha256 -days 3650 -key "$cert_work/ca.key" -out "$cert_work/ca.crt" \
    -subj '/C=MY/ST=Kuala_Lumpur/L=Kuala_Lumpur/O=SSH-one/OU=VPN/CN=SSH-one SSTP CA/emailAddress=admin@localhost'
  openssl genrsa -out "$cert_work/server.key" 4096
  openssl req -new -key "$cert_work/server.key" -out "$cert_work/server.csr" \
    -subj '/C=MY/ST=Kuala_Lumpur/L=Kuala_Lumpur/O=SSH-one/OU=VPN/CN=SSH-one SSTP Server/emailAddress=admin@localhost'
  openssl x509 -req -sha256 -days 3650 -in "$cert_work/server.csr" -CA "$cert_work/ca.crt" \
    -CAkey "$cert_work/ca.key" -set_serial 01 -out "$cert_work/server.crt"
  install -o root -g root -m 0600 "$cert_work/ca.key" /home/sstp/ca.key
  install -o root -g root -m 0644 "$cert_work/ca.crt" /home/sstp/ca.crt
  install -o root -g root -m 0600 "$cert_work/server.key" /home/sstp/server.key
  install -o root -g root -m 0644 "$cert_work/server.crt" /home/sstp/server.crt
fi

config_tmp=$(mktemp /etc/.accel-ppp.conf.ssh-one.XXXXXX) || fail 'could not stage the Accel-PPP configuration.'
if ! wget --tries=3 --timeout=30 -q -O "$config_tmp" "$sstp_raw_base/accel.conf"; then
  rm -f -- "$config_tmp"
  fail "could not download $sstp_raw_base/accel.conf."
fi
sed -i "s/xxxxxxxxx/${MYIP}/g" "$config_tmp"
grep -Fqx "gw-ip-address=$MYIP" "$config_tmp" || { rm -f -- "$config_tmp"; fail 'the downloaded Accel-PPP config did not receive the VPS IPv4 address.'; }
grep -Fq 'ssl-pemfile=/home/sstp/server.crt' "$config_tmp" || { rm -f -- "$config_tmp"; fail 'the downloaded Accel-PPP config does not reference the SSTP certificate.'; }
chmod 0644 "$config_tmp"
mv -fT -- "$config_tmp" /etc/accel-ppp.conf

install -d -m 0755 /home/vps/public_html
install -m 0644 /home/sstp/server.crt /home/vps/public_html/server.crt

iptables -C INPUT -m state --state NEW -m tcp -p tcp --dport 444 -j ACCEPT >/dev/null 2>&1 || \
  iptables -I INPUT -m state --state NEW -m tcp -p tcp --dport 444 -j ACCEPT
iptables-save > /etc/iptables.up.rules
iptables-restore -t < /etc/iptables.up.rules
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save
fi

if ! dpkg -i "${packages[0]}"; then
  apt-get install -f -y || fail 'could not resolve Accel-PPP package dependencies.'
  dpkg -i "${packages[0]}" || fail 'could not install the Accel-PPP Debian package.'
fi
systemctl daemon-reload
if ! systemctl enable accel-ppp.service || ! systemctl restart accel-ppp.service; then
  systemctl --no-pager --full status accel-ppp.service >&2 || true
  journalctl -u accel-ppp.service -n 40 --no-pager >&2 || true
  fail 'Accel-PPP could not be enabled or started; inspect the service status and journal above.'
fi

sstp_ready=0
attempt=0
while (( attempt < 50 )); do
  ((attempt += 1))
  if ss -H -ltn | awk '$4 ~ /:444$/ { found=1 } END { exit !found }'; then
    sstp_ready=1
    break
  fi
  if ! systemctl is-active --quiet accel-ppp.service; then
    break
  fi
  sleep 0.2
done
if (( sstp_ready == 0 )); then
  systemctl --no-pager --full status accel-ppp.service >&2 || true
  journalctl -u accel-ppp.service -n 40 --no-pager >&2 || true
  ss -H -ltnp >&2 || true
  fail 'Accel-PPP is active but SSTP is not listening on TCP port 444.'
fi

for command_name in addsstp delsstp ceksstp renewsstp; do
  command_tmp=$(mktemp "/usr/bin/.${command_name}.XXXXXX") || fail "could not stage ${command_name}."
  if ! wget --tries=3 --timeout=30 -q -O "$command_tmp" "$sstp_raw_base/${command_name}.sh"; then
    rm -f -- "$command_tmp"
    fail "could not download ${command_name} from the configured GitHub branch."
  fi
  chmod 0755 "$command_tmp"
  mv -fT -- "$command_tmp" "/usr/bin/${command_name}"
done

printf 'SSTP is installed and Accel-PPP is listening on TCP port 444.\n'
