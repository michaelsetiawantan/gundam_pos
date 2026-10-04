import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/data/config_cache.dart';
import 'package:gundam_pos/logic/print_format_render.dart';
import 'package:gundam_pos/state/session_store.dart';

import 'support/fake_backend.dart';

/// FIELD REGRESSION: a config sync that carries ONLY the changed domain wiped
/// everything else. After the server bumped OUTLET, the tablet rebuilt its whole
/// config from that one payload → the item catalog/layout AND the discount
/// masters vanished ("menu layout ilang semua", "discount ga bisa ditambah").
/// A partial sync must keep every other domain's last-known-good payload.
void main() {
  test('a partial (OUTLET-only) config sync keeps the menu AND the discount masters', () async {
    final backend = FakeBackend();
    final store = InMemorySessionStore();
    final session = backend.createSession(store: store);

    final dir = Directory.systemTemp.createTempSync('cfg-merge');
    addTearDown(() => dir.deleteSync(recursive: true));
    session.attachConfigCache(ConfigCache(dir));

    // A master that actually carries a discount master — the reported "discount
    // tidak bisa ditambah" was the same wipe, so it must be covered here too.
    final master = Map<String, dynamic>.from(FakeBackend.northstarMaster());
    master['discounts'] = [
      {'id': 'd10', 'name': 'Discount 10%', 'kind': 'PERCENTAGE', 'value': '10', 'target': 'WHOLE_BILL', 'active': true, 'categoryTags': <Map<String, dynamic>>[]},
    ];
    backend.configSyncFull = {'MASTER': master, 'OUTLET': FakeBackend.northstarOutlet()};

    await store.save(const PosContext()
        .withRedeem({'deviceToken': 'dev', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'NSTAR-POS1'})
        .copyWith(deviceId: 'device-1'));
    await session.init();
    await session.login(email: 'c@x.demo', password: 'Pass1234');

    // First sync: full → the tablet has a catalog and discount masters.
    expect(session.config, isNotNull);
    final itemsAfterFirst = session.config!.items.length;
    final catsAfterFirst = session.config!.categories.length;
    expect(itemsAfterFirst, greaterThan(0), reason: 'first sync must deliver the menu');
    expect(session.config!.discounts, isNotEmpty, reason: 'first sync must deliver discount masters');

    // Server bumps ONLY OUTLET (exactly what happened in production).
    backend.setVersions({'MASTER': 1, 'OUTLET': 2, 'FORMAT': 0, 'MEDIA': 0});
    backend.configSyncNeedsFull = const ['OUTLET'];
    backend.configSyncFull = {'OUTLET': FakeBackend.northstarOutlet()};

    await session.refreshConfig();

    expect(session.config!.items.length, itemsAfterFirst,
        reason: 'an OUTLET-only sync must NOT wipe the item catalog (menu layout)');
    expect(session.config!.categories.length, catsAfterFirst,
        reason: 'an OUTLET-only sync must NOT wipe the menu categories');
    expect(session.config!.discounts, isNotEmpty,
        reason: 'an OUTLET-only sync must NOT wipe the discount masters');
    expect(session.config!.outlet.name, isNotEmpty,
        reason: 'the refreshed OUTLET domain must still be applied');
  });

  test('published FORMAT is hydrated from disk — server layout, never the built-in', () async {
    final backend = FakeBackend();
    final store = InMemorySessionStore();
    final session = backend.createSession(store: store);

    final dir = Directory.systemTemp.createTempSync('cfg-fmt');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cache = ConfigCache(dir);
    // A previously synced FORMAT domain, exactly as the server ships it.
    await cache.writeJson('FORMAT', 9, {
      'formats': [
        {
          'formatId': 'f-bill', 'name': 'Agreed Bill', 'ticketType': 'BILL',
          'version': 1, 'widthMm': 80,
          'blocks': [
            {'id': 'a', 'type': 'TEXT', 'text': '{store_name}', 'align': 'CENTER', 'bold': true},
          ],
        },
      ],
      'skipped': <Object>[],
    });

    session.attachConfigCache(cache);
    await session.hydrateFromCache();

    final fmt = session.printFormats.formatFor('BILL');
    expect(fmt, isNotNull,
        reason: 'a persisted published format must be hydrated — otherwise a partial sync leaves '
            'the store empty and the tablet prints the built-in layout');

    final out = renderPrintFormat(
      format: fmt!,
      ticketPayload: const {
        'tokens': {'store_name': 'NORTHSTAR'},
        'items': [],
        'payments': [],
      },
      widthMm: 80,
    );
    final line = out.lines.firstWhere((l) => l.contains('NORTHSTAR'));
    expect(line.trim(), 'NORTHSTAR');
    expect(line.startsWith(' '), isTrue,
        reason: "the server's align=CENTER must be honoured (it rendered left-aligned)");
  });

  test('a domain version never advances without its payload (no permanent stuck claim)', () async {
    final backend = FakeBackend();
    final store = InMemorySessionStore();
    final session = backend.createSession(store: store);

    final dir = Directory.systemTemp.createTempSync('cfg-claim');
    addTearDown(() => dir.deleteSync(recursive: true));
    session.attachConfigCache(ConfigCache(dir));

    // The server answers this sync with MASTER ONLY, while the device asked for
    // every domain (it holds nothing yet). The domains it did NOT receive must
    // stay unclaimed, or the next sync calls them up-to-date and they are never
    // fetched again — the print format forever missing.
    backend.setVersions({'MASTER': 3, 'OUTLET': 1, 'FORMAT': 21, 'MEDIA': 4});
    backend.configSyncNeedsFull = const ['MASTER'];
    backend.configSyncFull = {'MASTER': FakeBackend.northstarMaster()};

    await store.save(const PosContext()
        .withRedeem({'deviceToken': 'dev', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'NSTAR-POS1'})
        .copyWith(deviceId: 'device-1'));
    await session.init();
    await session.login(email: 'c@x.demo', password: 'Pass1234');

    expect(session.deviceVersions['MASTER'], 3, reason: 'a received payload IS applied');
    expect(session.deviceVersions['FORMAT'] ?? 0, 0,
        reason: 'FORMAT was never received, so the device must NOT claim its version '
            '(that claim is what silently pinned the tablet to the built-in ticket)');
  });
}
