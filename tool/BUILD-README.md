# Gundam POS — test build

**APK:** `gundam-pos-release.apk` (release build, debug-signed — cukup untuk uji coba, bukan Play Store)
**Server yang ditanam di build ini:** `POS_API_BASE = http://10.80.88.20:3100`
(server web Gundam jalan di host AI CGKUB, port 3100, bind 0.0.0.0 — tablet harus di LAN yang sama)

## Install

1. Copy APK ke tablet (USB / Google Drive / LAN).
2. Buka file di tablet → Android minta "allow install from this source" **sekali** → Install.
3. Nama app: **Gundam POS**. Ikon: tile petrol/teal dengan mark "G".

## Alur pertama kali

1. **Activation** — butuh kode aktivasi 64 karakter. Kode dibuat di web:
   `/app/pos-assets` → pilih outlet → **Generate Activation Code** → plaintext muncul **sekali**.
2. **Login** — user POS dari seed:
   - `cashier@gundam.demo` / `Demo@123` (kasir)
   - `owner@gundam.demo` / `Demo@123`
   - `super@gundam.demo` / `Demo@123`
   Login POS hanya boleh 1 device aktif per user (single-active).
3. Setelah login: reminder lisensi (kalau GRACE), konfigurasi menu/printer/metode bayar ikut ter-sync.

## Kalau IP server beda

Base URL di-*compile* ke APK (bukan setting runtime di UI). Rebuild dengan IP tablet-reachable:

```bash
cd ~/agent-working/code/gundam/pos
export PATH="$HOME/.local/bin:$HOME/flutter/bin:$PATH"
flutter build apk --release --dart-define=POS_API_BASE=http://<IP-SERVER>:3100
# hasil: build/app/outputs/flutter-apk/app-release.apk
```

Cek IP host: `hostname -I`. Kalau tablet di jaringan lain, ganti `10.80.88.20` dengan IP publik/VPN
yang menembus port 3100.

## Printer

- **Network :9100** — jalan (bytes dikirim langsung ke printer LAN).
- **Bluetooth Classic SPP/RFCOMM** — jalan. Prasyarat: printer sudah **paired/bonded** di Android
  Settings (sekali saja), lalu izin `BLUETOOTH_CONNECT` (Android 12+) di-grant saat diminta app.
  MAC printer diambil dari config web, jadi tidak perlu discovery. Kalau belum paired, tablet
  menampilkan **Not paired** (pairing tidak bisa diam-diam, Android butuh konfirmasi PIN).
- **USB** — belum ada di build ini. Butuh kabel OTG + USB Host permission + driver chip serial
  (CH340/PL2303/FTDI); ini satu-satunya transport yang memang butuh driver.
- Router print: BILL = level outlet (bisa multi printer), CAPTAIN_ORDER & BEV_LABEL = level item
  (tanpa fallback kategori), captain per batch (A/B/C). Dialect ESC/POS diambil dari printer model
  (`protocol`) yang di-set di web; dialect tak dikenal → default ESC/POS dan dilaporkan.
- Tidak ada test print otomatis. Tombol **Test Print** manual tersedia; status printer dilaporkan
  tablet ke web (`/app/printers` menampilkan status + waktu cek + device pelapor, dengan penanda stale).

## Format struk

Format struk 100% custom dari web (`/app/print-formats`, System Administrator). Yang dipublish
server langsung dipakai tablet; kalau tidak ada format untuk ticket type itu, tablet pakai layout
bawaan (fallback), jadi penjualan tidak pernah gagal karena format.

## Yang belum ada di build ini

- Transport USB (hanya network :9100 dan Bluetooth SPP) — USB butuh OTG + driver chip serial.
- Image/raster block pada struk: QR dan barcode sudah byte asli, tapi blok gambar masih placeholder
  berlabel (butuh rasteriser = dependency).
- Reprint bill hanya same-day dan cache-nya in-memory (hilang kalau app di-restart).
- App icon iOS/web belum dibuat (hanya Android).
- Login dari tablet ke `http://<IP>:3100` bisa ditolak karena cookie sesi diset `Secure`
  (browser/Android menolak cookie Secure di HTTP non-localhost). Untuk LAN: pakai HTTPS,
  atau minta saya matikan flag Secure untuk mode LAN.
