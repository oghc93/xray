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
    case "$proto" in
      vmess)  secret=$(get_vmess_info "$username" | cut -d'|' -f2); [[ -z "$secret" ]] && json_err "akun tidak ditemukan"
              link=$(gen_vmess_link "$username" "$secret" "$domain" tls "") ;;
      vless)  secret=$(get_vless_info "$username" | cut -d'|' -f2); [[ -z "$secret" ]] && json_err "akun tidak ditemukan"
              link=$(gen_vless_link "$username" "$secret" "$domain" tls "") ;;
      trojan) secret=$(get_trojan_info "$username" | cut -d'|' -f2); [[ -z "$secret" ]] && json_err "akun tidak ditemukan"
              link=$(gen_trojan_link "$username" "$secret" "$domain" ws "") ;;
      ss)     secret=$(get_ss_info "$username" | cut -d'|' -f2); [[ -z "$secret" ]] && json_err "akun tidak ditemukan"
              link=$(gen_ss_link "$username" "$secret" "$domain" ws "") ;;
      sshws)  secret=$(get_ssh_info "$username" | cut -d'|' -f2); [[ -z "$secret" ]] && json_err "akun tidak ditemukan"
              jq -n --arg host "$domain" --arg user "$username" --arg pass "$secret" \
                '{ok:true, type:"ssh", host:$host, port:443, username:$user, password:$pass}'
              exit 0 ;;
      *) json_err "protokol tidak dikenal: $proto" ;;
    esac
    jq -n --arg link "$link" '{ok:true, type:"link", link:$link}'
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
