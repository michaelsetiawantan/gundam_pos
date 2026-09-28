# Gundam POS — changelog

Format: [Keep a Changelog](https://keepachangelog.com/) · versi semver, versionCode naik monoton.
Changelog ini yang dikirim ke server saat publish release (kolom `changelog` di `PosRelease`) dan
yang ditampilkan ke tablet sebagai "what's new".

## [0.2.0] — 2026-09-28

Rilis besar pertama yang benar-benar bisa dipakai untuk uji lapangan. Sebelumnya build adalah
kerangka MVP (versi 0.1.0) tanpa konfigurasi printer, tanpa update, dan tanpa log.

### Print (inti perubahan)
- **Bluetooth Classic SPP/RFCOMM** jalan: platform channel Kotlin sendiri (bonded check, izin
  `BLUETOOTH_CONNECT`, connect per MAC dengan timeout, write, close), tanpa dependency tambahan.
- **USB Host (OTG)** jalan dengan driver chip **built-in di APK**: CDC-ACM, CH340/CH341, PL2303
  (HX/HXA), FTDI FT232R/FT231X, CP210x, plus mode **USB printer class (0x07)** dan
  **vendor-specific (0xFF)** raw bulk tanpa serial init.
- **ESC/POS encoder asli**: init, code page (`ESC t n`), align, bold, double width/height, feed, cut,
  QR native (`GS ( k`), barcode native (`GS k`), plus fallback berlabel untuk blok gambar.
- **Dialect + code page dari config web**: `ESC/POS`, `ESC/POS-CLONE`; 10 code page
  (CP437, KATAKANA, CP850, CP860, CP863, CP865, CP1252, CP866, CP852, CP858). Karakter yang tidak
  terwakili ditransliterasi/diganti dan **dihitung**, bukan jadi byte rusak.
- **Format struk custom** dari web dipakai tablet; kalau tidak ada format untuk ticket type itu,
  tablet pakai layout bawaan (penjualan tidak pernah gagal karena format).
- **Routing**: BILL level outlet (multi-printer), CAPTAIN_ORDER & BEV_LABEL level item (tanpa
  fallback kategori), captain per batch (A/B/C). Reprint bill same-day; reprint captain tidak
  memicu bev-label lagi.
- **Test Print manual** per printer (network/Bluetooth/USB) — tidak ada test otomatis.

### Log diagnosis cetak (baru)
- Setiap percobaan cetak dicatat ke SQLite lokal **sebelum** mencetak, jadi app crash pun tetap ada
  jejaknya: error code typed, jumlah attempt, durasi, ukuran byte, dialect + code page + status
  fallback, dan semua warning encoder.
- Teks struk disimpan hanya untuk FAILED/FALLBACK (maks 4KB). Baris OK metadata saja.
- Upload batch idempotent ke server saat online; retensi lokal 500 baris / 14 hari dan baris yang
  belum terkirim tidak pernah dipangkas.
- Layar **More → Print diagnostics** di tablet; di web ada **`/app/print-diagnostics`**.

### Konfigurasi & sinkronisasi
- **Semua setting printer dari web benar-benar sampai ke tablet**: transport + addressing, driver
  chip USB, dialect, code page, width 58/80, raster capability, retry per printer, routing, dan
  metadata printer model. Sebelumnya beberapa route web tidak menaikkan versi config sehingga
  perubahan tidak pernah dikirim.
- **Printer model master** bisa dikelola dari web (brand, model, width, dialect, code page,
  capability, chip USB) dan dipilih per printer.
- **Capability** (native QR, native barcode, cutter) bisa dinyatakan per printer model.
- Vocabulary printer satu sumber + **drift guard** (manifest dari APK dibandingkan test web) supaya
  pilihan di web tidak pernah berbeda dengan yang benar-benar bisa dijalankan tablet.
- **Tax/Service Charge master level outlet** ikut dikirim ke tablet (flag include/exclude tetap per item).

### Alamat server (VPN / cloud)
- Field **alamat server di layar Activation & Login** (+ halaman More), tersimpan permanen.
  Prioritas: isi manual di tablet > default build > default bawaan. **Tidak perlu rebuild APK**
  lagi saat pindah environment.
- Validasi koneksi via `GET /api/health`, hasil jujur: server benar / host salah / tidak terjangkau /
  gagal TLS. Alamat lama tidak dihapus kalau probe gagal.

### Operasional
- **Reminder lisensi** setelah login (GRACE = merah + tanggal resmi; ACTIVE mendekati expiry = amber),
  informational dan bisa di-dismiss.
- **Shift**: label sesuai tipe (MANUAL: Start/End Shift; AUTOMATIC: Start/End Shift Cash Count),
  window meal-shift ditegakkan, alert order lewat tengah malam di recap window, dan perubahan config
  shift baru berlaku hari berikutnya.
- **Shipment** sebagai step sebelum payment (open shipment manual ≥ 0 atau master), ikut rounding
  sekali, dan dikirim ke server.
- **Payment wajib setelah send-cart** (tidak bisa langsung bayar cart yang belum dikirim).
- **Discount/voucher** lewat server (`POST /api/pos/orders/{id}/pricing`): eligibility kategori,
  mutually exclusive, expiry & quota divalidasi server, pending approval bila role di bawah ambang.
- Printer health dilaporkan tablet ke web (status + waktu cek + device pelapor, penanda stale).

### Branding
- Ikon launcher & splash sendiri (tile petrol/teal dengan mark "G"), adaptive icon Android 8+,
  nama app "Gundam POS" (sebelumnya ikon bawaan Flutter).

### Update & rilis (baru)
- **Versi aplikasi & changelog**: halaman About menampilkan version, versionCode, git sha + build time,
  versi schema DB, dan alamat server yang dipakai.
- **Cek versi baru** saat login dan tiap sync → notifikasi "New version vX.Y available" beserta
  changelog dan flag mandatory. Belum ada rilis = diam (tidak nag), offline = tidak memblokir kasir.
- **Update in-place**: download APK → verifikasi **SHA-256** (kalau tidak cocok, install DITOLAK) →
  install lewat FileProvider. Data lokal (DB + config) tetap karena install in-place.
- Server punya **registry rilis + changelog** (`/app/pos-releases`) dan endpoint publik
  `GET /api/pos/version.json`; publish wajib menyertakan sha256 dan changelog.

### Belum ada di versi ini
- Dialect `STAR` dan `CITIZEN` dideklarasikan tapi belum diimplementasi (dipilih → fallback ESC/POS
  dan dilaporkan).
- Blok gambar/raster pada struk masih placeholder berlabel (butuh rasteriser).
- Sequence init chip USB belum diverifikasi di hardware nyata (baru review + unit test).
- Reprint bill hanya same-day, cache in-memory.
