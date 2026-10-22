#!/usr/bin/env python3
"""SSH-one local account API. Bind is fixed to loopback; connect through SSH."""
import base64, datetime as dt, grp, hmac, http.server, json, os, pwd, re, secrets
import shutil, socketserver, stat, subprocess, sys, tempfile, threading, time, urllib.parse, uuid

ROOT = "/etc/ssh-one"
TOKENS = ROOT + "/api-tokens.json"
SECRETS = ROOT + "/api-secrets.json"
HOST, PORT, PREFIX = "127.0.0.1", 8765, "/api/v1"
SERVICES = ("ssh", "udp", "vmess", "vless", "trojan", "trojan-go")
PAYLOADS = {
    "websocket_tls": "GET wss://bug.com/ HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf][crlf]",
    "websocket_http": "GET / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf][crlf]",
}
XRAY = {
    "vmess": ("### ", ("#xray-vmess-tls", "#xray-vmess-nontls"), "id"),
    "vless": ("#### ", ("#xray-vless-tls", "#xray-vless-nontls"), "id"),
    "trojan": ("#&# ", ("#xray-trojan",), "password"),
}
LOCK = threading.RLock()


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def root():
    if os.geteuid() != 0:
        raise SystemExit("SSH-one API must run as root.")


def ensure_dir():
    os.makedirs(ROOT, mode=0o755, exist_ok=True)
    if os.path.islink(ROOT) or not os.path.isdir(ROOT):
        raise ApiError(500, "unsafe API state directory")


def load_json(path, default):
    if not os.path.exists(path):
        return default
    if os.path.islink(path) or not os.path.isfile(path):
        raise ApiError(500, "unsafe API state file")
    try:
        os.chmod(path, 0o600)
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as exc:
        raise ApiError(500, "cannot read API state file") from exc


def save_json(path, value):
    ensure_dir()
    if os.path.islink(path):
        raise ApiError(500, "refusing symbolic-link state file")
    fd, tmp = tempfile.mkstemp(prefix=".ssh-one-api.", dir=ROOT, text=True)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(value, f, ensure_ascii=False, separators=(",", ":"))
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        os.chmod(path, 0o600)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise


def tokens():
    data = load_json(TOKENS, {"tokens": []})
    if not isinstance(data, dict) or not isinstance(data.get("tokens"), list):
        raise ApiError(500, "invalid API token database")
    return data["tokens"]


def passwords():
    data = load_json(SECRETS, {"passwords": {}})
    if not isinstance(data, dict) or not isinstance(data.get("passwords"), dict):
        raise ApiError(500, "invalid credential database")
    return data


def secret(service, username):
    return passwords()["passwords"].get(service + ":" + username)


def set_secret(service, username, value=None):
    data = passwords()
    key = service + ":" + username
    if value is None:
        data["passwords"].pop(key, None)
    else:
        data["passwords"][key] = value
    save_json(SECRETS, data)


def prune_secrets():
    data = passwords()
    active = {
        "ssh": set(linux_users("ssh-one-ssh")),
        "udp": set(linux_users("ssh-one-udp")),
        "vmess": set(xray_rows("vmess")),
        "vless": set(xray_rows("vless")),
        "trojan": set(xray_rows("trojan")),
        "trojan-go": set(trojango_rows()),
    }
    removed = 0
    for key in list(data["passwords"]):
        service, separator, username = key.partition(":")
        if separator and service in active and username not in active[service]:
            del data["passwords"][key]
            removed += 1
    if removed:
        save_json(SECRETS, data)
    return removed


def run(argv, input_data=None, check=True, timeout=30):
    try:
        p = subprocess.run(argv, input=input_data, text=True, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=timeout, env={**os.environ, "LC_ALL": "C"})
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ApiError(500, "system command failed: " + os.path.basename(argv[0])) from exc
    if check and p.returncode:
        raise ApiError(500, "system command failed: " + os.path.basename(argv[0]))
    return p


