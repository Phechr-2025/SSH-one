# SSH-one API v1

English API guide for SSH-one v26. Thai version: [API_GUIDE_TH.md](API_GUIDE_TH.md).

## What the API can do

The API can read VPS information and manage accounts for SSH, UDP Custom, Xray VMess, Xray VLESS, Xray Trojan, and Trojan-Go. It supports account creation, listing, reading a single account, changing expiry, and deletion. It also returns available credentials, expiry, host, listener port, and connection payloads where the service supports them.

The API does not expose every SSH-one menu action. See [Scope and limitations](#scope-and-limitations).

## Security and connection model

The API listens only on <code>127.0.0.1:8765</code>. Keep it on loopback; do not expose port 8765 to the public internet. A client first authenticates to the VPS over SSH with the VPS IP and an SSH password or private key. It then forwards the local API port through an SSH tunnel and includes an API bearer token on each HTTP request.

Open a tunnel from the backend machine:

~~~~bash
ssh -N -L 8765:127.0.0.1:8765 root@VPS_IP
~~~~

With a private key:

~~~~bash
ssh -i ~/.ssh/id_ed25519 -N -L 8765:127.0.0.1:8765 root@VPS_IP
~~~~

To force password authentication:

~~~~bash
ssh -o PubkeyAuthentication=no -N -L 8765:127.0.0.1:8765 root@VPS_IP
~~~~

Keep the tunnel process running while making API calls to <code>http://127.0.0.1:8765</code>. SSH credentials authorize the tunnel; the API token authorizes each API request. Do not put an SSH password, private key, or API token in a browser, mobile client, public repository, or customer-visible page. Keep them on a trusted backend and load them from a secret store or protected environment configuration.

## Create, list, and revoke API tokens

On the VPS, open <code>menu</code>, select <code>27. API token management</code>, then:

1. Choose <code>1. Create token</code>.
2. Enter a unique name (1–64 characters; letters, digits, underscore, dot, space, and hyphen are accepted; the first character must be a letter or digit).
3. Enter an expiry from 1 to 3650 days. Press Enter for the default of 30 days.
4. Copy the token and deliver it to the backend operator through a secure channel.

Choose <code>2. List tokens</code> to see each token name, full token value, expiry, and active/expired state. Choose <code>3. Delete token</code>, then enter its name or exact token value to revoke it. Expired tokens are rejected even if they remain visible in the list. Revoke a token immediately if it is exposed or no longer needed.

All tokens have the same full API permissions. There are no per-token service scopes or read-only tokens in v26. Use separate tokens per integration for simpler revocation, and treat token-list output as secret data. Token records are stored at <code>/etc/ssh-one/api-tokens.json</code> with root-only permissions (<code>0600</code>).

## Request format and account rules

- Base URL through the tunnel: <code>http://127.0.0.1:8765/api/v1</code>.
- Every request must include <code>Authorization: Bearer YOUR_TOKEN</code>.
- Requests with a JSON body must include <code>Content-Type: application/json</code>. Body size must be 1–65,536 bytes.
- For account creation, <code>days</code> is an integer from 1 to 3650 and defaults to 30 when omitted. Expiry is calculated from the request time. SSH, Xray, and Trojan-Go expiry uses the date-based format used by the existing scripts; UDP Custom stores an exact timestamp. Responses show the VPS timezone.
- SSH and UDP usernames must be 1–32 characters, start with a letter or digit, and contain only letters, digits, dot, underscore, or hyphen.
- VMess, VLESS, Trojan, and Trojan-Go usernames must be 1–64 characters and contain only letters, digits, or underscore.
- Passwords must be 1–256 characters and cannot contain a colon, newline, carriage return, or NUL. VMess/VLESS IDs must also match the Xray UUID-like format accepted by the API. Trojan-Go uses the username as its password and does not accept a separate password.
- UDP account creation requires UDP Custom to be installed.
- Duplicate usernames and usernames already present as Linux users are rejected.

SSH and UDP Linux password hashes cannot be reversed. Passwords for SSH/UDP accounts created through the API are therefore also stored in <code>/etc/ssh-one/api-secrets.json</code> so the API can return them; the file is root-only (<code>0600</code>). For an existing account created outside the API, the API returns <code>"password": null</code> and <code>"password_available": false</code>. Xray credentials are read from the service configuration. Trojan-Go follows the upstream service format and uses the username as the password.

API responses can include passwords, bearer tokens, payloads, and connection links. Do not save full responses in access logs or expose them to other customers. The API returns <code>Cache-Control: no-store</code>, but the consuming backend must still protect its own logs, database, backups, and support tools.

## Endpoints

Every endpoint requires authentication.

| Method | Path | Purpose |
| --- | --- | --- |
| <code>GET</code> | <code>/api/v1/health</code> | Check API availability and version |
| <code>GET</code> | <code>/api/v1/system</code> | Read OS, kernel, uptime, memory, host, CPU core count, and main ports |
| <code>GET</code> | <code>/api/v1/accounts</code> | List accounts for all supported services |
| <code>GET</code> | <code>/api/v1/accounts?service=ssh</code> | List accounts for one service |
| <code>GET</code> | <code>/api/v1/accounts/{service}/{username}</code> | Read one account |
| <code>POST</code> | <code>/api/v1/accounts/{service}</code> | Create an account |
| <code>PATCH</code> | <code>/api/v1/accounts/{service}/{username}</code> | Set a new expiry from the current time |
| <code>DELETE</code> | <code>/api/v1/accounts/{service}/{username}</code> | Delete an account |

Supported service names are <code>ssh</code>, <code>udp</code>, <code>vmess</code>, <code>vless</code>, <code>trojan</code>, and <code>trojan-go</code>.

A successful account response is usually wrapped as <code>{"account": ...}</code>. Account fields include <code>service</code>, <code>username</code>, <code>password</code>, <code>password_available</code>, and <code>expires_at</code>. SSH accounts can include WebSocket payloads; UDP accounts include <code>listener_port</code>; Xray and Trojan-Go accounts include <code>host</code> and service-specific links/payloads. The exact fields depend on the service and installed configuration.

Example UDP account response:

~~~~json
{
  "account": {
    "service": "udp",
    "username": "udp01",
    "password": "Use-A-Unique-Secret",
    "password_available": true,
    "expires_at": "2026-11-04T12:00:00+07:00",
    "listener_port": 36712
  }
}
~~~~

## Examples

Replace <code>YOUR_TOKEN</code> with a token created from menu 27. These commands assume the SSH tunnel is already running.

### Check API health

~~~~bash
curl -sS http://127.0.0.1:8765/api/v1/health -H 'Authorization: Bearer YOUR_TOKEN'
~~~~

Expected response:

~~~~json
{"ok":true,"version":"v26"}
~~~~

### Read VPS information and ports

~~~~bash
curl -sS http://127.0.0.1:8765/api/v1/system -H 'Authorization: Bearer YOUR_TOKEN'
~~~~

### List accounts

List accounts for every supported service:

~~~~bash
curl -sS http://127.0.0.1:8765/api/v1/accounts -H 'Authorization: Bearer YOUR_TOKEN'
~~~~

Filter by service:

~~~~bash
curl -sS 'http://127.0.0.1:8765/api/v1/accounts?service=ssh' -H 'Authorization: Bearer YOUR_TOKEN'
~~~~

### Create an SSH account

~~~~bash
curl -sS -X POST http://127.0.0.1:8765/api/v1/accounts/ssh -H 'Authorization: Bearer YOUR_TOKEN' -H 'Content-Type: application/json' --data '{"username":"customer01","password":"Use-A-Unique-Secret","days":30}'
~~~~

The response contains the account credentials, expiry, and SSH WebSocket payloads.

### Create a UDP Custom account

~~~~bash
curl -sS -X POST http://127.0.0.1:8765/api/v1/accounts/udp -H 'Authorization: Bearer YOUR_TOKEN' -H 'Content-Type: application/json' --data '{"username":"udp01","password":"Use-A-Unique-Secret","days":14}'
~~~~

UDP Custom must already be installed. The account uses the listener port configured on the VPS.

### Create a VMess, VLESS, or Trojan account

The API generates a credential if <code>password</code> is omitted. VMess and VLESS credentials must be valid Xray IDs; if supplying one, use a UUID-form ID accepted by Xray. The response includes links for the service's configured TLS and non-TLS transports.

~~~~bash
curl -sS -X POST http://127.0.0.1:8765/api/v1/accounts/vmess -H 'Authorization: Bearer YOUR_TOKEN' -H 'Content-Type: application/json' --data '{"username":"customer02","days":30}'
~~~~

Use <code>/vless</code> or <code>/trojan</code> in the path to create those account types.

### Create a Trojan-Go account

~~~~bash
curl -sS -X POST http://127.0.0.1:8765/api/v1/accounts/trojan-go -H 'Authorization: Bearer YOUR_TOKEN' -H 'Content-Type: application/json' --data '{"username":"customer03","days":30}'
~~~~

Trojan-Go uses the username as the password, matching the existing service format.

### Read one account

~~~~bash
curl -sS http://127.0.0.1:8765/api/v1/accounts/ssh/customer01 -H 'Authorization: Bearer YOUR_TOKEN'
~~~~

### Change expiry

The requested number of days starts from the time the PATCH request is handled. It does not add days to the current expiry.

~~~~bash
curl -sS -X PATCH http://127.0.0.1:8765/api/v1/accounts/ssh/customer01 -H 'Authorization: Bearer YOUR_TOKEN' -H 'Content-Type: application/json' --data '{"days":45}'
~~~~

### Delete an account

~~~~bash
curl -sS -X DELETE http://127.0.0.1:8765/api/v1/accounts/ssh/customer01 -H 'Authorization: Bearer YOUR_TOKEN'
~~~~

## Python backend example

This example assumes the SSH tunnel is active on the backend host. Keep the token in a secret manager or protected environment variable; do not commit it to source control.

~~~~python
import os
import requests

API = "http://127.0.0.1:8765/api/v1"
HEADERS = {"Authorization": "Bearer " + os.environ["SSH_ONE_API_TOKEN"]}

response = requests.post(
    API + "/accounts/udp",
    headers={**HEADERS, "Content-Type": "application/json"},
    json={"username": "udp01", "password": "Use-A-Unique-Secret", "days": 30},
    timeout=15,
)
response.raise_for_status()
account = response.json()["account"]
print(account["username"], account["expires_at"], account["listener_port"])
~~~~

## HTTP status codes and troubleshooting

Error responses use JSON, for example <code>{"error":"..."}</code>.

| Status | Meaning |
| --- | --- |
| <code>200</code> | Read, update, or delete completed |
| <code>201</code> | Account created |
| <code>400</code> | Invalid service, username, days, JSON, or request |
| <code>401</code> | Token missing, invalid, or expired |
| <code>404</code> | Route or account not found |
| <code>405</code> | HTTP method not allowed for the route |
| <code>409</code> | Duplicate username, service not installed, or service data is unavailable |
| <code>415</code> | Request body is not <code>application/json</code> |
| <code>500</code> | System command or configuration operation failed; inspect the service journal |

Check the API service on the VPS:

~~~~bash
systemctl status ssh-one-api.service --no-pager
journalctl -u ssh-one-api.service -n 100 --no-pager
ss -lntp | grep ':8765'
~~~~

The listener should be <code>127.0.0.1:8765</code>. If it is missing, run <code>ssh-one-api --install-service</code> as root and inspect the journal. If the API returns 500, the response points to the service journal; do not repeatedly retry account creation until checking whether the prior operation changed service state.

## Scope and limitations

API v1 supports system/port information and account operations for SSH, UDP Custom, Xray VMess, Xray VLESS, Xray Trojan, and Trojan-Go. The API can return account password values when they are available, expiry, host, listener port, and connection payload/link information.

There are no v26 API endpoints for L2TP, PPTP, SSTP, WireGuard, Shadowsocks, ShadowsocksR, firewall, DNS/Cloudflare, update, reboot, uninstall, arbitrary shell commands, or other system-wide menu operations. Manage those through the existing menu or SSH. The API intentionally does not provide a general root shell endpoint.

The current UDP Custom service does not provide a reliable per-username online session list, so the API cannot report which UDP account is currently connected. It returns the account and listener information only.