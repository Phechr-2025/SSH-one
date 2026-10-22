# SSH-one

**ภาษา / Language:** [English](README.md) | [ไทย](README_TH.md)

<div align="center">
  <img src="assets/ssh-one-banner.svg" alt="SSH-one — VPN services installer" width="100%">
</div>

**รุ่น: SSH-one 2.0 v5**

v5 รอให้ BadVPN เปิด listener ก่อนตรวจ พร้อมบันทึกสถานะและ journal ลง log ติดตั้ง และเพิ่ม dependency PCRE2 สำหรับ build Accel-PPP โดยให้ขั้นตอน SSTP หยุดทันทีเมื่อ build ล้มเหลว

## ติดตั้ง

ใช้ VPS ใหม่ที่เป็น Ubuntu 20.04 x86_64 มี systemd, Public IPv4 และเข้า SSH ด้วย root ได้ รุ่น Debian, ARM และ Ubuntu อื่นยังไม่รับรอง

ก่อนติดตั้ง ให้สร้าง DNS-only A record ใน Cloudflare เช่น <code>ssh1.mydomain.com</code> ให้ชี้มายัง Public IPv4 ของ VPS และเตรียม Cloudflare API Token จากบัญชีที่จัดการ Zone นี้ โดยให้สิทธิ์ Zone Read และ DNS Write เฉพาะ Zone ที่ใช้

ดาวน์โหลดตัวติดตั้งแล้วรันใน VPS:

~~~~bash
curl -fsSL -o ssh-one-install.sh https://raw.githubusercontent.com/Phechr-2025/SSH-one/main/install.sh
bash ssh-one-install.sh Phechr-2025 SSH-one main
~~~~

กรอก Host/subdomain และ Cloudflare API Token ตามที่ถาม ตัวติดตั้งตรวจ DNS และสิทธิ์ Token ก่อนตั้งค่า เมื่อการตรวจ SSH หลังติดตั้งผ่าน ระบบจะนับ 10 วินาทีแล้ว reboot; มี cron reboot ประจำวันเวลา 05:00 ตาม timezone ของ VPS หากติดตั้งไม่สำเร็จ ให้ตรวจ <code>/root/log-install.txt</code> และอย่ารันติดตั้งซ้ำบนเครื่องที่ค้าง

## ค่าที่ต้องกรอก

- **Host/subdomain:** ชื่อเต็ม เช่น <code>ssh1.mydomain.com</code> ไม่ใส่ IP, port หรือ <code>https://</code> ต้องมี A record แบบ DNS only ชี้มายัง VPS ก่อนติดตั้ง
- **Cloudflare API Token:** สร้างจากบัญชีเดียวกับ Zone; ใช้สิทธิ์ Zone Read และ DNS Write จำกัดเฉพาะโดเมนนี้ ไม่ใช่ Global API Key

ตัวติดตั้งตรวจ DNS สาธารณะ, Zone, nameserver และ record ผ่าน Cloudflare API; DNS ต้องเผยแพร่แล้วและไม่มี record ชนกัน หากไม่ตรง ระบบจะหยุดพร้อมแจ้งสิ่งที่ต้องแก้

สร้าง Token ที่ Cloudflare: My Profile → API Tokens → Create Token → Edit Zone DNS; ให้สิทธิ์ Zone Read และ DNS Write และจำกัด Zone Resources ไว้เฉพาะโดเมนนี้

ดูขั้นตอนเตรียมค่าทีละข้อได้ที่ [คู่มือติดตั้งภาษาไทย](docs/install/INSTALL_GUIDE_TH.md)

## ใช้งานและจัดการ

