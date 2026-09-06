# VPN Panel

Web UI untuk mengelola script VPN tunnel manager (VMess / VLess / Trojan /
Shadowsocks / SSH‑WS) tanpa harus masuk terminal tiap kali buat atau hapus
akun. Dibuat ringan: cuma Nginx + PHP-FPM di sisi backend, HTML/CSS/JS polos
di sisi panel — tanpa Node, tanpa framework.

## Struktur

```
vpn-panel/
├── panel/
│   ├── index.html              ← panel utama (yang dipakai)
│   └── design-variants/        ← 2 alternatif desain (referensi, tidak dipakai)
├── api/
│   ├── index.php               ← backend, terima request dari panel
│   └── api-cli.sh              ← jembatan ke lib.sh script VPN aslimu
└── deploy/
    ├── DEPLOY.md                ← langkah pasang lengkap
    ├── nginx-api-snippet.conf   ← contoh konfigurasi nginx
    └── sudoers-vpnapi           ← batasi hak akses PHP ke satu script saja
```

## Cara pakai

1. Ikuti `deploy/DEPLOY.md` untuk pasang `api/` dan `panel/` di server VPS-mu
   (server yang sama dengan script VPN aslimu, karena `api-cli.sh` men-source
   `/etc/vpn-script/lib.sh` langsung).
2. Buka panel di browser, klik **"Hubungkan ke server"**, isi URL API dan API
   key yang kamu buat saat deploy.
3. Kelola akun VMess/VLess/Trojan/Shadowsocks/SSH‑WS dan layanan sistem
   langsung dari panel.

Tanpa dihubungkan, panel tetap bisa dibuka dan menampilkan data contoh — jadi
aman dipakai untuk pratinjau desain sebelum server-nya siap.

## Keamanan (baca sebelum dipakai online)

- Endpoint API ini bisa membuat/menghapus akun VPN di server — perlakukan
  API key-nya sekuat password root.
- **Wajib** HTTPS (mis. lewat certbot) sebelum dipakai lewat internet publik.
- `deploy/sudoers-vpnapi` sengaja membatasi PHP-FPM (`www-data`) hanya boleh
  menjalankan satu file (`api-cli.sh`) sebagai root — jangan diperlonggar.
- Jangan commit API key, domain asli, atau IP server ke repo publik. Lihat
  `.gitignore` — tambahkan file konfigurasi lokalmu sendiri di sana kalau perlu.
- Pertimbangkan batasi akses `/api/` per-IP di Nginx, atau taruh panel di
  belakang VPN/WireGuard terpisah kalau cuma dipakai sendiri.

## Lisensi

Belum ditentukan — tambahkan file `LICENSE` sesuai preferensimu sebelum
dipublikasikan (mis. MIT kalau ingin bebas dipakai orang lain).
