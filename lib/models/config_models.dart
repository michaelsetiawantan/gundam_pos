/// Typed mirror of the server config payloads returned by
/// `POST /api/pos/config/sync` (`full.MASTER` / `full.OUTLET`) and of the
/// operational domain objects the POS renders. Tolerant parsing: the server
/// currently ships bare `items` (no priceLevels) and bare `menuLayouts` (no
/// node tree), so the POS builds the order-entry tree from whatever the config
/// provides — menu nodes when present, else a category grouping fallback.
library;

import 'package:gundam_pos/logic/discount_voucher.dart';
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
    this.imageKey,
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
      // Uploaded tile image (media asset key) — absent → the built-in icon.
      imageKey: (j['imageKey'] as String?)?.trim().isEmpty ?? true ? null : j['imageKey'] as String?,
    );
  }

  final String id;
  final String name;
  /// Media-asset key of the uploaded tile image (null → draw the built-in icon).
  final String? imageKey;
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
    this.imageKey,
  });

  factory MenuNode.fromJson(Map<String, dynamic> j) {
    final assign = (j['assignments'] as List?) ?? (j['itemIds'] as List?);
    return MenuNode(
      id: j['id'] as String,
      parentId: j['parentId'] as String?,
      name: j['name'] as String,
      // Uploaded tile image (media asset key) — absent → the built-in icon.
      imageKey: (j['imageKey'] as String?)?.trim().isEmpty ?? true ? null : j['imageKey'] as String?,
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
  /// Media-asset key of the uploaded tile image (null → draw the built-in icon).
  final String? imageKey;
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
      return MenuNode(
        id: n.id, name: n.name, sortOrder: n.sortOrder, itemIds: n.itemIds,
        children: children, imageKey: n.imageKey,
      );
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

String _hhmm(int h, int m) => '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';

/// One meal-shift range (AUTOMATIC shift type). Mirrors the server
/// `MealShiftWindow` row shape (`web/app/api/shift-config/windows/route.ts`
/// SELECT: id, tenantId, name, startHour, endHour, startMinute, endMinute,
/// enabled). Tolerant: a missing key → defaults, never throws.
///
/// NOTE: `web/lib/config/resync.ts` (buildFull OUTLET) does NOT currently ship
/// these rows, so on a real tablet this list stays empty and the AUTOMATIC
/// window reads "not configured" — we never guess a range.
class MealShiftWindow {
  MealShiftWindow({
    required this.name,
    required this.startHour,
    required this.startMinute,
    required this.endHour,
    required this.endMinute,
    this.enabled = true,
  });

  factory MealShiftWindow.fromJson(Map<String, dynamic> j) => MealShiftWindow(
        name: j['name'] as String? ?? '',
        startHour: (j['startHour'] as num?)?.toInt() ?? 0,
        startMinute: (j['startMinute'] as num?)?.toInt() ?? 0,
        endHour: (j['endHour'] as num?)?.toInt() ?? 0,
        endMinute: (j['endMinute'] as num?)?.toInt() ?? 0,
        enabled: (j['enabled'] as bool?) ?? true,
      );

  final String name;
  final int startHour;
  final int startMinute;
  final int endHour;
  final int endMinute;
  final bool enabled;

  int get _startMin => startHour * 60 + startMinute;
  int get _endMin => endHour * 60 + endMinute;

  /// True when [t] is inside [start, end). Handles ranges that wrap midnight
  /// (e.g. 22:00–02:00).
  bool contains(DateTime t) {
    if (!enabled) return false;
    final n = t.hour * 60 + t.minute;
    if (_startMin <= _endMin) return n >= _startMin && n < _endMin;
    return n >= _startMin || n < _endMin;
  }

  String get label {
    final range = '${_hhmm(startHour, startMinute)}–${_hhmm(endHour, endMinute)}';
    return name.isEmpty ? range : '$name $range';
  }
}

/// Daily-close recap window (per group-tenant; 2–15 min). Mirrors the server
/// `RecapWindow` row shape (`web/app/api/shift-config/recap/route.ts` SELECT:
/// id, tenantId, startHour, startMinute, durationMin). NOT shipped by
/// resync.ts today → parses null.
class RecapWindow {
  RecapWindow({required this.startHour, required this.startMinute, required this.durationMin});

  factory RecapWindow.fromJson(Map<String, dynamic> j) => RecapWindow(
        startHour: (j['startHour'] as num?)?.toInt() ?? 0,
        startMinute: (j['startMinute'] as num?)?.toInt() ?? 0,
        durationMin: (j['durationMin'] as num?)?.toInt() ?? 0,
      );

  final int startHour;
  final int startMinute;
  final int durationMin;

  int get _startMin => startHour * 60 + startMinute;
  int get _endMin => _startMin + durationMin;

  /// True when [t] is inside [start, start+durationMin); wraps past midnight.
  bool contains(DateTime t) {
    final n = t.hour * 60 + t.minute;
    if (_endMin <= 1440) return n >= _startMin && n < _endMin;
    return n >= _startMin || n < (_endMin - 1440);
  }

  String get label => '${_hhmm(startHour, startMinute)}–${_hhmm((_endMin ~/ 60) % 24, _endMin % 60)}';
}

/// Why the master-shipment option is not offered: `web/lib/config/resync.ts`
/// (buildFull MASTER) ships categories/items/menuLayouts/paymentMasters/
/// priceLevels/discounts/vouchers — it does NOT ship `shipmentMasters`, so the
/// tablet can never pick one today and only the OPEN shipment path works.
const String kShipmentMastersUnavailable =
    'Shipment masters are not shipped in the outlet config — use an open shipment amount.';

/// Master shipment (precise amount, like an item). Mirrors Prisma
/// `ShipmentMaster`. NOT shipped by resync.ts today → [TenantConfig.shipmentMasters]
/// stays empty on a real device.
class ShipmentMaster {
  ShipmentMaster({
    required this.id,
    required this.name,
    required this.amount,
    this.description,
    this.active = true,
  });

  factory ShipmentMaster.fromJson(Map<String, dynamic> j) => ShipmentMaster(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        amount: _numOr(j['amount'], 0),
        description: j['description'] as String?,
        active: (j['active'] as bool?) ?? true,
      );

  final String id;
  final String name;
  final double amount;
  final String? description;
  final bool active;
}

/// Outlet identity for print tokens (`{store_*}`) — the outlet master (detail
/// toko = data tenant) shipped in the OUTLET domain by `web/lib/config/resync.ts`
/// (`outlet` key). Empty defaults when the field is unset, never a guess.
class OutletIdentity {
  const OutletIdentity({
    this.name = '',
    this.shortcode = '',
    this.address = '',
    this.phone = '',
    this.socialMedia = '',
    this.instagram = '',
    this.tiktok = '',
    this.email = '',
    this.timezone = '',
    this.currencyLabel = '',
  });

  factory OutletIdentity.fromJson(Map<String, dynamic> j) => OutletIdentity(
        name: j['name'] as String? ?? '',
        shortcode: j['shortcode'] as String? ?? '',
        address: j['address'] as String? ?? '',
        phone: j['phone'] as String? ?? '',
        socialMedia: j['socialMedia'] as String? ?? '',
        instagram: j['instagram'] as String? ?? '',
        tiktok: j['tiktok'] as String? ?? '',
        email: j['email'] as String? ?? '',
        timezone: j['timezone'] as String? ?? '',
        currencyLabel: j['currencyLabel'] as String? ?? '',
      );

  final String name;
  final String shortcode;
  final String address;
  final String phone;
  final String socialMedia;
  final String instagram;
  final String tiktok;
  final String email;
  final String timezone;
  final String currencyLabel;
}

/// Holding group identity for print tokens (`{group_name}`, `{group_shortcode}`).
/// Shipped in the OUTLET domain (`group` key). Empty when absent.
class GroupIdentity {
  const GroupIdentity({this.name = '', this.shortcode = ''});

  factory GroupIdentity.fromJson(Map<String, dynamic> j) => GroupIdentity(
        name: j['name'] as String? ?? '',
        shortcode: j['shortcode'] as String? ?? '',
      );

  final String name;
  final String shortcode;
}

class ShiftConfig {
  ShiftConfig({
    required this.shiftType,
    required this.defaultHouseBank,
    required this.roundingMode,
    this.endCountMode = EndCountMode.onlyCash,
    this.timezone,
    this.currencyLabel = '',
    this.mealShiftWindows = const [],
    this.recapWindow,
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
        endCountMode: endCountModeFrom(j['endCountMode'] as String?),
        timezone: j['timezone'] as String?,
        currencyLabel: j['currencyLabel'] as String? ?? '',
        mealShiftWindows: (j['mealShiftWindows'] as List?)
                ?.map((e) => MealShiftWindow.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        recapWindow: j['recapWindow'] == null
            ? null
            : RecapWindow.fromJson(j['recapWindow'] as Map<String, dynamic>),
      );

  final String shiftType;
  final double defaultHouseBank;
  final money.RoundingMode roundingMode;

  /// END SHIFT count mode for this outlet (server OUTLET config `shift.endCountMode`).
  /// Unknown/absent → [EndCountMode.onlyCash] (safe fallback).
  final EndCountMode endCountMode;
  final String? timezone;
  final String currencyLabel;

  /// Meal-shift ranges (AUTOMATIC only). Empty on a real device today — the
  /// server does not ship them (see [MealShiftWindow]).
  final List<MealShiftWindow> mealShiftWindows;

  /// Daily-close recap window. Null on a real device today.
  final RecapWindow? recapWindow;

  bool get isAutomatic => shiftType.toUpperCase() == 'AUTOMATIC';

  /// True when two configs describe the same shift RULES (type + windows +
  /// END SHIFT mode). Drives the "config change applies next day" rule: a
  /// running shift keeps the config it started with.
  bool sameRules(ShiftConfig other) =>
      isAutomatic == other.isAutomatic &&
      endCountMode == other.endCountMode &&
      mealShiftWindows.length == other.mealShiftWindows.length &&
      recapWindow?.label == other.recapWindow?.label;
}

/// END SHIFT count mode (mirrors server enum `EndCountMode`).
enum EndCountMode {
  onlyCash,
  cashCashless,
  crosscheckPerMethod;

  /// Server code for the close payload.
  String get code => switch (this) {
        EndCountMode.onlyCash => 'ONLY_CASH',
        EndCountMode.cashCashless => 'CASH_CASHLESS',
        EndCountMode.crosscheckPerMethod => 'CROSSCHECK_PER_METHOD',
      };
}

/// Parse the server code; anything unknown → [EndCountMode.onlyCash].
EndCountMode endCountModeFrom(String? s) {
  switch ((s ?? '').toUpperCase()) {
    case 'CASH_CASHLESS':
      return EndCountMode.cashCashless;
    case 'CROSSCHECK_PER_METHOD':
      return EndCountMode.crosscheckPerMethod;
    default:
      return EndCountMode.onlyCash;
  }
}

/// One counted-cash input rendered by the END SHIFT dialog. Its [key] is the
/// payload field it maps to: `countedTotal`, `cash`, `cashless`, or an outlet
/// method id (crosscheck).
class EndCountField {
  const EndCountField({required this.key, required this.label, this.type, this.outletMethodId});

  final String key;
  final String label;
  final String? type; // CASH | NON_CASH
  final String? outletMethodId;
}

/// The count inputs the POS must render for a mode:
/// 1 field (ONLY_CASH), 2 fields (CASH_CASHLESS), or one per ACTIVE outlet
/// method (CROSSCHECK_PER_METHOD). Pure → unit-testable.
List<EndCountField> endCountFields(EndCountMode mode, List<OutletPaymentMethod> methods) {
  switch (mode) {
    case EndCountMode.cashCashless:
      return const [
        EndCountField(key: 'cash', label: 'Cash', type: 'CASH'),
        EndCountField(key: 'cashless', label: 'Cashless', type: 'NON_CASH'),
      ];
    case EndCountMode.crosscheckPerMethod:
      return [
        for (final m in methods)
          EndCountField(
            key: m.id,
            label: m.displayName,
            type: m.type == money.PayType.cash ? 'CASH' : 'NON_CASH',
            outletMethodId: m.id,
          ),
      ];
    case EndCountMode.onlyCash:
      return const [EndCountField(key: 'countedTotal', label: 'Counted cash (total)', type: 'CASH')];
  }
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
    this.discounts = const [],
    this.vouchers = const [],
    this.shipmentMasters = const [],
    this.outlet = const OutletIdentity(),
    this.group = const GroupIdentity(),
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
    // Discount/voucher masters (tenant MASTER domain). Real server keys are
    // `discounts` and `vouchers` (web/lib/config/resync.ts buildFull MASTER).
    // Tolerant: a missing key → empty list, never throws.
    final discounts = (master['discounts'] as List?)
            ?.map((e) => DiscountMaster.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const <DiscountMaster>[];
    final vouchers = (master['vouchers'] as List?)
            ?.map((e) => VoucherMaster.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const <VoucherMaster>[];
    // Shipment masters (tenant MASTER domain). Not shipped by resync.ts today →
    // empty, and the master-shipment option stays unavailable (open shipment only).
    final shipments = (master['shipmentMasters'] as List?)
            ?.map((e) => ShipmentMaster.fromJson(e as Map<String, dynamic>))
            .where((s) => s.active)
            .toList() ??
        const <ShipmentMaster>[];
    return TenantConfig(
      items: items,
      categories: cats,
      menuLayouts: layouts.where((l) => l.active).toList(),
      paymentMethods: payments.where((p) => p.enabled).toList(),
      shift: shiftOut == null ? ShiftConfig.defaultValue() : ShiftConfig.fromJson(shiftOut),
      tables: tables,
      priceLevels: levels,
      discounts: discounts,
      vouchers: vouchers,
      shipmentMasters: shipments,
      // Outlet + group identity for print tokens (additive OUTLET keys; absent
      // on older payloads → empty, never a guess).
      outlet: outlet['outlet'] is Map<String, dynamic>
          ? OutletIdentity.fromJson(outlet['outlet'] as Map<String, dynamic>)
          : const OutletIdentity(),
      group: outlet['group'] is Map<String, dynamic>
          ? GroupIdentity.fromJson(outlet['group'] as Map<String, dynamic>)
          : const GroupIdentity(),
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
  /// Tenant discount masters (server MASTER domain; empty until the server
  /// ships the `discounts` key).
  final List<DiscountMaster> discounts;
  /// Tenant voucher masters (server MASTER domain; empty until the server
  /// ships the `vouchers` key).
  final List<VoucherMaster> vouchers;
  /// Tenant shipment masters (precise amount). NOT shipped by resync.ts today →
  /// empty on a real device; the master-shipment option stays unavailable.
  final List<ShipmentMaster> shipmentMasters;

  /// Outlet identity (name/shortcode/address/phone/social/tz/currency) for the
  /// `{store_*}` print tokens. Empty when the OUTLET payload omits it.
  final OutletIdentity outlet;

  /// Holding group identity for `{group_name}` / `{group_shortcode}`.
  final GroupIdentity group;

  /// Flat category-id → parent-id map (walks the nested `children` tree the
  /// server sends). Used for discount/voucher category eligibility inheritance.
  Map<String, String?> get categoryParentId {
    final out = <String, String?>{};
    void walk(Category c, String? parent) {
      out[c.id] = c.parentId ?? parent;
      for (final child in c.children) {
        walk(child, c.id);
      }
    }

    for (final c in categories) {
      walk(c, null);
    }
    return out;
  }

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
        out.add(MenuNode(
          id: n.id, parentId: n.parentId, name: n.name, sortOrder: n.sortOrder,
          itemIds: visible, children: children,
          // The tile image must survive the prune, or the order screen could
          // never show an uploaded category picture.
          imageKey: n.imageKey,
        ));
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
    final idToImage = {for (final c in categories) c.id: c.imageKey};
    return byCat.entries.map((e) {
      return MenuNode(
        id: 'cat:_${e.key}',
        name: idToName[e.key] ?? 'Items',
        itemIds: e.value.map((i) => i.id).toList(),
        imageKey: idToImage[e.key],
      );
    }).toList();
  }
}

class Category {
  Category({required this.id, this.parentId, required this.name, this.children = const [], this.imageKey});

  /// Uploaded tile image (media asset key) — used by the category fallback view.
  final String? imageKey;

  factory Category.fromJson(Map<String, dynamic> j) => Category(
        id: j['id'] as String,
        parentId: j['parentId'] as String?,
        name: j['name'] as String,
        imageKey: (j['imageKey'] as String?)?.trim().isEmpty ?? true ? null : j['imageKey'] as String?,
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