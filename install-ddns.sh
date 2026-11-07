#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行：sudo bash $0" >&2
  exit 1
fi

for cmd in python3 curl systemctl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "缺少依赖: $cmd，请先安装。" >&2
    exit 1
  fi
done

INSTALL_DIR="/opt/cf-ddns"
CONF_FILE="/etc/cf-ddns.conf"
SERVICE_FILE="/etc/systemd/system/cf-ddns.service"
TIMER_FILE="/etc/systemd/system/cf-ddns.timer"

CF_API_TOKEN="${CF_API_TOKEN:-}"
ZONE_ID="${ZONE_ID:-}"
RECORD_NAME="${RECORD_NAME:-}"
RECORD_TYPE="${RECORD_TYPE:-A}"
INTERVAL="${INTERVAL:-5}"

if [[ -f "$CONF_FILE" ]]; then
  _ENV_TOKEN="$CF_API_TOKEN"; _ENV_ZONE="$ZONE_ID"; _ENV_NAME="$RECORD_NAME"; _ENV_TYPE="$RECORD_TYPE"
  # shellcheck disable=SC1090
  source "$CONF_FILE"
  CF_API_TOKEN="${_ENV_TOKEN:-${CF_API_TOKEN:-}}"
  ZONE_ID="${_ENV_ZONE:-${ZONE_ID:-}}"
  RECORD_NAME="${_ENV_NAME:-${RECORD_NAME:-}}"
  RECORD_TYPE="${_ENV_TYPE:-${RECORD_TYPE:-}}"
fi

if [[ -z "$CF_API_TOKEN" ]]; then read -rsp "请输入 Cloudflare API Token: " CF_API_TOKEN; echo; fi
if [[ -z "$ZONE_ID" ]]; then read -rp "请输入 Zone ID: " ZONE_ID; fi
if [[ -z "$RECORD_NAME" ]]; then read -rp "请输入域名 (短名称或完整域名均可，如 kyokyo0412 或 kyokyo0412.example.com): " RECORD_NAME; fi
if [[ "$RECORD_TYPE" != "A" && "$RECORD_TYPE" != "AAAA" ]]; then echo "RECORD_TYPE 只能是 A 或 AAAA" >&2; exit 1; fi

echo "→ 正在验证凭据 ..."
resp=$(curl -sS -H "Authorization: Bearer $CF_API_TOKEN" "https://api.cloudflare.com/client/v4/zones/$ZONE_ID") || { echo "网络失败" >&2; exit 1; }
if ! printf '%s' "$resp" | python3 -c 'import sys,json; sys.exit(0 if json.load(sys.stdin).get("success") else 1)'; then
  echo "凭据验证失败。" >&2; echo "$resp" >&2; exit 1
fi
echo "  ✓ 凭据有效"

mkdir -p "$INSTALL_DIR"

cat > "$INSTALL_DIR/ddns.py" <<'PYEOF'
#!/usr/bin/env python3
"""
Cloudflare DDNS - 自动 FQDN 补全与清理模式。
- 从 Zone API 获取根域名，自动将短名称补全为 FQDN。
- 清理时同时按 FQDN 和原始短名称查询，删除所有冲突的遗留记录。
- 最终创建唯一正确的 FQDN 记录，避免 81058。
"""
import json, sys, ipaddress, urllib.request, urllib.error, urllib.parse

CONF_PATH = "/etc/cf-ddns.conf"
API = "https://api.cloudflare.com/client/v4"
IP_SOURCES = {"A": ["https://checkip.amazonaws.com", "https://ipv4.icanhazip.com", "https://api.ipify.org"],
              "AAAA": ["https://ipv6.icanhazip.com", "https://api6.ipify.org"]}

def load_conf():
    conf = {}
    with open(CONF_PATH) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1); v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'": v = v[1:-1]
                conf[k.strip()] = v
    return conf

def api(method, path, token, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code}: {e.read().decode()}") from e
    except urllib.error.URLError as e:
        raise RuntimeError(f"网络错误: {e.reason}") from e

def get_public_ip(record_type):
    for url in IP_SOURCES[record_type]:
        try:
            with urllib.request.urlopen(url, timeout=10) as r:
                ip = r.read().decode().strip(); ipaddress.ip_address(ip); return ip
        except Exception: continue
    raise RuntimeError(f"无法获取公网 {record_type} 地址")

def get_zone_name(zone_id, token):
    res = api("GET", f"/zones/{zone_id}", token)
    if not res.get("success"):
        raise RuntimeError(f"无法获取 Zone 信息: {res.get('errors')}")
    return res["result"]["name"]

