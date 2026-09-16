/// Local SQLite schema mirroring `docs/pos-client/LOCAL-SCHEMA.md` (v2) and the
/// F6 config/media cache contract. The DB is versioned via `PRAGMA user_version`
/// and migrated idempotently on launch (schema bump = new migration step; a
/// matching version is a no-op — the seamless APK-upgrade requirement). The
/// schema constant is tested directly; the [LocalDb] wrapper opens it on the
/// device through an injectable factory.
library;

import 'package:sqflite/sqflite.dart' as sqf;

const int schemaVersion = 2;

/// Migration step v2 → user_version=2. Every step is idempotent (IF NOT EXISTS
/// / guards). Each bump to `schemaVersion` MUST add a new step here; never
/// alter an earlier step in place.
const List<List<String>> migrations = [
  [
    '''
    CREATE TABLE IF NOT EXISTS config_store (
      config_key   TEXT PRIMARY KEY,
      version      INTEGER NOT NULL,
      json_payload TEXT NOT NULL,
      sha256       TEXT,
      applied_at   INTEGER NOT NULL
    );''',
    '''
    CREATE TABLE IF NOT EXISTS config_checkpoint (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      device_shortcode TEXT NOT NULL,
      full_config_version INTEGER NOT NULL,
      downloaded_at INTEGER NOT NULL
    );''',
    '''
    CREATE TABLE IF NOT EXISTS receipt_sequence (
      device_shortcode TEXT NOT NULL,
      date_yyyymmdd TEXT NOT NULL,
      last_seq INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (device_shortcode, date_yyyymmdd)
    );''',
    '''
    CREATE TABLE IF NOT EXISTS local_transactions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      receipt_id TEXT UNIQUE NOT NULL,
      receipt_seq INTEGER NOT NULL,
      status TEXT NOT NULL DEFAULT 'open',
      order_type TEXT NOT NULL DEFAULT 'dinein',
      table_name TEXT,
      guest_name TEXT,
      guest_phone TEXT,
      guest_email TEXT,
      pax INTEGER,
      shift_id INTEGER,
      kasir_user_id TEXT NOT NULL,
      paid_by_user_id TEXT,
      open_at INTEGER NOT NULL,
      paid_at INTEGER,
      closed_at INTEGER,
      local_total INTEGER NOT NULL,
      sync_attempts INTEGER DEFAULT 0,
      synced_at INTEGER,
      sync_error TEXT
    );''',
    '''
    CREATE TABLE IF NOT EXISTS local_transaction_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      transaction_id INTEGER NOT NULL REFERENCES local_transactions(id) ON DELETE CASCADE,
      item_uuid TEXT NOT NULL,
      itemcode TEXT,
      sku TEXT,
      name TEXT NOT NULL,
      category TEXT,
      qty INTEGER NOT NULL,
      unit_price INTEGER NOT NULL,
      price_level INTEGER,
      modifier_json TEXT,
      modifier_total INTEGER NOT NULL DEFAULT 0,
      vat_tag TEXT NOT NULL DEFAULT 'none',
      sc_tag TEXT NOT NULL DEFAULT 'none',
      shipment_id INTEGER,
      batch_label TEXT,
      sort_order INTEGER NOT NULL DEFAULT 0
    );''',
    '''
    CREATE TABLE IF NOT EXISTS local_money_lines (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      transaction_id INTEGER NOT NULL REFERENCES local_transactions(id) ON DELETE CASCADE,
      line_type TEXT NOT NULL,
      label TEXT,
      amount INTEGER NOT NULL,
      discount_id TEXT,
      approval_user TEXT,
      approval_state TEXT,
      created_at INTEGER NOT NULL
    );''',
    '''
    CREATE TABLE IF NOT EXISTS pending_sync (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      retry_count INTEGER DEFAULT 0,
      next_retry_at INTEGER,
      last_error TEXT,
      created_at INTEGER NOT NULL,
      synced_at INTEGER
    );''',
    '''
    CREATE TABLE IF NOT EXISTS local_shifts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      shift_ref TEXT UNIQUE,
      shift_type TEXT NOT NULL,
      kasir_user_id TEXT NOT NULL,
      opened_at INTEGER NOT NULL,
      closed_at INTEGER,
      housebank_start INTEGER NOT NULL DEFAULT 0,
      housebank_end INTEGER,
      cash_received INTEGER DEFAULT 0,
      cash_paidout INTEGER DEFAULT 0,
      cash_tips INTEGER DEFAULT 0,
      expected_cash INTEGER,
      closing_report_json TEXT,
      sync_state TEXT NOT NULL DEFAULT 'open'
    );''',
    '''
    CREATE TABLE IF NOT EXISTS local_cash_count (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      shift_id INTEGER NOT NULL REFERENCES local_shifts(id) ON DELETE CASCADE,
      kasir_user_id TEXT NOT NULL,
      counted_total INTEGER NOT NULL,
      expected_cash INTEGER,
      variance INTEGER,
      counted_at INTEGER NOT NULL
    );''',
    '''
    CREATE TABLE IF NOT EXISTS local_tables (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      table_name TEXT NOT NULL,
      pax INTEGER,
      state TEXT NOT NULL DEFAULT 'free',
      merged_label TEXT,
      open_order_id INTEGER,
      locked_by TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );''',
    '''
    CREATE TABLE IF NOT EXISTS config_snapshots (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      taken_at INTEGER NOT NULL,
      snapshot_type TEXT NOT NULL,
      version INTEGER NOT NULL,
      json_payload TEXT NOT NULL
    );''',
    '''
    CREATE TABLE IF NOT EXISTS local_guests (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT,
      phone TEXT,
      email TEXT,
      pax_hint INTEGER,
      last_seen INTEGER,
      upserted INTEGER DEFAULT 0
    );''',
    '''
    CREATE TABLE IF NOT EXISTS local_media_assets (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      asset_key TEXT NOT NULL,
      local_path TEXT NOT NULL,
      sha256 TEXT NOT NULL,
      size INTEGER NOT NULL,
      media_version INTEGER NOT NULL,
      kind TEXT,
      critical INTEGER NOT NULL DEFAULT 0,
      downloaded_at INTEGER,
      UNIQUE(asset_key, sha256)
    );''',
    // Indexes
    'CREATE INDEX IF NOT EXISTS idx_tx_status ON local_transactions(status);',
    'CREATE INDEX IF NOT EXISTS idx_tx_sync ON local_transactions(status, synced_at);',
    'CREATE INDEX IF NOT EXISTS idx_item_tx ON local_transaction_items(transaction_id);',
    'CREATE INDEX IF NOT EXISTS idx_money_tx ON local_money_lines(transaction_id, line_type);',
    'CREATE INDEX IF NOT EXISTS idx_pending_next ON pending_sync(next_retry_at);',
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_pending_dedupe ON pending_sync(entity_type, entity_id);',
    'CREATE INDEX IF NOT EXISTS idx_shifts_kasir ON local_shifts(kasir_user_id, opened_at);',
    'CREATE INDEX IF NOT EXISTS idx_cashcount_shift ON local_cash_count(shift_id);',
    'CREATE INDEX IF NOT EXISTS idx_tables_state ON local_tables(state);',
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_tables_name ON local_tables(table_name);',
    'CREATE INDEX IF NOT EXISTS idx_snap_type ON config_snapshots(snapshot_type, taken_at);',
    'CREATE INDEX IF NOT EXISTS idx_guests_dup ON local_guests(phone, email);',
    'CREATE INDEX IF NOT EXISTS idx_media_key ON local_media_assets(asset_key);',
  // v2 — reserved for incremental additions (structural no-op; keep empty and
  // append future steps as new list entries in `migrations` order).
  ],
];

