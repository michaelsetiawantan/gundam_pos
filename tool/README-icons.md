# Gundam POS — launcher icon & splash (cara bikin / how to regenerate)

Kalau APK cuma menampilkan logo Flutter, artinya `android/app/src/main/res/mipmap-*/ic_launcher.png`
masih file bawaan `flutter create`. Ganti file-file itu, atau regenerate dari nol seperti di bawah.

## Yang dipakai sekarang

| Layer | File | Catatan |
|---|---|---|
| Legacy icon (Android < 8) | `mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher.png` | 48 / 72 / 96 / 144 / 192 px, full-bleed |
| Adaptive icon (Android 8+) | `mipmap-anydpi-v26/ic_launcher.xml` | background `@color/ic_launcher_background`, foreground `@mipmap/ic_launcher_foreground` |
| Adaptive foreground | `mipmap-*/ic_launcher_foreground.png` | 108 / 162 / 216 / 324 / 432 px, transparan, mark di safe zone |
| Warna brand | `values/colors.xml` → `ic_launcher_background` = `#153B44` | sama dengan `--petrol` di `web/app/globals.css` |
| Splash | `drawable/launch_background.xml`, `drawable-v21/…` | petrol + mark di tengah |
| Nama app | `AndroidManifest.xml` → `android:label="Gundam POS"` | |

## Regenerate (tanpa dependency tambahan)

Tidak butuh `flutter_launcher_icons`. Background digambar oleh script Python murni (zlib+math,
tanpa PIL), glyph "G" dirender ffmpeg `drawtext` dengan font bold sistem, lalu di-downscale
ffmpeg lanczos. Totalnya 4 perintah.

```bash
cd ~/agent-working/code/gundam/pos
FF=~/.hermes/tools/ffmpeg-9.0.1-linux-x64/bin/ffmpeg
FONT=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf

# 1) master 1024: gradient petrol→teal, kosong (tanpa mark)
python3 tool/make_icon.py bgonly /tmp/gd_bg1024.png 1024

# 2) master icon: composite glyph "G" (geser +7px kanan, +5px turun = optis center)
"$FF" -y -i /tmp/gd_bg1024.png \
  -vf "drawtext=fontfile=$FONT:text='G':fontcolor=0xEAF7F4:fontsize=500:x=(w-text_w)/2+7:y=(h-text_h)/2+5" \
  -frames:v 1 /tmp/gd_icon_master.png

# 3) legacy icon 48/72/96/144/192
for s in 48 72 96 144 192; do
  "$FF" -y -i /tmp/gd_icon_master.png -vf scale=$s:$s:flags=lanczos -frames:v 1 /tmp/ic_$s.png
done

# 4) adaptive foreground (transparan, mark ±36% canvas = aman di safe zone 66dp)
"$FF" -y -f lavfi -i "color=black@0.0:s=432x432,format=rgba" \
  -vf "drawtext=fontfile=$FONT:text='G':fontcolor=0xEAF7F4:fontsize=155:x=(w-text_w)/2:y=(h-text_h)/2" \
  -frames:v 1 -pix_fmt rgba /tmp/ic_fg_432.png
for s in 108 162 216 324; do
  "$FF" -y -i /tmp/ic_fg_432.png -vf scale=$s:$s:flags=lanczos -frames:v 1 /tmp/ic_fg_$s.png
done

# 5) pasang ke mipmap
R=android/app/src/main/res
cp /tmp/ic_48.png $R/mipmap-mdpi/ic_launcher.png
cp /tmp/ic_72.png $R/mipmap-hdpi/ic_launcher.png
cp /tmp/ic_96.png $R/mipmap-xhdpi/ic_launcher.png
cp /tmp/ic_144.png $R/mipmap-xxhdpi/ic_launcher.png
cp /tmp/ic_192.png $R/mipmap-xxxhdpi/ic_launcher.png
cp /tmp/ic_fg_108.png $R/mipmap-mdpi/ic_launcher_foreground.png
cp /tmp/ic_fg_162.png $R/mipmap-hdpi/ic_launcher_foreground.png
cp /tmp/ic_fg_216.png $R/mipmap-xhdpi/ic_launcher_foreground.png
cp /tmp/ic_fg_324.png $R/mipmap-xxhdpi/ic_launcher_foreground.png
cp /tmp/ic_fg_432.png $R/mipmap-xxxhdpi/ic_launcher_foreground.png
```

## Aturan desain yang dipakai (jangan dilanggar)

- **Jangan pre-mask bentuk ikon.** Launcher Android menempelkan mask sendiri; kalau PNG sudah
  rounded-square, sudutnya jadi hitam dua kali. Master icon = full-bleed persegi.
- **Adaptive foreground wajib transparan** dan mark-nya di dalam safe zone 66dp dari canvas 108dp
  (script memakai ±36% canvas). Kalau lebih besar, ikon terpotong di mask bulat/squircle.
- **Glyph harus dari font asli**, bukan digambar dari geometri (ring + bar manual menghasilkan
  "step"/notch di sambungan crossbar yang terlihat di 48px). Pakai `drawtext` seperti di atas.
- **Center optis, bukan geometris**: glyph perlu turun sedikit (±0.5% canvas) karena cap-height
  font tidak simetris terhadap bounding box.
- Ganti warna brand → ubah `PETROL`/`TEAL` di `tool/make_icon.py` **dan** `values/colors.xml`
  (adaptive background), jangan cuma salah satu.

## Alternatif kalau mau tool pihak ketiga

`flutter_launcher_icons` (dev dependency) bisa dipakai dengan satu PNG 1024:

```yaml
dev_dependencies: { flutter_launcher_icons: ^0.14.1 }
flutter_launcher_icons:
  android: true
  image_path: "assets/icon/app_icon.png"   # 1024x1024, TANPA alpha untuk legacy
  adaptive_icon_background: "#153B44"
  adaptive_icon_foreground: "assets/icon/app_icon_foreground.png"  # transparan
```

Lalu `dart run flutter_launcher_icons`. Dipakai kalau nanti butuh ikon iOS/web juga; untuk Android
saja, cara dependency-free di atas sudah cukup dan ikut ter-commit di repo.
