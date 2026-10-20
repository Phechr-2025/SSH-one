# รายงานตรวจสอบตัวติดตั้ง SSH-one v17

## เพิ่มเติมใน v17

- เพิ่มเมนูข้อ 24 จากคำสั่ง `menu` สำหรับสถานะ, ติดตั้ง/ซ่อม UDP Custom, สร้าง/แสดง/ลบบัญชี UDP และเปิดพอร์ต/ช่วงพอร์ตแบบ TCP, UDP หรือทั้งคู่
- การเปิดพอร์ตใช้ UFW เมื่อทำงานอยู่ มิฉะนั้นใช้ iptables และบันทึกกฎด้วย `netfilter-persistent` เมื่อมี; แจ้งให้เปิด firewall/security group ฝั่งผู้ให้บริการแยกต่างหาก
- เมนูติดตั้ง/ซ่อมดึง installer จาก repository ที่บันทึกไว้และไม่เขียนทับ `/root/udp/config.json`; การติดตั้งปกติยังติดตั้ง UDP Custom อัตโนมัติตามเดิม
- บัญชีที่สร้างในเมนูถูกแยกด้วยกลุ่ม `ssh-one-udp` เพื่อให้รายการ/การลบไม่ไปยุ่งกับบัญชีระบบอื่น
- README และคู่มือระบุ listener เริ่มต้น `36712/UDP` แยกจากช่วงพอร์ต UDP ที่อนุญาต

เมนูเปิดกฎ firewall เท่านั้น ไม่ตรวจว่ามีโปรแกรมรับฟังพอร์ตนั้นหรือไม่; ยังต้องตรวจ listener และ firewall ภายนอกบน VPS จริง

## เพิ่มเติมใน v16

- ตัวค้นหา Cloudflare Zone อ่าน Account ID/ชื่อจาก Zone ที่ Token เข้าถึงได้ และแสดงบัญชีที่ใช้ก่อนแก้ DNS
- เปรียบเทียบ nameserver สาธารณะของ Zone กับ nameserver ที่ Cloudflare API ระบุ เพื่อหยุดก่อนเขียน DNS หาก Token เข้าถึง Zone ที่ไม่ได้รับมอบหมายให้ authoritative DNS จริง
- หลังบันทึก DNS อ่าน record จาก Zone เดิมกลับมาและยืนยัน Host, Public IPv4 และ DNS-only ก่อนเริ่มบริการ
- หาก token/บัญชีไม่มีสิทธิ์ใน Zone จะแจ้งให้ใช้ Token ที่ได้รับอนุญาตจากบัญชีจัดการโดเมน พร้อม Zone:Read และ DNS:Write
- README และคู่มือติดตั้งอธิบายการเลือกบัญชี Cloudflare และตรวจสอบ A record ให้ตรงกับ VPS

