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

- Print thermal **network :9100** sudah benar-benar mengirim byte.
- Bluetooth / USB → dilaporkan `unsupported` (belum ada paritas transport), jangan diharapkan jalan.
- Router print: BILL = level outlet (bisa multi printer), CAPTAIN_ORDER & BEV_LABEL = level item
  (tanpa fallback kategori), captain per batch (A/B/C).
- Printer diatur di web `/app/printers` + routing per outlet; tablet hanya menjalankan.

## Format struk

Format struk 100% custom dari web (`/app/print-formats`, System Administrator). Yang dipublish
server langsung dipakai tablet; kalau tidak ada format untuk ticket type itu, tablet pakai layout
bawaan (fallback), jadi penjualan tidak pernah gagal karena format.

## Yang belum ada di build ini

- Transport Bluetooth & USB (hanya network :9100).
- QR/barcode/image block: dikirim sebagai entri terstruktur, transport network masih menulis
  placeholder teks (butuh encoder).
- Reprint bill hanya same-day dan cache-nya in-memory (hilang kalau app di-restart).
- App icon iOS/web belum dibuat (hanya Android).