def valid_token(value):
    now = int(time.time())
    for row in tokens():
        if not isinstance(row, dict): continue
        candidate, expiry = row.get("token"), row.get("expires_epoch", 0)
        if isinstance(candidate, str) and isinstance(expiry, int) and expiry > now:
            if hmac.compare_digest(candidate, value): return True
    return False


def validate_username(value, pattern=r"[A-Za-z0-9][A-Za-z0-9._-]{0,31}"):
    if not isinstance(value, str) or not re.fullmatch(pattern, value):
        raise ApiError(400, "username has an invalid format")
    return value


def days_value(value):
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 3650:
        raise ApiError(400, "days must be an integer from 1 to 3650")
    return value


def password_value(value):
    if not isinstance(value, str) or not value or len(value) > 256 or any(c in value for c in ("\n", "\r", "\x00", ":")):
        raise ApiError(400, "password must be 1-256 characters without colon or newline")
    return value


def expiration(days):
    return (dt.datetime.now().astimezone() + dt.timedelta(days=days)).date().isoformat()


def read_first(paths):
    for path in paths:
        try:
            with open(path, encoding="utf-8") as f:
                value = f.readline().strip()
            if value: return value
        except OSError: pass
    return ""


def host_name():
    return read_first(("/etc/ssh-one/host", "/etc/xray/domain")) or read_first(("/etc/ssh-one/public-ip",))


def port(label, default):
    try:
        with open("/root/log-install.txt", encoding="utf-8", errors="replace") as f:
            for line in f:
                if re.search(r"\b" + re.escape(label) + r"\b", line, re.I):
                    m = re.search(r":\s*([0-9]{1,5})\s*$", line)
                    if m and 1 <= int(m.group(1)) <= 65535: return int(m.group(1))
    except OSError: pass
    return default


def linux_users(group):
    try:
        g = grp.getgrnam(group)
    except KeyError:
        return []
    users = set(g.gr_mem)
    for user in pwd.getpwall():
        try:
            if g.gr_gid in os.getgrouplist(user.pw_name, user.pw_gid):
                users.add(user.pw_name)
        except OSError: pass
    return sorted(u for u in users if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,31}", u))


def ssh_expiry(username):
    try:
        import spwd
        value = spwd.getspnam(username).sp_expire
        if value is None or value < 0: return None
        return dt.datetime.fromtimestamp(value * 86400, tz=dt.timezone.utc).astimezone().isoformat()
    except (ImportError, KeyError, OSError, ValueError): return None


def udp_expiries():
    data = {}
    try:
        with open(ROOT + "/udp-expirations.tsv", encoding="utf-8") as f:
            for line in f:
                fields = line.rstrip("\n").split("\t")
                if len(fields) == 2 and fields[1].isdigit(): data[fields[0]] = int(fields[1])
    except OSError: pass
    return data


def udp_expiry_write(username, epoch=None):
    path = ROOT + "/udp-expirations.tsv"
    if os.path.islink(path): raise ApiError(500, "unsafe UDP expiration file")
    rows = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                if line.split("\t", 1)[0] != username: rows.append(line.rstrip("\n"))
    except OSError: pass
    if epoch is not None: rows.append(username + "\t" + str(epoch))
    fd, tmp = tempfile.mkstemp(prefix=".udp-expirations.", dir=ROOT, text=True)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            if rows: f.write("\n".join(rows) + "\n")
            f.flush(); os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise


def udp_listener():
    try:
        with open("/root/udp/config.json", encoding="utf-8") as f: config = json.load(f)
        match = re.fullmatch(r".*:([0-9]{1,5})", config.get("listen", ""))
        if match and 1 <= int(match.group(1)) <= 65535: return int(match.group(1))
    except (OSError, ValueError, AttributeError): pass
    return 36712


