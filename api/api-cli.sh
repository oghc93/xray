#!/bin/bash
# ============================================================
#  API BRIDGE — dipanggil oleh backend PHP (index.php)
#  Tugasnya cuma satu: terima perintah lewat argumen,
#  panggil fungsi asli di lib.sh, keluarkan JSON ke stdout.
#  Script asli (create_vmess, dkk) TIDAK diubah sama sekali.
#
#  Install di: /etc/vpn-script/api/api-cli.sh
#  Jalan sebagai root lewat sudo (lihat README-DEPLOY.md)
# ============================================================
set -euo pipefail
SCRIPT_DIR="/etc/vpn-script"
source "$SCRIPT_DIR/lib.sh"

json_err() { printf '{"ok":false,"error":%s}\n' "$(jq -Rn --arg m "$1" '$m')"; exit 1; }
json_ok_secret() { printf '{"ok":true,"secret":%s}\n' "$(jq -Rn --arg s "$1" '$s')"; }

# Ubah baris "user|field2|field3|..." jadi 1 objek JSON.
# $1 = proto, $2..$n = field sesuai urutan di file .db protokol itu
row_to_json() {
  local proto="$1"; shift
  jq -cn --arg proto "$proto" --args '$ARGS.positional as $f | {proto:$proto, fields:$f}' "$@"
}

case "${1:-}" in

  summary)
    xray_on=$(systemctl is-active xray 2>/dev/null || echo inactive)
    nginx_on=$(systemctl is-active nginx 2>/dev/null || echo inactive)
    db_on=$(systemctl is-active dropbear 2>/dev/null || echo inactive)
    stunnel_on=$(systemctl is-active stunnel4 2>/dev/null || echo inactive)
    haproxy_on=$(systemctl is-active haproxy 2>/dev/null || echo inactive)
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
    echo "[]" > "$tmp"
    # format per protokol -> lihat DB_* di lib.sh
    # vmess/vless : user|secret|exp|created|ip_limit|quota_mb
    # trojan/ss   : sama (ss punya kolom method ekstra)
    # ssh         : user|password|exp|created|session_limit|quota_mb
    add_rows() {
      local proto="$1" file="$2" secret_field="$3"
      [[ -f "$file" ]] || return 0
      while IFS='|' read -r rest; do :; done < /dev/null # no-op guard
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
    : > "$tmp.ndjson"
    add_rows vmess "$DB_VMESS" 2
    add_rows vless "$DB_VLESS" 2
    add_rows trojan "$DB_TROJAN" 2
    add_rows ss "$DB_SS" 2
    add_rows sshws "$DB_SSH" 2
    jq -s '.' "$tmp.ndjson" 2>/dev/null || echo "[]"
    rm -f "$tmp" "$tmp.ndjson"
    ;;

  create_account)
    proto="${2:-}"; username="${3:-}"; days="${4:-30}"; ip_limit="${5:-}"; quota_gb="${6:-0}"; trial_hours="${7:-0}"
    [[ -z "$proto" || -z "$username" ]] && json_err "proto dan username wajib diisi"
    [[ "$username" =~ ^[a-zA-Z0-9_]{3,32}$ ]] || json_err "username tidak valid (huruf/angka/underscore, 3-32 karakter)"
    quota_mb=$(( ${quota_gb%.*} * 1024 ))
    case "$proto" in
      vmess)  secret=$(create_vmess  "$username" "$days" "$ip_limit" "$quota_mb" "$trial_hours") ;;
      vless)  secret=$(create_vless  "$username" "$days" "$ip_limit" "$quota_mb" "$trial_hours") ;;
      trojan) secret=$(create_trojan "$username" "$days" "$ip_limit" "$quota_mb" "$trial_hours") ;;
      ss)     secret=$(create_ss     "$username" "$days" "$ip_limit" "$quota_mb" "$trial_hours") ;;
      sshws)  secret=$(create_ssh    "$username" "$days" "" "$ip_limit" "$quota_mb" "$trial_hours") ;;
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
    state=$(systemctl is-active "$svc" 2>/dev/null || echo inactive)
    jq -n --arg svc "$svc" --arg state "$state" '{ok:true, service:$svc, state:$state}'
    ;;

  *)
    json_err "aksi tidak dikenal: ${1:-<kosong>}"
    ;;
esac
