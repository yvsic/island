#!/bin/bash
# Turns a fresh Oracle Cloud (Ubuntu) server into a private VLESS + REALITY
# server for Island, then prints the vless:// link to paste into Island.
# No domain or certificate needed: REALITY borrows the TLS look of a big site.
# Run on the server:  sudo bash oracle-server-setup.sh
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }

PORT=443
DEST=www.microsoft.com   # the site REALITY imitates; must support TLS 1.3 + h2

echo "1/5 Installing xray (official installer)…"
apt-get update -qq && apt-get install -y -qq curl unzip iptables-persistent >/dev/null 2>&1 || apt-get install -y -qq curl unzip >/dev/null
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null

echo "2/5 Making keys…"
XRAY=/usr/local/bin/xray
ID=$($XRAY uuid)
KEYS=$($XRAY x25519)
PRIV=$(echo "$KEYS" | awk -F': ' '/^PrivateKey/{print $2}')
PUB=$(echo "$KEYS" | awk -F': ' '/PublicKey|^Password/{print $2}' | head -1)
SID=$(openssl rand -hex 8)

echo "3/5 Writing config (no logs kept)…"
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "none", "access": "none", "error": "none" },
  "inbounds": [{
    "listen": "0.0.0.0", "port": $PORT, "protocol": "vless",
    "settings": { "clients": [{ "id": "$ID", "flow": "xtls-rprx-vision" }], "decryption": "none" },
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": {
        "dest": "$DEST:443", "serverNames": ["$DEST"],
        "privateKey": "$PRIV", "shortIds": ["$SID"]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true }
  }],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }, { "protocol": "blackhole", "tag": "block" }],
  "routing": { "rules": [{ "type": "field", "ip": ["geoip:private"], "outboundTag": "block" }] }
}
EOF
chmod 644 /usr/local/etc/xray/config.json
$XRAY run -test -c /usr/local/etc/xray/config.json >/dev/null

echo "4/5 Opening port $PORT and speeding up TCP…"
# Oracle's Ubuntu images block everything but SSH in iptables, on top of the cloud firewall.
iptables -C INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport $PORT -j ACCEPT
command -v netfilter-persistent >/dev/null && netfilter-persistent save >/dev/null 2>&1 || true
# BBR congestion control: noticeably faster on long-distance links.
grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf || {
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
}
sysctl -p >/dev/null 2>&1 || true

echo "5/5 Starting xray…"
systemctl enable xray >/dev/null 2>&1
systemctl restart xray
sleep 1
systemctl is-active --quiet xray || { echo "xray didn't start: journalctl -u xray"; exit 1; }

IP=$(curl -fsS4 https://api.ipify.org || hostname -I | awk '{print $1}')
echo
echo "Done. Copy this whole line, then click Add a Server in Island:"
echo
echo "vless://$ID@$IP:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$DEST&fp=chrome&pbk=$PUB&sid=$SID&type=tcp#Oracle"
echo
echo "Treat it like a password."
