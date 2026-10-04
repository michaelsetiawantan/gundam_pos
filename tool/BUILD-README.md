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

## Alamat server (VPN / cloud / LAN)

**Tidak perlu rebuild APK lagi.** Di layar **Activation** dan **Login** ada field alamat server;
di halaman **More** bisa dilihat/diubah juga. Prioritas: **isi manual di tablet > default build > default bawaan**.

- Terima `host`, `host:port`, atau URL lengkap `http(s)://...`.
- Setelah disimpan, app **probe** `GET /api/health` dan bilang jujur: server benar / host salah /
  tidak terjangkau / gagal TLS (sertifikat).
- Kalau probe gagal, alamat lama yang sudah jalan **tidak dihapus**.
- Kalau alamat `http://` ke host non-localhost, app kasih peringatan: cookie sesi `Secure` bisa
  ditolak client di HTTP. Solusinya: pakai HTTPS, atau jalankan server dengan `COOKIE_SECURE=false`
  (lihat `docs/runbook.md`).

## Kalau printer gagal cetak (log diagnosis)

Tablet mencatat **setiap percobaan cetak** ke SQLite lokal sebelum mencetak, lalu mengirimnya ke server
saat online. Tidak ada lagi kegagalan yang hilang begitu snackbar ditutup.

- **Di tablet**: halaman **More → Print diagnostics** — daftar terbaru, filter (outcome/ticket type/tanggal),
  hitungan per hasil, dan detail berisi error code, warning encoder (karakter ditransliterasi, QR/barcode/
  image fallback), dialect + code page beserta status fallback, dan potongan teks struk (hanya untuk
  FAILED/FALLBACK, maks 4KB). Ada tombol **Retry upload** dan **Copy** satu entri untuk dikirim ke dev.
- **Di web**: **`/app/print-diagnostics`** — filter outlet/device/ticket type/outcome/error code/tanggal/cari
  receipt, hitungan per outcome, indikator last-reported (stale >60 menit), detail lengkap + copy.
- Retensi: tablet 500 baris / 14 hari (baris yang belum terkirim tidak pernah dipangkas); server
  30 hari / 5000 baris per outlet. Upload idempotent (`clientLogId`) — kirim ulang tidak pernah duplikat.

Kalau ada printer yang tidak nge-print: buka `/app/print-diagnostics`, kirim entri FAILED-nya (error code +
warning + teks struknya) — itu cukup untuk saya perbaiki tanpa harus menebak.

## Kalau IP server beda

Base URL di APK itu hanya **default/fallback** sekarang — di tablet bisa diganti sendiri lewat field
alamat server. Kalau tetap mau ganti default build, pakai IP tablet-reachable:

```bash
cd ~/agent-working/code/gundam/pos
export PATH="$HOME/.local/bin:$HOME/flutter/bin:$PATH"
flutter build apk --release --dart-define=POS_API_BASE=http://<IP-SERVER>:3100
# hasil: build/app/outputs/flutter-apk/app-release.apk
```

Cek IP host: `hostname -I`. Kalau tablet di jaringan lain, ganti `10.80.88.20` dengan IP publik/VPN
yang menembus port 3100.

## Vocabulary printer (driver ada di APK, web hanya memilih)

Semua pilihan di bawah berasal dari satu registry (`GET /api/printers/vocabulary`) dan dipakai
sebagai *trigger*: APK sudah memuat drivernya, web hanya menunjuk yang mana.

| Kategori | Pilihan | Status di APK |
|---|---|---|
| Transport | `NETWORK`, `BLUETOOTH`, `USB` | semua jalan |
| USB driver/chip | `CDC_ACM`, `CH340_CH341`, `PL2303`, `FTDI_FT232R`, `FTDI_FT231X`, `CP210X`, `USB_PRINTER_CLASS` (class 0x07), `USB_VENDOR_SPECIFIC` (0xFF) | 8/8 ada di APK |
| Dialect | `ESC/POS` (Epson), `ESC/POS-CLONE` (clone: init/cut/code page beda) | jalan |
| Dialect | `STAR` (Star Line Mode — perintahnya beda: `ESC GS t n`, `ESC i n1 n2`, `ESC E`/`ESC F`, `ESC GS a n`, `ESC a n` feed, `ESC d n` cut) | jalan |
| Dialect | `CITIZEN` (mode ESC/POS Citizen — byte identik Epson untuk semua perintah yang dipakai; tabel code page Citizen sendiri) | jalan |
| Code page | `CP437`, `KATAKANA`, `CP850`, `CP860`, `CP863`, `CP865`, `CP1252`, `CP866`, `CP852`, `CP858` | jalan (index `ESC t n` asli; Star pakai `ESC GS t n` dengan penomoran Star sendiri — `CP850` tidak ada padanannya di Star → fallback CP437 + warning) |
| Code page | `UTF-8` | ditolak jujur → fallback CP437 + warning (ESC/POS tidak punya page UTF-8) |
| Capability | `NATIVE_QR`, `NATIVE_BARCODE`, `CUTTER` | jalan, bisa di-override per printer model |
| Capability | `RASTER_IMAGE` | belum (butuh rasteriser/dependency) — blok gambar jadi placeholder berlabel |
| Width | 58 mm (32 cell), 80 mm (48 cell) | jalan |

Ejaan lama tetap diterima sebagai alias (`ESC/POS-GENERIC`, `STAR-LINE-MODE`, `CITIZEN-ESCPOS`,
`WPC1252`), jadi config yang sudah tersimpan tidak pernah rusak.

Drift antara web dan APK dijaga oleh test: `pos/tool/printer-vocabulary.json` di-generate dari
registry Dart, dan vitest di web membandingkan vocabulary server dengan file itu.
Regenerate manifest: `cd pos && UPDATE_PRINTER_VOCABULARY=1 flutter test test/printer_vocabulary_test.dart`

## Printer

- **Network :9100** — jalan (bytes dikirim langsung ke printer LAN).
- **Bluetooth Classic SPP/RFCOMM** — jalan. Prasyarat: printer sudah **paired/bonded** di Android
  Settings (sekali saja), lalu izin `BLUETOOTH_CONNECT` (Android 12+) di-grant saat diminta app.
  MAC printer diambil dari config web, jadi tidak perlu discovery. Kalau belum paired, tablet
  menampilkan **Not paired** (pairing tidak bisa diam-diam, Android butuh konfirmasi PIN).
- **USB (OTG)** — jalan, driver chip **built-in di APK**: CDC-ACM, CH340/CH341, PL2303 (HX/HXA),
  FTDI (FT232R/FT231X). Chip dipilih di web (`/app/printers` → printer model / printer → USB chip).
  Prasyarat: kabel OTG, izin USB diminta sekali saat printer dicolok, dan VID:PID di config harus
  cocok dengan perangkat yang tercolok (kalau tidak cocok → error typed, bukan cetak ke chip salah).
  Catatan: sequence init tiap chip belum diverifikasi di hardware nyata, hanya unit test/review.
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