- เข้าเมนูด้วยคำสั่ง <code>menu</code>; ถ้าชนคำสั่งเดิมใช้ <code>/usr/bin/menu</code>
- เมนูข้อ **1** จัดการ UDP Custom และ firewall; UDP Custom ติดตั้งอัตโนมัติ
- เมนูข้อ **21** อัปเดตไฟล์ SSH-one ตาม branch ที่ตั้งไว้ใน GitHub แม้ `VERSION` จะต่ำกว่า marker ในเครื่อง เมื่อสำเร็จจะแสดงรุ่น/ไฟล์ที่เปลี่ยน นับ 10 วินาที แล้ว reboot
- เมนูข้อ **22 Settings → 21** ตั้งว่าจะกลับเมนูหลักหลังทำรายการหรือไม่; ค่าเริ่มต้นคือไม่กลับ
- เมนูข้อ **26** ถอนการติดตั้ง; อ่านสรุปและสำรองข้อมูลก่อนพิมพ์ <code>UNINSTALL</code>
- เมนูข้อ **27** สร้าง ดู และลบ API token; ค่าเริ่มต้นหมดอายุใน 30 วัน

> **การรองรับเวอร์ชันเดิม:** กำหนด `VERSION` เป็น `v30` เพื่อให้เครื่องที่ใช้ตัวอัปเดต v30 รุ่นเก่าติดตั้งรุ่นเปลี่ยนผ่านนี้ได้ หลังติดตั้งแล้ว ตัวอัปเดตจะยึด branch ที่ตั้งไว้ใน GitHub แม้ `VERSION` ต่ำกว่า เช่น v28 ต้องติดตั้งรุ่นนี้ก่อนเปลี่ยน branch ไปยังรุ่นที่ต่ำกว่า เพราะตัวอัปเดตเก่าเปลี่ยนตัวเองจากระยะไกลก่อนยอมรับการอัปเดตไม่ได้

การเชื่อมต่อ SSH และ UDP gateway กลับมาใช้รูปแบบเดิม: OpenSSH ใช้ TCP 22, 2253 และ 42 ส่วน BadVPN แยก process ตาม listener แต่ละพอร์ต การอัปเดตย้ายบริการ BadVPN แบบเดิมและแทนไฟล์ใน manifest แต่ไม่อัปเดตแพ็กเกจระบบ, config/บัญชีบริการอื่น หรือไบนารีที่ไม่ได้จัดการ การถอนจะลบข้อมูลบริการบางส่วน; เก็บ OpenSSH, แพ็กเกจระบบ, กฎ firewall ที่ไม่ได้ระบุว่าเป็นของ SSH-one และไฟล์ที่ถูกแก้ไขภายหลังไว้

## บริการและพอร์ตเริ่มต้น

เปิดพอร์ตที่ต้องใช้ทั้งใน firewall ของ VPS และ firewall/security group ของผู้ให้บริการ ตารางนี้เป็นค่าตั้งต้นเมื่อบริการนั้นติดตั้งและทำงาน; ตรวจ config กับสถานะจริงก่อนใช้งาน

| บริการ | พอร์ต/โปรโตคอล |
| --- | --- |
| OpenSSH | TCP 22, 2253, 42 |
| Dropbear | TCP 109, 143, 1153 |
| OpenVPN | TCP 1194, UDP 2200, TLS/TCP 990 |
| SSLH / SSH WebSocket | TCP 443 (TLS multiplex), HTTP 8880 |
| Stunnel5 | TCP 445, 777, 990 |
| BadVPN UDPGW | TCP 7100, 7200, 7300 (แยก listener ที่ loopback; SSH app ที่รองรับ) |
| WireGuard | UDP 7070 |
| L2TP/IPsec, PPTP | UDP 500, 1701, 4500; TCP 1732 |
| SSTP | TCP 444 |
| Shadowsocks-R | TCP 1443–1543 |
| Shadowsocks OBFS | TCP/TLS 2443–2543, TCP/HTTP 3443–3543 |
| Xray VMess | TCP/TLS 8443, TCP 80 |
| Xray VLESS | TCP/TLS 8444, TCP 81 |
| Xray Trojan, Trojan-Go | TCP 2083, 2087 |
| OHP | TCP 8181, 8282, 8383 |
| UDP Custom | UDP 1–65535; listener เริ่มต้น 36712 |


## เล่นเกมและทราฟฟิก UDP

