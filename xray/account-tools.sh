#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'SSH-one Xray account tools: run as root.\n' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf 'SSH-one Xray account tools: python3 is required.\n' >&2; exit 1; }

python3 - "$@" <<'PY'
import json
import os
import re
import stat
import sys
import tempfile


def fail(message, code=1):
    print(f"SSH-one Xray accounts: {message}", file=sys.stderr)
    raise SystemExit(code)


def load(path):
    if os.path.islink(path) or not os.path.isfile(path):
        fail(f"refusing an unsafe config path: {path}")
    with open(path, encoding="utf-8") as stream:
        lines = stream.read().splitlines()
    return lines, stat.S_IMODE(os.stat(path).st_mode)


def block(lines, marker):
    marker_indexes = [i for i, line in enumerate(lines) if line.strip() == marker]
    if len(marker_indexes) != 1:
        fail(f"expected one config marker {marker!r}; found {len(marker_indexes)}")
    marker_index = marker_indexes[0]
    client_index = next((i for i in range(marker_index, -1, -1) if '"clients"' in lines[i]), None)
    if client_index is None:
        fail(f"client array for {marker!r} was not found")
    end = next((i for i in range(marker_index + 1, len(lines)) if lines[i].lstrip().startswith("]")), None)
    if end is None:
        fail(f"closing bracket for {marker!r} was not found")
    legacy_anchor = any(line.strip().startswith("{") for line in lines[client_index + 1:marker_index])
    return marker_index, end, legacy_anchor


def write(path, lines, mode):
    directory = os.path.dirname(path) or "."
    fd, temp_path = tempfile.mkstemp(prefix=".ssh-one-xray.", dir=directory, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            stream.write("\n".join(lines) + "\n")
        os.chmod(temp_path, mode)
        os.replace(temp_path, path)
    except BaseException:
        try:
            os.unlink(temp_path)
        except FileNotFoundError:
            pass
        raise


def record_prefix(kind):
    return {"vmess": "### ", "vless": "#### ", "trojan": "#&# "}[kind]


def add(path, marker, kind, username, expiry, credential):
    if kind not in {"vmess", "vless", "trojan"}:
        fail("account type must be vmess, vless, or trojan")
    if not re.fullmatch(r"[A-Za-z0-9_]{1,64}", username):
        fail("username contains unsupported characters")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", expiry):
        fail("expiry date is invalid")
    if kind in {"vmess", "vless"} and not re.fullmatch(r"[A-Fa-f0-9-]{16,64}", credential):
        fail("Xray ID is invalid")
    if kind == "trojan" and not credential:
        fail("Trojan password is empty")
    lines, mode = load(path)
    marker_index, end, legacy = block(lines, marker)
    prefix = record_prefix(kind)
    if any(line.startswith(prefix + username + " ") for line in lines[marker_index + 1:end]):
        fail(f"account {username!r} already exists in this client array")
    if kind == "vmess":
        entry = {"id": credential, "alterId": 32, "email": username}
    elif kind == "vless":
        entry = {"id": credential, "email": username}
    else:
        entry = {"password": credential, "email": username}
    entry_line = json.dumps(entry, separators=(",", ":"), ensure_ascii=False)
    metadata = prefix + username + " " + expiry
    if legacy:
        # Old templates use a hidden initial client as the insertion anchor.
        entry_line = "}," + entry_line[1:-1]
    else:
        existing = sum(line.startswith(prefix) for line in lines[marker_index + 1:end])
        if existing:
            entry_line += ","
    lines[marker_index + 1:marker_index + 1] = [metadata, entry_line]
    write(path, lines, mode)


def remove(path, marker, username, expiry=None, by_user=False):
    lines, mode = load(path)
    marker_index, end, legacy = block(lines, marker)
    if legacy:
        fail("legacy client layout uses the compatibility removal path", 3)
    prefix = "#&# " if marker == "#xray-trojan" else ("#### " if "vless" in marker else "### ")
    target = prefix + username + " "
    if expiry is not None:
        target += expiry
    kept = []
    found = 0
    i = marker_index + 1
    while i < end:
        line = lines[i]
        if line.startswith(target) and (by_user or line == target):
            if i + 1 >= end:
                fail(f"account object for {username!r} is missing")
            try:
                json.loads(lines[i + 1].strip().rstrip(","))
            except json.JSONDecodeError:
                fail(f"account object for {username!r} is not a one-line JSON object")
            found += 1
            i += 2
            continue
        kept.append(line)
        i += 1
    if not found:
        fail(f"account {username!r} was not found", 4)
    # Rebuild just the account entries so the final JSON object has no trailing comma.
    records = []
    j = 0
    while j < len(kept):
        line = kept[j]
        if line.startswith(prefix) and j + 1 < len(kept):
            try:
                entry = json.loads(kept[j + 1].strip().rstrip(","))
            except json.JSONDecodeError:
                records.append(line)
                j += 1
                continue
            records.append((line, json.dumps(entry, separators=(",", ":"), ensure_ascii=False)))
            j += 2
            continue
        records.append(line)
        j += 1
    normalized = []
    indexes = [i for i, item in enumerate(records) if isinstance(item, tuple)]
    last_account = indexes[-1] if indexes else -1
    for i, item in enumerate(records):
        if isinstance(item, tuple):
            metadata, entry_line = item
            normalized.extend([metadata, entry_line + ("," if i != last_account else "")])
        else:
            normalized.append(item)
    lines[marker_index + 1:end] = normalized
    write(path, lines, mode)


args = sys.argv[1:]
if not args:
    fail("usage: ssh-one-xray-accounts {mode|add|remove|remove-user|getid} ...", 2)
action = args[0]
if action == "mode" and len(args) == 3:
    lines, _ = load(args[1])
    _, _, legacy = block(lines, args[2])
    print("legacy" if legacy else "empty")
elif action == "add" and len(args) == 7:
    add(*args[1:])
elif action == "remove" and len(args) == 5:
    remove(args[1], args[2], args[3], args[4])
elif action == "remove-user" and len(args) == 4:
    remove(args[1], args[2], args[3], by_user=True)
elif action == "getid" and len(args) == 4:
    lines, _ = load(args[1])
    wanted = args[2] + args[3] + " "
    for i, line in enumerate(lines[:-1]):
        if line.startswith(wanted):
            for candidate in lines[i + 1:i + 6]:
                match = re.search(r'"id"\s*:\s*"([^"]+)"', candidate)
                if match:
                    print(match.group(1))
                    raise SystemExit(0)
    fail(f"ID for account {args[3]!r} was not found", 4)
else:
    fail("invalid arguments", 2)
PY
