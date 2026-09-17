/// Typed mirror of the server config payloads returned by
/// `POST /api/pos/config/sync` (`full.MASTER` / `full.OUTLET`) and of the
/// operational domain objects the POS renders. Tolerant parsing: the server
/// currently ships bare `items` (no priceLevels) and bare `menuLayouts` (no
/// node tree), so the POS builds the order-entry tree from whatever the config
/// provides — menu nodes when present, else a category grouping fallback.
library;

import 'package:gundam_pos/logic/money.dart' as money;

money.RoundingMode _roundingFrom(String? s) {
  switch (s) {
    case 'UP':
      return money.RoundingMode.up;
    case 'DOWN':
      return money.RoundingMode.down;
    default:
      return money.RoundingMode.none;
  }
}

money.VatScMode _vatScFrom(String? s) => switch (s) {
      'INCLUDE' => money.VatScMode.include,
      'EXCLUDE' => money.VatScMode.exclude,
      _ => money.VatScMode.none,
    };

/// Decimals from Prisma serialize as strings ("11", "8000.00"); accept num too.
double? _num(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String && v.isNotEmpty) return double.tryParse(v);
  return null;
}

double _numOr(Object? v, double fallback) => _num(v) ?? fallback;

int? _int(Object? v) => _num(v)?.toInt();

class PriceLevel {
  PriceLevel({required this.levelIndex, required this.label, required this.price});

  factory PriceLevel.fromJson(Map<String, dynamic> j) => PriceLevel(
        levelIndex: (j['levelIndex'] as num?)?.toInt() ?? 0,
        label: j['label'] as String? ?? '',
        price: _numOr(j['price'], 0),
      );

  final int levelIndex;
  final String label;
  final double price;
}

class PricedModifier {
  PricedModifier({required this.id, required this.name, required this.price, this.isOpenMod = false});

  final String id;
  final String name;
  final double price;
  final bool isOpenMod;
}

/// A sellable item from `config.sync` MASTER.
class MenuItem {
  MenuItem({
    required this.id,
    required this.name,
    required this.itemcode,
    required this.sku,
    required this.categoryId,
    required this.active,
    required this.vatMode,
    required this.scMode,
    this.vatRate,
    this.scRate,
    this.priceLevels = const [],
    this.modifiers = const [],
    this.isOpenPrice = false,
    this.captainPrinterId,
    this.bevPrinterId,
  });

  factory MenuItem.fromJson(Map<String, dynamic> j) {
    final priceLevels = (j['priceLevels'] as List?)
        ?.map((e) => PriceLevel.fromJson(e as Map<String, dynamic>))
        .toList();
    final mods = (j['itemModifiers'] as List?)?.map((e) {
      final m = e as Map<String, dynamic>;
      final mod = (m['modifier'] as Map<String, dynamic>?) ?? m;
      return PricedModifier(
        id: (m['modifierId'] ?? mod['id'] ?? '') as String,
        name: mod['name'] as String? ?? '',
        price: _numOr(mod['price'], 0),
        isOpenMod: (mod['isOpenMod'] as bool?) ?? false,
      );
    }).toList();
    return MenuItem(
      id: j['id'] as String,
      name: j['name'] as String,
      itemcode: j['itemcode'] as String? ?? '',
      sku: j['sku'] as String? ?? '',
      categoryId: j['categoryId'] as String? ?? '',
      active: (j['active'] as bool?) ?? true,
      vatMode: _vatScFrom(j['vatMode'] as String?),
      scMode: _vatScFrom(j['scMode'] as String?),
      vatRate: _num(j['vatRate']),
      scRate: _num(j['scRate']),
      priceLevels: priceLevels ?? const [],
      modifiers: mods ?? const [],
      isOpenPrice: (j['isOpenPrice'] as bool?) ?? false,
      captainPrinterId: j['captainPrinterId'] as String?,
      bevPrinterId: j['bevPrinterId'] as String?,
    );
  }

  final String id;
  final String name;
  final String itemcode;
  final String sku;
  final String categoryId;
  final bool active;
  final money.VatScMode vatMode;
  final money.VatScMode scMode;
  final double? vatRate;
  final double? scRate;
  final List<PriceLevel> priceLevels;
  final List<PricedModifier> modifiers;
  final bool isOpenPrice;
  final String? captainPrinterId;
  final String? bevPrinterId;

  bool get sellable => active;
}

/// One arbitrary menu-layout node (server `MenuLayoutNode`); the client renders
/// a drill-down tree starting from root nodes — never hardcoded Food/Beverage.
class MenuNode {
  MenuNode({
    required this.id,
    this.parentId,
    required this.name,
    this.sortOrder = 0,
    this.children = const [],
    this.itemIds = const [],
  });

