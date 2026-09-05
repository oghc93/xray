# CHANGELOG v1.5.4 — Limit Device/IP (Perbaikan Nyata)

## Latar Belakang

`CHANGELOG-1.5.0.md` sebelumnya mengklaim fitur "Limit Device/IP" sudah
selesai dibuat untuk SSH-WS dan Xray. Setelah dicek ulang, klaim itu
**tidak sesuai kenyataan**:

- File `addon/session-limiter.sh` dan `addon/xray-device-limiter.sh`
  yang disebut sebagai "File Baru" di changelog 1.5.0 **tidak pernah
  benar-benar ada** di repo.
- `install.sh` tidak pernah mendaftarkan cron untuk kedua file tsb
  (hanya `quota-limiter.sh` yang didaftarkan).
- Menu "Buat Akun" (SSH-WS, VMess, VLess, Trojan, Shadowsocks) selalu
  hardcode `ip_limit`/`session_limit = 0` (unlimited), tidak pernah
  benar-benar tanya ke admin.
- Menu "Edit Kuota" justru **mereset limit device/IP ke 0** setiap kali
  dipakai, karena parameter limit di-hardcode 0 saat memanggil
  `edit_*_limits`.

Singkatnya: kolom `ip_limit`/`session_limit` di database SUDAH ADA
sejak lama, tapi TIDAK ADA satupun mekanisme yang benar-benar
membacanya untuk membatasi apa pun. Fitur ini murni kosmetik sebelum
v1.5.4.

## Yang Diperbaiki di v1.5.4

### File baru (BENERAN ada kali ini)
- `addon/session-limiter.sh` — limiter SSH berbasis hitung sesi aktif
  per akun (bukan IP, karena SSH-WS selalu di-proxy lewat
  Nginx→127.0.0.1 sehingga IP asli tidak pernah terlihat oleh
  Dropbear/OpenSSH). Sesi tertua diputus otomatis kalau melebihi
  `session_limit`.
- `addon/xray-device-limiter.sh` — limiter VMess/VLess/Trojan/SS
  berbasis `statsUserOnline` Xray. Akun yang melebihi `ip_limit`
  di-"bounce" (semua koneksi diputus, device dlm batas bisa reconnect).
  Sengaja SKIP (bukan pura-pura jalan) kalau prasyarat real-IP di
  bawah belum aktif. **Semua akun yang kena bounce dalam 1x siklus
  cron di-BATCH jadi cuma 1x restart Xray** (bukan 1x restart per
  akun) + cooldown 5 menit per akun, supaya akun yang rutin
  kelebihan device tidak memicu restart server berulang-ulang tiap
  2 menit. Lihat catatan "kenapa restart penuh, bukan reload" di
  `lib.sh` (`xray_reload_or_restart`) — unit systemd Xray tidak
  punya `ExecReload`, jadi tiap perubahan config Xray SELALU restart
  penuh (bukan cuma reload), yang artinya sebentar mengganggu SEMUA
  user Xray di server, bukan cuma akun yang kena limit. Ini juga
  berlaku untuk `quota-limiter.sh` yang sudah lama begini (sudah
  batch 1x restart per siklus 10 menit sejak awal, sekarang dirapikan
  supaya pakai helper `xray_reload_or_restart` yang sama).
- `addon/enable-xray-realip.sh` — retrofit PROXY protocol Nginx↔Xray
  (idempotent, backup + rollback otomatis) untuk VPS yang sudah lama
  jalan, supaya `statsUserOnline` akurat.

### `install.sh`
- 6 inbound WS Xray (vmess-ws-tls/ntls, vless-ws-tls/ntls,
  trojan-ws-tls, ss-ws-tls) sekarang default `acceptProxyProtocol: true`.
- 6 location block Nginx terkait sekarang default `proxy_protocol on;`.
- Cron baru didaftarkan (guard `[[ -f ]]`, pola sama seperti
  `quota-limiter.sh`): `session-limiter.sh` & `xray-device-limiter.sh`
  tiap 2 menit.