def list_all_records(zone_id, token, name, rtype):
    """分页获取指定 name 的所有记录"""
    all_records, page = [], 1
    while True:
        q = urllib.parse.urlencode({"type": rtype, "name": name, "page": page, "per_page": 100})
        res = api("GET", f"/zones/{zone_id}/dns_records?{q}", token)
        if not res.get("success"):
            raise RuntimeError(f"查询记录失败: {res.get('errors')}")
        all_records.extend(res.get("result", []))
        if page >= res.get("result_info", {}).get("total_pages", 1): break
        page += 1
    return all_records

def main():
    conf = load_conf()
    token, zone = conf["CF_API_TOKEN"], conf["ZONE_ID"]
    raw_name = conf["RECORD_NAME"].strip().lower()
    rtype = conf.get("RECORD_TYPE", "A")

    # --- 获取根域名并构建 FQDN ---
    zone_name = get_zone_name(zone, token).lower()
    if "." in raw_name:
        fqdn = raw_name  # 已经是 FQDN
    else:
        fqdn = f"{raw_name}.{zone_name}"  # 自动补全
    print(f"配置解析: 原始名称='{raw_name}', 根域名='{zone_name}', 将使用的 FQDN='{fqdn}'")

    ip = get_public_ip(rtype)

    # --- 收集所有需要清理的记录：同时按 FQDN 和原始短名称查询 ---
    records_to_delete = []
    seen_ids = set()

    for lookup_name in {fqdn, raw_name}:  # 去重后的集合
        try:
            found = list_all_records(zone, token, lookup_name, rtype)
        except RuntimeError as e:
            print(f"  ⚠ 查询 '{lookup_name}' 时出错，跳过: {e}")
            continue
        for r in found:
            if r["id"] not in seen_ids:
                seen_ids.add(r["id"])
                records_to_delete.append(r)

    # --- 无差别清理 ---
    if records_to_delete:
        print(f"发现 {len(records_to_delete)} 条可能冲突的 {rtype} 记录，开始清理...")
        for r in records_to_delete:
            try:
                api("DELETE", f"/zones/{zone}/dns_records/{r['id']}", token)
                print(f"  已删除: name='{r['name']}', content='{r['content']}' (id={r['id']})")
            except RuntimeError as e:
                print(f"  删除 id={r['id']} 失败 (可能已不存在): {e}")

    # --- 创建唯一正确的 FQDN 记录 ---
    print(f"正在创建唯一记录: {fqdn} -> {ip}")
    try:
        res = api("POST", f"/zones/{zone}/dns_records", token, {
            "type": rtype, "name": fqdn, "content": ip, "ttl": 60, "proxied": False,
        })
        if not res.get("success"):
            raise RuntimeError(f"创建失败: {res.get('errors')}")
        print(f"✓ 成功创建 {rtype} 记录 {fqdn} -> {ip}")
    except RuntimeError as e:
        if "81058" in str(e):
            print(f"✗ 清理后创建仍然返回 81058。", file=sys.stderr)
            print(f"  可能还存在脚本不可见的冲突（如 stale DCV 记录）。", file=sys.stderr)
            print(f"  请登录 Cloudflare Dashboard 检查是否有手动创建的短名称记录或隐藏的 TXT 记录。", file=sys.stderr)
        raise

if __name__ == "__main__":
    try: main()
    except Exception as e: print(f"错误: {e}", file=sys.stderr); sys.exit(1)
PYEOF

chmod 755 "$INSTALL_DIR/ddns.py"

umask 077
cat > "$CONF_FILE" <<EOF
CF_API_TOKEN="$CF_API_TOKEN"
ZONE_ID="$ZONE_ID"
RECORD_NAME="$RECORD_NAME"
RECORD_TYPE="$RECORD_TYPE"
EOF
chmod 600 "$CONF_FILE"

cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Cloudflare DDNS Update
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/cf-ddns/ddns.py
EOF

cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Run Cloudflare DDNS every ${INTERVAL} minutes
[Timer]
OnBootSec=1min
OnUnitActiveSec=${INTERVAL}min
Unit=cf-ddns.service
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now cf-ddns.timer >/dev/null 2>&1

echo "→ 立即执行一次清理与 FQDN 重建测试 ..."
systemctl start cf-ddns.service || true
sleep 2
journalctl -u cf-ddns.service -n 40 --no-pager -o cat || true

echo -e "\n✅ 安装完成 (模式: 自动 FQDN 补全 + 清理重建)"
echo "   程序: $INSTALL_DIR/ddns.py"
echo "   配置: $CONF_FILE (权限 600)"
echo "   定时: 每 ${INTERVAL} 分钟"
echo "   日志: journalctl -u cf-ddns.service -f"
