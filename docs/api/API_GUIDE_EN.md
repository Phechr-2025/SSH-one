# SSH-one API v1

Languages: [English](API_GUIDE_EN.md) | [ไทย](API_GUIDE_TH.md)

## Contents

- [What the API can do](#what-the-api-can-do)
- [Security and connection model](#security-and-connection-model)
- [Install and check the API service](#install-and-check-the-api-service)
- [Create, list, and revoke tokens](#create-list-and-revoke-api-tokens)
- [Request format and account rules](#request-format-and-account-rules)
- [Endpoints](#endpoints)
- [Examples](#examples)
- [HTTP status and troubleshooting](#http-status-codes-and-troubleshooting)
- [Response fields and schemas](#response-fields-and-schemas)
- [Account behavior and expiry](#create-payloads-and-operation-side-effects)
- [Production integration notes](#production-integration-notes)
- [Scope and limitations](#scope-and-limitations)

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

## Install and check the API service

A fresh v30 installation and the v30 updater install and enable <code>ssh-one-api.service</code>. The daemon runs as root and listens only on <code>127.0.0.1:8765</code>; do not open this port in UFW or the provider firewall.

~~~~bash
systemctl is-active ssh-one-api.service
systemctl status ssh-one-api.service --no-pager
ss -lntp | grep ':8765'
~~~~

The listener should be <code>127.0.0.1:8765</code> only. If the API command is installed but the unit is missing, run <code>ssh-one-api --install-service</code> as root. If the port is already occupied, inspect the process using it with <code>ss</code> before starting the service. Re-running the installer command enables and starts the SSH-one-managed unit.

## Create, list, and revoke API tokens

On the VPS, open <code>menu</code>, select <code>27. API token management</code>, then:

1. Choose <code>1. Create token</code>.
2. Enter a unique name (1–64 characters; letters, digits, underscore, dot, space, and hyphen are accepted; the first character must be a letter or digit).
3. Enter an expiry from 1 to 3650 days. Press Enter for the default of 30 days.
4. Copy the token and deliver it to the backend operator through a secure channel.

Choose <code>2. List tokens</code> to see each token name, full token value, expiry, and active/expired state. Choose <code>3. Delete token</code>, then enter its name or exact token value to revoke it. Expired tokens are rejected even if they remain visible in the list. Revoke a token immediately if it is exposed or no longer needed.

The daemon runs as root, so every token can manage every supported account. There are no per-token scopes or read-only tokens in v30. Treat a token like administrator access. Use separate tokens per integration for simpler revocation, and treat token-list output as secret data. Token records are stored at <code>/etc/ssh-one/api-tokens.json</code> with root-only permissions (<code>0600</code>).

## Request format and account rules

- Base URL through the tunnel: <code>http://127.0.0.1:8765/api/v1</code>.
- Every request must include <code>Authorization: Bearer YOUR_TOKEN</code>.
- Requests with a JSON body must include <code>Content-Type: application/json</code>. Body size must be 1–65,536 bytes.
- For account creation, <code>days</code> is an integer from 1 to 3650 and defaults to 30 when omitted. Expiry is calculated from the request time. SSH, Xray, and Trojan-Go expiry uses the date-based format used by the existing scripts; UDP Custom stores an exact timestamp. Responses show the VPS timezone.
- SSH and UDP usernames must be 1–32 characters, start with a letter or digit, and contain only letters, digits, dot, underscore, or hyphen.
- VMess, VLESS, Trojan, and Trojan-Go usernames must be 1–64 characters and contain only letters, digits, or underscore.
- Passwords must be 1–256 characters and cannot contain a colon, newline, carriage return, or NUL. VMess/VLESS credentials must match the API check: 16–64 hexadecimal or hyphen characters. Use a standard UUID for Xray compatibility. Trojan-Go uses the username as its password and does not accept a separate password.
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
{"ok":true,"version":"v30"}
~~~~

### Read VPS information and ports

~~~~bash
curl -sS http://127.0.0.1:8765/api/v1/system -H 'Authorization: Bearer YOUR_TOKEN'
~~~~

Example <code>/system</code> response:

~~~~json
{
  "os": "Ubuntu 20.04.6 LTS",
  "kernel": "5.4.0-example",
  "uptime_seconds": 3600.5,
  "cpu_cores": 2,
  "memory_mb": {"total": 4096, "available": 3590},
  "host": "ssh1.example.com",
  "api_bind": "127.0.0.1",
  "api_port": 8765,
  "supported_services": ["ssh", "udp", "vmess", "vless", "trojan", "trojan-go"],
  "ports": {
    "ssh_tcp": [22, 2253, 42],
    "udp_custom_range": [1, 65535],
    "udp_custom_listener": 36712,
    "vmess_tls": 8443,
    "vmess_plain": 80,
    "vless_tls": 8444,
    "vless_plain": 81,
    "trojan": 2083
  }
}
~~~~

OS, memory, and port values above are illustrative; use the values returned by your VPS.

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

The API generates a credential if <code>password</code> is omitted. VMess and VLESS credentials must pass the API format check (16–64 hexadecimal or hyphen characters). Use a standard UUID for Xray compatibility. The response includes links for the service's configured TLS and non-TLS transports.

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
| <code>500</code> | Internal error; inspect the related service and configuration (request details are not written to the journal) |

Check the API service on the VPS:

~~~~bash
systemctl status ssh-one-api.service --no-pager
journalctl -u ssh-one-api.service -n 100 --no-pager
ss -lntp | grep ':8765'
~~~~

The listener should be <code>127.0.0.1:8765</code>. If it is missing, run <code>ssh-one-api --install-service</code> as root and inspect the journal. The API returns a generic 500 and suppresses request-level details; the unit journal may only show service startup output. Check the related service/configuration, and reconcile account state before retrying a timed-out create request.

## Scope and limitations

API v1 supports system/port information and account operations for SSH, UDP Custom, Xray VMess, Xray VLESS, Xray Trojan, and Trojan-Go. The API can return account password values when they are available, expiry, host, listener port, and connection payload/link information.

There are no v30 API endpoints for L2TP, PPTP, SSTP, WireGuard, Shadowsocks, ShadowsocksR, firewall, DNS/Cloudflare, update, reboot, uninstall, arbitrary shell commands, or other system-wide menu operations. Manage those through the existing menu or SSH. The API intentionally does not provide a general root shell endpoint.

The current UDP Custom service does not provide a reliable per-username online session list, so the API cannot report which UDP account is currently connected. It returns the account and listener information only.
## Response fields and schemas

All responses are UTF-8 JSON and include <code>Cache-Control: no-store</code>.

- <code>GET /health</code> returns <code>ok</code> and the API version.
- <code>GET /system</code> returns <code>os</code>, <code>kernel</code>, <code>uptime_seconds</code>, <code>cpu_cores</code>, <code>memory_mb.total</code>, <code>memory_mb.available</code>, <code>host</code>, <code>api_bind</code>, <code>api_port</code>, <code>supported_services</code>, and <code>ports</code>.
- <code>GET /accounts</code> returns <code>accounts</code> and <code>supported_services</code>. Add <code>?service=udp</code> to filter. Valid service values are <code>ssh</code>, <code>udp</code>, <code>vmess</code>, <code>vless</code>, <code>trojan</code>, and <code>trojan-go</code>.
- Read/create/update account responses wrap the record in <code>account</code>. Delete returns <code>deleted</code>, <code>service</code>, and <code>username</code>.

Service-specific account fields:

| Service | Additional fields |
| --- | --- |
| SSH | <code>payloads.websocket_tls</code>, <code>payloads.websocket_http</code> |
| UDP Custom | <code>listener_port</code> |
| VMess | <code>host</code>, <code>payloads.tls</code>, <code>payloads.non_tls</code> |
| VLESS | <code>host</code>, <code>payloads.tls</code>, <code>payloads.non_tls</code> |
| Trojan | <code>host</code>, <code>payloads.link</code> |
| Trojan-Go | <code>host</code>, <code>payloads.link</code> |

<code>password_available</code> tells whether the API can return a password; otherwise <code>password</code> is <code>null</code>. <code>expires_at</code> is a date or timestamp depending on the service, and can be <code>null</code> for legacy accounts without recorded expiry metadata. <code>host</code> can be <code>null</code> if no host/domain file is available.

The system endpoint reports CPU core count, not CPU percentage or load average. It does not return bandwidth usage, connected UDP usernames, or a complete list of every service port. Values under <code>ports</code> are configured/default values; they do not prove a firewall rule exists or that a service is listening.

## Create payloads and operation side effects

| Service | POST JSON fields | Important behavior |
| --- | --- | --- |
| <code>ssh</code> | <code>username</code>, <code>password</code>, optional <code>days</code> | Creates a Linux user in the SSH-one account group |
| <code>udp</code> | <code>username</code>, <code>password</code>, optional <code>days</code> | Requires UDP Custom; records expiry as a timestamp |
| <code>vmess</code>, <code>vless</code> | <code>username</code>, optional <code>password</code>, optional <code>days</code> | Generates an ID when omitted; edits config and restarts <code>xray.service</code> |
| <code>trojan</code> | <code>username</code>, optional <code>password</code>, optional <code>days</code> | Generates a password when omitted; edits config and restarts <code>xray.service</code> |
| <code>trojan-go</code> | <code>username</code>, optional <code>password</code> (must equal username), optional <code>days</code> | Username is the password; edits config and restarts <code>trojan-go.service</code> |

SSH/UDP account creation uses Linux users. Deleting either stops processes owned by that account and removes the user. Xray and Trojan-Go create/update/delete operations rewrite service configuration and restart the relevant service, which can briefly interrupt active connections. On a configuration or restart failure the API attempts to restore the previous config; keep a backup before using a sales system in production.

<code>PATCH</code> changes only <code>days</code>; there is no password-change endpoint. <code>DELETE</code> removes the account immediately and the API has no restore operation. Verify the service and username before deleting.

## Expiry and legacy accounts

<code>days</code> must be from 1 to 3650 and starts when the request is handled, but expiry precision varies:

- SSH, VMess, VLESS, Trojan, and Trojan-Go use date-based expiry in the existing scripts. Do not interpret this as an exact 24-hour interval.
- UDP Custom stores an expiry timestamp; its timer checks expired accounts every 15 seconds.
- <code>PATCH {"days":N}</code> resets expiry from the current time; it does not add N days to the previous expiry.
- Legacy UDP accounts without expiry metadata return <code>expires_at: null</code>. Passwords for SSH/UDP accounts created outside the API cannot be recovered from Linux password hashes.

## Production integration notes

- Account lists are not paginated and can contain passwords, links, and payloads. Avoid exposing a full list response to an individual customer.
- There is no idempotency key, rate limit, per-token permission scope, or HTTP token-management endpoint. After a timed-out POST, read the account list before retrying to avoid creating duplicates.
- The token list displays full token values, including expired entries. Restrict access to menu 27.
- HTTP request/access logs and request details are not written by the API. A 500 response is generic and does not include a traceback or password.
- The API does not enable browser CORS or provide HTTPS; call it from a trusted backend through SSH, or from localhost on the VPS.
- Verify the VPS SSH host key when creating a tunnel; do not permanently disable host-key checking to work around connection errors.
- If local port 8765 is occupied, map another local port, for example <code>ssh -N -L 18765:127.0.0.1:8765 root@VPS_IP</code>, and use <code>http://127.0.0.1:18765</code>. The VPS-side API port remains 8765.

Create/list/revoke tokens on the VPS using menu option <code>27</code>; there are no HTTP token-administration endpoints.
