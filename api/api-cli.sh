#!/bin/bash
# ============================================================
#  API BRIDGE — dipanggil oleh backend PHP (index.php)
#  Tugasnya cuma satu: terima perintah lewat argumen,
#  panggil fungsi asli di lib.sh, keluarkan JSON ke stdout.
#  Script asli (create_vmess, dkk) TIDAK diubah sama sekali.
#
#  Install di: /etc/vpn-script/api/api-cli.sh
#  Jalan sebagai root lewat sudo (lihat README-DEPLOY.md)
#
#  CATATAN PERBAIKAN (dari sesi debugging):
#  - "set -e" dibuang (jadi "set -uo pipefail" saja) karena
#    beberapa fungsi asli di lib.sh (mis. reset_xray_user_traffic)
#    bisa return non-zero untuk kegagalan yang sebenarnya tidak
#    fatal (mis. Xray API stats belum aktif) — dengan "set -e"
#    itu mematikan seluruh bridge tanpa output apa pun.
#  - baris terakhir lib.sh punya idiom
#    `[[ "${BASH_SOURCE[0]}" == "${0}" ]] && "$@"` yang exit
#    status-nya ikut jadi status "source" — makanya ditambah
#    `|| true` di baris source supaya tidak dianggap gagal.
#  - gen_*_link butuh 5 argumen (yang ke-5/"remark" opsional),
#    tapi karena lib.sh pakai `set -u` di beberapa tempat,
#    argumen ke-5 harus tetap dikirim eksplisit sebagai ""
#    kalau tidak dipakai, kalau tidak akan "unbound variable".
# ============================================================
set -uo pipefail
SCRIPT_DIR="/etc/vpn-script"
source "$SCRIPT_DIR/lib.sh" || true

json_err() { printf '{"ok":false,"error":%s}\n' "$(jq -Rn --arg m "$1" '$m')"; exit 1; }
json_ok_secret() { printf '{"ok":true,"secret":%s}\n' "$(jq -Rn --arg s "$1" '$s')"; }

