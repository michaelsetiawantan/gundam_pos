# Gundam POS Client (Tablet)

The Android cashier app (Flutter) for **Project Gundam**. It runs on a tablet, keeps its own data in a local
SQLite database, prints to thermal printers, and **keeps working when the server or the internet is down**.

- Current version: **0.12.0 (build 36)** — see [`CHANGELOG.md`](CHANGELOG.md)
- Server counterpart: **gundam-web** (`/api/pos/*`) — two separate repositories, one working monorepo
- In-app UI text is **English only** (locked repo convention); this document is the English mirror.

🇮🇩 [Versi Indonesia](README.md)

---

## What it does

| Area | On the tablet |
|---|---|
| **Orders** | Open/create a table, order by price level, modifiers, send to kitchen, split bill, move/merge tables |
| **Payment** | Cash / non-cash / mixed, discounts & vouchers (server approval rules apply), change, local receipt |
| **Offline** | Ordering, sending to kitchen and **settling** keep working; results queue and push when back online |
| **Shift** | Start/End Shift. Three end-shift count types (ONLY_CASH / CASH_CASHLESS / CROSSCHECK_PER_METHOD), set per outlet in the web |
| **Approval** | VOID, CANCEL ORDER, CANCEL ITEM, DISCOUNT, VOUCHER ask for an authorizer's credentials when the cashier's session may not decide |
| **Printing** | Network (LAN), Bluetooth, USB. Formats are managed in the web; the tablet renders them itself |
| **Diagnostics** | Every print attempt is recorded and can be uploaded (`/app/print-diagnostics` in the web) |
| **Self-update** | Polls `/api/pos/version.json`, downloads the APK, verifies sha256, offers to install |

### Offline-first (the important part)

- The server stays **authoritative** for prices, line ids and the ledger.
- Done locally while offline: adding lines, money math, printing and **settling**.
- Everything lands in a **durable queue** (`PushStore`, SQLite) keyed for idempotency
  (`clientLineKey`, `clientSettlementKey`) so a re-send **never** duplicates data.
- Transaction state on the tablet: `PAID` (server has it) · `PAID - Offline` (still local) ·
  `FAILED` plus the server's reason.
- The queue pushes automatically after a successful config sync (login/refresh/home) and via **Push now**
  on the More screen.

---

## Layout

```
lib/
├── api/         api_client.dart · pos_api.dart        # HTTP + the /api/pos/* contract
├── data/        local_db · config_cache · pos_store    # SQLite, config cache, PushStore (the queue)
├── logic/       cart · money · print_format_render     # pure rules: cart, money, receipt rendering
├── models/      config_models · app_release · license
├── services/    print_broker/transports, escpos, media_sync, update_service, diagnostics
├── state/       app_session (the core), order, payment, pricing, shift, session, release
└── ui/          screens (home, open tables, order entry, payment, shift, approvals, …)
tool/            package_apk.sh, print-tokens.json, BUILD-README.md
test/            67 test files (unit + widget)
```

**Golden rule**: `lib/logic/` stays free of I/O so it can be tested directly; I/O lives in `data/` and `services/`.

---

## Run & test

```bash
flutter pub get
flutter analyze                 # must be clean
flutter test                    # the whole suite (currently 660/660)
flutter run -d <device>         # run straight onto the tablet
```

## Build a release APK

```bash
./tool/package_apk.sh http://<SERVER-IP>:3100 /tmp/gundam-pos.zip
```

That script builds the release APK, stamps the version from `pubspec.yaml` (plus the git sha) and emits a
**zip** holding the APK + `sha256.txt` + `version.json` — exactly what the server needs to publish a release.

Bump `pubspec.yaml` (`version: X.Y.Z+NN`, where `+NN` must increase monotonically) and write the changelog
section; that changelog is what the tablet and `/app/pos-releases` show.

Install steps and the rest of the build lore (icons, printer vocabulary, changing the baked-in server
address, demo logins) live in **[`tool/BUILD-README.md`](tool/BUILD-README.md)**.

## Server address

The server address is a **build-time default**, not a constraint: the Activation/Login screens (and the More
screen) let you change and probe it (`GET /api/health`). Precedence: **set on the tablet > build default >
built-in default**.

---

## How the tablet talks to the server

- Everything goes through `/api/pos/*` (config, orders, tables, shifts, print, media, releases). Authentication
  is per **device** (a one-time activation code plus a session), not a web login.
- **Config sync is per domain**: `MASTER` · `OUTLET` · `FORMAT` · `MEDIA`. The server bumps a domain marker when
  something changes and the tablet pulls **only the changed domain** — so a sync can never wipe another
  domain's data (a classic bug, now closed with a test).
- **Print formats** come from the server (replacing the built-in ones). Internal tickets
  (CAPTAIN ORDER / BEV LABEL / CANCEL ORDER) carry **no money**; money tickets (BILL, RECEIPT, SHIFT, Z REPORT)
  use the outlet currency label from the web. BEV LABEL prints **one sticker per unit**.
- The **cash drawer** opens via an ESC/POS pulse (`0x1B 0x70`) whenever a settle takes cash — it rides the bill
  job, so it works offline, and a reprint never kicks the drawer.

---

## Conventions we keep

1. **UI text is English**, error messages included (operators may speak Indonesian; the app does not).
2. **Credentials are never logged or stored** — an authorizer password is used transiently (verified server-side).
3. Every fix **ships with a falsifiable test** (the test must fail if the fix is removed).
4. A change that alters a payload shape asks the server to bump the matching config domain.
