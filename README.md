# Gundam POS Client (Tablet)

Aplikasi kasir Android (Flutter) untuk **Project Gundam**. Berjalan di tablet, menyimpan datanya sendiri
di SQLite lokal, mencetak ke printer thermal, dan **tetap bisa dipakai walau server mati / internet putus**.

- Versi saat ini: **0.12.0 (build 36)** — lihat [`CHANGELOG.md`](CHANGELOG.md)
- Server pasangannya: **gundam-web** (`/api/pos/*`) — dua repo terpisah, satu monorepo kerja
- UI aplikasi **wajib berbahasa Inggris** (konvensi terkunci repo ini), walau dokumennya Indonesia

🇬🇧 English version: [README.en.md](README.en.md)

---

## Fitur utama

| Area | Yang bisa dilakukan tablet |
|---|---|
| **Order** | Buka/buat meja, pesan per level harga, modifier, kirim ke dapur, split bill, pindah/gabung meja |
| **Bayar** | Tunai / non-tunai / campuran, diskon & voucher (ikut aturan approval server), kembalian, receipt lokal |
| **Offline** | Order, kirim dapur, dan **settle** tetap jalan; hasilnya masuk antrean lalu dikirim otomatis saat online |
| **Shift** | Start/End Shift. Tiga cara hitung tutup shift (ONLY_CASH / CASH_CASHLESS / CROSSCHECK_PER_METHOD) — diatur per outlet di web |
| **Approval** | VOID, CANCEL ORDER, CANCEL ITEM, DISCOUNT, VOUCHER: minta kredensial autorizer bila sesi kasir tidak berhak |
| **Cetak** | Jaringan (LAN), Bluetooth, USB. Format cetak dikelola di web; tablet merender sendiri |
| **Diagnosa** | Setiap percobaan cetak dicatat + bisa dikirim ke server (`/app/print-diagnostics` di web) |
| **Update diri** | Cek `/api/pos/version.json`, unduh APK, verifikasi sha256, tawarkan install |

### Offline-first (penting)

- Server tetap **otoritatif** untuk harga, id baris, dan ledger.
- Yang dikerjakan lokal saat offline: tambah baris, hitung uang, cetak, dan **settle**.
- Semua disimpan di **antrean durable** (`PushStore`, SQLite) dengan kunci idempotensi
  (`clientLineKey`, `clientSettlementKey`) supaya kirim ulang **tidak pernah** menggandakan data.
- Status transaksi di tablet: `PAID` (sudah sinkron server) · `PAID - Offline` (masih lokal) ·
  `FAILED` + alasan dari server.
- Kirim antrean: otomatis setelah config sync sukses (login/refresh/home) + tombol **Push now** di halaman More.

---

## Struktur

```
lib/
├── api/         api_client.dart · pos_api.dart        # HTTP + kontrak /api/pos/*
├── data/        local_db · config_cache · pos_store    # SQLite, cache config, PushStore (antrean)
├── logic/       cart · money · print_format_render     # aturan murni: keranjang, uang, render struk
├── models/      config_models · app_release · license
├── services/    print_broker/transports, escpos, media_sync, update_service, diagnostik
├── state/       app_session (inti), order, payment, pricing, shift, session, release
└── ui/          layar-layar (home, open tables, order entry, payment, shift, approvals, …)
tool/            package_apk.sh, print-tokens.json, BUILD-README.md
test/            67 file test (unit + widget)
```

**Aturan emas**: `lib/logic/` bebas dari I/O supaya bisa diuji lurus; I/O hanya di `data/` & `services/`.

---

## Menjalankan & menguji

```bash
flutter pub get
flutter analyze                 # harus bersih
flutter test                    # seluruh suite (saat ini 660/660)
flutter run -d <device>         # jalankan langsung ke tablet
```

## Build APK rilis

```bash
./tool/package_apk.sh http://<IP-SERVER>:3100 /tmp/gundam-pos.zip
```

Skrip itu: build APK release, stempel versi dari `pubspec.yaml` (+ git sha), lalu mengeluarkan
**zip** berisi APK + `sha256.txt` + `version.json` yang dipakai server untuk publish rilis.

Naikkan versi di `pubspec.yaml` (`version: X.Y.Z+NN` — `+NN` harus **naik monoton**) dan tulis
bagian changelog-nya; changelog itulah yang tampil di tablet/`/app/pos-releases`.

Cara pasang & hal-hal build lain (ikon, vocabulary printer, ganti default alamat server, demo login)
ada di **[`tool/BUILD-README.md`](tool/BUILD-README.md)**.

## Alamat server

Alamat server adalah **default build-time**, bukan keharusan: di layar Activation/Login (dan halaman More)
alamatnya bisa diubah dan diuji (`GET /api/health`). Urutan prioritas: **isi di tablet > default build >
default bawaan**.

---

## Cara tablet bicara ke server

- Semua lewat `/api/pos/*` (config, order, table, shift, print, media, release). Autentikasi per **device**
  (kode aktivasi sekali pakai + sesi), bukan login web.
- **Config sync per domain**: `MASTER` · `OUTLET` · `FORMAT` · `MEDIA`. Server menaikkan penanda domain
  saat ada perubahan; tablet menarik **hanya domain yang berubah** — jadi sync tidak pernah menghapus
  data domain lain (bug klasik yang sudah ditutup dengan test).
- **Format cetak** datang dari server (menggantikan baku internal). Tiket internal
  (CAPTAIN ORDER / BEV LABEL / CANCEL ORDER) **tanpa harga**; tiket beruang (BILL, RECEIPT, SHIFT, Z REPORT)
  memakai label mata uang dari web. BEV LABEL dicetak **satu stiker per unit**.
- **Laci kasir** terbuka lewat pulse ESC/POS (`0x1B 0x70`) saat ada pembayaran tunai — menempel pada job bill,
  jadi tetap jalan offline; cetak ulang tidak membuka laci.

---

## Konvensi yang dijaga

1. **UI English**, pesan error juga English (walau operator berbahasa Indonesia).
2. **Kredensial tidak pernah dicatat** — password autorizer hanya dipakai sesaat (verifikasi di server).
3. Setiap perbaikan **wajib punya test yang falsifiable** (bisa dibuktikan gagal bila perbaikannya dilepas).
4. Perubahan yang mengubah bentuk payload → minta server menaikkan domain config yang tepat.