Cloudflare API แสดง Account ID/ชื่อและ nameserver ของ Zone ในผล `GET /zones`; ตัวติดตั้งใช้ข้อมูลนี้แสดงบัญชีและเทียบ nameserver กับ public DNS ก่อนแก้ record ([Cloudflare API: List Zones](https://developers.cloudflare.com/api/resources/zones/methods/list/)).

## เพิ่มเติมใน v15

- ใช้ `flock` เพื่อปฏิเสธตัวติดตั้งอีกชุดที่กำลังทำงาน พร้อมตรวจ completion marker, in-progress marker และไฟล์ติดตั้ง/โดเมนเดิมก่อนเริ่ม
- ตรวจ Public IPv4 ของ VPS และ public DNS A record ก่อนติดตั้งบริการ; ต้องเป็น A record โดยตรงและทุก IP ต้องตรงกับ VPS
- เมื่อ DNS ไม่ตรงจะแสดง IP ที่คาดหวังกับ IP ที่พบ และให้แก้แล้วตรวจซ้ำ, เปลี่ยน Host หรือยกเลิก; แยกกรณี resolver ติดต่อไม่ได้และแนะนำตรวจ outbound HTTPS; unattended run จะหยุดพร้อมคำแนะนำ
- หลังตั้ง DNS สำเร็จ `setup.sh` เขียน in-progress marker ก่อนติดตั้งบริการ แล้วเปลี่ยนเป็น completion marker หลังตรวจ SSH ผ่าน
- ข้อความเตือนใหม่ใน installer/setup เป็นภาษาอังกฤษ

การตรวจ DNS พึ่งการเข้าถึง `api.ipify.org` และ Google Public DNS. ยังไม่ได้รันการติดตั้งบน VPS จริงในรอบนี้; provider firewall, DNS propagation และการล็อกอิน SSH จริงยังต้องตรวจจาก VPS ของผู้ใช้.

## แก้ไขเพิ่มเติมใน v14

upstream และ repository นี้ไม่มี `ssh/set.sh` แต่ `setup.sh` เดิมสร้างและ enable `autosett.service` ก่อนดาวน์โหลดไฟล์ดังกล่าว ทำให้ติดตั้งบริการส่วนใหญ่แล้วแต่จบไม่สำเร็จ v14 ตัดการดาวน์โหลดและ unit ที่เสียออก ส่วน `recover-v13.sh` ใช้ปิด unit ของการติดตั้ง v13 ที่ค้าง ตรวจ OpenSSH, listener และ firewall ก่อนทำเครื่องหมายติดตั้งสำเร็จและ reboot

ตรวจเส้นทางคำสั่งเดียวตั้งแต่ `install.sh` → `setup.sh` → ตั้งค่าโดเมน/Cloudflare → ตัวติดตั้ง Xray และบริการหลัก → UDP Custom รวมถึงไฟล์ที่บริการเหล่านี้เรียกใช้

## สาเหตุที่รันแล้วไม่ถามโดเมน

1. ตัวติดตั้งรุ่นก่อนตรวจ OS ก่อนเริ่มถามข้อมูล และรองรับเฉพาะ Ubuntu 20.04 x86_64 + systemd หาก VPS เป็น Ubuntu รุ่นอื่น, Debian, ARM หรือ OpenVZ จะหยุดก่อนถามโดเมน
2. `setup.sh` รุ่นก่อนหยุดทันทีเมื่อพบ `/etc/xray/domain` แล้วแสดงเพียง `Script Already Installed` จึงข้ามการถามโดเมนหลังมีไฟล์ค้างจากการติดตั้งที่ล้มเหลว
3. การถาม host เดิมอยู่หลัง `apt update` และคำสั่งตรวจ IP หลายครั้ง อีกทั้งอ่านจาก stdin ปกติซึ่งอาจไม่ใช่ terminal เมื่อรันผ่านตัวติดตั้งแบบดาวน์โหลด

## การแก้ในชุดนี้

- ลดข้อมูลเริ่มต้นเหลือ Host กับ API Token; อ่านจาก `/dev/tty` และซ่อน token
- ค้นหา Cloudflare Zone ที่ Active โดยลอง Host แล้วไล่ตัด subdomain label ไปยังโดเมนหลัก ใช้ Zone ที่ตรงและเฉพาะเจาะจงที่สุดที่ Token อ่านได้
- หลังสร้าง/แก้ record ให้อ่าน A record กลับจาก Cloudflare API และตรวจว่า Google Public DNS resolve Host ไปยัง IP ของ VPS ก่อนเขียนไฟล์โดเมน; retry เมื่อ DNS ยังไม่กระจาย และหยุดพร้อมสาเหตุเมื่อยังตรวจไม่พบ
- ตรวจสถานะ OS, architecture, systemd, OpenVZ และไฟล์การติดตั้งเก่าด้วยข้อความชัดเจน
- เพิ่ม marker เมื่อจบการติดตั้ง และปฏิเสธการติดตั้งซ้ำ/กู้คืน partial install ที่สคริปต์เก่าไม่ปลอดภัยพอจะ resume
- ทำให้ download/run ของ installer หลักและ UDP Custom ล้มเหลวแบบรายงาน error แทนการไปต่อเงียบ ๆ
- แก้ URL Xray release asset ให้ตรงตัวพิมพ์ของชื่อไฟล์, ตรวจผลดาวน์โหลด/ใบรับรอง/config และสถานะ service
- แยกพอร์ต VMess/VLESS ที่ชนกัน: VMess TLS/ไม่เข้ารหัสใช้ 8443/80; VLESS TLS/ไม่เข้ารหัสใช้ 8444/81
- เอา dependency `libssl1.0-dev` ที่ล้าสมัยออกจาก Ubuntu installer; แก้ JSON Shadowsocks ที่มี comma เกิน และ unit header OHP ที่สะกดผิด
- เก็บ log สรุปไว้ที่ `/root/log-install.txt` แทนไฟล์ใน working directory ชั่วคราว
- เอา rclone OAuth config และ SMTP credentials ออกจากไฟล์ปัจจุบัน; ตั้งค่า rclone remote ของตนเองชื่อ `dr` ก่อนใช้ backup/restore
- เพิ่มค่ากำหนด OpenSSH ในส่วน global ก่อน `Match`: อนุญาต root ผ่าน password/key และเปิด TCP 22/2253; เก็บสำเนา config และ rollback หาก syntax, restart, effective settings หรือ listener ไม่ผ่าน
- เอาการปิด IPv6 แบบถาวรออก และไม่เขียนทับ `/etc/pam.d/common-password` เพื่อหลีกเลี่ยงการตัดเส้นทางจัดการหรือทำให้ policy รหัสผ่านของระบบเสีย
- ก่อนจบจะตรวจ `sshd -t`, ค่า `sshd -T`, สถานะ `ssh.service` และ listener ที่ไม่ใช่ loopback บน TCP 22/2253; เมื่อผ่านแล้วจึงนับถอยหลัง 10 วินาทีและ reboot
- เพิ่มกฎ INPUT ให้ TCP 22/2253 สำหรับ IPv4 และ IPv6 (เมื่อมี) แล้วบันทึกด้วย `netfilter-persistent`; ยังต้องเปิดพอร์ตเดียวกันใน firewall/security group ของผู้ให้บริการ VPS
- เรียก installer หลักแบบ synchronous โดยตรง เพื่อให้ `setup.sh` รับ exit code จริงของสคริปต์ลูกและหยุดเมื่อตัวติดตั้งรายงานความล้มเหลว แทนการพึ่ง exit code ของ `screen`
- ยังคงงาน reboot รายวันที่มาจากสคริปต์เดิม (`/etc/crontab` เวลา 05:00 ตาม timezone GMT+8); การ reboot หลังติดตั้ง 10 วินาทีเป็นอีกคำสั่งหนึ่ง

## ข้อกำหนดและข้อจำกัดที่ยังเหลือ

- โค้ดรุ่นนี้ยังจำกัดที่ Ubuntu 20.04 x86_64 + systemd เพราะ binary UDP Custom จาก upstream ระบุแพลตฟอร์มนี้; ยังไม่รับรอง Ubuntu รุ่นใหม่/Debian/ARM
- Ubuntu 20.04 หมดระยะ Standard Security Maintenance ตั้งแต่ 31 พฤษภาคม 2025; หากจะใช้งานต่อ ต้องเปิด Ubuntu Pro/ESM หรือย้ายไป OS รุ่นที่ยังได้รับ security updates หลังจากทดสอบและปรับ installer ให้รองรับก่อน
- ต้องใช้ VPS ใหม่ การติดตั้งที่ล้มเหลวหลังสร้าง `/etc/xray/domain` ไม่สามารถ resume อย่างปลอดภัยได้ ต้องใช้ VPS ใหม่
- Xray ใช้ ACME standalone ผ่าน HTTP จึงต้องมี DNS A record ชี้เข้า VPS และ TCP port 80 ว่าง/เข้าถึงได้จากอินเทอร์เน็ตก่อนออกใบรับรอง
- ต้องเปิดพอร์ตบริการและ UDP 1–65535 ใน security group/firewall ของผู้ให้บริการ VPS ด้วย; กฎในเครื่องไม่เปิด firewall ภายนอกให้
- การตรวจ listener ในเครื่องไม่ยืนยันว่า firewall/security group ของผู้ให้บริการเปิด TCP 22/2253 แล้ว และไม่ยืนยันว่ารหัส root หรือ SSH key ของผู้ใช้ถูกต้อง; หาก root password ถูกล็อก ต้องตั้งหรือปลดล็อกจาก console ของผู้ให้บริการก่อน
- OHP ต้นฉบับต้องมี HTTP proxy ที่ `127.0.0.1:3128`; ชุดนี้ไม่ติดตั้ง Squid จึงต้องตั้ง proxy เองก่อน OHP ใช้งานได้
- SlowDNS ไม่ติดตั้งอัตโนมัติ เพราะ installer ต้นฉบับอ้างไฟล์ที่ขาดและมีคำสั่งเสี่ยงลบข้อมูลใน `/root`; gRPC และ Squid ถูกปิดตามข้อจำกัดของ upstream
- บริการ legacy บางตัวสร้างจาก source หรือใช้ URL/config เก่า; การตรวจแบบ static ไม่รับประกันการทำงานบน kernel, network, provider firewall และสถานะพอร์ตของ VPS แต่ละเครื่อง
- ไม่ได้รันบน VPS จริงในรอบตรวจนี้ จึงยังยืนยัน apt, การออกใบรับรอง, การ bind พอร์ต, firewall ภายนอก, การล็อกอินจริง และสถานะทุก service ในระบบจริงไม่ได้

## ข้อมูลความปลอดภัย

ต้นฉบับในประวัติ Git ก่อนหน้าเคยมี credential ของ remote storage/mail อยู่ การเอาออกจากไฟล์ปัจจุบันไม่ได้ลบ commit เก่า ให้ revoke/rotate credential เหล่านั้น และล้างประวัติ Git ก่อนเผยแพร่ repository สาธารณะต่อ
