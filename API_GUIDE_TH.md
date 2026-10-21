# SSH-one API v1

ภาษา: [ไทย](API_GUIDE_TH.md) | [English](API_GUIDE_EN.md)

เอกสารสำหรับเชื่อมระบบเว็บขายหรือระบบจัดการบัญชีกับ VPS ที่ติดตั้ง SSH-one v26

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

## เริ่มใช้งาน

1. อัปเดต VPS เป็น v26 แล้วเปิดเมนูด้วย `menu`.
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
- token ทุกตัวมีสิทธิ์เท่ากันและเข้าถึงข้อมูล/การจัดการบัญชีทุกบริการที่รองรับ ไม่มีการแยก scope ให้สร้าง token แยกต่อระบบขายและลบทันทีเมื่อเลิกใช้
- Token และ password ที่แสดงจาก API เป็นข้อมูลลับ ห้ามบันทึก request/response เต็มลง access log หรือส่งต่อให้ลูกค้าอื่น

## Endpoints

ทุก endpoint ด้านล่างต้องผ่าน SSH tunnel และต้องแนบ API token

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
{"ok":true,"version":"v26"}
```

### ดูข้อมูล VPS และพอร์ต

```bash
curl -sS http://127.0.0.1:8765/api/v1/system \
  -H 'Authorization: Bearer YOUR_TOKEN'
```

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
| `409` | ชื่อซ้ำ, บริการยังไม่ติดตั้ง หรือข้อมูลบริการไม่พร้อม |
| `415` | body ไม่ได้ส่งเป็น `application/json` |
| `500` | คำสั่งระบบ/การแก้ config ล้มเหลว; ตรวจ `journalctl -u ssh-one-api.service` |

ตรวจ service:

```bash
systemctl status ssh-one-api.service --no-pager
journalctl -u ssh-one-api.service -n 100 --no-pager
ss -lntp | grep ':8765'
```

ผล `ss` ควรแสดง `127.0.0.1:8765` เท่านั้น หากไม่มี listener ให้รัน `ssh-one-api --install-service` ด้วย root แล้วตรวจ journal

## ขอบเขตของ v26

API v1 จัดการบัญชี SSH, UDP Custom, Xray VMess, Xray VLESS, Xray Trojan และ Trojan-Go รวมถึงอ่านข้อมูลระบบ/พอร์ตและอ่าน payload/link ของบริการเหล่านี้ การดำเนินการ Xray ใช้ account helper และ restart Xray หลังเปลี่ยน config

การจัดการ L2TP, PPTP, SSTP, WireGuard, Shadowsocks, ShadowsocksR, firewall, update, reboot, uninstall, DNS และงานตั้งค่าระบบ ยังใช้เมนู/คำสั่ง SSH ตามเดิมและ **ยังไม่มี endpoint API ใน v26** ไม่เปิด endpoint สำหรับสั่ง shell command ทั่วไปหรือเมนูที่มีผลระดับ root

UDP Custom ไม่แสดงชื่อผู้ใช้ที่กำลังเชื่อมต่อได้จากตัวบริการปัจจุบัน API จึงคืนสถานะ/ข้อมูลบัญชีและ listener แต่ไม่รายงาน online username
