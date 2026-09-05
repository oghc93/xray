#!/bin/bash
# ============================================================
#  CHANELOG VPN SCRIPT - XRAY DEVICE LIMITER (Limit Device/IP)
#  Jalan via cron tiap 2 menit. Cek jumlah device/IP yang lagi
#  online bersamaan per akun (VMess/VLess/Trojan/Shadowsocks)
#  lewat Xray Stats API (statsUserOnline), lawan ip_limit yang
#  di-set saat create akun / lewat menu Edit Limit. Kalau lampau,
#  akun di-"bounce" (client dicabut dari config Xray lalu LANGSUNG
#  dipasang ulang) supaya SEMUA koneksi aktif akun itu putus dan
#  device yang masih dalam batas limit bisa connect ulang. Ini
#  BUKAN suspend permanen seperti quota-limiter.sh -- akun tetap
#  aktif, cuma dipaksa reconnect.
#
#  !! KENAPA DI-BATCH JADI 1 RESTART, BUKAN 1x PER AKUN !!
#  Unit systemd Xray gak punya ExecReload, jadi tiap kali config
#  diubah, Xray HARUS di-restart penuh (bukan reload) supaya
#  perubahan kepakai -- ini artinya SEMUA user Xray di server
#  (bukan cuma akun yang kena limit) ikut putus sebentar tiap kali
#  restart terjadi. Kalau tiap akun yang lampau limit langsung
#  memicu restart sendiri-sendiri, dan ada 3 akun lampau limit di
#  siklus yang sama, itu jadi 3x restart beruntun ("dc dc") dalam
#  hitungan detik -- padahal cukup 1x restart aja buat nerapin
#  semua perubahan sekaligus. Makanya di sini SEMUA akun yang
#  lampau limit dikumpulkan dulu, config diedit utk semuanya, baru
#  di akhir script di-restart SATU KALI.
#  Ditambah cooldown per akun (lihat BOUNCE_COOLDOWN_SEC) supaya
#  akun yang emang rutin kelebihan device gak bikin server
#  restart tiap 2 menit terus-menerus -- dia cuma di-bounce ulang
#  paling cepat tiap 5 menit, sisanya cuma dicatat di log.
#
#  !! SYARAT WAJIB SUPAYA BENERAN AKURAT !!
#  statsUserOnline Xray cuma akurat kalau Xray bisa lihat IP ASLI
#  client. Karena semua Xray-WS di server ini selalu di-proxy
#  lewat Nginx -> 127.0.0.1, itu CUMA kejadian kalau inbound WS
#  Xray sudah diaktifkan "acceptProxyProtocol" (di install.sh
#  versi ini sudah default aktif utk instalasi baru; utk VPS yang
#  sudah lama jalan, jalankan dulu addon/enable-xray-realip.sh).
#  Kalau belum aktif, script ini SENGAJA skip semua akun (bukan
#  jalan diam-diam dengan angka yang salah) dan cuma catat 1 baris
#  warning ke syslog -- supaya gak kasih rasa aman palsu.
# ============================================================

SCRIPT_DIR="/etc/vpn-script"
source "$SCRIPT_DIR/lib.sh"

STATE_DIR="$SCRIPT_DIR/.xray-device-limiter-state"
mkdir -p "$STATE_DIR"
NOTIFY_COOLDOWN_SEC=600   # jarak minimal antar notifikasi Telegram utk akun yang sama
BOUNCE_COOLDOWN_SEC=300   # jarak minimal antar BOUNCE NYATA utk akun yang sama (anti restart beruntun)
WARN_FLAG="$STATE_DIR/.realip-not-active"

command -v xray >/dev/null 2>&1 || exit 0
[[ -f "$XRAY_CONFIG" ]] || exit 0