def xray_rows(service):
    prefix, markers, field = XRAY[service]
    try:
        with open("/etc/xray/config.json", encoding="utf-8") as f: lines = f.read().splitlines()
    except OSError: return {}
    found = {}
    marker_set = set(markers)
    for i, line in enumerate(lines):
        if not line.startswith(prefix): continue
        parts = line.split()
        if len(parts) < 3 or not re.fullmatch(r"[A-Za-z0-9_]{1,64}", parts[1]): continue
        username, expiry = parts[1], parts[2]
        if username in found: continue
        credential = None
        for candidate in lines[i + 1:i + 6]:
            if candidate in marker_set or candidate.startswith(("### ", "#### ", "#&# ")): break
            m = re.search(r'"' + field + r'"\s*:\s*"([^"]+)"', candidate)
            if m: credential = m.group(1); break
        found[username] = {"service": service, "username": username, "password": credential, "expires_at": expiry}
    return found


def xray_decorate(row):
    row = dict(row)
    user, host, svc = row["username"], host_name(), row["service"]
    row["password_available"] = bool(row.get("password"))
    if svc == "vmess":
        common = {"v":"2","ps":"XRAY_VMESS_" + user,"add":host,"id":row.get("password") or "",
                  "aid":"0","net":"ws","path":"/vmess","type":"none","host":host}
        tls = dict(common, port=str(port("Vmess TLS",8443)), tls="tls")
        plain = dict(common, port=str(port("Vmess None TLS",80)), tls="none")
        row["payloads"] = {"tls":"vmess://" + base64.b64encode(json.dumps(tls,separators=(",",":")).encode()).decode(),
                           "non_tls":"vmess://" + base64.b64encode(json.dumps(plain,separators=(",",":")).encode()).decode()}
    elif svc == "vless":
        ident = urllib.parse.quote(row.get("password") or "", safe="-")
        domain = urllib.parse.quote(host, safe=".-")
        row["payloads"] = {"tls":f"vless://{ident}@{domain}:{port('Vless TLS',8444)}?type=ws&encryption=none&security=tls&host={domain}&path=%2Fvless#{user}",
                           "non_tls":f"vless://{ident}@{domain}:{port('Vless None TLS',81)}?type=ws&encryption=none&security=none&host={domain}&path=%2Fvless#{user}"}
    else:
        row["payloads"] = {"link":f"trojan://{urllib.parse.quote(row.get('password') or '',safe='')}@{host}:{port('Trojan',2083)}"}
    row["host"] = host or None
    return row


def trojango_rows():
    try:
        with open("/etc/trojan-go/config.json", encoding="utf-8") as f:
            config = json.load(f)
    except (OSError, ValueError):
        return {}
    if not isinstance(config.get("password"), list):
        return {}
    expiries = {}
    try:
        with open("/etc/trojan-go/akun.conf", encoding="utf-8") as f:
            for line in f:
                fields = line.split()
                if len(fields) >= 3 and fields[0] == "###":
                    expiries[fields[1]] = fields[2]
    except OSError:
        pass
    return {user: {"service": "trojan-go", "username": user, "password": user,
                   "password_available": True, "expires_at": expiries.get(user)}
            for user in config["password"] if isinstance(user, str) and re.fullmatch(r"[A-Za-z0-9_]{1,64}", user)}


def trojango_decorate(row):
    row = dict(row)
    host = host_name()
    user = row["username"]
    row["host"] = host or None
    row["payloads"] = {"link": f"trojan-go://{urllib.parse.quote(user, safe='')}@{host}:{port('TrojanGo', 2087)}/?sni={host}&type=ws&host={host}&path=%2Ftrojango&encryption=none#{user}"}
    return row