case "${1:-}" in

  summary)
    xray_on=$(systemctl is-active xray 2>/dev/null || true)
    nginx_on=$(systemctl is-active nginx 2>/dev/null || true)
    db_on=$(systemctl is-active dropbear 2>/dev/null || true)
    stunnel_on=$(systemctl is-active stunnel4 2>/dev/null || true)
    haproxy_on=$(systemctl is-active haproxy 2>/dev/null || true)
    jq -n \
      --arg domain "$(get_domain)" \
      --arg ip "$(get_server_ip)" \
      --arg os "$(get_os_info)" \
      --arg uptime "$(get_uptime)" \
      --arg load "$(get_load_avg)" \
      --argjson cores "$(get_cpu_cores)" \
      --arg mem "$(get_mem_usage)" \
      --arg disk "$(get_disk_usage)" \
      --argjson vmess "$(count_vmess)" \
      --argjson vless "$(count_vless)" \
      --argjson trojan "$(count_trojan)" \
      --argjson ss "$(count_ss)" \
      --argjson ssh "$(count_ssh 2>/dev/null || wc -l < "$DB_SSH" 2>/dev/null || echo 0)" \
      --arg xray "$xray_on" --arg nginx "$nginx_on" --arg dropbear "$db_on" \
      --arg stunnel4 "$stunnel_on" --arg haproxy "$haproxy_on" \
      '{domain:$domain, server_ip:$ip, os:$os, uptime:$uptime, load:$load, cpu_cores:$cores,
        mem:$mem, disk:$disk,
        counts:{vmess:$vmess, vless:$vless, trojan:$trojan, ss:$ss, sshws:$ssh},
        services:{xray:$xray, nginx:$nginx, dropbear:$dropbear, stunnel4:$stunnel4, haproxy:$haproxy}}'
    ;;

  list_accounts)
    tmp=$(mktemp)
    : > "$tmp.ndjson"
    add_rows() {
      local proto="$1" file="$2"
      [[ -f "$file" ]] || return 0
      while IFS='|' read -r c1 c2 c3 c4 c5 c6 c7; do
        [[ -z "$c1" ]] && continue
        if [[ "$proto" == "ss" ]]; then
          exp="$c4"; ip_limit="$c6"; quota_mb="$c7"
        else
          exp="$c3"; ip_limit="$c5"; quota_mb="$c6"
        fi
        jq -c -n --arg proto "$proto" --arg user "$c1" --arg exp "$exp" \
          --argjson ip_limit "${ip_limit:-0}" --argjson quota_mb "${quota_mb:-0}" \
          '{proto:$proto, username:$user, exp:$exp, ip_limit:$ip_limit, quota_mb:$quota_mb}' \
          >> "$tmp.ndjson"
      done < "$file"
    }
    add_rows vmess "$DB_VMESS"
    add_rows vless "$DB_VLESS"
    add_rows trojan "$DB_TROJAN"
    add_rows ss "$DB_SS"
    add_rows sshws "$DB_SSH"
    jq -s '.' "$tmp.ndjson" 2>/dev/null || echo "[]"
    rm -f "$tmp" "$tmp.ndjson"
    ;;

  create_account)
    proto="${2:-}"; username="${3:-}"; days="${4:-30}"; ip_limit="${5:-}"; quota_gb="${6:-0}"; trial_hours="${7:-0}"; custom_password="${8:-}"
    [[ -z "$proto" || -z "$username" ]] && json_err "proto dan username wajib diisi"
    [[ "$username" =~ ^[a-zA-Z0-9_]{3,32}$ ]] || json_err "username tidak valid (huruf/angka/underscore, 3-32 karakter)"
    quota_mb=$(( ${quota_gb%.*} * 1024 ))
    case "$proto" in
      vmess)  secret=$(create_vmess  "$username" "$days" "$ip_limit" "$quota_mb" "$trial_hours") ;;
      vless)  secret=$(create_vless  "$username" "$days" "$ip_limit" "$quota_mb" "$trial_hours") ;;
      trojan) secret=$(create_trojan "$username" "$days" "$ip_limit" "$quota_mb" "$trial_hours") ;;
      ss)     secret=$(create_ss     "$username" "$days" "$ip_limit" "$quota_mb" "$trial_hours") ;;
      sshws)  secret=$(create_ssh    "$username" "$days" "$custom_password" "$ip_limit" "$quota_mb" "$trial_hours") ;;
      *) json_err "protokol tidak dikenal: $proto" ;;
    esac
    json_ok_secret "$secret"
    ;;

  delete_account)
    proto="${2:-}"; username="${3:-}"
    [[ -z "$proto" || -z "$username" ]] && json_err "proto dan username wajib diisi"
    case "$proto" in
      vmess)  delete_vmess  "$username" ;;
      vless)  delete_vless  "$username" ;;
      trojan) delete_trojan "$username" ;;
      ss)     delete_ss     "$username" ;;
      sshws)  userdel -f "$username" 2>/dev/null; sed -i "/^$username|/d" "$DB_SSH" ;;
      *) json_err "protokol tidak dikenal: $proto" ;;
    esac
    echo '{"ok":true}'
    ;;

  toggle_service)
    svc="${2:-}"; action="${3:-}"
    allowed=(xray nginx dropbear stunnel4 haproxy)
    ok=0; for a in "${allowed[@]}"; do [[ "$svc" == "$a" ]] && ok=1; done
    [[ "$ok" -eq 1 ]] || json_err "layanan tidak diizinkan: $svc"
    [[ "$action" == "start" || "$action" == "stop" || "$action" == "restart" ]] || json_err "aksi tidak dikenal"
    systemctl "$action" "$svc" 2>/dev/null || true
    sleep 1
    state=$(systemctl is-active "$svc" 2>/dev/null || true)
    jq -n --arg svc "$svc" --arg state "$state" '{ok:true, service:$svc, state:$state}'
    ;;

  get_link)
    proto="${2:-}"; username="${3:-}"
    [[ -z "$proto" || -z "$username" ]] && json_err "proto dan username wajib diisi"
    domain=$(get_domain)
    fmt_quota() { [[ "${1:-0}" == "0" ]] && echo "Unlimited" || echo "$(( $1 / 1024 )) GB"; }
    fmt_limit() { [[ "${1:-0}" == "0" ]] && echo "Unlimited" || echo "$1"; }
    case "$proto" in
      vmess)
        row=$(grep "^$username|" "$DB_VMESS" 2>/dev/null); [[ -z "$row" ]] && json_err "akun tidak ditemukan"
        IFS='|' read -r u secret exp created ip_limit quota_mb <<< "$row"
        l_tls=$(gen_vmess_link "$username" "$secret" "$domain" tls "")
        l_ntls=$(gen_vmess_link "$username" "$secret" "$domain" ntls "")
        detail="✅ AKUN VMESS
Username        : $username
UUID            : $secret
Domain          : $domain
Expired         : $exp
Limit Device/IP : $(fmt_limit "$ip_limit")
Limit Kuota     : $(fmt_quota "$quota_mb")

── WS TLS (443, path /vmess-ws) ──
$l_tls

── WS nTLS (80, path /vmess-ntls) ──
$l_ntls"
        ;;
      vless)
        row=$(grep "^$username|" "$DB_VLESS" 2>/dev/null); [[ -z "$row" ]] && json_err "akun tidak ditemukan"
        IFS='|' read -r u secret exp created ip_limit quota_mb <<< "$row"
        l_tls=$(gen_vless_link "$username" "$secret" "$domain" tls "")
        l_ntls=$(gen_vless_link "$username" "$secret" "$domain" ntls "")
        l_grpc="vless://${secret}@${domain}:443?encryption=none&security=tls&type=grpc&serviceName=vless-grpc&sni=${domain}#${username}-vless-grpc"
        detail="✅ AKUN VLESS
Username        : $username
UUID            : $secret
Domain          : $domain
Expired         : $exp
Limit Device/IP : $(fmt_limit "$ip_limit")
Limit Kuota     : $(fmt_quota "$quota_mb")