# Cek prasyarat: minimal 1 inbound WS sudah acceptProxyProtocol=true.
if ! jq -e '[.inbounds[]? | select(.streamSettings.network=="ws") | .streamSettings.sockopt.acceptProxyProtocol // false] | any' \
    "$XRAY_CONFIG" >/dev/null 2>&1; then
  if [[ ! -f "$WARN_FLAG" ]]; then
    logger -t vpn-script "xray-device-limiter: SKIP -- acceptProxyProtocol belum aktif di config Xray, limit device/IP Xray belum efektif. Jalankan: bash $SCRIPT_DIR/addon/enable-xray-realip.sh"
    touch "$WARN_FLAG"
  fi
  exit 0
fi
rm -f "$WARN_FLAG"

need_restart=0

notify_kena_limit() {
  local proto="$1" user="$2" online="$3" limit="$4"
  local state_file="$STATE_DIR/notify_${proto}_${user}"
  local last=$(cat "$state_file" 2>/dev/null || echo 0)
  local now=$(date +%s)
  logger -t vpn-script "xray-device-limiter: [$proto] '$user' $online device online > limit $limit, koneksi di-bounce"
  if (( now - last >= NOTIFY_COOLDOWN_SEC )); then
    tg_notify "🔌 <b>Limit Device/IP Tercapai</b>

Protokol      : <code>$proto</code>
Username      : <code>$user</code>
Device online : <code>$online</code>
Limit         : <code>$limit</code>
Aksi          : semua koneksi aktif akun ini diputus, device dalam batas limit bisa connect ulang." "limit"
    echo "$now" > "$state_file"
  fi
}

check_and_bounce() {
  local proto="$1" tag_prefix="$2" user="$3" ip_limit="$4"
  [[ -z "$user" ]] && return
  ip_limit="${ip_limit:-0}"
  [[ "$ip_limit" =~ ^[0-9]+$ ]] || return
  [[ "$ip_limit" -eq 0 ]] && return                       # 0 = unlimited
  is_quota_disabled "$proto" "$user" && return             # lagi disuspend krn kuota, biarkan quota-limiter yg urus

  local online
  online=$(get_xray_user_online "$user")
  [[ "$online" =~ ^[0-9]+$ ]] || return
  [[ "$online" -le "$ip_limit" ]] && return

  # Cooldown bounce NYATA per akun -- kalau baru di-bounce < 5 menit
  # lalu, jangan bounce lagi sekarang (cukup catat di log), supaya
  # 1 akun bandel gak bikin server restart tiap 2 menit terus.
  local bounce_state="$STATE_DIR/bounce_${proto}_${user}"
  local last_bounce=$(cat "$bounce_state" 2>/dev/null || echo 0)
  local now=$(date +%s)
  if (( now - last_bounce < BOUNCE_COOLDOWN_SEC )); then
    logger -t vpn-script "xray-device-limiter: [$proto] '$user' masih $online online > limit $ip_limit, tapi masih dalam cooldown bounce -- dilewati siklus ini"
    return
  fi

  xray_disable_client "$tag_prefix" "$user"
  xray_readd_client_config "$proto" "$user"   # config-only, TIDAK restart di sini (lihat catatan di atas)
  echo "$now" > "$bounce_state"
  notify_kena_limit "$proto" "$user" "$online" "$ip_limit"
  need_restart=1
}

while IFS='|' read -r user uuid exp created ip_limit quota_mb; do
  check_and_bounce "vmess" "vmess" "$user" "$ip_limit"
done < <(list_vmess)

while IFS='|' read -r user uuid exp created ip_limit quota_mb; do
  check_and_bounce "vless" "vless" "$user" "$ip_limit"
done < <(list_vless)

while IFS='|' read -r user pass exp created ip_limit quota_mb; do
  check_and_bounce "trojan" "trojan" "$user" "$ip_limit"
done < <(list_trojan)

while IFS='|' read -r user pass method exp created ip_limit quota_mb; do
  check_and_bounce "ss" "ss-" "$user" "$ip_limit"
done < <(list_ss)

# SATU restart utk semua akun yang di-bounce di siklus ini (bukan 1x per akun).
[[ "$need_restart" -eq 1 ]] && xray_reload_or_restart
