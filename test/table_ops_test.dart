import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/state/session_store.dart';
import 'package:gundam_pos/ui/open_tables_screen.dart';
import 'package:gundam_pos/ui/table_ops_sheet.dart';
import 'package:gundam_pos/ui/theme.dart';

import 'support/fake_backend.dart';

Map<String, dynamic> _order({
  required String id,
  required String tableName,
  String? tableId,
  List<Map<String, dynamic>> lines = const [],
  String status = 'OPEN',
}) =>
    {
      'id': id,
      'status': status,
      'tableId': tableId,
      'tableName': tableName,
      'openedAt': DateTime.now().toIso8601String(),
      'lines': lines,
    };

Map<String, dynamic> _line(String id, String name, int qty) => {
      'id': id,
      'itemName': name,
      'qty': qty,
      'unitPrice': 25000,
      'sentToKitchen': true,
      'mods': <Map<String, dynamic>>[],
    };

TenantConfig _northstar() =>
    TenantConfig.fromSyncPayloads(FakeBackend.northstarMaster(), FakeBackend.northstarOutlet());

Future<AppSession> _readySession(FakeBackend backend) async {
  final store = InMemorySessionStore();
  await store.save(const PosContext()
      .withRedeem({'deviceToken': 'dev', 'groupId': 'g1', 'tenantId': 't1', 'shortcode': 'NSTAR-POS1'})
      .withSession({
        'sessionId': 'sess-1',
        'user': {'id': 'u1', 'fullName': 'C1'},
        'outlet': {'id': 't1', 'name': 'Northstar'},
      })
      .copyWith(deviceId: 'device-1'));
  final session = backend.createSession(store: store);
  await session.init();
  return session;
}

Widget _wrap(Widget child) => MaterialApp(theme: PosTheme.theme(), home: child);

/// Opens the sheet on a standalone route so the test can drive it directly.
Future<void> _openSheet(
  WidgetTester tester, {
  required FakeBackend backend,
  required AppSession session,
  required List<Map<String, dynamic>> orders,
  TableOpKind kind = TableOpKind.merge,
}) async {
  await tester.pumpWidget(_wrap(Builder(
    builder: (ctx) => Scaffold(
      body: TextButton(
        onPressed: () => showTableOpsSheet(ctx,
            session: session, config: _northstar(), orders: orders, initialKind: kind),
        child: const Text('open-ops'),
      ),
    ),
  )));
  await tester.tap(find.text('open-ops'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('merge sends action=merge with the picked orderIds and refreshes the list', (tester) async {
    final backend = FakeBackend()
      ..openOrders = [
        _order(id: 'o-a1', tableName: 'A1', tableId: 'tbl-a1', lines: [_line('l1', 'Espresso', 2)]),
        _order(id: 'o-a2', tableName: 'A2', tableId: 'tbl-a2', lines: [_line('l2', 'Nasi', 1)]),
      ];
    final session = await _readySession(backend);

    await tester.pumpWidget(_wrap(OpenTablesScreen(session: session, config: _northstar())));
    await tester.pumpAndSettle();

    // The function is visible from the table list.
    await tester.tap(find.byIcon(Icons.table_rows_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Merge tables'));
    await tester.pumpAndSettle();

    final sheet = find.byType(TableOpsSheet);
    await tester.tap(find.descendant(of: sheet, matching: find.text('A1')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: sheet, matching: find.text('A2')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: sheet, matching: find.text('A1-A2-MGR')), findsOneWidget); // merged bill name preview

    // The server will answer with a single merged order — the reload must show it.
    backend.openOrders = [
      _order(id: 'o-merged', tableName: 'A1-A2-MGR', lines: [_line('l1', 'Espresso', 2), _line('l2', 'Nasi', 1)]),
    ];
    await tester.tap(find.text('Merge 2 tables'));
    await tester.pumpAndSettle();

    expect(backend.lastTableOpsBody!['action'], 'merge');
    expect(backend.lastTableOpsBody!['orderIds'], unorderedEquals(['o-a1', 'o-a2']));
    expect(backend.lastTableOpsBody!['tenantId'], 't1');
    expect(backend.lastTableOpsBody!['assetId'], 'device-1');
    // List was refreshed after the accepted op.
    expect(find.text('A1-A2-MGR'), findsOneWidget);
    expect(find.text('A2'), findsNothing);
  });

  testWidgets('split sends parts with the per-item allocation', (tester) async {
    final backend = FakeBackend();
    final session = await _readySession(backend);
    final orders = [
      _order(id: 'o-b4', tableName: 'B4', tableId: 'tbl-a1', lines: [
        _line('line-a', 'Espresso', 4),
        _line('line-b', 'Nasi', 1),
      ]),
    ];

    await _openSheet(tester, backend: backend, session: session, orders: orders, kind: TableOpKind.split);
    await tester.tap(find.text('B4'));
    await tester.pumpAndSettle();

    // Move 2 of the 4 espressos to the new part.
    await tester.tap(find.byIcon(Icons.add_circle_outline).at(0));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add_circle_outline).at(0));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Split table'));
    await tester.pumpAndSettle();

    expect(backend.lastTableOpsBody!['action'], 'split');
    expect(backend.lastTableOpsBody!['orderId'], 'o-b4');
    expect(backend.lastTableOpsBody!['parts'], [
      {
        'items': [
          {'lineId': 'line-a', 'qty': 2},
          {'lineId': 'line-b', 'qty': 1},
        ]
      },
      {
        'items': [
          {'lineId': 'line-a', 'qty': 2},
        ]
      },
    ]);
  });

  testWidgets('a server refusal is shown as-is (never a silent failure)', (tester) async {
    final backend = FakeBackend()
      ..tableOpsError = 'table_locked'
      ..openOrders = [
        _order(id: 'o-a1', tableName: 'A1', lines: [_line('l1', 'Espresso', 1)]),
        _order(id: 'o-a2', tableName: 'A2', lines: [_line('l2', 'Nasi', 1)]),
      ];
    final session = await _readySession(backend);
    final orders = [
      _order(id: 'o-a1', tableName: 'A1', lines: [_line('l1', 'Espresso', 1)]),
      _order(id: 'o-a2', tableName: 'A2', lines: [_line('l2', 'Nasi', 1)]),
    ];

    await _openSheet(tester, backend: backend, session: session, orders: orders, kind: TableOpKind.merge);
    await tester.tap(find.text('A1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Merge 2 tables'));
    await tester.pumpAndSettle();

    expect(find.textContaining('table_locked'), findsOneWidget);
    expect(find.text('Merge 2 tables'), findsOneWidget); // sheet stayed open
  });
}