── WS TLS (443, path /vless-ws) ──
$l_tls

── WS nTLS (80, path /vless-ntls) ──
$l_ntls

── gRPC TLS (443, service vless-grpc) ──
$l_grpc"
        ;;
      trojan)
        row=$(grep "^$username|" "$DB_TROJAN" 2>/dev/null); [[ -z "$row" ]] && json_err "akun tidak ditemukan"
        IFS='|' read -r u secret exp created ip_limit quota_mb <<< "$row"
        l_ws=$(gen_trojan_link "$username" "$secret" "$domain" ws "")
        l_grpc=$(gen_trojan_link "$username" "$secret" "$domain" grpc "")
        detail="✅ AKUN TROJAN
Username        : $username
Password        : $secret
Domain          : $domain
Expired         : $exp
Limit Device/IP : $(fmt_limit "$ip_limit")
Limit Kuota     : $(fmt_quota "$quota_mb")

── WS TLS (443, path /trojan-ws) ──
$l_ws

── gRPC TLS (443, service trojan-grpc) ──
$l_grpc"
        ;;
      ss)
        row=$(grep "^$username|" "$DB_SS" 2>/dev/null); [[ -z "$row" ]] && json_err "akun tidak ditemukan"
        IFS='|' read -r u secret method exp created ip_limit quota_mb <<< "$row"
        l_ws=$(gen_ss_link "$username" "$secret" "$domain" ws "")
        l_grpc=$(gen_ss_link "$username" "$secret" "$domain" grpc "")
        detail="✅ AKUN SHADOWSOCKS
Username        : $username
Password        : $secret
Method          : $method
Domain          : $domain
Expired         : $exp
Limit Device/IP : $(fmt_limit "$ip_limit")
Limit Kuota     : $(fmt_quota "$quota_mb")

── WS TLS (443, path /ss-ws) ──
$l_ws

── gRPC TLS (443, service ss-grpc) ──
$l_grpc"
        ;;
      sshws)
        row=$(grep "^$username|" "$DB_SSH" 2>/dev/null); [[ -z "$row" ]] && json_err "akun tidak ditemukan"
        IFS='|' read -r u secret exp created ip_limit quota_mb <<< "$row"
        detail="✅ AKUN SSH
Username        : $username
Password        : $secret
Domain/IP       : $domain
Expired         : $exp
Limit Sesi      : $(fmt_limit "$ip_limit")
Limit Kuota     : $(fmt_quota "$quota_mb")

── Port Koneksi ──
SSH Direct   : 442 / 109 / 143
SSH-SSL      : $STUNNEL_SSL_PORT (Dropbear) / $HAPROXY_SSL_PORT (OpenSSH) — SNI bebas, tanpa payload
SSH-WS nTLS  : 80 / 8880 / 8080 / 2080 / 2082
SSH-WS TLS   : 443
Path         : /ssh-ws (Dropbear) atau /ssh-ws-ssh (OpenSSH)

── Payload WS ──
Dropbear:
GET /ssh-ws HTTP/1.1[crlf]Host: $domain[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]

OpenSSH:
GET /ssh-ws-ssh HTTP/1.1[crlf]Host: $domain[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]"
        ;;
      *) json_err "protokol tidak dikenal: $proto" ;;
    esac
    jq -n --arg detail "$detail" '{ok:true, type:"detail", detail:$detail}'
    ;;

  renew_account)
    proto="${2:-}"; username="${3:-}"; days="${4:-30}"
    [[ -z "$proto" || -z "$username" ]] && json_err "proto dan username wajib diisi"
    case "$proto" in
      vmess)  renew_vmess  "$username" "$days" ;;
      vless)  renew_vless  "$username" "$days" ;;
      trojan) renew_trojan "$username" "$days" ;;
      ss)     renew_ss     "$username" "$days" ;;
      sshws)  renew_ssh    "$username" "$days" ;;
      *) json_err "protokol tidak dikenal: $proto" ;;
    esac
    echo '{"ok":true}'
    ;;

  edit_limits)
    proto="${2:-}"; username="${3:-}"; ip_limit="${4:-2}"; quota_gb="${5:-0}"
    [[ -z "$proto" || -z "$username" ]] && json_err "proto dan username wajib diisi"
    quota_mb=$(( ${quota_gb%.*} * 1024 ))
    case "$proto" in
      vmess)  edit_vmess_limits  "$username" "$ip_limit" "$quota_mb" ;;
      vless)  edit_vless_limits  "$username" "$ip_limit" "$quota_mb" ;;
      trojan) edit_trojan_limits "$username" "$ip_limit" "$quota_mb" ;;
      ss)     edit_ss_limits     "$username" "$ip_limit" "$quota_mb" ;;
      sshws)  edit_ssh_limits    "$username" "$ip_limit" "$quota_mb" ;;
      *) json_err "protokol tidak dikenal: $proto" ;;
    esac
    echo '{"ok":true}'
    ;;

  *)
    json_err "aksi tidak dikenal: ${1:-<kosong>}"
    ;;
esac
