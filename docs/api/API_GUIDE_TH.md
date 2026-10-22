# SSH-one API v1

ภาษา: [ไทย](API_GUIDE_TH.md) | [English](API_GUIDE_EN.md)

## สารบัญ

- [รูปแบบการเชื่อมต่อ](#รูปแบบการเชื่อมต่อ)
- [ติดตั้งและตรวจบริการ API](#ติดตั้งและตรวจบริการ-api)
- [เริ่มใช้งานและจัดการ token](#เริ่มใช้งาน)
- [ข้อกำหนด request และความปลอดภัย](#authentication-และข้อกำหนด-request)
- [รายการ endpoint](#endpoints)
- [ตัวอย่างเรียกใช้งาน](#ตรวจสถานะ-api)
- [HTTP status และการแก้ปัญหา](#http-status-และการแก้ปัญหา)
- [โครงสร้าง response](#รายละเอียดข้อมูลที่ส่งกลับ)
- [พฤติกรรมของบริการและวันหมดอายุ](#รูปแบบสร้างบัญชีและผลของคำสั่ง)
- [ข้อควรรู้สำหรับระบบขาย](#ข้อควรรู้สำหรับระบบขาย)
- [ขอบเขต API](#ขอบเขตของ-v31)

## รูปแบบการเชื่อมต่อ

API ฟังเฉพาะ `127.0.0.1:8765` ภายใน VPS จึงไม่ต้องเปิดพอร์ต 8765 ใน firewall และไม่ควรแก้ให้ API ฟังบน IP สาธารณะ ให้ระบบผู้เรียกเชื่อม VPS ด้วย SSH โดยใช้ IP ของ VPS และรหัสผ่านหรือ SSH key จากนั้นเปิด SSH tunnel แล้วส่ง API token ในทุกคำขอ

```bash
ssh -N -L 8765:127.0.0.1:8765 root@VPS_IP
```

ใช้ SSH key:

```bash
ssh -i ~/.ssh/id_ed25519 -N -L 8765:127.0.0.1:8765 root@VPS_IP
```

หรือให้ SSH ถามรหัสผ่าน:

```bash
ssh -o PubkeyAuthentication=no -N -L 8765:127.0.0.1:8765 root@VPS_IP
```

ปล่อยหน้าต่าง tunnel ทำงานไว้ แล้วเรียก `http://127.0.0.1:8765` จากเครื่องหรือ backend ที่เปิด tunnel นี้ คำสั่ง SSH จะตรวจรหัสผ่านหรือ key ส่วน API จะตรวจ token อีกชั้นหนึ่ง อย่าฝังรหัสผ่าน SSH หรือ API token ไว้ในหน้าเว็บฝั่งผู้ใช้ ให้ backend เก็บ secret ในระบบจัดการความลับของตน

ระบบขายที่ทำงานบนเซิร์ฟเวอร์อื่นสามารถเปิด SSH tunnel จาก backend ด้วย SSH library แล้วเรียก API ผ่าน tunnel นั้นได้ ห้ามนำ SSH password, private key หรือ API token ไปส่งให้ browser/app ของลูกค้า

## ติดตั้งและตรวจบริการ API

การติดตั้ง v31 และตัวอัปเดตจะติดตั้ง/เปิด <code>ssh-one-api.service</code> อัตโนมัติ บริการทำงานเป็น root และฟังเฉพาะ <code>127.0.0.1:8765</code>; ไม่ต้องเปิดพอร์ตนี้ใน UFW หรือ firewall ของผู้ให้บริการ

~~~~bash
systemctl is-active ssh-one-api.service
systemctl status ssh-one-api.service --no-pager
ss -lntp | grep ':8765'
~~~~

ควรเห็น listener ที่ <code>127.0.0.1:8765</code> เท่านั้น หากติดตั้งตัวคำสั่ง API แล้วแต่ยังไม่มี unit ให้เรียก <code>ssh-one-api --install-service</code> ในฐานะ root; ถ้าพอร์ตถูกใช้อยู่ service จะเริ่มไม่ได้ ให้ตรวจ process ที่ใช้พอร์ตด้วย <code>ss</code> ก่อน การเรียกคำสั่งติดตั้ง service ซ้ำจะ enable และ start unit เดิมที่ SSH-one ดูแล

## เริ่มใช้งาน

1. อัปเดต VPS เป็น v31 แล้วเปิดเมนูด้วย `menu`.
2. เลือก `27. API token management` แล้วเลือก `1. Create token`.
3. ใส่ชื่อ token ยาว 1–64 ตัว (ขึ้นต้นด้วยตัวอักษรหรือตัวเลข ใช้ตัวอักษร ตัวเลข จุด ขีดล่าง เว้นวรรค และขีดกลางได้) แล้วใส่อายุ 1–3650 วัน; เว้นว่างใช้อายุเริ่มต้น 30 วัน.
4. เก็บ token ที่แสดงไว้อย่างปลอดภัย รายการ token จะแสดง token เต็มรวมถึงรายการที่หมดอายุแล้ว จึงจำกัด SSH/root access ให้เฉพาะผู้ดูแลและลบ token ที่ไม่ใช้งาน
5. เปิด SSH tunnel และแนบ token ใน header `Authorization: Bearer ...` ทุก request

รายการ token ที่หมดอายุจะถูกปฏิเสธทันที แม้ยังอยู่ในไฟล์รายการ การลบ token มีผลกับ request ถัดไป เมื่อ token รั่ว ให้ใช้เมนู 27 ลบ token นั้นและสร้างใหม่

## Authentication และข้อกำหนด request

- API ต้องเรียกจาก tunnel ที่เปิดไปยัง VPS และต้องส่ง `Authorization: Bearer <TOKEN>`.
- API ใช้ JSON; request ที่มี body ต้องส่ง `Content-Type: application/json`.
- body รับได้สูงสุด 65,536 bytes.
- อายุบัญชีรับ `days` เป็นจำนวนเต็ม 1–3650; หากไม่ระบุในคำขอสร้างบัญชี ใช้ 30 วัน SSH/Xray/Trojan-Go ใช้วันหมดอายุแบบวันที่ตามระบบเดิม ส่วน UDP Custom ใช้เวลาหมดอายุเป็น timestamp.
- ชื่อบัญชี SSH/UDP ยาว 1–32 ตัว: ตัวอักษร/ตัวเลขจุด `_` `-` และต้องขึ้นต้นด้วยตัวอักษรหรือตัวเลข.
- ชื่อ VMess/VLESS/Trojan ยาว 1–64 ตัว: ตัวอักษร/ตัวเลขและ `_`.
- Password ยาว 1–256 ตัว ห้ามมี `:` หรือขึ้นบรรทัดใหม่ เพราะข้อมูลต้องส่งให้ระบบบัญชี Linux ได้อย่างปลอดภัย.
- Password ที่สร้างผ่าน API สำหรับ SSH และ UDP ถูกเก็บใน `/etc/ssh-one/api-secrets.json` ซึ่งมีสิทธิ์ root เท่านั้น (`0600`) เพื่อให้ API อ่านคืนได้ ระบบปฏิบัติการ Linux เก็บ password ปกติเป็น hash จึงอ่าน password เดิมของบัญชีที่สร้างนอก API กลับไม่ได้; API จะแสดง `password: null` และ `password_available: false` สำหรับบัญชีเหล่านั้น
- token เต็มถูกเก็บใน `/etc/ssh-one/api-tokens.json` สิทธิ์ root เท่านั้น (`0600`) เพื่อให้เมนูแสดง token ตามที่ร้องขอ สำรองไฟล์นี้อย่างระมัดระวังและป้องกัน backup เช่นเดียวกับ token จริง
- ตัว API ทำงานด้วยสิทธิ์ root; token ทุกตัวจึงเข้าถึงข้อมูลและจัดการบัญชีทุกบริการที่รองรับ ไม่มีการแยก scope หรือ read-only token ให้ถือว่า token มีอำนาจระดับผู้ดูแล สร้าง token แยกต่อระบบและลบทันทีเมื่อเลิกใช้
- Token และ password ที่แสดงจาก API เป็นข้อมูลลับ ห้ามบันทึก request/response เต็มลง access log หรือส่งต่อให้ลูกค้าอื่น

## Endpoints

เรียกจาก VPS ผ่าน localhost หรือจากเครื่องอื่นผ่าน SSH tunnel; ทุก endpoint ต้องแนบ API token

| Method | Path | การทำงาน |
| --- | --- | --- |
| `GET` | `/api/v1/health` | ตรวจว่า API ตอบสนองและแสดงเวอร์ชัน |
| `GET` | `/api/v1/system` | OS, kernel, uptime, RAM, host, จำนวน core และพอร์ตหลัก |
| `GET` | `/api/v1/accounts` | รายชื่อบัญชีของบริการที่ API รองรับ |
| `GET` | `/api/v1/accounts?service=ssh` | รายชื่อบัญชีของบริการเดียว |
| `GET` | `/api/v1/accounts/{service}/{username}` | รายละเอียดบัญชีหนึ่งรายการ |
| `POST` | `/api/v1/accounts/{service}` | สร้างบัญชี |
| `PATCH` | `/api/v1/accounts/{service}/{username}` | ตั้งวันหมดอายุใหม่ โดยนับจากเวลาที่เรียก |
| `DELETE` | `/api/v1/accounts/{service}/{username}` | ลบบัญชี |

ค่าที่รองรับใน `{service}`: `ssh`, `udp`, `vmess`, `vless`, `trojan`, `trojan-go`.

ผลลัพธ์ของการอ่าน/สร้าง/แก้บัญชีห่ออยู่ใน `account` โดยปกติมี `service`, `username`, `password`, `password_available` และ `expires_at`; บัญชี SSH จะมี `payloads.websocket_tls` กับ `payloads.websocket_http`, บัญชี UDP มี `listener_port`, และบัญชี Xray/Trojan-Go มี `host` กับ `payloads` ซึ่งเป็น link/config ของบริการนั้น ตัวอย่าง:

```json
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
```

วันที่/เวลาใน `expires_at` แสดง timezone ของ VPS ส่วนข้อมูลบัญชีเดิมที่ password อ่านคืนไม่ได้จะมี `password: null` และ `password_available: false`.

### ตรวจสถานะ API

```bash
curl -sS http://127.0.0.1:8765/api/v1/health \
  -H 'Authorization: Bearer YOUR_TOKEN'
```

ผลสำเร็จ:

```json
{"ok":true,"version":"v31"}
```

### ดูข้อมูล VPS และพอร์ต

```bash
curl -sS http://127.0.0.1:8765/api/v1/system \
  -H 'Authorization: Bearer YOUR_TOKEN'
```

ตัวอย่าง response จาก <code>/system</code>:

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

ค่า OS, memory และพอร์ตเป็นตัวอย่าง; ใช้ค่าที่ VPS ตอบกลับจริง

### ดูบัญชีทั้งหมดหรือแยกบริการ

```bash
curl -sS 'http://127.0.0.1:8765/api/v1/accounts?service=ssh' \
  -H 'Authorization: Bearer YOUR_TOKEN'
```

ไม่ใส่ `service` จะคืนบัญชีทุกบริการที่รองรับ ตัวอย่างข้อมูลมีชื่อบัญชี, password (ถ้าอ่านได้), สถานะการอ่าน password, วันหมดอายุ, host, listener และ payload/link ที่เกี่ยวข้อง

### สร้างบัญชี SSH

```bash
curl -sS -X POST http://127.0.0.1:8765/api/v1/accounts/ssh \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Content-Type: application/json' \
  --data '{"username":"customer01","password":"Use-A-Unique-Secret","days":30}'
```

การตอบกลับมี credential ที่ส่งเข้ามา, วันหมดอายุ, host และ WebSocket payload แบบ TLS/HTTP

### สร้างบัญชี UDP Custom

```bash
curl -sS -X POST http://127.0.0.1:8765/api/v1/accounts/udp \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Content-Type: application/json' \
  --data '{"username":"udp01","password":"Use-A-Unique-Secret","days":14}'
```

บัญชี UDP ต้องติดตั้ง UDP Custom ก่อน API จะแจ้ง `409` หากบริการยังไม่มี บัญชีจะใช้ listener port ที่ตั้งอยู่ในเครื่อง

### สร้างบัญชี Xray

```bash
curl -sS -X POST http://127.0.0.1:8765/api/v1/accounts/vmess \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Content-Type: application/json' \
  --data '{"username":"customer02","days":30}'
```

VMess/VLESS จะสร้าง ID ให้อัตโนมัติ หากต้องการระบุ credential เองให้ใส่ `password`; Trojan จะสร้างรหัสผ่านให้อัตโนมัติหรือใช้ค่าที่ส่งมา ผลตอบกลับมี link/config ที่จำเป็นสำหรับเชื่อมต่อ

### สร้างบัญชี Trojan-Go

```bash
curl -sS -X POST http://127.0.0.1:8765/api/v1/accounts/trojan-go \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Content-Type: application/json' \
  --data '{"username":"customer03","days":30}'
```

ตามรูปแบบของบริการเดิม Trojan-Go ใช้ชื่อบัญชีเป็นรหัสผ่านด้วย จึงไม่รับ `password` แยกต่างหาก API จะเพิ่มบัญชีใน config และ restart เฉพาะ `trojan-go.service`

### อ่านบัญชีหนึ่งรายการ

```bash
curl -sS http://127.0.0.1:8765/api/v1/accounts/ssh/customer01 \
  -H 'Authorization: Bearer YOUR_TOKEN'
```

### เปลี่ยนวันหมดอายุ

`days` หมายถึงจำนวนวันจากเวลาที่ส่งคำขอ ไม่ใช่จำนวนวันที่บวกต่อจากวันหมดอายุเดิม

```bash
curl -sS -X PATCH http://127.0.0.1:8765/api/v1/accounts/ssh/customer01 \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Content-Type: application/json' \
  --data '{"days":45}'
```

### ลบบัญชี

```bash
curl -sS -X DELETE http://127.0.0.1:8765/api/v1/accounts/ssh/customer01 \
  -H 'Authorization: Bearer YOUR_TOKEN'
```

## ตัวอย่าง Python สำหรับ backend

ตัวอย่างนี้สมมติว่า backend เปิด SSH tunnel ไว้ที่ `127.0.0.1:8765`; ให้เก็บ token ใน environment/secret store ของ backend และอย่าใส่ token ลง source control:

```python
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
```

## HTTP status และการแก้ปัญหา

| Status | ความหมาย |
| --- | --- |
| `200` | อ่าน/แก้ไข/ลบสำเร็จ |
| `201` | สร้างบัญชีสำเร็จ |
| `400` | service, username, days หรือ JSON ไม่ถูกต้อง |
| `401` | token หาย ผิด หรือหมดอายุ |
| `404` | ไม่พบ endpoint หรือบัญชี |
| `405` | method ไม่รองรับกับ endpoint นี้ |
| `409` | ชื่อซ้ำ, บริการยังไม่ติดตั้ง หรือข้อมูลบริการไม่พร้อม |
| `415` | body ไม่ได้ส่งเป็น `application/json` |
| `500` | เกิดข้อผิดพลาดภายใน; ตรวจสถานะบริการและ config ที่เกี่ยวข้อง (รายละเอียดคำขอไม่ถูกบันทึกใน journal) |

ตรวจ service:

```bash
systemctl status ssh-one-api.service --no-pager
journalctl -u ssh-one-api.service -n 100 --no-pager
ss -lntp | grep ':8765'
```

ผล `ss` ควรแสดง `127.0.0.1:8765` เท่านั้น หากไม่มี listener ให้รัน `ssh-one-api --install-service` ด้วย root แล้วตรวจ journal

## ขอบเขตของ v31

API v1 จัดการบัญชี SSH, UDP Custom, Xray VMess, Xray VLESS, Xray Trojan และ Trojan-Go รวมถึงอ่านข้อมูลระบบ/พอร์ตและอ่าน payload/link ของบริการเหล่านี้ การดำเนินการ Xray ใช้ account helper และ restart Xray หลังเปลี่ยน config

การจัดการ L2TP, PPTP, SSTP, WireGuard, Shadowsocks, ShadowsocksR, firewall, update, reboot, uninstall, DNS และงานตั้งค่าระบบ ยังใช้เมนู/คำสั่ง SSH ตามเดิมและ **ยังไม่มี endpoint API ใน v31** ไม่เปิด endpoint สำหรับสั่ง shell command ทั่วไปหรือเมนูที่มีผลระดับ root

UDP Custom ไม่แสดงชื่อผู้ใช้ที่กำลังเชื่อมต่อได้จากตัวบริการปัจจุบัน API จึงคืนสถานะ/ข้อมูลบัญชีและ listener แต่ไม่รายงาน online username

## รายละเอียดข้อมูลที่ส่งกลับ

ทุกคำตอบเป็น JSON UTF-8 และมี header <code>Cache-Control: no-store</code>. เมื่อสำเร็จ:

- <code>GET /health</code> คืน <code>ok</code> และรุ่น API
- <code>GET /system</code> คืน <code>os</code>, <code>kernel</code>, <code>uptime_seconds</code>, <code>cpu_cores</code>, <code>memory_mb.total</code>, <code>memory_mb.available</code>, <code>host</code>, <code>api_bind</code>, <code>api_port</code>, <code>supported_services</code> และ <code>ports</code>
- <code>GET /accounts</code> คืน <code>accounts</code> และ <code>supported_services</code>; ใส่ query <code>?service=udp</code> เพื่อกรองบริการ ค่า service ที่รับได้คือ <code>ssh</code>, <code>udp</code>, <code>vmess</code>, <code>vless</code>, <code>trojan</code>, <code>trojan-go</code>
- การอ่าน/สร้าง/แก้บัญชีคืน object ใน <code>account</code>; การลบคืน <code>deleted</code>, <code>service</code>, <code>username</code>

ช่องข้อมูลบัญชีแตกต่างกันตามบริการ:

| บริการ | ช่องเพิ่มเติม |
| --- | --- |
| SSH | <code>payloads.websocket_tls</code>, <code>payloads.websocket_http</code> |
| UDP Custom | <code>listener_port</code> |
| VMess | <code>host</code>, <code>payloads.tls</code>, <code>payloads.non_tls</code> |
| VLESS | <code>host</code>, <code>payloads.tls</code>, <code>payloads.non_tls</code> |
| Trojan | <code>host</code>, <code>payloads.link</code> |
| Trojan-Go | <code>host</code>, <code>payloads.link</code> |

<code>password_available</code> ระบุว่ามี password ส่งกลับได้หรือไม่; ถ้าไม่มีค่า <code>password</code> จะเป็น <code>null</code>. <code>expires_at</code> อาจเป็นวันที่หรือ timestamp ตามชนิดบริการ และอาจเป็น <code>null</code> สำหรับบัญชีเก่าที่ไม่มีข้อมูลหมดอายุบันทึกไว้ ค่า <code>host</code> ก็เป็น <code>null</code> ได้หากเครื่องไม่มีไฟล์ host/domain ที่ API อ่านได้

ข้อมูล <code>/system</code> รายงานจำนวน CPU core ไม่ใช่เปอร์เซ็นต์ CPU หรือ load average; ไม่มี bandwidth, รายชื่อ UDP ออนไลน์ หรือพอร์ตทุกบริการใน response นี้ พอร์ตใน <code>ports</code> เป็นค่าหลักที่ API อ่าน ไม่ใช่ผลตรวจว่าพอร์ตเปิดผ่าน firewall หรือบริการกำลัง listen อยู่

## รูปแบบสร้างบัญชีและผลของคำสั่ง

| Service | Body สำหรับ POST | พฤติกรรมสำคัญ |
| --- | --- | --- |
| <code>ssh</code> | <code>username</code>, <code>password</code>, <code>days</code> (ไม่บังคับ) | สร้าง Linux user ในกลุ่ม SSH-one |
| <code>udp</code> | <code>username</code>, <code>password</code>, <code>days</code> (ไม่บังคับ) | ต้องติดตั้ง UDP Custom; เก็บเวลาหมดอายุแบบ timestamp |
| <code>vmess</code>, <code>vless</code> | <code>username</code>, <code>password</code> (ไม่บังคับ), <code>days</code> (ไม่บังคับ) | ถ้าไม่ส่ง password จะสร้าง ID ให้อัตโนมัติ; การเปลี่ยน config จะ restart <code>xray.service</code> |
| <code>trojan</code> | <code>username</code>, <code>password</code> (ไม่บังคับ), <code>days</code> (ไม่บังคับ) | ถ้าไม่ส่ง password จะสุ่มให้; การเปลี่ยน config จะ restart <code>xray.service</code> |
| <code>trojan-go</code> | <code>username</code>, <code>password</code> (ไม่บังคับแต่ถ้าส่งต้องเท่ากับ username), <code>days</code> (ไม่บังคับ) | ใช้ username เป็น password และ restart <code>trojan-go.service</code> |

การสร้าง SSH/UDP ใช้ Linux user และ password แบบเดียวกับระบบบริการ; การลบจะปิด process ของ user นั้นแล้วลบ user. การแก้/ลบบัญชี Xray หรือ Trojan-Go เขียน config แล้ว restart service ที่เกี่ยวข้อง จึงอาจตัดการเชื่อมต่อชั่วครู่ หากการแก้ config หรือ restart ล้มเหลว API พยายามคืนไฟล์ config เดิม แต่ควรสำรองข้อมูลก่อนใช้งานระบบขายจริง

<code>PATCH</code> เปลี่ยนได้เฉพาะ <code>days</code>; ไม่มี endpoint เปลี่ยน password. <code>DELETE</code> ลบบัญชีทันทีและไม่มีกลไกคืนบัญชีจาก API. ตรวจ service/username ให้ถูกก่อนเรียก

## อายุบัญชีและบัญชีเดิม

<code>days</code> ใช้ได้ตั้งแต่ 1 ถึง 3650 วันและเริ่มนับจากเวลาที่รับคำขอ แต่ความละเอียดต่างกัน:

- SSH, VMess, VLESS, Trojan และ Trojan-Go ใช้วันหมดอายุแบบวันที่ตามระบบเดิม จึงไม่ควรตีความว่าเป็นเวลาครบ 24 ชั่วโมงพอดี
- UDP Custom บันทึกเวลาหมดอายุเป็น timestamp และ timer ตรวจบัญชีหมดอายุทุก 15 วินาที
- <code>PATCH {"days":N}</code> ตั้งวันหมดอายุใหม่จากเวลาปัจจุบัน ไม่ได้บวก N วันต่อจากวันหมดอายุเดิม
- บัญชี UDP เก่าที่ไม่มี metadata วันหมดอายุจะแสดง <code>expires_at: null</code>; API อ่าน password เดิมของ SSH/UDP ที่สร้างนอก API ไม่ได้

## ข้อควรรู้สำหรับระบบขาย

- รายการบัญชีไม่แบ่งหน้า และอาจคืน password, link และ payload ของทุกบัญชีที่ถามมา อย่าเรียก endpoint รวมแล้วส่งผลลัพธ์ทั้งก้อนไปให้ลูกค้ารายเดียว
- API ไม่มี idempotency key, rate limit, token scope หรือ endpoint จัดการ token หาก POST timeout ให้ตรวจรายการบัญชีก่อน retry เพื่อป้องกันบัญชีซ้ำ
- การดูรายการ token แสดง token เต็ม รวมถึง token หมดอายุ; จำกัดสิทธิ์ผู้ดูแลที่ใช้เมนู 27
- HTTP access log และรายละเอียด request ไม่ถูกเขียนโดย API; 500 จะคืนข้อความทั่วไป ไม่ส่ง traceback หรือ password ใน error
- API ไม่มี CORS สำหรับ browser และไม่มี HTTPS เอง; ใช้จาก backend/server ผ่าน SSH tunnel หรือเรียก localhost ภายใน VPS เท่านั้น
- ตรวจ host key ของ VPS ตามปกติเมื่อสร้าง tunnel; อย่าปิดการตรวจ host key เพื่อแก้ปัญหาแบบถาวร
- หาก local port 8765 ถูกใช้อยู่ ให้เปลี่ยนเฉพาะ local port เช่น <code>ssh -N -L 18765:127.0.0.1:8765 root@VPS_IP</code> แล้วเรียก <code>http://127.0.0.1:18765</code>; port ฝั่ง VPS ยังคง 8765

ไม่มี endpoint สำหรับสร้าง/ลบ token ผ่าน HTTP; ให้ผู้ดูแลใช้เมนู <code>27</code> บน VPS เท่านั้น