def account_list(service):
    prune_secrets()
    if service == "ssh":
        rows = []
        for user in linux_users("ssh-one-ssh"):
            try: pwd.getpwnam(user)
            except KeyError: continue
            secret_value = secret(service, user)
            rows.append({"service":service,"username":user,"password":secret_value,
                         "password_available":secret_value is not None,"expires_at":ssh_expiry(user),"payloads":PAYLOADS})
        return rows
    if service == "udp":
        expiry = udp_expiries()
        return [{"service":service,"username":user,"password":secret(service,user),
                 "password_available":secret(service,user) is not None,
                 "expires_at":dt.datetime.fromtimestamp(expiry[user],tz=dt.timezone.utc).astimezone().isoformat() if user in expiry else None,
                 "listener_port":udp_listener()} for user in linux_users("ssh-one-udp")]
    if service == "trojan-go":
        records = trojango_rows()
        return [trojango_decorate(records[user]) for user in sorted(records)]
    rows = xray_rows(service)
    return [xray_decorate(rows[user]) for user in sorted(rows)]


def get_account(service, username):
    for row in account_list(service):
        if row["username"] == username: return row
    raise ApiError(404, "account was not found")


def create_linux(service, body):
    username = validate_username(body.get("username"))
    password = password_value(body.get("password"))
    days = days_value(body.get("days", 30))
    group = "ssh-one-ssh" if service == "ssh" else "ssh-one-udp"
    if service == "udp" and not os.path.isfile("/root/udp/udp-custom"):
        raise ApiError(409, "UDP Custom is not installed")
    try:
        pwd.getpwnam(username)
        raise ApiError(409, "username already exists on this VPS")
    except KeyError:
        pass
    if username in set(linux_users(group)): raise ApiError(409, "username already exists")
    if run(["getent","group",group],check=False).returncode != 0: run(["groupadd","--system",group])
    run(["useradd","-M","-s","/bin/false","-G",group,"-e",expiration(days),username])
    try:
        run(["chpasswd"], input_data=username + ":" + password + "\n")
        if service == "udp":
            udp_expiry_write(username, int((dt.datetime.now().astimezone()+dt.timedelta(days=days)).timestamp()))
        set_secret(service,username,password)
    except BaseException:
        run(["userdel",username],check=False)
        if service == "udp": udp_expiry_write(username,None)
        set_secret(service,username,None)
        raise
    return get_account(service,username)


def backup_file(path):
    if os.path.islink(path) or not os.path.isfile(path): raise ApiError(409,"service config is missing or unsafe")
    with open(path,"rb") as f: content=f.read()
    return path,content,stat.S_IMODE(os.stat(path).st_mode)


def restore_file(saved):
    path, content, mode = saved
    if content is None:
        try: os.unlink(path)
        except FileNotFoundError: pass
        return
    fd,tmp=tempfile.mkstemp(prefix=".ssh-one-api-restore.",dir=os.path.dirname(path))
    try:
        os.fchmod(fd,mode)
        with os.fdopen(fd,"wb") as f: f.write(content); f.flush(); os.fsync(f.fileno())
        os.replace(tmp,path)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise


def create_xray(service, body):
    username=validate_username(body.get("username"),r"[A-Za-z0-9_]{1,64}")
    days=days_value(body.get("days",30))
    password=body.get("password")
    if username in xray_rows(service): raise ApiError(409,"username already exists")
    if password is None: password=str(uuid.uuid4()) if service in ("vmess","vless") else secrets.token_urlsafe(24)
    password=password_value(password)
    if service in ("vmess","vless") and not re.fullmatch(r"[A-Fa-f0-9-]{16,64}", password):
        raise ApiError(400,"VMess/VLESS password must be a valid Xray ID")
    path="/etc/xray/config.json"
    saved=backup_file(path)
    prefix,markers,field=XRAY[service]
    added=[]
    try:
        for marker in markers:
            run(["ssh-one-xray-accounts","add",path,marker,service,username,expiration(days),password])
            added.append(marker)
        run(["systemctl","restart","xray.service"])
    except BaseException:
        restore_file(saved)
        run(["systemctl","restart","xray.service"],check=False)
        raise
    set_secret(service,username,password)
    return get_account(service,username)


def trojango_saved():
    config = backup_file("/etc/trojan-go/config.json")
    meta_path = "/etc/trojan-go/akun.conf"
    if os.path.islink(meta_path): raise ApiError(409, "Trojan-Go account file is unsafe")
    try:
        meta = backup_file(meta_path)
    except ApiError:
        if os.path.exists(meta_path): raise
        meta = (meta_path, None, None)
    return [config, meta]


