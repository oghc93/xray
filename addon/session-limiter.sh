#!/bin/bash
# ============================================================
#  CHANELOG VPN SCRIPT - SESSION LIMITER (Limit Device/IP SSH)
#  Jalan via cron tiap 2 menit. Hitung berapa sesi SSH yang lagi
#  AKTIF BERSAMAAN per akun (SSH Direct, SSH-SSL via Stunnel/
#  HAProxy, SSH-WS via ws-dropbear/ws-openssh -- SEMUA jalur),
#  lawan session_limit yang di-set saat create akun / lewat menu
#  Edit Limit. Kalau lampau, sesi TERTUA diputus otomatis sampai
#  jumlahnya pas dengan limit. Sesi yang lebih baru TIDAK
#  diganggu. Akun TIDAK di-suspend/dikunci -- device yang masih
#  dalam batas limit tetap bisa connect seperti biasa.
#
#  Kenapa hitung JUMLAH SESI, bukan IP asli client?
#  Dropbear/OpenSSH di server ini menjalankan proses tiap koneksi
#  sebagai UID akun itu sendiri setelah autentikasi (shell akun
#  memang /bin/false -- akun ini cuma dipakai buat tunneling,
#  bukan login shell, jadi 1 proses aktif = 1 koneksi/device).
#  Karena SSH-WS selalu lewat proxy Nginx -> ws-dropbear/
#  ws-openssh -> 127.0.0.1, Dropbear/OpenSSH TIDAK PERNAH lihat
#  IP asli client (semua kelihatan dari 127.0.0.1) -- jadi
#  "limit IP" beneran gak bisa dicek dari sisi Dropbear/OpenSSH.
#  Hitung sesi aktif per akun adalah cara yang akurat & gak
#  tergantung IP asli untuk arsitektur proxy seperti ini, dan
#  secara praktik mencapai tujuan yang sama: membatasi berapa
#  device boleh connect bersamaan per akun.
# ============================================================

SCRIPT_DIR="/etc/vpn-script"
source "$SCRIPT_DIR/lib.sh"

STATE_DIR="$SCRIPT_DIR/.session-limiter-state"
mkdir -p "$STATE_DIR"
COOLDOWN_SEC=600   # jarak minimal antar notifikasi Telegram utk akun yang sama

notify_kena_limit() {
  local user="$1" active="$2" limit="$3" killed="$4"
  local state_file="$STATE_DIR/$user"
  local last=$(cat "$state_file" 2>/dev/null || echo 0)
  local now=$(date +%s)
  logger -t vpn-script "session-limiter: '$user' $active sesi aktif > limit $limit, $killed sesi tertua diputus"
  if (( now - last >= COOLDOWN_SEC )); then
    tg_notify "🔌 <b>Limit Device/IP SSH Tercapai</b>

Username     : <code>$user</code>
Sesi aktif   : <code>$active</code>
Limit        : <code>$limit</code>
Aksi         : $killed sesi tertua diputus otomatis, device dalam batas limit tetap jalan." "limit"
    echo "$now" > "$state_file"
  fi
}

while IFS='|' read -r user pass exp created session_limit quota_mb; do
  [[ -z "$user" ]] && continue
  session_limit="${session_limit:-0}"
  [[ "$session_limit" =~ ^[0-9]+$ ]] || continue
  [[ "$session_limit" -eq 0 ]] && continue   # 0 = unlimited, skip
  id "$user" &>/dev/null || continue          # akun linux-nya gak ada, skip

  # PID milik UID akun ini + umur proses (etimes, detik) -- makin
  # besar etimes makin lama/tua sesinya. Urut dari PALING TUA dulu.
  mapfile -t pids < <(ps -u "$user" -o etimes=,pid= 2>/dev/null | sort -rn -k1,1 | awk '{print $2}')
  active="${#pids[@]}"   # setara get_ssh_active_sessions "$user", tapi PID-nya sudah kepakai lagi di bawah
  [[ "$active" -le "$session_limit" ]] && continue

  excess=$(( active - session_limit ))
  killed=0
  for ((i = 0; i < excess; i++)); do
    pid="${pids[$i]}"
    [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null && killed=$((killed + 1))
  done

  [[ "$killed" -gt 0 ]] && notify_kena_limit "$user" "$active" "$session_limit" "$killed"
done < <(list_ssh)