  factory MenuNode.fromJson(Map<String, dynamic> j) {
    final assign = (j['assignments'] as List?) ?? (j['itemIds'] as List?);
    return MenuNode(
      id: j['id'] as String,
      parentId: j['parentId'] as String?,
      name: j['name'] as String,
      sortOrder: (j['sortOrder'] as num?)?.toInt() ?? 0,
      itemIds: assign?.map((a) {
        if (a is Map) return a['itemId'] as String? ?? '';
        return a as String;
      }).where((id) => id.isNotEmpty).toList() ??
          const [],
      children: (j['children'] as List?)
              ?.map((e) => MenuNode.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }

  final String id;
  final String? parentId;
  final String name;
  final int sortOrder;
  final List<MenuNode> children;
  final List<String> itemIds;

  Map<String, dynamic> toJson() => {
        'id': id,
        'parentId': parentId,
        'name': name,
        'sortOrder': sortOrder,
        'children': children.map((c) => c.toJson()).toList(),
        'itemIds': itemIds,
      };
}

/// A menu layout container (server `MenuLayout`). Nodes may arrive flat
/// (parentId links) or nested (`children`); buildTree normalizes both.
class MenuLayout {
  MenuLayout({required this.id, required this.name, this.active = true, this.nodes = const []});

  factory MenuLayout.fromJson(Map<String, dynamic> j) => MenuLayout(
        id: j['id'] as String,
        name: j['name'] as String,
        active: (j['active'] as bool?) ?? true,
        nodes: (j['nodes'] as List?)?.map((e) => MenuNode.fromJson(e as Map<String, dynamic>)).toList() ?? const [],
      );

  final String id;
  final String name;
  final bool active;
  final List<MenuNode> nodes;

  /// Root nodes (parentId == null, active), stable-sorted by sortOrder.
  List<MenuNode> get rootNodes {
    final roots = nodes.where((n) => n.parentId == null).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return roots;
  }

  /// Build a nested drill-down tree. Accepts both flat (parentId links) and
  /// pre-nested node lists.
  List<MenuNode> buildTree() {
    // Pre-nested: roots carry parentId == null (or none at all). Return as-is.
    if (nodes.every((n) => n.parentId == null)) {
      return List.unmodifiable(rootNodes);
    }

    // Flat list with parentId links → assemble a forest from the root nodes.
    final byId = {for (final n in nodes) n.id: n};
    MenuNode attach(MenuNode n, Set<String> parents) {
      final children = nodes
          .where((c) => c.parentId == n.id && !parents.contains(c.id))
          .map((c) => attach(c, {...parents, c.id}))
          .toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      return MenuNode(id: n.id, name: n.name, sortOrder: n.sortOrder, itemIds: n.itemIds, children: children);
    }

    final roots = nodes.where((n) => n.parentId == null || !byId.containsKey(n.parentId)).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return roots.map((r) => attach(r, {r.id})).toList();
  }
}

class OutletPaymentMethod {
  OutletPaymentMethod({
    required this.id,
    required this.masterId,
    required this.displayName,
    required this.code,
    required this.type,
    required this.enabled,
    this.sortOrder = 0,
    this.buttonColor,
  });

  factory OutletPaymentMethod.fromJson(Map<String, dynamic> j) {
    final master = (j['master'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    return OutletPaymentMethod(
      id: j['id'] as String,
      masterId: (j['masterId'] ?? master['id'] ?? '') as String,
      displayName: j['displayName'] as String? ?? master['name'] as String? ?? '',
      code: master['code'] as String? ?? '',
      type: (master['type'] as String? ?? 'CASH') == 'CASH' ? money.PayType.cash : money.PayType.nonCash,
      enabled: (j['enabled'] as bool?) ?? true,
      sortOrder: (j['sortOrder'] as num?)?.toInt() ?? 0,
      buttonColor: j['buttonColor'] as String?,
    );
  }

  final String id;
  final String masterId;
  final String displayName;
  final String code;
  final money.PayType type;
  final bool enabled;
  final int sortOrder;
  final String? buttonColor;
}

class ShiftConfig {
  ShiftConfig({
    required this.shiftType,
    required this.defaultHouseBank,
    required this.roundingMode,
    this.timezone,
    this.currencyLabel = '',
  });

  factory ShiftConfig.defaultValue() => ShiftConfig(
        shiftType: 'MANUAL',
        defaultHouseBank: 0,
        roundingMode: money.RoundingMode.none,
      );

  factory ShiftConfig.fromJson(Map<String, dynamic> j) => ShiftConfig(
        shiftType: j['shiftType'] as String? ?? 'MANUAL',
        defaultHouseBank: double.tryParse((j['defaultHouseBank'] ?? '0').toString()) ?? 0,
        roundingMode: _roundingFrom(j['roundingMode'] as String?),
        timezone: j['timezone'] as String?,
        currencyLabel: j['currencyLabel'] as String? ?? '',
      );

  final String shiftType;
  final double defaultHouseBank;
  final money.RoundingMode roundingMode;
  final String? timezone;
  final String currencyLabel;
}

class TableInfo {
  TableInfo({required this.id, this.name, this.enabled = true, this.capacity});

  factory TableInfo.fromJson(Map<String, dynamic> j) => TableInfo(
        id: j['id'] as String,
        name: j['name'] as String?,
        enabled: (j['enabled'] as bool?) ?? true,
        capacity: _int(j['capacity']),
      );

  final String id;
  final String? name;
  final bool enabled;
  final int? capacity;
}

/// Full outlet config assembled from MASTER + OUTLET sync payloads.
class TenantConfig {
  TenantConfig({
    required this.items,
    required this.categories,
    required this.menuLayouts,
    required this.paymentMethods,
    required this.shift,
    required this.tables,
    this.priceLevels = const [],
  });

  factory TenantConfig.fromSyncPayloads(Map<String, dynamic> master, Map<String, dynamic> outlet) {
    final items = (master['items'] as List?)
            ?.map((e) => MenuItem.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const <MenuItem>[];
    final cats = (master['categories'] as List?)
            ?.map((e) => Category.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const <Category>[];
    final layouts = (master['menuLayouts'] as List?)
            ?.map((e) => MenuLayout.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const <MenuLayout>[];
    final payments = (outlet['paymentMethods'] as List?)
            ?.map((e) => OutletPaymentMethod.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const <OutletPaymentMethod>[];
    final tables = (outlet['tables'] as List?)
            ?.map((e) => TableInfo.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const <TableInfo>[];
    final shiftOut = outlet['shift'] as Map<String, dynamic>?;
    // Top-level negotiated price-level catalog (distinct levelIndex/label).
    // Tolerant: items may also carry per-item priceLevels; missing here → [].
    final levels = (master['priceLevels'] as List?)
            ?.map((e) => PriceLevel.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const <PriceLevel>[];
    return TenantConfig(
      items: items,
      categories: cats,
      menuLayouts: layouts.where((l) => l.active).toList(),
      paymentMethods: payments.where((p) => p.enabled).toList(),
      shift: shiftOut == null ? ShiftConfig.defaultValue() : ShiftConfig.fromJson(shiftOut),
      tables: tables,
      priceLevels: levels,
    );
  }

  final List<MenuItem> items;
  final List<Category> categories;
  final List<MenuLayout> menuLayouts;
  final List<OutletPaymentMethod> paymentMethods;
  final ShiftConfig shift;
  final List<TableInfo> tables;
  /// Distinct price-level catalog shipped by MASTER (levelIndex + label). Used
  /// to drive size/level selection labels across the outlet.
  final List<PriceLevel> priceLevels;

  MenuItem? itemById(String id) {
    for (final i in items) {
      if (i.id == id) return i;
    }
    return null;
  }

  /// Order-entry catalog: sellable items under a non-empty drill tree. Uses
  /// menu layout nodes when present; else groups by category (MVP fallback).
  List<MenuNode> orderTree({bool filterActive = true}) {
    if (menuLayouts.isNotEmpty) {
      final roots = <MenuNode>[];
      for (final l in menuLayouts) {
        roots.addAll(l.buildTree());
      }
      if (roots.isNotEmpty) return _pruneItems(roots, filterActive);
    }
    return _categoryFallback(filterActive);
  }

  List<MenuNode> _pruneItems(List<MenuNode> nodes, bool filterActive) {
    final out = <MenuNode>[];
    for (final n in nodes) {
      final visible = n.itemIds.where((id) {
        final it = itemById(id);
        return it != null && (!filterActive || it.sellable);
      }).toSet().toList();
      final children = _pruneItems(n.children, filterActive);
      if (visible.isNotEmpty || children.isNotEmpty) {
        out.add(MenuNode(id: n.id, parentId: n.parentId, name: n.name, sortOrder: n.sortOrder, itemIds: visible, children: children));
      }
    }
    return out;
  }

  List<MenuNode> _categoryFallback(bool filterActive) {
    final byCat = <String, List<MenuItem>>{};
    for (final i in items) {
      if (filterActive && !i.sellable) continue;
      byCat.putIfAbsent(i.categoryId, () => []).add(i);
    }
    final idToName = {for (final c in categories) c.id: c.name};
    return byCat.entries.map((e) {
      return MenuNode(
        id: 'cat:_${e.key}',
        name: idToName[e.key] ?? 'Items',
        itemIds: e.value.map((i) => i.id).toList(),
      );
    }).toList();
  }
}

class Category {
  Category({required this.id, this.parentId, required this.name, this.children = const []});

  factory Category.fromJson(Map<String, dynamic> j) => Category(
        id: j['id'] as String,
        parentId: j['parentId'] as String?,
        name: j['name'] as String,
        children: (j['children'] as List?)
                ?.map((e) => Category.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );

  final String id;
  final String? parentId;
  final String name;
  final List<Category> children;
}