พอร์ต SSH เช่น 22 และ 443 รับการเชื่อมต่อ TCP ส่วน BadVPN UDPGW เป็นพอร์ต TCP ที่ฟังเฉพาะ loopback สำหรับแอป SSH ที่รองรับโปรโตคอล UDPGW; ไม่ใช่ VPN UDP ทั้งเครื่องและไม่รองรับทราฟฟิกของทุกเกม หากเกมต้องใช้ UDP โดยตรง ให้ใช้ WireGuard แทนการต่อ SSH อย่างเดียว

รัน `addwg` บน VPS เพื่อสร้างโปรไฟล์ ไฟล์จะอยู่ที่ `/root/wg0-client-NAME.conf` และอ่านได้เฉพาะ root ให้ดึงไฟล์ผ่าน SSH/SCP แล้วนำเข้าแอป WireGuard และเปิดใช้งาน โปรไฟล์จะส่ง IPv4 ผ่าน VPS ส่วน IPv6 ไม่ผ่าน tunnel ต้องอนุญาต UDP 7070 ใน firewall/security group ของผู้ให้บริการ ตัวติดตั้งจะเปิด IPv4 forwarding และ NAT บน VPS อย่าแชร์โปรไฟล์ เพราะมี private key

เปลี่ยนพอร์ต WireGuard ได้ที่ `menu` → `Change Port WireGuard`; สคริปต์ตรวจและใช้พอร์ต UDP ใหม่ พร้อมแจ้งกฎที่ต้องเปิดใน firewall ของผู้ให้บริการ

วิธีนี้ช่วยรองรับเกมที่ต้องใช้ UDP เช่น Roblox ซึ่งเอกสารช่วยเหลือระบุว่าเกมเลือกพอร์ต UDP แบบไดนามิก และในบางเครือข่ายการเปิดเกมไม่รองรับ proxy แต่ยังรับประกันไม่ได้ว่าทุกเกมหรือทุกเครือข่ายจะใช้ได้ หากผู้ให้บริการ/ISP กรอง UDP, NAT หรือเส้นทางมีปัญหา หรือนโยบายเกม/ระบบป้องกันโกงไม่อนุญาต VPN ก็อาจเชื่อมต่อไม่ได้ ค่า ping ขึ้นกับเส้นทางระหว่างผู้เล่น VPS และเซิร์ฟเวอร์เกม
## API สำหรับระบบอัตโนมัติ

API v1 อ่านข้อมูลเครื่อง/พอร์ต และสร้าง ดู ต่ออายุ หรือลบบัญชี SSH, UDP Custom, VMess, VLESS, Trojan และ Trojan-Go ได้ ใช้ SSH tunnel ไปยัง <code>127.0.0.1:8765</code> และส่ง Bearer token ทุก request ห้ามเปิดพอร์ต API สู่อินเทอร์เน็ตหรือใส่ secret ไว้ใน browser

- [คู่มือ API ภาษาไทย](docs/api/API_GUIDE_TH.md)
- [English API guide](docs/api/API_GUIDE_EN.md)

API ยังไม่มี endpoint สำหรับ L2TP/PPTP/SSTP, WireGuard, Shadowsocks/SSR, firewall, DNS, update, reboot, uninstall หรือคำสั่ง shell ทั่วไป

## ข้อจำกัดและช่วยเหลือ

SlowDNS ไม่ติดตั้ง, gRPC ปิดไว้ และ Squid ไม่รวมในชุดติดตั้ง; OHP ต้องมี HTTP proxy ที่ <code>127.0.0.1:3128</code> บริการที่อ้าง upstream อาจทำงานต่างกันตาม VPS/เครือข่าย จึงไม่มีการรับประกัน ping หรือความเร็ว

หาก API หรือบริการมีปัญหา ตรวจ <code>systemctl status</code> และ <code>/root/log-install.txt</code>; สำรองข้อมูลก่อนติดตั้ง อัปเดต หรือถอน หาก Token เคยอยู่ใน Git history ให้ revoke แล้วสร้างใหม่