def trojango_write(config, expiries):
    config_path = "/etc/trojan-go/config.json"
    meta_path = "/etc/trojan-go/akun.conf"
    if not isinstance(config.get("password"), list):
        raise ApiError(409, "Trojan-Go password list is invalid")
    old_meta = []
    try:
        with open(meta_path, encoding="utf-8") as f:
            old_meta = [line.rstrip("\n") for line in f if not line.startswith("### ")]
    except FileNotFoundError:
        pass
    atomic_text(config_path, json.dumps(config, ensure_ascii=False, indent=2) + "\n")
    managed = ["### " + user + " " + expires for user, expires in sorted(expiries.items())]
    atomic_text(meta_path, "\n".join(old_meta + managed) + ("\n" if old_meta or managed else ""))


def atomic_text(path, content):
    directory = os.path.dirname(path)
    mode = stat.S_IMODE(os.stat(path).st_mode) if os.path.exists(path) else 0o600
    fd, tmp = tempfile.mkstemp(prefix=".ssh-one-api.", dir=directory, text=True)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise


def create_trojango(body):
    user = validate_username(body.get("username"), r"[A-Za-z0-9_]{1,64}")
    days = days_value(body.get("days", 30))
    if body.get("password") not in (None, user):
        raise ApiError(400, "Trojan-Go uses the username as its password")
    records = trojango_rows()
    if user in records: raise ApiError(409, "username already exists")
    saved = trojango_saved()
    try:
        with open("/etc/trojan-go/config.json", encoding="utf-8") as f: config = json.load(f)
        config["password"].append(user)
        expiries = {name: row["expires_at"] for name, row in records.items() if row.get("expires_at")}
        expiries[user] = expiration(days)
        trojango_write(config, expiries)
        run(["systemctl", "restart", "trojan-go.service"])
    except BaseException:
        for item in saved: restore_file(item)
        run(["systemctl", "restart", "trojan-go.service"], check=False)
        raise
    set_secret("trojan-go", user, user)
    return get_account("trojan-go", user)


def change_trojango(user, days=None, delete=False):
    records = trojango_rows()
    if user not in records: raise ApiError(404, "account was not found")
    saved = trojango_saved()
    try:
        with open("/etc/trojan-go/config.json", encoding="utf-8") as f: config = json.load(f)
        if delete:
            config["password"] = [name for name in config["password"] if name != user]
            records.pop(user, None)
        else:
            records[user]["expires_at"] = expiration(days)
        expiries = {name: row["expires_at"] for name, row in records.items() if row.get("expires_at")}
        trojango_write(config, expiries)
        run(["systemctl", "restart", "trojan-go.service"])
    except BaseException:
        for item in saved: restore_file(item)
        run(["systemctl", "restart", "trojan-go.service"], check=False)
        raise
    if delete:
        set_secret("trojan-go", user, None)
        return None
    return get_account("trojan-go", user)


def patch_xray(service, username, days):
    if username not in xray_rows(service): raise ApiError(404,"account was not found")
    path,saved,mode=backup_file("/etc/xray/config.json")
    lines=saved.decode("utf-8").splitlines()
    prefix,markers,_=XRAY[service]
    active=False; changed=0; new_exp=expiration(days)
    for i,line in enumerate(lines):
        if line in markers: active=True; continue
        if line.startswith("#xray-"): active=False
        if active and line.startswith(prefix):
            fields=line.split()
            if len(fields)>=3 and fields[1]==username:
                lines[i]=prefix+username+" "+new_exp; changed+=1
    if changed != len(markers): raise ApiError(409,"account metadata is incomplete; expiry unchanged")
    fd,tmp=tempfile.mkstemp(prefix=".ssh-one-api-xray.",dir=os.path.dirname(path),text=True)
    try:
        os.fchmod(fd,mode)
        with os.fdopen(fd,"w",encoding="utf-8") as f: f.write("\n".join(lines)+"\n")
        os.replace(tmp,path)
        run(["systemctl","restart","xray.service"])
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        restore_file((path,saved,mode))
        run(["systemctl","restart","xray.service"],check=False)
        raise
    return get_account(service,username)