- **Ketiga file addon baru ditambahkan ke daftar download
  install.sh/update.sh** — sebelumnya ini juga jadi penyebab fitur
  1.5.0 tidak pernah benar-benar terpasang di VPS manapun walau
  filenya sempat dibuat.

### `lib.sh`
- Helper baru: `get_ssh_active_sessions`, `get_ssh_session_limit`.
- Refactor `xray_disable_client`/`reactivate_xray_client`: dipecah
  jadi `xray_readd_client_config` (edit config doang, gak restart)
  + `xray_reload_or_restart` (satu fungsi restart bersama, dipakai
  `quota-limiter.sh` & `xray-device-limiter.sh`) supaya proses batch
  banyak akun bisa diakhiri dengan 1x restart, bukan restart
  berulang-ulang.
- Komentar lama yang bilang "fitur limit sesi/device sudah dihapus"
  diperbarui — sekarang menjelaskan solusi & prasyaratnya.

### `menu/sshws.sh`, `menu/vmess.sh`, `menu/vless.sh`, `menu/trojan.sh`, `menu/ss.sh`
- "Buat Akun" sekarang benar-benar tanya Limit Device/IP ke admin
  (default dari `SESSION_LIMIT_DEFAULT`/`IP_LIMIT_DEFAULT`).
- "Edit Kuota" → "Edit Limit Device/IP & Kuota": sekarang benar-benar
  edit limit device (kosongkan input = tidak diubah, TIDAK lagi
  direset ke 0).
- "Info Akun" menampilkan sesi aktif / device online vs limit.

## Yang PERLU Dilakukan Admin

1. **WAJIB**: push semua file yang berubah ke repo GitHub yang dipakai
   `install.sh`/`update.sh` (mengulang catatan di `CHANGELOG-1.5.0.md`
   poin 4) — kalau tidak, VPS yang update akan tetap dapat versi lama.
2. Untuk VPS yang **sudah** terinstall (bukan instalasi baru), jalankan
   `bash addon/enable-xray-realip.sh` sekali sebagai root supaya limit
   device Xray akurat.
3. Wajib diuji dulu di VPS test/staging sebelum dipakai di server
   produksi banyak user — terutama `enable-xray-realip.sh` yang
   mengubah config Nginx & Xray yang sedang live (walau sudah ada
   backup+rollback otomatis).
4. gRPC (vmess/vless/trojan/ss-grpc) BELUM tercakup limit device —
   hanya WS yang sudah didukung di iterasi ini.

## Keterbatasan yang Masih Ada (Diketahui, Belum Diperbaiki)

- **Restart Xray tetap terjadi saat ada akun yang kena limit/kuota**,
  cuma sudah di-batch jadi maksimal 1x per siklus cron (bukan 1x per
  akun) + ada cooldown 5 menit per akun. Ini artinya SEMUA user Xray
  ikut putus koneksi sebentar (biasanya auto-reconnect < 1 detik)
  setiap kali ada satu akun yang lampau limit — bukan cuma akun yang
  bersangkutan. Penyebabnya: unit systemd Xray gak punya `ExecReload`,
  jadi Xray-core (beda dari Nginx) memang belum bisa reload config
  tanpa restart proses penuh di sini.
- **Perbaikan sebenarnya (belum dikerjakan)**: aktifkan `HandlerService`
  di `api.services` Xray dan pindah dari edit `config.json`+restart ke
  panggilan gRPC `AlterInbound`/`AddUserOperation`/`RemoveUserOperation`
  langsung ke Xray yang sedang jalan (persis seperti yang dipakai
  panel-panel seperti 3x-ui/Marzban) — ini akan menghilangkan restart
  sama sekali, jadi cuma device/koneksi si akun bandel yang putus,
  bukan seluruh server. Ini butuh implementasi gRPC (grpcurl atau
  wrapper Go kecil) dan pengujian langsung ke Xray yang hidup sebelum
  aman dipakai di server produksi, jadi sengaja belum dikerjakan di
  v1.5.4 ini.
