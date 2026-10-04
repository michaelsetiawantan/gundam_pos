# Gundam POS — changelog

Format: [Keep a Changelog](https://keepachangelog.com/) · versi semver, versionCode naik monoton.
Changelog ini yang dikirim ke server saat publish release (kolom `changelog` di `PosRelease`) dan
yang ditampilkan ke tablet sebagai "what's new".

## [0.12.2] — 2026-10-04

Diagnostics grew up: the tablet now leaves a readable trail for problems that never touch the API, and that
trail survives the app dying.

### Added
- **Device log screen** (More → Open device log): the recent log lines newest-first with level, tag, time and a
  marker for lines that came from an earlier run; filter per level, a count (`N lines · X error, Y warn`),
  Copy, Refresh and **Send to server** (the durable send path: queued in the outbox first, uploaded after).
- **App failures are logged.** Thirteen previously silent `catch` paths now write a bounded line through the
  same log — outbox order/line/send refusals with their code, order-queue and settlement flush failures,
  print-log pending/upload failures, config hydration from cache, open-orders cache reads/writes, shift
  restore, media cache init and release-manifest load/save. Behaviour is unchanged: nothing new is thrown and
  no password/token ever appears in a line.

### Fixed
- **The trail survives a crash.** The log ring was in-memory only, so the evidence died with the process —
  exactly when it matters. warn/error lines are now persisted to a bounded SQLite table (`device_log`, schema
  4 → 5), restored on the next start and shipped in the diagnostic bundle tagged `previousSession: true`.
  Capped at 200 rows / 7 days; info lines stay memory-only on purpose.

## [0.12.1] — 2026-10-04

### Fixed
- **The queue now pushes when the app comes back to the front.** Auto-push used to ride config sync only, so a
  cashier who never left the order screen could sit on a full offline queue. The app shell observes the
  lifecycle and pushes on resume — but only when signed in, idle and the queue is not empty, so a resume never
  fires an empty round trip.
- **A refused settlement keeps its FAILED badge across a restart.** The refusal (status + the server's error
  code) lived only in memory; the outbox row in SQLite now stores it and the session rehydrates it on start, so
  the cashier can still see what was refused and why. Idempotency is unchanged: the same key is retried, never
  a second settlement.
- **Merging tables carries the captain batches.** The next batch label is derived from the order's batch count,
  so a merge used to restart the merged table at "A" although A/B were already printed on its dishes. The merge
  now moves the CaptainBatch rows (and their line links) with the lines — the merged table continues at C, D…

### Notes
- SQLite schema version 3 → 4 (additive `ALTER TABLE pending_sync ADD COLUMN status/error_code`), applied
  automatically on first launch of this build.

## [0.12.0] — 2026-10-04

### Fixed
- **Cart qty no longer reverts.** Adding the same product again never asks for a sync and never drops back to
  the first qty: the queued add now carries the tablet's `clientLineKey` and only the DELTA for a line the
  server already knows, so the server merges by key and sums the qty. Send-cart therefore sends the real qty.
- **Bill modifiers sit under their own line.** A flat `MODIFIER_LIST` at the end of the ticket (web format
  builder) detached every modifier from its dish — modifiers now print per item line, in the flat list too,
  qty following the real order. Money columns are sized from the rendered text so a 13-cell label is never
  clipped.
- **No order work without an open shift.** New Order, entering an active table and starting an order are
  blocked with a clear "Start a shift first" dialog (button straight to Shift). The server rejects a line add
  with `409 shift_required` too. Read-only screens and the offline settle queue stay open.

### Changed
- Payment method buttons are larger (180 wide, 34 icon, 17 text).
- Today's orders gained a filter: All / Paid / Canceled / Voided.
- The dashboard shows the signed-in user's ROLE under the name instead of repeating the outlet.
- Dashboard menu icons are bigger (glyph 22 -> 30, title 16 -> 17) inside the same tile, still overflow-free.

## [0.11.0] — 2026-10-04

POS jalan tanpa internet: penjualan, kirim dapur, antrean push, + pembuka laci kasir.

### Added — POS CLIENT bisa bekerja tanpa server
- **Penjualan/settle offline**: kalau server tak terjangkau, penjualan **tetap selesai** di tablet — uang dihitung lokal (engine yang sama), nomor receipt dibuat lokal, bill **tetap tercetak**, order jadi PAID, lalu penjualannya **diantrekan**. Tidak ada lagi "No network — payment not settled".
- **Send cart ke dapur offline**: tidak perlu server untuk boleh; baris ditandai terkirim lokal + captain/bev **langsung cetak**, pengirimannya diantre.
- **Antrean push** FIFO per order (`create → line → send → settle`), **otomatis** saat tablet berhasil kontak server + tombol **Push now** di layar More.
- **Penolakan server ditangani jujur**: settle yang ditolak ditandai **FAILED + kode alasannya** dan kasir diberi tahu (tidak diulang diam-diam). **Commit ulang** mengirim snapshot terbaru dengan kunci yang sama — idempoten, mustahil dobel.
- **Label di daftar**: **`PAID - Offline`** selama masih hanya di tablet, **`PAID`** setelah diterima server, dan **FAILED + alasan** untuk yang ditolak (ada menu Retry).
- Sisi server: **kunci idempotensi** (`clientSettlementKey`) + **verifikasi nominal yang ditagih vs hitungan server** (beda → `totals_mismatch`, tidak dibukukan) + **jam penjualan offline dihormati**.

### Added — pembuka laci kasir (cash drawer)
- Penjualan yang memuat pembayaran **CASH** memicu **pulse ESC/POS** (`ESC p`) ke printer struk untuk membuka laci — menempel pada job bill yang sama, jadi ikut jalur antrean/retry dan **tetap bekerja offline**. Reprint **tidak** membuka laci; pembayaran non-cash juga tidak.

## [0.10.0] — 2026-10-04

Gabung QTY di cart & cetakan, kolom uang lurus, meja cancel langsung hilang.

### Added — QTY digabung untuk item yang sama
- **Di cart**: pilih A (modifier X), lalu B, lalu A (modifier X) lagi → **satu baris** dengan QTY dijumlah. Syaratnya: item sama + modifier sama (opsi & harga) + price level sama + **belum dikirim** ke dapur; baris yang sudah dikirim **tidak pernah** digabung (dibuat baris baru).
- **Di cetakan**: baris identik digabung jadi satu baris (QTY dijumlah) di **BILL**, **RECEIPT_COPY**, dan **CAPTAIN_ORDER** (captain tetap boleh terpecah **antar batch**, digabung di dalam batch).
- Didukung sisi server: tablet mengirim **kunci baris** (`clientLineKey`); menambah dengan kunci yang sama **menjumlahkan QTY** di baris yang sama, bukan membuat baris kedua — jadi replay antrean offline pun tidak bisa menggandakan baris. Baris yang sudah dikirim ke dapur menolak digabung (tablet otomatis memakai baris baru).

### Fixed — BEV LABEL satu label per satuan (bukan digabung)
- Printer beverage adalah **label printer**: **1 produk = 1 cetakan**. Baris QTY 3 mencetak **3 label**, masing-masing 1 unit — bukan satu label bertuliskan “3”. (Captain order tetap digabung per batch.)

### Fixed — kolom uang di cetakan tidak lurus
- Angka uang kini dicetak sebagai **dua kolom terpisah**: label mata uang di posisi tetap + angka rata kanan di kolomnya sendiri (jarak 2 spasi). Sebelumnya seluruh “Rp. 1.000,00” dipad sebagai satu sel, jadi label `Rp.` menjorok ke dalam saat nominalnya lebih pendek. Berlaku untuk baris SUBTOTAL/DISCOUNT/VAT/TOTAL dan baris pembayaran; sama di preview dan cetakan.

### Fixed — meja yang sudah di-cancel masih tampil di Open Tables
- Begitu cancel sukses, tablet **menyaring meja itu langsung** dari daftar (tanpa menunggu server, tanpa refresh). Antrean `order_create` untuk order itu juga dibuang, jadi meja tidak muncul lagi sampai sync.

## [0.9.0] — 2026-10-04

Open Tables offline-first, audit transaksi, dan cetakan yang benar.

### Added — info transaksi CANCELED / VOIDED
- Di **Today's Transactions**, baris CANCELED/VOIDED/REFUNDED bisa diketuk → **pop-up** berisi: status, **waktu aksi**, **siapa yang mengajukan**, **siapa yang meng-authorize**, dan **alasan**. Data lama / tanpa catatan → `-`.
- Kalau aksinya diterapkan langsung oleh role yang memang berhak (tanpa approver kedua), authorize ditulis **“Auto-approved — <nama> (role-nya berhak)”**.

### Changed — Open Tables bisa jalan offline
- Daftar meja **langsung tampil dari daftar terakhir yang tersimpan** (tanpa menunggu server), server di-tarik di belakang; **refresh yang gagal tidak mengosongkan** daftar. Lanjut/lihat order & buat order baru tetap bisa **tanpa internet**; server hanya wajib untuk approval.
- **Meja hantu setelah cancel diperbaiki**: order yang dibuat offline menyisakan antrean `order_create`, sehingga meja yang sudah dicancel muncul lagi sampai sync. Sekarang begitu cancel sukses, antrean untuk order itu dibuang. Order yang belum pernah sampai ke server → cancel = tarik antrean + tutup lokal (bukan error).

### Fixed — aturan uang di cetakan
- **Tiket internal** (CAPTAIN_ORDER, BEV_LABEL, CANCELED_ORDER) **tidak pernah mencetak harga** — nama + qty saja (+ modifier nama/qty). Ditegakkan di render sehingga format yang salah-publish pun tidak bisa membocorkan harga.
- **Tiket BILL/RECEIPT_COPY/SHIFT_OPEN/SHIFT_CLOSE/Z_REPORT** mencetak uang **dengan mata uang dari config Web POS** (`Rp. 45.000,00`), bukan angka polos lagi.
- **Jarak QTY ↔ mata uang** diberi jeda (gutter 2 sel) supaya tidak menempel.
- **Kolom uang pada baris Subtotal/Discount/Total dll kini sejalur** — satu kolom tetap per blok (sebelumnya dihitung per baris sehingga nilai panjang/pendek mulai di titik berbeda).
- Nama **diskon/voucher** ikut tercetak: `Discount (Happy Hour)   Rp. 9.500,00`.

### Fixed — captain order tercetak dua kali
- Format default punya blok **BATCH** (yang mencetak isi batch) **dan** `ITEM_LIST` per kategori → item tampil dua kali. Sekarang **sekali**, dikelompokkan per kategori (routing per kategori tidak berubah).

### Changed — semua angka uang di UI pakai mata uang server
- Seluruh label harga di aplikasi (kartu menu, cart, tombol, panel diskon/voucher, pembayaran, sukses, shift, hari ini, approval) memakai **label currency dari server** + pemisah ribuan + 2 desimal. Nilai tidak berubah — murni tampilan.

### Changed — Cancel order & cancel item
- Cart **benar-benar kosong** → Cancel langsung tanpa minta alasan; kalau server tetap meminta alasan, POS meminta sekali lalu mencoba lagi (tidak buntu lagi).
- Setelah **cancel item berhasil**, item **langsung hilang** (cart ditarik ulang dari server) — tanpa refresh manual.
- Modal “Cancel sent item” didesain ulang (ringkas, ada kartu item, stepper rapi dengan batas `/ N`, dan aman terhadap keyboard).

## [0.8.2] — 2026-10-03

Cancel item/order + aturan uang di cetakan (internal tanpa harga, bill pakai mata uang).

### Fixed — modal "Cancel sent item" berantakan
- Didesain ulang: kartu ringkas item (nama + qty × harga satuan + total baris), baris kuantitas dengan stepper rapi (menampilkan batas `/ N` di baris yang sama, bukan menggantung di bawahnya), kolom alasan berlabel, dan dialog **aman terhadap keyboard** (bisa di-scroll, tidak terdorong keluar layar).

### Fixed — item yang sudah dicancel tidak langsung hilang
- Setelah cancel item **berhasil**, tablet kini **menarik ulang cart dari server** sendiri — item hilang saat itu juga, **tanpa refresh manual**. Kalau cancel-nya masih menunggu approval, item sengaja **tetap ada** (penolakan tidak boleh menghilangkan baris).

### Fixed — cancel order gagal `reason_required` padahal cart kosong
- **Akar**: server hanya menutup langsung bila order belum pernah dikirim ke dapur (tidak ada batch). Order yang cartnya sudah dikosongkan tapi punya riwayat batch dianggap masih "ada yang dibatalkan" → minta alasan → dan POS mengirim alasan kosong → gagal buntu.
- **Fix (server)**: order yang **tidak punya baris tersisa** ditutup langsung — tidak ada yang perlu dibalik, jadi tidak ada yang perlu dialasan.
- **Fix (client)**: kalau server tetap meminta alasan (mis. masih ada baris terkirim yang tak terlihat di cart), POS **meminta alasan sekali lalu mencoba lagi** — tidak lagi buntu.

### Fixed — tiket INTERNAL tidak boleh ada harga
- `CAPTAIN_ORDER`, `BEV_LABEL`, `CANCELED_ORDER` kini **hanya nama + qty** (+ modifier nama/qty). Tidak ada harga per item, tidak ada subtotal/total/pajak/pembayaran.
- **Ditegakkan di render kedua engine** (Dart & web), jadi format yang salah-publish pun **tidak bisa** membocorkan harga ke tiket dapur — dan format default-nya juga sudah qty-only.

### Fixed — angka uang di cetakan tanpa mata uang
- `BILL`, `RECEIPT_COPY`, `SHIFT_OPEN`, `SHIFT_CLOSE`, `Z_REPORT` kini mencetak uang dengan **label mata uang dari config Web POS**: `Rp. 45.000,00` (bukan `45000.00`). Berlakupula untuk preview.
- Bukti nyata: captain order (format ber-`NAME_QTY_PRICE` + `MONEY_LINES`) tercetak `Espresso   2` saja; bill tercetak `Subtotal  Rp. 45.000,00`.

## [0.8.1] — 2026-10-03

Semua angka uang ditampilkan dengan label currency server + separator + 2 desimal.

### Changed — tampilan uang seragam di seluruh app
- **Semua** label harga/uang (kartu menu, cart, tombol, panel diskon/voucher, layar pembayaran, layar sukses, shift, hari ini, approval) kini memakai **satu formatter bersama**: `<label currency dari server>. 1.000,00` — contoh `Rp. 1.000,00`.
- Label diambil dari config server (`shift.currencyLabel` pada payload outlet), **bukan** hardcoded "Rp" lagi. Ganti mata uang di server → seluruh app ikut.
- Selalu **2 desimal** dengan pemisah desimal koma, ribuan titik; negatif ditulis `-Rp. …`.
- **Nilai tidak berubah sama sekali** — ini murni tampilan; perhitungan, penyimpanan, dan payload server tetap angka polos (ada test yang mengunci: format ↔ parse tetap berbalik arah).

## [0.8.0] — 2026-10-03

END SHIFT 3 tipe, hak approval terpisah, separator ribuan, pesan error jelas.

### Added — END SHIFT dengan 3 tipe hitung
- Tipe diatur **per outlet** di Web POS dan **di-snapshot ke shift** saat closing (shift lama tetap benar walau setting berubah):
  - **ONLY CASH** — 1 input (perilaku lama, tetap default).
  - **CASH / CASHLESS** — 2 input; expected cash = opening + cash sales − payout, expected cashless = seluruh penjualan non-cash.
  - **CROSSCHECK PER PAYMENT METHOD** — satu input **per metode pembayaran aktif**, variance per metode + total.
- Breakdown tersimpan (JSON) dan tampil di **Closing Report** web.

### Added — hak approval dipisah per aksi
- **`VOID_APPROVE`** (void bill sudah dibayar), **`CANCEL_ORDER_APPROVE`** (cancel satu order), **`CANCEL_ITEM_APPROVE`** (cancel satu item terkirim) kini **tiga permission terpisah** — tag per role di Web POS → Roles. Approval kini juga membawa tipe aksi yang membedakan cancel item vs cancel order.
- Layar approval POS menampilkan **"Cancel item"** / **"Cancel order"** / **"Void"** secara terpisah.
- Hak yang sudah ada tidak hilang: flag baru otomatis disalin dari `VOID_APPROVE` untuk semua role saat migrasi.

### Changed — cancel order dengan cart kosong
- Cart **benar-benar kosong** → tombol Cancel langsung menutup order **tanpa meminta alasan** (server memang menutupnya tanpa approval). Cart berisi item tetap minta alasan.

### Changed — separator ribuan pada semua input uang
- Ketik `1000` → tampil `1.000`, **nilainya tetap 1000**. Berlaku untuk opening cash, counted cash (semua tipe END SHIFT), shipment, dan jumlah pembayaran. Huruf/tanda minus tidak bisa menjadi angka; paste dibersihkan otomatis.

### Fixed — pesan error yang tidak menjelaskan apa-apa
- Sebelumnya POS hanya menerjemahkan **9** kode error; **113 kode** yang bisa diterima tablet kini punya penjelasan **apa yang harus dilakukan** (78 pesan spesifik + fallback per keluarga seperti `*_not_found`, `*_required`, `invalid_*`). Kode aslinya tetap dicantumkan untuk penelusuran.
- Termasuk seluruh keluarga approval: salah username/password authoriser (permintaan tetap PENDING sampai diotorisasi/ditolak), hak approve tidak cocok, sudah diputuskan, penjaga void (`not_paid`, `void_outside_trading_day`, `no_transaction`, `reason_required`), cancel item/order, diskon/voucher, shift, meja, pembayaran.

## [0.7.1] — 2026-10-03

Preview printout: pilih bill atau captain order.

### Added — "Printout preview" di menu order
- Tombol **Preview bill** diganti **Printout preview**: sekali klik muncul pilihan **Preview bill** atau **Preview captain order**, lalu masuk ke preview masing-masing.
- **Preview captain order** baru: menampilkan lembar yang benar-benar akan dikirim ke dapur — item dikelompokkan per **menu**, per **batch** (kalau lebih dari satu batch, tiap lembar diberi label `captain sheet n of m`), lengkap dengan nomor meja.
- Preview captain memakai **format CAPTAIN_ORDER terpublish dari server**; kalau belum ada (atau gagal render) jatuh ke layout built-in dengan **catatan jujur** — sama seperti preview bill.

### Changed — satu kerangka preview untuk semua ticket
- Chrome preview (toggle 58/80 mm, catatan fallback, baris "format server/built-in", badan monospace, footer) kini **satu implementasi bersama** (`PreviewChrome`) dipakai preview bill maupun captain → tampilan dan pesan tidak bisa lagi berbeda antar ticket. Key test lama (`bill-preview-*`) tetap sama.

### Catatan penting untuk konsistensi preview ≡ cetak
- Payload captain dibangun lewat **builder yang sama** dengan jalur cetak (`TicketPayloadBuilder.captainOrderSheets`) dan konteks dari dispatcher, jadi preview = yang tercetak. Label menu pun diresolusi dengan cara yang sama seperti printer (`routing.menuForItem`).

## [0.7.0] — 2026-10-03

Gambar tile dari upload (kategori & produk) + kotak menu lebih besar.

### Added — upload gambar untuk kategori & produk
- **Kategori (node menu layout)** dan **produk (item)** kini punya gambar hasil **upload**, disimpan sebagai **key aset media** (`MenuLayoutNode.imageKey`, `Item.imageKey`). Input gambar berbasis URL pada dialog menu layout **dihapus dari UI** (kolom lama tetap ada untuk data lama, tidak dipakai).
- Di **WEB POS**: dialog node menu layout dapat pilih-file upload + tombol hapus + pratinjau; halaman **produk** dapat hal yang sama. Labelnya menyebut jelas: kalau kosong, tablet memakai icon bawaan.
- Gambar ikut jalur media yang sudah terverifikasi (upload → domain MEDIA naik → tablet menarik cache → disajikan dari origin API yang sama dengan tablet pakai, LAN maupun domain). **Tidak ada jalur sync baru.**
- Payload config MASTER kini memuat `imageKey` untuk node & item. Menyimpan node menu layout dan item **menaikkan versi MASTER** — sebelumnya route node menu layout **tidak** melakukannya, jadi perubahan menu (termasuk nama) tidak pernah sampai ke tablet.

### Changed — POS order: gambar menggantikan icon bila ada
- Tile produk/kategori menampilkan **gambar yang di-upload** kalau byte-nya sudah ada di tablet; kalau **belum/tidak ada**, tetap **icon bawaan** (tile tidak pernah kosong) — persis yang diminta.
- Kotak menu diperbesar lagi: kolom per tile 215px → **255px**, rasio 1.15 → **0.98** (lebih tinggi daripada lebar) supaya gambar benar-benar terlihat; icon fallback 46px, judul 17, harga 15.

### Fixed — gambar hilang saat pohon menu disusun
- `imageKey` **dibuang** saat `orderTree()` membangun ulang node (prune item + perakitan parent/child) dan saat kategori fallback dibuat → gambar kategori tak akan pernah muncul walau sudah di-upload. Kini diteruskan di ketiga jalur.

## [0.6.9] — 2026-10-03

URL media mengikuti alamat yang dipakai tablet.

### Changed — URL gambar media mengikuti host tablet
- Sebelumnya URL aset memakai `MINIO_PUBLIC_URL` yang tetap (IP LAN). Sekarang server **menyesuaikan URL ke host yang dipakai tablet** saat meminta manifest/resolve: host ditukar, **port object-storage tetap**. Tablet lewat LAN dapat `10.80.88.20:39000`, yang lewat domain publik dapat host publik itu — **tanpa perubahan apa pun di tablet**, termasuk tablet yang sudah terpasang.
- `key`/`sha256` tidak berubah (nama yang dipakai blok IMAGE tetap sama).
- Test: satu aset, dua host → dua URL yang benar; kunci & sha tetap.

### Fixed — unduhan gambar yang gagal dulu kini dicoba ulang
- Sinkronisasi media kini dijalankan **setiap** config sync (bukan hanya saat versi domain MEDIA berubah). Operasinya idempoten (hash sama = skip), jadi ini otomatis **mengulang unduhan yang gagal** (offline, host salah) tanpa perlu mengubah data apa pun.
- Best-effort seperti sebelumnya: kegagalan tidak pernah menghambat kasir.

## [0.6.8] — 2026-10-03

Field kontak outlet sebagai variabel print + gambar media benar-benar tercetak.

### Added — Instagram / TikTok / email outlet sebagai variabel print
- Kolom baru `Tenant.instagram` / `tiktok` / `email` (+ migrasi additive) dan **form Outlet di web** kini punya ketiga input dengan label variabelnya.
- Token print baru: **`{store_instagram}`, `{store_tiktok}`, `{store_email}`** — tersedia di builder web (grup *Store / outlet*, `show_if_present`) dan **ikut tersync ke POS** lewat domain OUTLET (menyimpan outlet sudah menaikkan versi domain OUTLET, jadi tablet menariknya).
- POS mengisinya dari config ke jalur yang sama dengan token lain (satu kosakata token untuk preview **dan** cetak). Manifest paritas token diperbarui (98 token).

### Fixed — gambar media untuk blok IMAGE tidak tercetak di printer LAN
- **Akar**: transport **LAN :9100** memakai encoder sinkron **tanpa** image source, jadi blok IMAGE selalu keluar placeholder `[IMAGE key]` **walau byte-nya sudah ada di cache tablet**. Bluetooth dan USB sudah benar — hanya LAN yang tidak.
- **Fix**: source gambar kini diteruskan **eksplisit ke SEMUA transport** dari satu tempat (app factory). Tidak ada seam global, tidak ada celah per-transport.
- Rantai lain sudah terbukti benar: upload → manifest (hanya aset tenant aktif) → unduh+verifikasi sha256 → cache lokal (skip kalau hash sama, prune kalau aset hilang) → render memakai `assetKey` yang sama dengan `key` manifest.
- Test pengunci: key manifest ≡ `assetKey` blok ≡ file cache; assetKey ter-cache → byte raster nyata (`GS v 0`), bukan placeholder; assetKey tak ada → placeholder berlabel jujur; **loopback socket :9100** membuktikan byte yang benar-benar dikirim.

## [0.6.7] — 2026-10-03

Format print akhirnya benar-benar turun ke tablet (akar version-handshake).

### Fixed — format print tidak pernah turun ke POS (akar sebenarnya)
- **Akar**: handshake versi domain mempercayai **klaim versi dari client**. POS mencatat domain sebagai "applied" **tanpa memastikan payload-nya benar-benar diterima/disimpan**. Jadi tablet bisa mengaku `FORMAT` sudah up-to-date sementara store-nya **kosong** → server (benar menurut klaim itu) **tidak pernah mengirim FORMAT lagi** → tiket dirender dengan **layout built-in** selamanya. Domain lain (MASTER/OUTLET) sering berubah sehingga selalu terkirim dan "sembuh sendiri" — itulah sebabnya **hanya print** yang tak pernah selesai.
- **Fix 1 (server)**: domain **FORMAT selalu dikirim** pada tiap config sync, apa pun klaim client (payloadnya kecil). Tidak ada lagi keadaan "tablet terkurung tanpa format".
- **Fix 2 (client)**: klaim versi kini **jujur** — versi hanya dicatat kalau payload-nya benar-benar diterima & disimpan; kalau tidak, versinya di-nol-kan agar sync berikutnya menariknya ulang. Payload dari server juga **selalu ditulis ke cache** (bukan hanya domain yang diminta device).
- **Fix 3 (client)**: hidrasi dari cache dijalankan **sebelum** perencanaan sync (deterministik, tidak balapan) — dan klaim versi yang tidak didukung payload dibuang saat start.
- **Fix 4 (operator)**: tombol **"Re-sync everything"** di layar More — melupakan versi domain terpasang dan menarik **semua** domain lagi. Jalan keluar kalau ada tablet yang terlanjur macet.
- **Bukti**: payload FORMAT asli dari DB produksi (7 format terpublish, termasuk BILL v3) diuji langsung: validator server **meloloskannya** (tidak ada yang di-skip), store POS **menerimanya**, dan `{store_name}` keluar **rata tengah** sesuai `align: CENTER` server.
- Test baru: (a) server — FORMAT tetap dikirim walau client mengklaim versi terkini; (b) server — format terpublish lolos validasi & masuk payload, yang unpublished tidak dikirim; (c) client — versi domain tak pernah maju tanpa payload (falsifiable: kode lama → FORMAT mengaku 21 tanpa payload); (d) client — format terpublish di cache menghasilkan tiket server, bukan built-in.

## [0.6.6] — 2026-10-03

Perbaikan regresi: menu & diskon hilang setelah sync, format server tak dipakai.

### Fixed — menu layout hilang semua + diskon tak bisa ditambah (REGRESI)
- **Akar**: sync config itu **parsial** — server hanya mengirim domain yang berubah. Tablet membangun ulang seluruh config dari `full` saja, jadi saat server menaikkan domain **OUTLET** saja, `MASTER` (katalog item, layout menu, **master diskon/voucher**) dibaca sebagai kosong → menu lenyap dan diskon tak bisa ditambahkan.
- **Fix**: setiap domain kini jatuh ke **payload cache last-known-good** bila server tidak mengirimnya. Test baru membuktikan sync OUTLET-saja tetap mempertahankan item, kategori, dan master diskon (falsifiable: kode lama → item 0).

### Fixed — format print tetap memakai built-in walau server sudah punya format
- **Akar**: store format print **hanya** diisi di dalam cabang sync, dan hanya kalau payload `FORMAT` ada di respons. Pada sync parsial (FORMAT tidak berubah) store tetap **kosong**, sementara versi domain yang tersimpan berkata "sudah up-to-date" → tiket dirender dengan **layout built-in** dan aturan server (mis. `align: CENTER`) diabaikan.
- **Fix**: `attachConfigCache` sekarang **menghidrasi** payload dari disk — katalog/outlet, **format print terpublish**, dan versi domain — sebelum dan terlepas dari sync. Format server kini benar-benar dipakai (termasuk alignment); renderer sudah benar (sudah diuji langsung dengan format persis dari DB).
- Test: format terpublish di cache → setelah hydrate, `formatFor('BILL')` ada dan `{store_name}` keluar **rata tengah** sesuai `align` server.

## [0.6.5] — 2026-10-03

Token print server ↔ POS disamakan; dashboard Home satu layar.

### Fixed — token print kosong padahal ada di format server
- **`{store_address}` (dan banyak token lain) memang tak pernah diisi.** Field `storeAddress` default kosong dan tak ada call-site yang mengisinya; server juga tidak mengirim identitas outlet di domain OUTLET. Kini payload config mengirim **`outlet`** (nama, shortcode, alamat, telepon, social, timezone, currency) dan **`group`** (nama, shortcode).
- **Akar struktural: token dibangun di DUA tempat** (`buildBillPreviewPayload` vs `TicketPayloadBuilder.bill`) → pasti drift. Kini **satu kosakata token bersama**: `TicketContext.tokens()` memuat **seluruh 95 token** yang dideklarasikan server — bernilai nyata atau string kosong (tak pernah absen), sehingga blok `show_if_present` melewatinya alih-alih mencetak token mentah.
- **BEV_LABEL menimpa identitas**: ia membangun `TicketContext` baru lalu disebar **setelah** `ctx.tokens()` sehingga token identitas jadi kosong. Kini memakai `copyWith`.
- **`{voucher_name}`/`{voucher_amount}` tak pernah tercetak**: `bill()` mengunci `voucher_amount: 0` dan tak membawa nama diskon/voucher; `payment_controller._printBill` juga tidak meneruskannya. Kini nama + nilai diskon/voucher mengalir ke cetak dan cache reprint.
- Token yang **sengaja kosong** didaftarkan eksplisit beserta alasannya (`kIntentionallyEmptyTokens`: void/refund/approval = khusus web; `legal_footer`/`custom_*` = belum ada field tenant; `shipment_description` = jalur amount-only).
- **Test paritas** dua sisi: `web/tests/print-token-parity.test.ts` + `pos/test/print_token_parity_test.dart` memakai manifest `pos/tool/print-tokens.json` (95 token, dibangkitkan dari `registry.ts`). Termasuk bukti **preview ≡ cetak**: teks hasil broker identik dengan teks preview, dan `{store_address}`/`{store_social}`/`{group_name}` benar-benar tercetak.

### Changed — Home dashboard satu layar, tanpa scroll
- Body diganti dari `ListView` ke `Column` + grid `Expanded` yang dihitung `LayoutBuilder` agar tepat mengisi tinggi tersisa. Tile dikecilkan (ikon 40, judul 16, sub 12, padding 12), `minHeight:132` dibuang, isi tile dibungkus `FittedBox(scaleDown)` agar tak pernah overflow.
- Kartu konteks dan banner lisensi dirampingkan (banner inilah yang dulu memaksa halaman scroll).
- Test: layar 800×1200 dengan banner lisensi aktif → `maxScrollExtent == 0`, tak ada `ListView`, tak ada overflow.

## [0.6.4] — 2026-10-03

Hapus diskon jadi instan, cetak ikut format server, tombol New order.

### Fixed — hapus diskon/voucher tidak benar-benar terhapus
- "Cancel discount" di halaman payment ikut **antrean approval** (kasir di bawah threshold), sehingga server **tidak membersihkan** diskon dan malah meninggalkan **approval PENDING hantu** — itu sebabnya diskon "balik lagi" saat membuka payment + muncul tulisan *awaiting approval*, dan baris yang sudah disilang tetap nongol di daftar approval. Kini **membersihkan = instan** (tidak menerapkan apa pun, jadi tak perlu approval) dan **permintaan PENDING yang tergantikan ikut ditarik**. Berlaku sama untuk **voucher**.

### Fixed — cetak/preview mengikuti format yang dipublish server
- **Menu grouping** pada captain order: nama menu kini benar-benar terisi (sebelumnya header menu kosong bila routing memakai menu item) sehingga hasil cetak sama seperti format yang disepakati.
- Token **`{table_number}`** dan **`{opened_by}`** kini diisi di jalur cetak Bill dan Captain (sebelumnya kosong di cetakan padahal terisi di preview).
- **Fallback tidak lagi senyap**: kalau outlet punya format terpublish tapi sebuah ticket tidak memakainya (tidak cocok/gagal render), operator mendapat **alert jujur** menyebut ticket type + alasannya — jadi tiket yang menyimpang tidak bisa disangka "sesuai format".
- Diverifikasi juga: **kunci ticket type** (BILL/CAPTAIN_ORDER/BEV_LABEL/CANCELED_ORDER/…) memang **sama** antara server dan tablet (dugaan mismatch terbantah).

### Changed — semua approval satu alur
- VOID, CANCEL ORDER, DISCOUNT, dan VOUCHER memakai alur yang sama: kalau role peminta berhak memutuskan → langsung diterapkan tanpa approval; kalau tidak → PENDING dan diputuskan lewat dialog otorisasi (username+password) dengan gate **per jenis approval**. Hapus diskon/voucher kini juga instan seperti reject.

### Changed — tombol New order diperbesar
- FAB "New order" di Open Tables dibuat lebih besar (ikon 30, teks 19, padding lebih lega) agar nyaman ditekan.

## [0.6.3] — 2026-10-03

Diskon yang di-approve kini benar-benar muncul di bill preview & payment.

### Fixed — diskon ter-approve tapi tidak ada di bill preview/payment
- Setelah approver meng-otorisasi (username+password) di POS, **server sudah menerapkan diskon** (`Order.discountId` terisi) — tapi POS **tidak pernah membaca** `discountId`/`voucherId` dari data order, sehingga bill preview dan perhitungan payment berjalan tanpa diskon.
- Kini POS **mengadopsi pricing dari baris order** saat reload/resume, dan **menyegarkan dari server sesaat sebelum membuka Payment dan Bill preview** (best-effort; saat offline tetap memakai yang lokal, tanpa mengganggu). Jadi diskon yang di-approve — di POS ini, dari device lain, atau dari web — selalu tercermin di tagihan.
- Test regresi: order dengan `discountId` → setelah reload, `pricing.applied` terisi dan payment menghitung `discountAmount` 300 / `payable` 27.450 (25000 − 300 + 11% VAT). Falsifiable: tanpa adopsi, test gagal.

## [0.6.2] — 2026-10-03

Approval informatif + otorisasi, modifier tanpa harga 0, navigasi web.

### Added — tampilan approval informatif
- Baris approval di POS kini menampilkan yang dimengerti operator: **meja** (nama table), **label diskon/voucher** (di-resolve dari master config lokal, mis. `Happy Hour · 10%`), **nama peminta**, **jam request (waktu lokal)**, dan **alasan** yang sudah dibersihkan dari suffix JSON `::{...}` (sebelumnya bocor ke layar).

### Added — Approve dengan otorisasi user yang berhak
- Kalau session POS tidak punya hak approve, tombol Approve memunculkan **dialog username + password**; server memverifikasi (argon2), memastikan user itu satu group **dan** punya hak memutuskan, lalu mencatat keputusan **atas nama user itu**. Kredensial salah atau tidak berhak → **401 `invalid_credentials` yang identik** (tidak membocorkan mana yang salah) dan dialog meminta lagi sampai benar. Password tidak pernah di-log/di-simpan.

### Changed — modifier di bill/print: tanpa harga 0
- Baris modifier dengan harga **0 → nama saja** (tidak ada `0.00`); modifier berharga >0 tetap menampilkan harga. Diterapkan **konsisten di dua engine** (web print-format + POS) sehingga bill preview tidak lagi menampilkan `+ Add egg 0.00` — total tetap di parent item.

### Changed — navigasi web lebih nyaman (web console)
- Sidebar diberi nafas (jarak antar item 4→8px, tinggi baris 39→44px, padding grup/sisi lebih lega) dan **highlight hasil pencarian** dirapikan: substring **kata utuh** dalam pil teal, bukan potongan kata (`Report` + `s`).

## [0.6.1] — 2026-10-03

Modifier tampil di cart, cetak paralel, bill preview, dan New Order.

### Fixed — modifier tidak muncul di cart
- Panel cart hanya menulis nama item induk; modifier yang dipilih tidak terlihat. Kini modifier **ditampilkan di bawah itemnya** ("Add egg · Crackers"), di panel kanan maupun sheet Cart.
- Sekaligus bug data: nama modifier **dibuang** saat baris diadopsi dari server. Kini nama tetap disimpan (harga di-set 0 karena `unitPrice` server sudah termasuk modifier — supaya total tidak dobel-hitung).

### Changed — cetak tidak lagi menahan proses
- `settle` menunggu print bill dan `send cart` menunggu print captain/bev — dengan retry printer **3× timeout 20s**, proses bisa tertahan ±1 menit. Cetak kini **fire-and-forget**: settle/send selesai tanpa menunggu printer, sementara **alert cetak tetap sampai** ke operator (permukaan alert di session → muncul sebagai SnackBar walau layar sudah berpindah). Kegagalan cetak tetap tidak pernah menggagalkan penjualan.

### Added — Bill preview
- Di dalam order, tombol **Preview bill** (panel kanan) membuka contoh bill yang akan dicetak, dirender dengan **engine print-format yang sama** dan **format BILL dari web POS server** (fallback layout bawaan + catatan jujur kalau belum ada format dari server). Ada toggle lebar 58/80 mm.

### Fixed — "Other table" tidak bisa Start order tanpa klik chip lagi
- Field nama meja tidak punya `onChanged`, jadi tombol **Start order** hanya re-evaluasi saat chip "Other table" di-tap ulang. Kini tombol aktif **begitu nama meja diketik**.

## [0.6.0] — 2026-10-03

Offline-first: tablet bisa kerja tanpa koneksi, sinkron sendiri.

### Added — keranjang optimistis
- Item yang dipilih **langsung masuk cart** dari data lokal (harga preview dari price level + modifier); pengiriman ke server terjadi di belakang. Harga server tetap yang menang saat adopsi, jadi tidak ada beda angka.

### Added — antrean durable + indikator jujur
- Baris yang belum terkirim ditandai **UNSYNCED** (kuning) / **FAILED** (merah) di panel cart, dengan tombol **Sync now**. More menampilkan "Queued order items: N".
- Antrean di-flush otomatis saat sinkronisasi config **dan** saat aplikasi kembali aktif (resume) — tidak perlu refresh manual.
- `Send cart` menahan diri bila masih ada item belum tersinkron ("N item belum tersinkron ke server…") — dapur tidak pernah menerima cart setengah.

### Added — buat ORDER BARU tanpa koneksi
- Nomor order dibuat tablet: `[shortcode POS]-[YYYYMMDD]-[HHMM]-[NNNNNN]` — **unik per perangkat** karena memuat shortcode POS, jadi antar tablet mustahil bentrok.
- Server menerima `clientOrderId` secara **idempoten**: id klien dipakai apa adanya (retry mengembalikan order yang sama, tanpa duplikat); id milik tenant/grup lain ditolak; guard lama (shift, meja, hanging) tetap berlaku.
- **Urutan flush** benar: `order_create` dulu, baru `order_line` milik order itu; baris untuk order yang belum tercipta **dilewati** (tetap antre), bukan dibuang.
- **Open Tables offline** menampilkan order server **plus** order lokal yang belum tersinkron, tanpa menggandakan setelah tersinkron.

### Fixed
- Reload/reconcile tidak lagi menghapus baris yang belum tersinkron (pekerjaan offline aman).
- Tombol lama **"Push pending"** meng-*ack* seluruh antrean **tanpa mengirim** (akan membuang item order) → diganti **"Sync now"** yang mengirim lalu dequeue hanya saat server menerima.

## [0.5.0] — 2026-10-03

Akar "item tidak muncul di cart", tanpa refresh manual, dan printer health.

### Fixed — AKAR item tidak muncul di panel cart (3× dilaporkan)
- Server (Prisma) mengirim **Decimal sebagai STRING** (`"45000"`), dan `addItem` melakukan cast kaku `line['unitPrice'] as num?` → **TypeError** → baris tidak pernah masuk cart lokal (server sudah menyimpannya), sehingga baru muncul setelah Refresh. Dibuktikan dari log tablet: `type 'String' is not a subtype of type 'num?' in type cast`.
- Parser kini **toleran** (num atau string) di `addItem` (qty/priceLevelIndex/unitPrice), `sendCart` (batch sequence), `_adoptLines`, `retryAfter` pada error body, `openHousebank` shift, dan versi config — kelas bug ini tidak boleh terulang.

### Fixed — void same-day langsung sukses (tidak "pending approval")
- POS hanya membaca `approval.status` dan default ke `PENDING`; server sekarang **auto-apply** untuk role yang berhak (`{voided:true}`) sehingga pesannya salah sampai halaman di-refresh. Kini bentuk langsung dikenali → **"Void applied — the bill is now VOIDED."**, dan daftar dimuat ulang otomatis.

### Changed — tidak perlu refresh manual
- Setiap aksi (void, approve/reject, kirim cart, dll) **memuat ulang daftar sendiri**, dan saat layar kembali aktif / app di-resume data di-refresh otomatis (Today's transactions, Approvals, Open Tables). Tombol Refresh tetap ada, hanya tak lagi wajib.

### Fixed — printer health selalu 404
- `POST /api/pos/printers/health` me-resolve aset pelapor hanya lewat `PosAsset.id`, padahal tablet mengirim `deviceId` miliknya → `asset_not_found` (404) di setiap laporan. Kini menerima **deviceId atau asset id** (selaras dengan settle/print-logs/diagnostics/shift).

### Changed — kotak menu lebih besar
- Grid menu ~215px per kotak (rasio 1.15) — kotak lebih besar dan lebih pas.

## [0.4.9] — 2026-10-03

Perbaikan update APK.

### Fixed — "APK terbaru tidak bisa diinstall"
- Prune APK saat app start (baru di 0.4.8) menghapus **semua** `*.apk`, termasuk APK yang baru saja diunduh dan **belum sempat dikonfirmasi** ke package installer. Kalau operator menekan Update lalu kembali ke app sebelum menekan "Install", file-nya sudah hilang → installer gagal ("can't install / problem parsing the package"). Kini **unduhan yang masih segar (< 30 menit) tidak pernah dihapus**, sementara APK lama tetap dibersihkan.
- Catatan: artefak APK sudah diverifikasi sehat (sha256 cocok dengan registry, zip utuh, signature sama dengan versi sebelumnya, minSdk 24 / targetSdk 36 tidak berubah).

## [0.4.8] — 2026-10-03

Waktu lokal, panel cart, storage update, dan diagnostik.

### Fixed — waktu bill & void same-day meleset 7 jam
- Container `gundam-web` **tidak punya tzdata** sehingga `TZ=Asia/Jakarta` diabaikan → server berjalan **UTC** (bill 00:02 WIB tercatat 17:02 dan cek "hari ini" meleset). Kini **tzdata dipasang** di image dan aturan batas hari/trading-day memakai **zona outlet** (`Tenant.timezone`) lewat satu helper `lib/pos/day.ts` (dipakai `requestVoid` same-day dan `listTodayOrders`).
- Di tablet, semua timestamp dari server kini di-parse lalu **`.toLocal()`** sebelum ditampilkan/dibandingkan (Today's orders, void same-day, Open Tables "opened Xm ago", Approvals).

### Fixed — item yang dipilih tidak muncul di panel cart kanan
- Body layar memakai `Listenable.merge([...])` yang **dibuat ulang setiap build** → callback lepas-pasang tiap frame dan notifikasi bisa terlewat, jadi panel tak repaint sampai refresh manual. Kini memakai **satu listenable stabil** + pengaman `setState` setelah item ditambahkan.

### Fixed — penyimpanan APK menumpuk
- Prune APK lama kini juga jalan **saat app start** (sebelumnya hanya saat mengunduh versi baru, sehingga ~200 MB yang sudah menumpuk tidak pernah dibersihkan). APK yang **sedang di-install tidak dihapus**; file non-APK tidak disentuh; kegagalan prune tidak pernah melempar.

### Added — "Send diagnostics to server" mudah ditemukan
- Di More, seksi **Diagnostics & support** kini punya tombol utama **Send diagnostics to server** (dialog catatan → kirim → pesan jujur: terkirim/ter-antre + alasan bila gagal).

## [0.4.7] — 2026-10-02

Approval dipindah ke POS Client (web hanya TIP).

### Added — layar Approvals di POS Client
- POS kini punya layar **Approvals** (dari Home): daftar permintaan **PENDING** untuk CANCEL / VOID / REFUND / DISCOUNT-VOUCHER + tombol **Approve/Reject** (konfirmasi), filter per jenis, refresh + "last synced" jujur, pesan ramah bila role tidak berhak. **TIP dikecualikan** — itu tetap di web.

### Changed — web console hanya TIP
- Halaman **Approvals di web dihapus** (beserta entri nav-nya). Web console kembali hanya punya **Tip Approval Queue**, sesuai desain: approval lain diputuskan dari POS Client.

### Changed — kalau role bisa approve, tidak ada approval yang diminta
- Peminta **CANCEL/VOID/REFUND/DISCOUNT/VOUCHER** yang rolenya berhak memutuskan **langsung ter-apply** di POS (tanpa langkah approval). Yang di bawah threshold tetap masuk PENDING dan diputuskan dari layar Approvals di POS.

### Fixed — tile Home overflow
- Menambah tile ke-5 membuat sub-judul panjang membungkus dan **overflow ~6px**. Sub-judul dipendekkan dan judul/sub-judul kini **ellipsised** sehingga label panjang tak bisa lagi merusak grid.

## [0.4.6] — 2026-10-02

Approval auto-apply, panel cart tablet, ukuran update, tombol Copy, dan POS asset group.

### Added — auto-approve + halaman Approvals
- Peminta **CANCEL / VOID / REFUND** yang rolenya berhak memutuskan kini **langsung ter-apply** (tanpa approval kedua) — sesuai PRD "kalau role-nya sendiri bisa approve → tanpa minta approval". Peminta di bawah threshold tetap masuk **PENDING**.
- Halaman baru **Approvals** (W55, perm `VOID_APPROVE`) untuk memutuskan cancel/void/refund/discount — sebelumnya yang ada hanya Tip Queue, jadi approver tak punya tempat memutuskan void.

### Fixed — panel cart tidak muncul di tablet 10"
- Panel cart kanan hanya tampil bila lebar ≥900 logical; tablet 10" yang di-scale melaporkan ±853 → panel tak muncul. Ambang diturunkan ke **820**; item yang dipilih langsung tampil di panel.

### Fixed — Cancel order sukses tapi layar stuck
- Setelah cancel sukses, layar kini **kembali ke Open Tables** (`pop`), bukan diam di layar order.

### Fixed — ukuran aplikasi membesar tiap update
- Setiap APK hasil unduhan disimpan dengan nama per-versi dan **tidak pernah dihapus** → tiap update menumpuk ±55 MB. Kini **hanya satu APK** yang disimpan (yang lama/`.part` dibersihkan sebelum menulis, dan file dihapus setelah diserahkan ke installer). Unduhan/verifikasi gagal tidak menghapus APK valid sebelumnya.
- Catatan: tidak ada patch inkremental — setiap APK memang build penuh; yang diperbaiki adalah akumulasi file unduhan.

### Fixed — tombol Copy tidak menyalin (web console)
- Semua tombol Copy memakai `navigator.clipboard`, yang **tidak ada di non-secure context** — console dibuka lewat `http://<IP-LAN>:3100`, jadi tombolnya gagal bisu dan operator harus blok teks manual. Kini memakai helper bersama dengan fallback `execCommand('copy')` + pesan jujur bila browser menolak.

### Added — POS asset → POS asset group, dan rename diblokir saat REVOKED (web)
- Aksi **Group…** per baris di POS Assets untuk **menetapkan/melepas** asset dari asset group (ter-scope; group milik grup lain → 404).
- Asset berstatus **REVOKED** tidak bisa di-rename lagi: tombol di-*disable* **dan** server menolak (`asset_revoked`, 409).

## [0.4.5] — 2026-10-02

Perbaikan lapangan: void 500, upload diagnostik/print-log, dan halaman sukses pembayaran.

### Fixed — void same-day error 500
- `Approval.orderId` itu **unik** (satu slot approval per order), tapi `requestVoid` memanggil `approval.create()` langsung → request kedua melanggar constraint → `P2002` → HTTP 500. Kini void **memakai ulang slot** yang ada (di-refresh jadi VOID), sama seperti cancel/discount.

### Fixed — "Send diagnostic" & "Retry upload" tidak jalan (server balas 404)
- Kedua endpoint (`/api/pos/diagnostics`, `/api/pos/print-logs`) me-resolve `assetId` sebagai **`PosAsset.id`**, padahal tablet mengirim **`deviceId`** miliknya → `asset_not_found` (404) → unggahan selalu ditolak. Kini keduanya menerima **deviceId atau asset id** (discope ke outlet + group).

### Fixed — "no network" padahal jaringan normal
- Retry upload print log kini **membedakan**: server **menjawab & menolak** (mis. `asset_not_found`) vs **tidak bisa dihubungi**. Pesan menyebut kode penolakannya, dan barisnya tetap disimpan untuk dicoba lagi.
- Kirim diagnostik menampilkan **alasan kegagalan** (mis. `server rejected (404 asset_not_found)`) alih-alih menuduh jaringan.

### Fixed — setelah settle sukses tidak muncul halaman sukses pembayaran
- Angka bill di-parse **defensif** (Decimal server bisa datang sebagai string) sehingga pembangunan halaman sukses tidak pernah gagal; peringatan cetak tidak lagi menghalangi. Setelah bill terbayar, halaman sukses **selalu** tampil.

## [0.4.4] — 2026-10-02

Observability: error POS client tercatat semua dan bisa dikirim ke server.

### Fixed — "settlement failed – unknown error" (server-side, ikut terdokumentasi)
- Akar: tablet mengirim identitas dirinya (`deviceId` klien) ke kolom `Transaction.deviceAssetId` yang merupakan **FK ke `PosAsset.id`** → `P2003 Transaction_deviceAssetId_fkey` → HTTP 500 tanpa body → tampil "unknown error". Settle kini **resolve identitas** (terima `PosAsset.deviceId` **atau** `PosAsset.id`, discope ke outlet) dan **tidak pernah menggagalkan penjualan** karena urusan pembukuan (id asing → `null` + warn).

### Added — pesan error menyebut status HTTP
- Kegagalan 5xx yang tak dijelaskan server kini berbunyi **"server error (HTTP 500) — log server punya detailnya"**, bukan lagi "unknown error". Kode 4xx yang tak dipetakan ikut menampilkan status.

### Added — semua error POS tercatat & bisa dikirim ke server
- **Setiap request yang gagal** (error HTTP maupun kegagalan jaringan) dicatat ke log diagnostik tablet (method + path + status + kode) — tanpa body/kredensial.
- Error **5xx otomatis mengantre** satu bundel diagnostik (durable outbox, dikirim saat sinkronisasi berikutnya; throttle 1 bundel / 5 menit) sehingga bisa **dicek dari sisi server** walau operator tidak membuka layar Print diagnostics.
- **Error tak tertangkap** (`FlutterError.onError` + `PlatformDispatcher.onError`) ikut masuk buffer diagnostik yang sama — bukan lagi layar blank tanpa jejak.

## [0.4.3] — 2026-10-02

Perbaikan UI/UX order entry, Today's Orders, cancel per-item, dan print diagnostics.

### Added — preview cart di sisi kanan (sesuai mockup)
- Di tablet lanskap, layar Order kini punya **panel cart persisten di kanan** (kiri: katalog, kanan: isi pesanan) — daftar baris (qty × nama, sub-total, tag SENT/UNSENT), Subtotal, dan aksi Send cart / Discount / Cancel order / Payment. Layar sempit/portrait tetap memakai bottom bar + sheet.

### Changed — nama menu & produk lebih besar
- Judul tile item/layout **16px**, harga **14px**, ikon item **40** — nama menu dan nama produk lebih mudah dibaca/ditekan.

### Fixed — navigasi back di order entry
- Tombol back naik **satu level menu** saat sudah drill (bukan langsung lompat ke Open Tables); tombol back Android ikut naik level (`PopScope`). Tersedia tombol eksplisit **All menus** untuk kembali ke root.

### Added — search produk
- Kotak search di panel menu mencari **seluruh item yang di-assign & aktif** (nama + SKU + itemcode) lintas semua node layout; kosong = drill-down normal.

### Added — cancel per-item untuk item yang sudah di-send
- Baris yang **sudah terkirim** bisa dibatalkan sebagian: pilih **qty** + **reason** → server membuat **approval PENDING** (diputus di web). Baris belum terkirim tetap hapus langsung.

### Fixed — order CANCELED/VOIDED tidak muncul di Today's Orders
- Order yang dibatalkan/void **hilang** dari daftar (layar hanya memuat bill yang baru di-settle). Kini ada feed server **`GET /api/pos/orders/today`** (transaksi hari itu per outlet, group-scoped) dan layar Today's Orders menampilkan **PAID / CANCELED / VOIDED / REFUNDED** dengan tag status + refresh. Aksi Reprint/Void hanya untuk PAID.

### Fixed — "Retry upload" print diagnostics selalu gagal
- Akar masalah: satu baris yang **ditolak server** menenggelamkan **seluruh batch** — baris yang sudah diterima tak pernah ditandai terkirim, dan pesan menuduh "offline/printer" padahal ini unggah log ke **server**. Kini baris dinilai per-id; pesan jujur (berapa terkirim, berapa ditolak + kodenya, atau server tak terjangkau — bukan printer). Baris ditolak disimpan untuk dicoba lagi.

### Fixed — Open Tables 403 untuk kasir POS
- Gate `GET /api/pos/orders` salah memakai `??` sehingga kasir ber-flag `POS_SALES` (tanpa `WEB_DASHBOARD`) ditolak 403. Kini salah satu flag cukup.

## [0.4.2] — 2026-10-02

Perbaikan lapangan lanjutan: alur order (hapus item, batal order), diskon/voucher, dan move table.

### Fixed — pembayaran diblok "cart belum di-send" padahal sudah di-send
- Baris yang dihapus di keranjang **hanya hilang di tablet**, tidak di server. Server tetap menyimpan baris yang sudah dihapus, sehingga saat settle server menjawab `require_send_cart` padahal tak ada lagi yang bisa di-send — operator terjebak. Hapus sekarang **menghapus di server** (`DELETE /orders/[id]/lines/[lineId]`) lalu di tablet.
- Keranjang kini **1:1 dengan server** (tidak lagi merge baris) dan tiap baris menyimpan **id baris server**, sehingga hapus/reload menunjuk baris yang benar.
- Tombol **Refresh** di order entry: baca ulang order dari server dan bangun ulang keranjang — jalan keluar saat tablet dan server tak sinkron.

### Added — batalkan order (termasuk yang sudah di-send)
- Aksi **Cancel order** di order entry. Order yang belum pernah send-cart **ditutup langsung** (tabel bebas); order yang sudah terkirim masuk **approval PENDING** (diputus di web console; POS tidak membalik apa pun sendiri).

### Added — diskon/voucher dapat diakses dari alur order
- Tombol **Discount** di cart bar (selain ikon di app bar) membuka pemilihan diskon/voucher. Master **tanpa tag kategori** kini berlaku untuk **seluruh bill** (mirror aturan server), sehingga diskon/voucher whole-bill benar-benar muncul dan bisa dipakai.

### Changed — move table ke nama custom
- Pindah meja bisa ke **nama meja free-text** (≤16 karakter) selain meja yang ada di daftar.

### Changed — ikon order lebih besar
- Ikon item di grid order diperbesar (26 → **38**) dan ikon folder grup (26 → **32**).

## [0.4.1] — 2026-10-02

Perbaikan UI/UX layar order (keluhan operator di tablet).

### Fixed — keranjang tidak sinkron di layar order
- Daftar keranjang (sheet "Cart") sebelumnya **tidak mendengarkan** perubahan order: baris yang dihapus tetap tampil dan total tetap basi sampai sheet ditutup lalu dibuka lagi. Sheet sekarang reaktif — item yang dipilih/hapus langsung tampil **tanpa perlu refresh**.

### Added — diskon/voucher dari alur order
- Diskon/voucher kini bisa dipakai **saat mengambil order** (aksi di app bar order entry, dengan ringkasan di cart bar), bukan hanya di layar pembayaran. Pilihan tetap **server-authoritative** (POST `/api/pos/orders/[id]/pricing`) dan **dibagikan** ke layar pembayaran, sehingga preview total di tablet sama dengan yang di-settle server. Bila tidak ada yang cocok, ditampilkan penanda.

### Changed — kotak menu sedikit lebih besar
- Grid menu mengikuti lebar layar: **±150 px per kotak** (rasio 1,35 — lebih lebar daripada tinggi), ikon 26, padding 10 — lebih nyaman ditekan tanpa mengisi layar.

## [0.4.0] — 2026-10-02

Perbaikan alur lapangan: order yang tidak bisa dilanjutkan, order hanging yang tak bisa dibuka lagi, layout menu, diagnostik, dan pesan error yang bisa dimengerti.

### Fixed — operator terjebak setelah memilih item
- Alur kirim keranjang tidak lagi bisa membuntukan operator: kalau server menjawab `nothing_to_send` padahal tablet masih menganggap ada baris belum terkirim (mis. kiriman sebelumnya sukses tapi responsnya hilang), keadaan **direkonsiliasi** sehingga gerbang pembayaran terbuka.
- Setiap penolakan server kini **ditampilkan dengan sebabnya** dan selalu meninggalkan jalan maju — tidak ada lagi layar mati tanpa penjelasan.

### Fixed — order hanging tidak bisa dibuka kembali
- Daftar **Open Tables** sebelumnya hanya menampilkan (tidak ada aksi tap) dan tidak ada jalur untuk mengadopsi order yang sudah ada — satu-satunya jalan adalah membuat order BARU. Sekarang baris order bisa di-tap dan order tersebut **dilanjutkan** (id, meja, waktu buka, nama pembuka, dan baris yang sudah terkirim tetap `sent` sehingga tidak dicetak ulang).

### Fixed — layout menu terlalu besar
- Grid menu mengikuti **lebar layar**, bukan jumlah entri: ±118 px per kotak, rasio 1,5 (lebih lebar daripada tinggi), ikon 20–22, padding 8–10 → 7–9 pilihan per baris di tablet (sebelumnya maksimal 5 kotak nyaris persegi).

### Added — diagnostik dari tablet
- Kartu **"Report issue to server"** di layar Print diagnostics: mengumpulkan bundel log + konteks device (versi app, device, outlet, koneksi, ringkasan print ok/fallback/failed, baris log terakhir) dan mengirimnya dengan catatan operator. **Tahan offline**: masuk outbox dulu, terkirim saat sinkronisasi berikutnya.

### Changed — pesan error yang bisa ditindaklanjuti
- Kode error server dipetakan ke kalimat yang menyebut tindakan: `shift_required` (mulai shift dulu), `device_not_registered` (aktivasi ulang perangkat), `credential_group_mismatch`, `order_closed`, `nothing_to_send`, dan `unknown_error` (arahkan kirim diagnostik). Tidak ada lagi pesan berbentuk kode mentah.

## [0.3.3] — 2026-10-02

### Added — izin lanjutan (kamera, task, push, sync otomatis)
- **CAMERA** (`android.permission.CAMERA`) — untuk foto & video. Dideklarasikan bersama `<uses-feature android.hardware.camera required="false">` **dengan sengaja**: meminta izin CAMERA membuat Android menganggap perangkat punya kamera, sehingga tablet tanpa kamera (umum pada panel POS) akan ditolak saat instalasi.
- **REORDER RUNNING APPS** (`android.permission.REORDER_TASKS`) — tablet bisa membawa task-nya sendiri ke depan (mis. setelah proses install update).
- **LISTEN TO C2DM MESSAGE** (`com.google.android.c2dm.permission.RECEIVE`) dan **LISTEN TO FCM MESSAGE** — FCM memakai izin receiver yang sama, jadi satu deklarasi mencakup keduanya, ditambah izin aplikasi `${applicationId}.permission.C2D_MESSAGE` (protectionLevel signature) dan **POST_NOTIFICATIONS** supaya pesan benar-benar tampil di API 33+.
- **PULL DATA FROM SERVER AUTOMATICALLY** — izin yang benar-benar dipakai adalah `INTERNET` (sudah ada). Ditambahkan `READ_SYNC_SETTINGS` + `WRITE_SYNC_SETTINGS` untuk implementasi bergaya SyncAdapter (sinkronisasi latar yang dijadwalkan sistem).

### Changed
- Guard pada `tool/package_apk.sh` kini mencakup 17 izin wajib (plus izin C2D_MESSAGE ber-applicationId yang dicek lewat akhiran nama).

> Catatan: izin hanya membuka kemampuan. Push belum berjalan sebelum app menyertakan SDK messaging + konfigurasi google-services; sinkronisasi latar otomatis belum ada kodenya; dan kamera belum dipakai UI mana pun.

## [0.3.2] — 2026-10-02

### Added — set izin tablet untuk pemakaian lapangan
Semua izin berikut dideklarasikan di **manifest release** (`android/app/src/main/AndroidManifest.xml`), karena build release tidak mewarisi manifest debug:

- **FULL NETWORK ACCESS** — `INTERNET` + `ACCESS_NETWORK_STATE` (membedakan "tak ada rute/DNS" dari "server menolak" saat probe aktivasi).
- **VIEW WIFI CONNECTIONS** — `ACCESS_WIFI_STATE` (diagnosa printer LAN; `CHANGE_WIFI_STATE` sengaja tidak diambil karena app tidak pernah mengubah setelan Wi-Fi).
- **PREVENT TABLET FROM SLEEPING** — `WAKE_LOCK` (menjaga CPU/screen hidup saat hitung shift atau antrean cetak sedang jalan).
- **RUN FOREGROUND SERVICE** — `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_DATA_SYNC` (tipe yang diwajibkan API 34+ untuk job sinkronisasi).
- **DOWNLOAD FILES WITHOUT NOTIFICATION** — unduhan APK update berjalan tanpa notifikasi sistem per berkas.
- **STORAGE (internal + SD card)** — `READ_EXTERNAL_STORAGE` (cap API 32) + `WRITE_EXTERNAL_STORAGE` (cap API 29, karena scoped storage sejak API 30).
  Catatan penting: pada API 30+ menulis ke lokasi SD yang terlihat pengguna tetap memerlukan **"All files access"** (`MANAGE_EXTERNAL_STORAGE`) yang harus diberikan manual di setelan sistem, dan app perlu membuka layar setelan itu. Penyimpanan privat app (staging APK, log cetak) tidak butuh izin apa pun.

### Changed
- `tool/package_apk.sh` memverifikasi **seluruh** daftar izin wajib pada APK hasil build (via `aapt2 dump badging`) dan menolak membuat paket bila ada yang hilang.

## [0.3.1] — 2026-10-02

### Fixed — tablet tidak bisa konek ke server sama sekali (KRITIS)
- **Izin `android.permission.INTERNET` hilang dari manifest release.** Flutter hanya menyuntikkan izin itu ke manifest `debug/` dan `profile/` (untuk tooling dev-nya), jadi build **release** tidak bisa membuat satu pun request HTTP — di tablet tampak seperti "tidak ada internet" padahal Chrome di tablet yang sama bisa membuka alamat server dengan normal. Sekarang izin tersebut ada di `android/app/src/main/AndroidManifest.xml`.
- `tool/package_apk.sh` menolak menghasilkan paket kalau APK hasil build tidak mendeklarasikan `INTERNET` (diverifikasi dengan `aapt2 dump badging` pada APK jadi, bukan pada file sumber), supaya kesalahan ini tidak bisa terulang.

> Rilis 0.3.0 tidak bisa dipakai di lapangan karena cacat ini: tablet pada 0.3.0 **tidak bisa** mengunduh pembaruan sendiri (butuh jaringan). Pasang 0.3.1 secara manual lewat halaman <server>/release.

## [0.3.0] — 2026-10-02

Penyelarasan dengan server: routing cetak per MENU, token siklus bill, dan gambar cetak dari object storage.

### Print routing
- Station per KATEGORI (`categoryRoutes` pada payload OUTLET): mis. menu Coffee → printer bar, Food → printer dapur. Urutan resolusi: override item → kategori terdekat (naik ke parent) → fallback routing `CAPTAIN_ORDER`. Printer nonaktif tidak pernah dipakai.
- Tanpa penugasan apa pun, `captainPrintersForStep` tetap dipakai (perilaku lama).
- Batch tetap DELTA: hanya baris yang belum terkirim dicetak — batch 2 tidak mengulang batch 1.

### Print payload (token baru)
- `{table_number}`, `{cashier_name_opened_bill}`, `{cashier_name_closed_bill}`, `{datetime_closed_bill}`, `{vat_percent}`, `{sc_percent}`.
- `{cashier_name_closed_bill}` = kasir yang membayar; `{datetime_closed_bill}` = waktu bayar. Keduanya kosong di tiket captain (dibuat sebelum pembayaran).
- `{table_number}` = label meja bila isinya murni angka (meja "Terrace" → kosong, tidak dikarang).
- Nama pembuka order dibaca dari `openedByName` pada payload order.

### Print format
- `ITEM_LIST` kini mendukung `groupByMenu`, `withModifiers`, dan `menuChar`: satu tiket bisa memuat beberapa menu dengan header pemisah, dan modifier menempel di bawah itemnya.
- Format captain bawaan memakai bentuk grouped (satu bagian per menu).

### Media cetak
- Berkas media ditarik dari manifest (`/api/pos/media/manifest`) ke cache lokal: verifikasi `sha256` + `size`, tulis ke `.part` lalu rename atomik, lewati kalau hash sama, hapus aset yang sudah tak ada di manifest.
- Blok `IMAGE` mencetak dari berkas lokal; raster 1-bit (Floyd–Steinberg) dibuat di perangkat, jadi cetak tetap jalan tanpa server.

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