def delete_account(service, username):
    if service in ("ssh","udp"):
        group="ssh-one-ssh" if service=="ssh" else "ssh-one-udp"
        if username not in set(linux_users(group)): raise ApiError(404,"account was not found")
        run(["pkill","-KILL","-u",username],check=False)
        run(["userdel",username])
        if service=="udp": udp_expiry_write(username,None)
        set_secret(service,username,None)
        return
    if service == "trojan-go":
        change_trojango(username, delete=True)
        return
    if username not in xray_rows(service): raise ApiError(404,"account was not found")
    path="/etc/xray/config.json"; saved=backup_file(path)
    try:
        for marker in XRAY[service][1]:
            run(["ssh-one-xray-accounts","remove-user",path,marker,username])
        run(["systemctl","restart","xray.service"])
    except BaseException:
        restore_file(saved)
        run(["systemctl","restart","xray.service"],check=False)
        raise
    set_secret(service,username,None)


def patch_account(service, username, body):
    if not isinstance(body,dict): raise ApiError(400,"body must be a JSON object")
    days=days_value(body.get("days"))
    if service=="ssh":
        if username not in set(linux_users("ssh-one-ssh")): raise ApiError(404,"account was not found")
        run(["chage","-E",expiration(days),username])
        return get_account(service,username)
    if service=="udp":
        if username not in set(linux_users("ssh-one-udp")): raise ApiError(404,"account was not found")
        udp_expiry_write(username,int((dt.datetime.now().astimezone()+dt.timedelta(days=days)).timestamp()))
        return get_account(service,username)
    if service=="trojan-go": return change_trojango(username,days=days)
    return patch_xray(service,username,days)


def system_info():
    try:
        with open("/etc/os-release",encoding="utf-8") as f:
            pretty=next((x.split("=",1)[1].strip().strip('"') for x in f if x.startswith("PRETTY_NAME=")),"Linux")
    except OSError: pretty="Linux"
    try:
        with open("/proc/meminfo",encoding="ascii") as f:
            memory={x.split(":",1)[0]:int(x.split()[1]) for x in f if ":" in x}
    except (OSError,ValueError,IndexError): memory={}
    try:
        with open("/proc/uptime",encoding="ascii") as f: up=float(f.read().split()[0])
    except (OSError,ValueError,IndexError): up=None
    return {"os":pretty,"kernel":os.uname().release,"uptime_seconds":up,"cpu_cores":os.cpu_count(),
            "memory_mb":{"total":round(memory.get("MemTotal",0)/1024),"available":round(memory.get("MemAvailable",0)/1024)},
            "host":host_name() or None,"api_bind":HOST,"api_port":PORT,
            "supported_services":list(SERVICES),
            "ports":{"ssh_tcp":[22,2253,42],"udp_custom_range":[1,65535],"udp_custom_listener":udp_listener(),
                     "vmess_tls":port("Vmess TLS",8443),"vmess_plain":port("Vmess None TLS",80),
                     "vless_tls":port("Vless TLS",8444),"vless_plain":port("Vless None TLS",81),
                     "trojan":port("Trojan",2083)}}


