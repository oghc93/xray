#!/bin/bash
# ============================================================
#  enable-xray-realip.sh
#  CHANELOG VPN SCRIPT
#
#  Aktifkan PROXY protocol antara Nginx <-> Xray utk 6 inbound WS
#  (vmess-ws-tls, vless-ws-tls, vmess-ws-ntls, vless-ws-ntls,
#  trojan-ws-tls, ss-ws-tls). Ini PRASYARAT WAJIB supaya Xray bisa
#  lihat IP asli client (bukan cuma 127.0.0.1 dari Nginx), yang
#  artinya juga prasyarat wajib supaya statsUserOnline (dipakai
#  addon/xray-device-limiter.sh, "Limit Device/IP") beneran akurat.
#
#  SSH-WS/ssh-ws-ssh SENGAJA TIDAK disentuh -- limit device SSH
#  pakai hitung sesi aktif per akun (addon/session-limiter.sh),
#  bukan real-IP, jadi gak butuh perubahan ini.
#  gRPC inbound (vmess-grpc, vless-grpc, trojan-grpc, ss-grpc)
#  JUGA TIDAK disentuh (nginx grpc_pass beda mekanisme dari
#  proxy_pass) -- device limit utk gRPC belum dicakup skrip ini.
#
#  Aman dijalankan berkali-kali (idempotent, skip yang sudah aktif)
#  + backup otomatis (Nginx & Xray) + rollback kalau nginx -t /
#  xray run -test gagal setelah dipatch.
#
#  SYARAT: dipakai di VPS dengan layout Nginx all-in-one dari
#  install.sh versi ini (tag/port inbound Xray harus sama persis:
#  10001/10002/10003/10004/10005/10007). Kalau layout Nginx-mu
#  sudah dimodifikasi manual / pakai addon multiplex 443, skrip
#  ini otomatis SKIP baris yang jumlah/bentuknya gak sesuai
#  ekspektasi (gak akan maksa ubah sesuatu yang gak dikenali).
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}[ERROR]${NC} Jalankan sebagai root!"
  exit 1
fi

NGINX_CONF="/etc/nginx/conf.d/xray.conf"
XRAY_CONFIG="/etc/xray/config.json"

command -v nginx >/dev/null 2>&1 || { echo -e "${RED}[ERROR]${NC} Nginx belum terinstall."; exit 1; }
command -v xray  >/dev/null 2>&1 || { echo -e "${RED}[ERROR]${NC} Xray belum terinstall."; exit 1; }
command -v jq    >/dev/null 2>&1 || { echo -e "${RED}[ERROR]${NC} jq belum terinstall."; exit 1; }
[[ -f "$NGINX_CONF" ]]   || { echo -e "${RED}[ERROR]${NC} $NGINX_CONF tidak ditemukan."; exit 1; }
[[ -f "$XRAY_CONFIG" ]]  || { echo -e "${RED}[ERROR]${NC} $XRAY_CONFIG tidak ditemukan."; exit 1; }

echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
echo -e "  Aktifkan Real-IP (PROXY protocol) Nginx -> Xray"
echo -e "${CYAN}══════════════════════════════════════════════════${NC}"

TS=$(date +%Y%m%d%H%M%S)
NGINX_BACKUP="${NGINX_CONF}.bak.${TS}"
XRAY_BACKUP="${XRAY_CONFIG}.bak.${TS}"
cp "$NGINX_CONF" "$NGINX_BACKUP"
cp "$XRAY_CONFIG" "$XRAY_BACKUP"
echo -e "${YELLOW}[*]${NC} Backup dibuat:"
echo -e "    $NGINX_BACKUP"
echo -e "    $XRAY_BACKUP"

# ── 1. Patch Nginx: tambah "proxy_protocol on;" di 6 location WS Xray ──
echo -e "\n${YELLOW}[*]${NC} Patch Nginx (${NGINX_CONF})..."
PORTS=(10001 10002 10003 10004 10005 10007)
for port in "${PORTS[@]}"; do
  count=$(grep -c "proxy_pass http://127\.0\.0\.1:${port};" "$NGINX_CONF")
  if [[ "$count" -ne 1 ]]; then
    echo -e "  ${YELLOW}[SKIP]${NC} Port $port: ditemukan $count baris proxy_pass (harusnya 1) -- layout beda dari yang diharapkan, dilewati demi keamanan."
    continue
  fi
  if grep -A1 "proxy_pass http://127\.0\.0\.1:${port};" "$NGINX_CONF" | grep -q "proxy_protocol on;"; then
    echo -e "  ${CYAN}[SKIP]${NC} Port $port: proxy_protocol sudah aktif."
    continue
  fi
  sed -i "s|proxy_pass http://127\.0\.0\.1:${port};|proxy_pass http://127.0.0.1:${port};\n        proxy_protocol on;|" "$NGINX_CONF"
  echo -e "  ${GREEN}[OK]${NC} Port $port: proxy_protocol diaktifkan."
done

# ── 2. Patch Xray: tambah sockopt.acceptProxyProtocol di 6 inbound WS ──
echo -e "\n${YELLOW}[*]${NC} Patch Xray (${XRAY_CONFIG})..."
TMP_XRAY=$(mktemp)
jq '
  (.inbounds[] | select(.tag=="vmess-ws-tls" or .tag=="vless-ws-tls" or .tag=="vmess-ws-ntls"
    or .tag=="vless-ws-ntls" or .tag=="trojan-ws-tls" or .tag=="ss-ws-tls")
    | .streamSettings.sockopt) |= ((. // {}) + {"acceptProxyProtocol": true})
' "$XRAY_CONFIG" > "$TMP_XRAY" && mv "$TMP_XRAY" "$XRAY_CONFIG"
echo -e "  ${GREEN}[OK]${NC} 6 inbound WS Xray (vmess/vless/trojan/ss) diaktifkan acceptProxyProtocol."

# ── 3. Validasi + apply, rollback kalau gagal ──
echo -e "\n${YELLOW}[*]${NC} Validasi konfigurasi..."
NGINX_OK=1; XRAY_OK=1
nginx -t 2>/tmp/nginx_realip_test.log || NGINX_OK=0
xray run -test -config "$XRAY_CONFIG" >/tmp/xray_realip_test.log 2>&1 || XRAY_OK=0

if [[ "$NGINX_OK" -eq 1 && "$XRAY_OK" -eq 1 ]]; then
  systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null
  systemctl restart xray 2>/dev/null
  echo -e "\n${GREEN}══════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}[OK]${NC} Real-IP aktif. Nginx & Xray sudah di-reload."
  echo -e "${GREEN}[OK]${NC} addon/xray-device-limiter.sh sekarang bisa jalan akurat."
  echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
else
  echo -e "\n${RED}[GAGAL]${NC} Konfigurasi baru error, rollback ke versi sebelumnya..."
  [[ "$NGINX_OK" -eq 0 ]] && { echo -e "${RED}-- nginx -t --${NC}"; cat /tmp/nginx_realip_test.log; }
  [[ "$XRAY_OK" -eq 0 ]]  && { echo -e "${RED}-- xray run -test --${NC}"; cat /tmp/xray_realip_test.log; }
  cp "$NGINX_BACKUP" "$NGINX_CONF"
  cp "$XRAY_BACKUP" "$XRAY_CONFIG"
  systemctl reload nginx 2>/dev/null
  echo -e "${YELLOW}[INFO]${NC} Rollback selesai, config dikembalikan ke versi sebelumnya. Xray TIDAK direstart (config lama masih jalan)."
  exit 1
fi
