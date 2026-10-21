# คู่มือเตรียมค่า SSH-one v25

ตัวติดตั้งถาม Host/subdomain และ Cloudflare API Token โดยตรวจ DNS ให้ผ่านก่อนเริ่มติดตั้งบริการ

## เตรียมก่อน

- ใช้ VPS ใหม่ที่รองรับตาม [README](../../README.md)
- โดเมนต้องอยู่ใน Cloudflare, Zone ต้องเป็น Active และ nameserver ที่ตั้งกับผู้รับจดทะเบียนต้องตรงกับ nameserver ของ Zone
- สร้าง DNS-only A record ของ Host ให้ชี้มายัง Public IPv4 ของ VPS ก่อนติดตั้ง
- เตรียม Cloudflare API Token จากบัญชีที่จัดการ Zone ของโดเมนนี้ โดยให้สิทธิ์ Zone Read และ DNS Write เฉพาะ Zone

## 1. Host/subdomain

กรอกชื่อเต็มที่ใช้เชื่อมต่อ เช่น `ssh1.mydomain.com` ไม่ต้องใส่ `https://`, พอร์ต หรือ IP

ก่อนติดตั้ง ตัวติดตั้งอ่าน Public IPv4 ของ VPS แล้วตรวจ A record ผ่าน public DNS หาก IP ไม่ตรงหรือ Host ยังไม่มี A record จะเตือนเป็นภาษาอังกฤษ พร้อมแสดง IP ที่คาดหวังและ IP ที่พบ จากนั้นให้แก้ DNS แล้วกด Enter เพื่อตรวจซ้ำ, กรอก Host อื่น หรือกด `Q` เพื่อยกเลิก หากติดต่อ public DNS ไม่ได้ ระบบจะแจ้งให้ตรวจการเชื่อมต่อ HTTPS ขาออกของ VPS ก่อนลองใหม่

ตั้ง DNS ใน Cloudflare ดังนี้:

1. เปิดโดเมน แล้วเข้า **DNS → Records → Add record**
2. เลือกชนิด **A**; ช่อง **Name** ใส่ชื่อย่อย เช่น `ssh1`
3. ช่อง **IPv4 address** ใส่ Public IPv4 ของ VPS
4. ปิด Proxy ให้เป็น **DNS only** แล้วบันทึก
5. รอให้ public DNS แสดง IP ดังกล่าว แล้วค่อยรันตัวติดตั้ง

อย่าใช้ Host ที่มี A record ชี้ไปหลาย IP ที่ต่างกัน, เปิด Proxy หรือมี CNAME ชนกัน การตรวจต้องเห็น A record ชี้ตรงมายัง IP ของ VPS ทุกค่า

## 2. Cloudflare API Token

หลัง DNS ผ่าน ตัวติดตั้งจึงขอ Token เพื่อค้นหา Zone และตรวจ/ยืนยัน A record ผ่าน Cloudflare API ควรสร้าง Token ขณะเข้าสู่ระบบบัญชี Cloudflare เดียวกับบัญชีที่มี DNS zone ของโดเมน Host หากมีหลายบัญชี ให้ใช้บัญชีที่จัดการ DNS record นี้

1. ไปที่ **My Profile → API Tokens → Create Token**
2. เลือก template **Edit Zone DNS** เพื่อให้สิทธิ์ **DNS Write** แล้วเพิ่ม **Zone Read** หากยังไม่มี
3. จำกัด **Zone Resources** เป็น **Include → Specific zone** แล้วเลือกโดเมนในบัญชี Cloudflare ที่จัดการ DNS จริง
4. สร้าง Token แล้วคัดลอก secret; Cloudflare แสดงค่าเต็มครั้งเดียว

วาง Token ในช่องที่ซ่อนไว้ขณะพิมพ์ อย่าใส่ Token ในคำสั่ง, GitHub หรือแชต