class Handler(http.server.BaseHTTPRequestHandler):
    server_version="SSH-one-API/1"
    sys_version=""
    def log_message(self,*_): pass
    def reply(self,status,obj):
        raw=json.dumps(obj,ensure_ascii=False,separators=(",",":")).encode()
        self.send_response(status); self.send_header("Content-Type","application/json; charset=utf-8")
        self.send_header("Content-Length",str(len(raw))); self.send_header("Cache-Control","no-store")
        self.send_header("X-Content-Type-Options","nosniff"); self.end_headers(); self.wfile.write(raw)
    def auth(self):
        value=self.headers.get("Authorization","")
        if not value.startswith("Bearer ") or not valid_token(value[7:].strip()):
            raise ApiError(401,"API token is missing, invalid, or expired")
    def body(self):
        try: size=int(self.headers.get("Content-Length","0"))
        except ValueError: raise ApiError(400,"invalid Content-Length")
        if size<1 or size>65536: raise ApiError(400,"JSON body must be 1-65536 bytes")
        if self.headers.get_content_type()!="application/json": raise ApiError(415,"Content-Type must be application/json")
        try: return json.loads(self.rfile.read(size))
        except (ValueError,UnicodeDecodeError): raise ApiError(400,"body is not valid JSON")
    def dispatch(self):
        try:
            self.auth()
            parsed=urllib.parse.urlsplit(self.path)
            path=urllib.parse.unquote(parsed.path)
            if not path.startswith(PREFIX): raise ApiError(404,"route not found")
            parts=path[len(PREFIX):].strip("/").split("/") if path[len(PREFIX):].strip("/") else []
            if self.command=="GET" and parts==["health"]: status,result=200,{"ok":True,"version":"v28"}
            elif self.command=="GET" and parts==["system"]: status,result=200,system_info()
            elif parts and parts[0]=="accounts" and self.command=="GET" and len(parts)==1:
                service=urllib.parse.parse_qs(parsed.query).get("service",[None])[0]
                if service and service not in SERVICES: raise ApiError(400,"unsupported service; supported: "+", ".join(SERVICES))
                rows=account_list(service) if service else sum((account_list(s) for s in SERVICES),[])
                status,result=200,{"accounts":rows,"supported_services":list(SERVICES)}
            elif parts and parts[0]=="accounts" and len(parts)==2 and self.command=="POST":
                service=parts[1]
                if service not in SERVICES: raise ApiError(400,"unsupported service; supported: "+", ".join(SERVICES))
                with LOCK:
                    body=self.body()
                    if not isinstance(body,dict): raise ApiError(400,"body must be a JSON object")
                    if service in ("ssh","udp"): row=create_linux(service,body)
                    elif service=="trojan-go": row=create_trojango(body)
                    else: row=create_xray(service,body)
                status,result=201,{"account":row}
            elif parts and parts[0]=="accounts" and len(parts)==3:
                service,user=parts[1],validate_username(parts[2],r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
                if service not in SERVICES: raise ApiError(400,"unsupported service; supported: "+", ".join(SERVICES))
                if self.command=="GET": status,result=200,{"account":get_account(service,user)}
                elif self.command=="PATCH":
                    with LOCK: status,result=200,{"account":patch_account(service,user,self.body())}
                elif self.command=="DELETE":
                    with LOCK: delete_account(service,user)
                    status,result=200,{"deleted":True,"service":service,"username":user}
                else: raise ApiError(405,"method not allowed")
            else: raise ApiError(404,"route not found")
            self.reply(status,result)
        except ApiError as exc: self.reply(exc.status,{"error":str(exc)})
        except Exception: self.reply(500,{"error":"internal API error; see journalctl -u ssh-one-api.service"})
    do_GET=dispatch
    do_POST=dispatch
    do_PATCH=dispatch
    do_DELETE=dispatch


def token_admin():
    root(); ensure_dir()
    print("SSH-one API TOKEN MANAGEMENT")
    print("1. Create token\n2. List tokens\n3. Delete token\n0. Back")
    choice=input("Select an option: ").strip()
    if choice=="0": return 99
    if choice=="1":
        name=input("Token name: ").strip()
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_. -]{0,63}",name): raise ApiError(400,"token name is invalid")
        raw=input("Expiry days [30]: ").strip() or "30"
        if not re.fullmatch(r"[0-9]{1,4}",raw) or not 1<=int(raw)<=3650: raise ApiError(400,"expiry must be from 1 to 3650 days")
        rows=tokens()
        if any(isinstance(r,dict) and r.get("name")==name for r in rows): raise ApiError(409,"token name already exists")
        now=int(time.time()); end=now+int(raw)*86400; token="ssh1_"+secrets.token_urlsafe(48)
        rows.append({"name":name,"token":token,"created_at":dt.datetime.fromtimestamp(now,dt.timezone.utc).astimezone().isoformat(),
                     "expires_at":dt.datetime.fromtimestamp(end,dt.timezone.utc).astimezone().isoformat(),"expires_epoch":end})
        save_json(TOKENS,{"tokens":rows})
        print("Name    : "+name+"\nExpires : "+rows[-1]["expires_at"]+"\nToken   : "+token)
        print("Copy this token now and deliver it securely. Token lists also show active token values.")
    elif choice=="2":
        rows=tokens()
        if not rows: print("No API tokens.")
        for row in rows:
            state="expired" if int(row.get("expires_epoch",0))<=int(time.time()) else "active"
            print("Name    : "+str(row.get("name",""))+"\nToken   : "+str(row.get("token",""))+
                  "\nExpires : "+str(row.get("expires_at",""))+" ("+state+")\n------------------------------")
    elif choice=="3":
        target=input("Token name or exact token to delete: ").strip()
        rows=tokens(); kept=[r for r in rows if not (isinstance(r,dict) and
            (r.get("name")==target or (isinstance(r.get("token"),str) and hmac.compare_digest(r["token"],target))))]
        if len(kept)==len(rows): print("No matching token.")
        else: save_json(TOKENS,{"tokens":kept}); print("Token deleted.")
    else: print("Invalid option.")


