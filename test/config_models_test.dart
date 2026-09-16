import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/models/config_models.dart';

// Fixtures mirror the server `POST /api/pos/config/sync` MASTER/OUTLET payloads.
Map<String, dynamic> masterFixture() => {
      'categories': [
        {
          'id': 'cat-drink',
          'groupId': 'g1',
          'parentId': null,
          'name': 'Beverages',
          'children': [
            {'id': 'cat-soda', 'parentId': 'cat-drink', 'name': 'Soda', 'children': []},
          ],
        },
      ],
      'items': [
        {
          'id': 'item-coffee',
          'categoryId': 'cat-drink',
          'name': 'Espresso',
          'itemcode': 'ESP',
          'sku': 'NSTAR-NS-ESP',
          'active': true,
          'vatMode': 'EXCLUDE',
          'scMode': 'NONE',
          'vatRate': '11',
        },
        {
          'id': 'item-disabled',
          'categoryId': 'cat-drink',
          'name': 'Old Brew',
          'itemcode': 'OBR',
          'sku': 'NSTAR-NS-OBR',
          'active': false,
          'vatMode': 'NONE',
          'scMode': 'NONE',
        },
      ],
      'menuLayouts': [
        {'id': 'layout1', 'name': 'Main', 'active': true, 'nodes': []},
      ],
      'paymentMasters': [
        {'id': 'm-cash', 'code': 'CASH', 'name': 'Cash', 'type': 'CASH'},
        {'id': 'm-card', 'code': 'CARD', 'name': 'Card', 'type': 'NON_CASH'},
      ],
    };

Map<String, dynamic> outletFixture() => {
      'paymentMethods': [
        {
          'id': 'pm-cash',
          'tenantId': 't1',
          'masterId': 'm-cash',
          'displayName': 'Cash',
          'enabled': true,
          'sortOrder': 0,
          'master': {'id': 'm-cash', 'code': 'CASH', 'name': 'Cash', 'type': 'CASH'},
        },
        {
          'id': 'pm-card',
          'tenantId': 't1',
          'masterId': 'm-card',
          'displayName': 'Visa',
          'enabled': true,
          'sortOrder': 1,
          'master': {'id': 'm-card', 'code': 'CARD', 'name': 'Card', 'type': 'NON_CASH'},
        },
        {
          'id': 'pm-off',
          'tenantId': 't1',
          'masterId': 'm-cash',
          'displayName': 'Old Terminal',
          'enabled': false,
          'sortOrder': 2,
          'master': {'id': 'm-x', 'code': 'OLD', 'name': 'Old', 'type': 'CASH'},
        },
      ],
      'shift': {'shiftType': 'MANUAL', 'defaultHouseBank': '500000', 'roundingMode': 'UP', 'timezone': 'Asia/Jakarta', 'currencyLabel': 'Rp'},
      'tables': [
        {'id': 'tbl-1', 'name': 'A1', 'enabled': true, 'capacity': 4},
        {'id': 'tbl-2', 'name': 'A2', 'enabled': true, 'capacity': 6},
      ],
      'printRoutings': [],
    };

void main() {
  group('TenantConfig.fromSyncPayloads', () {
    test('parses MASTER + OUTLET into typed config', () {
      final cfg = TenantConfig.fromSyncPayloads(masterFixture(), outletFixture());
      expect(cfg.items, hasLength(2));
      expect(cfg.itemById('item-coffee')!.name, 'Espresso');
      expect(cfg.categories, hasLength(1));
      expect(cfg.categories.first.children, hasLength(1));
      // only enabled outlet methods surface
      expect(cfg.paymentMethods, hasLength(2));
      expect(cfg.paymentMethods.any((p) => p.code == 'OLD'), isFalse);
      expect(cfg.tables, hasLength(2));
      expect(cfg.shift.roundingMode, money.RoundingMode.up);
      expect(cfg.shift.defaultHouseBank, 500000);
    });

    test('payment method type follows the MASTER, not client input', () {
      final cfg = TenantConfig.fromSyncPayloads(masterFixture(), outletFixture());
      final cash = cfg.paymentMethods.firstWhere((p) => p.code == 'CASH');
      final card = cfg.paymentMethods.firstWhere((p) => p.code == 'CARD');
      expect(cash.type, money.PayType.cash);
      expect(card.type, money.PayType.nonCash);
    });

    test('orderTree falls back to category grouping when layouts have no nodes', () {
      final cfg = TenantConfig.fromSyncPayloads(masterFixture(), outletFixture());
      final tree = cfg.orderTree();
      expect(tree, isNotEmpty);
      // disabled item is filtered out
      final allItems = tree.expand((n) => n.itemIds).toList();
      expect(allItems, contains('item-coffee'));
      expect(allItems, isNot(contains('item-disabled')));
    });

    test('item with no priceLevels parses tolerantly to an empty list', () {
      final cfg = TenantConfig.fromSyncPayloads(masterFixture(), outletFixture());
      final it = cfg.itemById('item-coffee')!;
      expect(it.priceLevels, isEmpty);
      expect(it.vatMode, money.VatScMode.exclude);
      expect(it.vatRate, 11.0);
    });
  });

  group('MenuLayout.buildTree (flat + nested)', () {
    test('flat node list assembles a parent→child tree', () {
      final layout = MenuLayout.fromJson({
        'id': 'l1',
        'name': 'Main',
        'active': true,
        'nodes': [
          {'id': 'n-food', 'parentId': null, 'name': 'Food', 'sortOrder': 0},
          {'id': 'n-beer', 'parentId': 'n-food', 'name': 'Beer', 'sortOrder': 0, 'assignments': [{'itemId': 'i1'}]},
          {'id': 'n-grid', 'parentId': 'n-food', 'name': 'Grill', 'sortOrder': 1},
          {'id': 'n-steak', 'parentId': 'n-grid', 'name': 'Steak', 'sortOrder': 0, 'assignments': [{'itemId': 'i2'}]},
        ],
      });
      final tree = layout.buildTree();
      expect(tree, hasLength(1));
      expect(tree.first.children, hasLength(2));
      final grill = tree.first.children.firstWhere((c) => c.name == 'Grill');
      expect(grill.children.first.name, 'Steak');
      expect(grill.children.first.itemIds, ['i2']);
    });

    test('nested (pre-grouped) nodes return roots unchanged', () {
      final layout = MenuLayout.fromJson({
        'id': 'l1',
        'name': 'Main',
        'nodes': [
          {
            'id': 'n-root',
            'parentId': null,
            'name': 'Root',
            'children': [
              {'id': 'n-leaf', 'parentId': 'n-root', 'name': 'Leaf', 'itemIds': ['i9']},
            ],
          },
        ],
      });
      final tree = layout.buildTree();
      expect(tree, hasLength(1));
      expect(tree.first.children.single.itemIds, ['i9']);
    });
  });
}