เมื่อติดตั้ง ตัวติดตั้งจะแสดงชื่อและ ID ของ Cloudflare account ที่ API พบใน Zone และตรวจว่า public nameserver ตรงกับ nameserver ที่ Cloudflare กำหนดให้ Zone นั้น จากนั้นอ่าน A record กลับจากบัญชี/Zone เดียวกันและตรวจว่าชี้ไปยัง Public IPv4 ของ VPS พร้อมปิด Proxy หากบัญชี/Zone ไม่ตรง, Token ไม่มีสิทธิ์ หรือ record ไม่ตรง ระบบจะหยุดก่อนติดตั้งบริการ ให้ตรวจว่าเข้าสู่บัญชีที่จัดการโดเมนและกำหนด Zone Resources ถูก Zone

คู่มือ Cloudflare: [เพิ่มโดเมน](https://developers.cloudflare.com/fundamentals/manage-domains/add-site/), [สร้าง API Token](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/), [สิทธิ์ Token](https://developers.cloudflare.com/fundamentals/api/reference/template/)

## เมนู UDP และพอร์ต

ตัวติดตั้งจะตรวจว่าสคริปต์เมนูหลักเรียกใช้ได้ก่อนจบ เมื่อติดตั้งเสร็จให้รัน <code>menu</code> แล้วเลือกข้อ 1 หากคำสั่งไม่แสดงเมนู ให้ลอง <code>/usr/bin/menu</code>; สำหรับเครื่อง v17 ที่ไม่มีคำสั่งนี้ ให้อัปเดตด้วย bootstrap ใน README ก่อน

หน้าแรกแสดง version จาก marker ที่อัปเดตหลังติดตั้ง พร้อม OS, kernel, uptime, CPU, RAM, Host/domain, IP VPS, bandwidth และจำนวนบัญชีบริการ เมนูข้อ 13 แสดงรายการพอร์ตที่ตั้งไว้ ตัวอัปเดตข้อ 21 จะแสดงรุ่นเดิม/ใหม่และจำนวนไฟล์ที่จัดการ แล้วนับถอยหลัง 10 วินาทีก่อน reboot เมื่ออัปเดตสำเร็จ

เมนูข้อ 1 เปิดพอร์ตหรือช่วงพอร์ตใน firewall ของ VPS ได้ โดยเลือก UDP, TCP หรือทั้งคู่; หากเว้นช่อง Protocol และ Ports ค่าเริ่มต้นคือ UDP <code>1–65535</code> ซึ่งสามารถระบุช่วงอื่นแทนได้

ตัวติดตั้งเปิดช่วง UDP <code>1–65535</code> ใน UFW หาก UFW ทำงานอยู่ และกันพอร์ตบริการ UDP อื่น <code>500, 1701, 2200, 4500, 7070</code> ไว้ตามค่าเริ่มต้น รายการยกเว้นแก้ได้จาก <code>menu → 1 → 3</code>; listener ใน config เริ่มต้นคือ <code>:36712</code> บัญชีที่สร้างจากเมนูใช้ username/password บนไคลเอนต์ที่รองรับ UDP Custom

หลังเลือกพอร์ต listener ใหม่ ต้องเปิดพอร์ตเดียวกันใน firewall/security group ของผู้ให้บริการ VPS ด้วย การเปิด firewall ไม่ได้เริ่ม service บนพอร์ตนั้น ช่วง UDP ทั้งหมดอาจชนกับพอร์ตที่บริการอื่นใช้อยู่

## ป้องกันติดตั้งซ้ำ

ตัวติดตั้งปฏิเสธการทำงานหากพบเครื่องหมายติดตั้งสำเร็จ, เครื่องหมายการติดตั้งที่ค้าง, ไฟล์โดเมนของบริการ หรือมีตัวติดตั้งอีกชุดกำลังทำงานอยู่ หากการติดตั้งครั้งก่อนล้มเหลว ให้ตรวจ `/root/log-install.txt` และใช้ VPS ใหม่ เว้นแต่มีขั้นตอนกู้คืนที่ระบุชัดว่ารองรับรุ่นนั้น
