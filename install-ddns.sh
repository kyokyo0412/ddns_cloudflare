#!/usr/bin/env bash
set -euo pipefail

# ============ 基础检查 ============
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

# ============ 读取参数 ============
CF_API_TOKEN="${CF_API_TOKEN:-}"
ZONE_ID="${ZONE_ID:-}"
RECORD_NAME="${RECORD_NAME:-}"
RECORD_TYPE="${RECORD_TYPE:-A}"
INTERVAL="${INTERVAL:-5}"

if [[ -z "$CF_API_TOKEN" ]]; then
  read -rsp "请输入 Cloudflare API Token: " CF_API_TOKEN; echo
fi
if [[ -z "$ZONE_ID" ]]; then
  read -rp  "请输入 Zone ID: " ZONE_ID
fi
if [[ -z "$RECORD_NAME" ]]; then
  read -rp  "请输入要 DDNS 的完整域名 (如 home.example.com): " RECORD_NAME
fi
if [[ "$RECORD_TYPE" != "A" && "$RECORD_TYPE" != "AAAA" ]]; then
  echo "RECORD_TYPE 只能是 A 或 AAAA" >&2
  exit 1
fi

# ============ 验证凭据 ============
echo "→ 正在验证 API Token 与 Zone ID ..."
resp=$(curl -sS -H "Authorization: Bearer $CF_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID") || {
  echo "请求 Cloudflare API 失败，请检查网络。" >&2
  exit 1
}
if ! printf '%s' "$resp" | python3 -c '
import sys, json
try:
    sys.exit(0 if json.load(sys.stdin).get("success") else 1)
except Exception:
    sys.exit(1)
'; then
  echo "验证失败。返回内容：" >&2
  echo "$resp" >&2
  echo "请检查 Token 权限（需 Zone.DNS:Edit + Zone.Zone:Read）和 Zone ID 是否正确。" >&2
  exit 1
fi
echo "  ✓ 凭据有效"

# ============ 写入程序 ============
mkdir -p "$INSTALL_DIR"

cat > "$INSTALL_DIR/ddns.py" <<'PYEOF'
#!/usr/bin/env python3
"""Cloudflare DDNS：仅在公网 IP 变化时更新 A/AAAA 记录；记录不存在则自动创建。"""
import json
import sys
import ipaddress
import urllib.request
import urllib.error
import urllib.parse

CONF_PATH = "/etc/cf-ddns.conf"
API = "https://api.cloudflare.com/client/v4"
IP_SOURCES = {
    "A": ["https://checkip.amazonaws.com",
          "https://ipv4.icanhazip.com",
          "https://api.ipify.org"],
    "AAAA": ["https://ipv6.icanhazip.com",
             "https://api6.ipify.org"],
}

def load_conf():
    conf = {}
    try:
        with open(CONF_PATH) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                    v = v[1:-1]
                conf[k.strip()] = v
    except FileNotFoundError:
        sys.exit(f"配置文件不存在: {CONF_PATH}")
    return conf

def api(method, path, token, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        API + path, data=data, method=method,
        headers={"Authorization": f"Bearer {token}",
                 "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            res = json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code}: {e.read().decode()}") from e
    except urllib.error.URLError as e:
        raise RuntimeError(f"网络错误: {e.reason}") from e
    if not res.get("success"):
        raise RuntimeError(f"Cloudflare API 失败: {res.get('errors')}")
    return res

def get_public_ip(record_type):
    for url in IP_SOURCES[record_type]:
        try:
            with urllib.request.urlopen(url, timeout=10) as r:
                ip = r.read().decode().strip()
            ipaddress.ip_address(ip)  # 校验格式
            return ip
        except Exception:
            continue
    raise RuntimeError(f"无法获取公网 {record_type} 地址")

def main():
    conf = load_conf()
    token = conf["CF_API_TOKEN"]
    zone = conf["ZONE_ID"]
    name = conf["RECORD_NAME"]
    rtype = conf.get("RECORD_TYPE", "A")

    ip = get_public_ip(rtype)
    query = urllib.parse.urlencode({"type": rtype, "name": name})
    records = api("GET", f"/zones/{zone}/dns_records?{query}", token)["result"]

    if not records:
        api("POST", f"/zones/{zone}/dns_records", token, {
            "type": rtype, "name": name, "content": ip,
            "ttl": 60, "proxied": False,
        })
        print(f"已创建 {rtype} 记录 {name} -> {ip}")
        return

    rec = records[0]
    if rec["content"] == ip:
        print(f"IP 未变化 ({ip})，跳过。")
        return

    api("PATCH", f"/zones/{zone}/dns_records/{rec['id']}", token, {"content": ip})
    print(f"已更新 {name}: {rec['content']} -> {ip}")

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"错误: {e}", file=sys.stderr)
        sys.exit(1)
PYEOF

chmod 755 "$INSTALL_DIR/ddns.py"

# ============ 写入凭据（权限 600） ============
umask 077
cat > "$CONF_FILE" <<EOF
CF_API_TOKEN="$CF_API_TOKEN"
ZONE_ID="$ZONE_ID"
RECORD_NAME="$RECORD_NAME"
RECORD_TYPE="$RECORD_TYPE"
EOF
chmod 600 "$CONF_FILE"

# ============ 安装 systemd 单元 ============
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

# ============ 立即执行一次验证 ============
echo "→ 立即执行一次更新测试 ..."
systemctl start cf-ddns.service || true
sleep 2
journalctl -u cf-ddns.service -n 10 --no-pager -o cat || true

echo
echo "✅ 安装完成"
echo "   程序:   $INSTALL_DIR/ddns.py"
echo "   配置:   $CONF_FILE (权限 600)"
echo "   定时:   每 ${INTERVAL} 分钟"
echo
echo "常用命令："
echo "  查看定时器:  systemctl list-timers cf-ddns.timer"
echo "  查看日志:    journalctl -u cf-ddns.service -f"
echo "  手动执行:    systemctl start cf-ddns.service"
echo "  修改配置:    sudo nano $CONF_FILE"