/// SQL to apply when migrating the DB up to the given absolute version step.
List<String> migrationUpStatements(int targetVersion) => [
      if (targetVersion >= 1) ...migrations[0],
      // future steps appended in order
    ];

/// Manages the local SQLite instance. The factory is injectable so tests can
/// use an in-memory database without an Android platform channel.
typedef LocalDbFactory = sqf.Database Function();

class LocalDb {
  LocalDb({LocalDbFactory? factory}) : _factory = factory;

  final LocalDbFactory? _factory;
  sqf.Database? _db;

  Future<sqf.Database> open(String path, {bool inMemory = false}) async {
    if (_db != null) return _db!;
    final db = _factory != null
        ? _factory()
        : await sqf.openDatabase(
            inMemory ? ':memory:' : path,
            version: schemaVersion,
            onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
            onCreate: (db, v) => applyMigrations(db),
            onUpgrade: (db, oldV, newV) => applyMigrations(db),
          );
    _db = db;
    return db;
  }

  /// Apply every migration step idempotently and stamp the user_version.
  /// Steps use IF NOT EXISTS, so replaying the full set on upgrade is safe.
  Future<void> applyMigrations(sqf.DatabaseExecutor db) async {
    for (final step in migrationUpStatements(schemaVersion)) {
      await db.execute(step);
    }
    await db.execute('PRAGMA user_version = $schemaVersion;');
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}