# Deploy panel VPN (ringan: Nginx + PHP-FPM, tanpa Node)

## 1. Siapkan PHP
```bash
apt install -y php-fpm php-cli jq
```

## 2. Taruh file
```bash
mkdir -p /etc/vpn-script/api /var/www/vpn-api /var/www/vpn-panel
cp api-cli.sh /etc/vpn-script/api/api-cli.sh
chmod 750 /etc/vpn-script/api/api-cli.sh
chown root:root /etc/vpn-script/api/api-cli.sh

cp index.php /var/www/vpn-api/index.php
cp variant-b-topbar-grid.html /var/www/vpn-panel/index.html
```

## 3. Batasi hak akses lewat sudoers
```bash
cp sudoers-vpnapi /etc/sudoers.d/vpnapi
chmod 440 /etc/sudoers.d/vpnapi
visudo -c
```

## 4. Set API key
```bash
# di file service php-fpm pool (mis. /etc/php/8.1/fpm/pool.d/www.conf) tambahkan:
env[VPN_API_KEY] = "isi-dengan-string-acak-panjang-min-32-karakter"
systemctl restart php8.1-fpm
```
Generate string acak: `openssl rand -hex 32`

## 5. Tambahkan konfigurasi Nginx
Lihat `nginx-api-snippet.conf` — sesuaikan path socket PHP-FPM-nya, lalu:
```bash
nginx -t && systemctl reload nginx
```

## 6. Buka panel
Buka `https://tunnel.contoh-domain.com/` (atau subdomain panel-mu), klik
**"Hubungkan ke server"** di kanan atas, isi URL API (`https://.../api/`) dan
API key yang tadi dibuat. Panel akan mulai menarik data asli, bukan data contoh lagi.

## Catatan keamanan (penting)
- Panel ini bisa membuat/menghapus akun VPN di server — anggap API key
  ini sekuat password root. Jangan taruh di file yang ke-commit ke Git publik.
- Wajib pasang HTTPS (certbot) sebelum dipakai lewat internet.
- Pertimbangkan batasi akses `/api/` hanya dari IP tertentu lewat `allow`/`deny`
  di Nginx, atau taruh panel di belakang VPN/WireGuard terpisah kalau dipakai sendiri.
- Baris `sudoers-vpnapi` sengaja dibatasi hanya boleh menjalankan satu file
  (`api-cli.sh`) — jangan diperlonggar jadi `ALL=(ALL) NOPASSWD: ALL`.