def install_service():
    root(); ensure_dir()
    path="/etc/systemd/system/ssh-one-api.service"
    unit="""# SSH-one managed API service
[Unit]
Description=SSH-one loopback API
After=network.target

[Service]
Type=simple
User=root
Group=root
UMask=0077
ExecStart=/usr/bin/ssh-one-api serve
Restart=on-failure
RestartSec=2
PrivateTmp=true
NoNewPrivileges=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
"""
    if os.path.islink(path): raise SystemExit("Refusing symbolic-link API unit.")
    if os.path.exists(path):
        with open(path,encoding="utf-8") as f: old=f.read()
        if "# SSH-one managed API service" not in old: raise SystemExit("An unrelated ssh-one-api.service already exists.")
    fd,tmp=tempfile.mkstemp(prefix=".ssh-one-api.",dir="/etc/systemd/system",text=True)
    with os.fdopen(fd,"w",encoding="utf-8") as f: f.write(unit)
    os.chmod(tmp,0o644); os.replace(tmp,path)
    run(["systemctl","daemon-reload"])
    run(["systemctl","enable","--now","ssh-one-api.service"])
    print("API service enabled on 127.0.0.1:8765.")


def serve():
    root(); ensure_dir()
    class Server(socketserver.ThreadingMixIn,http.server.HTTPServer):
        daemon_threads=True
    try: server=Server((HOST,PORT),Handler)
    except OSError as exc: raise SystemExit("Cannot listen on 127.0.0.1:8765: "+str(exc))
    print("SSH-one API listening on 127.0.0.1:8765",flush=True)
    server.serve_forever(poll_interval=0.5)


def main():
    root()
    if len(sys.argv)!=2: raise SystemExit("Usage: ssh-one-api {serve|tokens|prune-secrets|--install-service}")
    if sys.argv[1]=="serve": serve()
    elif sys.argv[1]=="tokens":
        try: raise SystemExit(token_admin())
        except ApiError as exc: print("SSH-one API: "+str(exc),file=sys.stderr); raise SystemExit(1)
    elif sys.argv[1]=="--install-service": install_service()
    elif sys.argv[1]=="prune-secrets": prune_secrets()
    else: raise SystemExit("Usage: ssh-one-api {serve|tokens|prune-secrets|--install-service}")


if __name__=="__main__": main()
