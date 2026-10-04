/// Discount / voucher masters + pure eligibility + selection for the POS.
///
/// Mirrors the SERVER rules exactly (server is authoritative at settle):
///   - at most ONE discount OR ONE voucher per bill (mutually exclusive);
///   - the amount applies BEFORE VAT/SC (i.e. subtracted from the pre-tax
///     subtotal inside the money-flow);
///   - a master is offered only when the cart conforms to its category tags,
///     and a parent-category tag covers all descendants (inheritance);
///   - expired / inactive / quota-exhausted entries are NOT offered;
///   - percentage → subtotal × value/100, fixed → value, clamped to subtotal.
///
/// Web mirrors: `web/lib/pos/money.ts` (`applyPricing`, `payableForOrder`) and
/// `web/lib/eligibility.ts` (`eligibleDiscounts` / `eligibleVouchers`).
library;

enum PricingKind { percentage, fixed }

enum PricingTarget { wholeBill, itemGroup }

PricingKind _kindFrom(String? s) => s == 'FIXED' ? PricingKind.fixed : PricingKind.percentage;

PricingTarget _targetFrom(String? s) => s == 'ITEM_GROUP' ? PricingTarget.itemGroup : PricingTarget.wholeBill;

double? _num(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String && v.isNotEmpty) return double.tryParse(v);
  return null;
}

int _intOr(Object? v, int fallback) => _num(v)?.toInt() ?? fallback;

/// Category eligibility tag (server `DiscountCategoryTag` / `VoucherCategoryTag`).
class PricingCategoryTag {
  PricingCategoryTag({required this.categoryId, this.includesChildren = true});

  factory PricingCategoryTag.fromJson(Map<String, dynamic> j) => PricingCategoryTag(
        categoryId: (j['categoryId'] ?? '') as String,
        includesChildren: (j['includesChildren'] as bool?) ?? true,
      );

  final String categoryId;
  final bool includesChildren;
}

/// Shared amount surface: a discount and a voucher both carry a [kind] + value.
abstract class PricingMaster {
  String get id;
  String get name;
  PricingKind get kind;
  double get value;
  DateTime? get expiresAt;
  List<PricingCategoryTag> get categoryTags;
}

/// Server `Discount` master (`web/prisma/schema.prisma` model Discount).
class DiscountMaster implements PricingMaster {
  DiscountMaster({
    required this.id,
    required this.name,
    required this.kind,
    required this.value,
    this.target = PricingTarget.wholeBill,
    this.expiresAt,
    this.active = true,
    this.categoryTags = const [],
  });

  factory DiscountMaster.fromJson(Map<String, dynamic> j) => DiscountMaster(
        id: (j['id'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        kind: _kindFrom(j['kind'] as String?),
        value: _num(j['value']) ?? 0,
        target: _targetFrom(j['target'] as String?),
        expiresAt: _date(j['expiresAt']),
        active: (j['active'] as bool?) ?? true,
        categoryTags: (j['categoryTags'] as List?)
                ?.map((e) => PricingCategoryTag.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );

  @override
  final String id;
  @override
  final String name;
  @override
  final PricingKind kind;
  @override
  final double value;
  final PricingTarget target;
  @override
  final DateTime? expiresAt;
  final bool active;
  @override
  final List<PricingCategoryTag> categoryTags;
}

/// Server `Voucher` master (`web/prisma/schema.prisma` model Voucher). [qtyUse]
/// and [usedCount] are per-OUTLET; the quota is exhausted once used ≥ qtyUse.
class VoucherMaster implements PricingMaster {
  VoucherMaster({
    required this.id,
    required this.name,
    required this.kind,
    required this.value,
    this.qtyUse = 0,
    this.usedCount = 0,
    this.expiresAt,
    this.active = true,
    this.categoryTags = const [],
  });

  factory VoucherMaster.fromJson(Map<String, dynamic> j) => VoucherMaster(
        id: (j['id'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        kind: _kindFrom(j['kind'] as String?),
        value: _num(j['value']) ?? 0,
        qtyUse: _intOr(j['qtyUse'], 0),
        usedCount: _intOr(j['usedCount'], 0),
        expiresAt: _date(j['expiresAt']),
        active: (j['active'] as bool?) ?? true,
        categoryTags: (j['categoryTags'] as List?)
                ?.map((e) => PricingCategoryTag.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );

  @override
  final String id;
  @override
  final String name;
  @override
  final PricingKind kind;
  @override
  final double value;
  final int qtyUse;
  final int usedCount;
  @override
  final DateTime? expiresAt;
  final bool active;
  @override
  final List<PricingCategoryTag> categoryTags;

  /// A per-outlet quota is enforced only when qtyUse > 0; 0 = unlimited.
  bool get quotaAvailable => qtyUse <= 0 || usedCount < qtyUse;
}

DateTime? _date(Object? v) {
  if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
  return null;
}

/// Server rule: expiresAt == null → never expires; else must be strictly in the
/// future (`expiresAt > now`). `<= now` is expired → not offered.
bool isExpired(DateTime? expiresAt, DateTime now) => expiresAt != null && !expiresAt.isAfter(now);

/// Ancestor-or-self category ids (walks the parent chain via [parentById]).
Set<String> ancestorsOf(String categoryId, Map<String, String?> parentById) {
  final seen = <String>{};
  String? cur = categoryId;
  while (cur != null && seen.add(cur)) {
    cur = parentById[cur];
  }
  return seen;
}

bool _tagsMatch(List<PricingCategoryTag> tags, Set<String> lineCats, List<Set<String>> ancestors) {
  // A master with NO category tag applies to the WHOLE bill (a whole-bill
  // discount/voucher needs no category restriction). Mirrors the server
  // (`web/lib/eligibility.ts isEligible`). Tagged masters still match exactly.
  if (tags.isEmpty) return true;
  for (final t in tags) {
    if (t.includesChildren) {
      if (ancestors.any((a) => a.contains(t.categoryId))) return true;
    } else if (lineCats.contains(t.categoryId)) {
      return true; // exact category only
    }
  }
  return false;
}

(List<Set<String>>, Set<String>) _eligibilityContext(
  List<String> lineCategoryIds,
  Map<String, String?> parentById,
) {
  final lineCats = lineCategoryIds.toSet();
  final ancestors = lineCategoryIds.map((c) => ancestorsOf(c, parentById)).toList();
  return (ancestors, lineCats);
}

/// Discounts offered for a cart: active, unexpired, category-eligible.
List<DiscountMaster> eligibleDiscounts({
  required List<DiscountMaster> discounts,
  required List<String> lineCategoryIds,
  required Map<String, String?> parentById,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final (ancestors, lineCats) = _eligibilityContext(lineCategoryIds, parentById);
  return discounts
      .where((d) => d.active && !isExpired(d.expiresAt, at) && _tagsMatch(d.categoryTags, lineCats, ancestors))
      .toList();
}

/// Vouchers offered for a cart: active, unexpired, category-eligible, in quota.
List<VoucherMaster> eligibleVouchers({
  required List<VoucherMaster> vouchers,
  required List<String> lineCategoryIds,
  required Map<String, String?> parentById,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final (ancestors, lineCats) = _eligibilityContext(lineCategoryIds, parentById);
  return vouchers
      .where((v) =>
          v.active &&
          v.quotaAvailable &&
          !isExpired(v.expiresAt, at) &&
          _tagsMatch(v.categoryTags, lineCats, ancestors))
      .toList();
}

/// Raw amount for a master against a pre-tax subtotal. Percentage → subtotal ×
/// value/100; fixed → value. Clamped to subtotal (never negative). NOT rounded:
/// the money-flow rounds exactly once. Mirrors `web/lib/pos/money.ts`.
double pricingAmount(PricingMaster m, double subtotal) {
  final raw = m.kind == PricingKind.percentage ? subtotal * m.value / 100 : m.value;
  return raw < subtotal ? raw : subtotal;
}

/// The bill's single applied pricing (at most one discount OR one voucher).
class PricingSelection {
  const PricingSelection({this.discount, this.voucher});

  static const PricingSelection none = PricingSelection();

  final DiscountMaster? discount;
  final VoucherMaster? voucher;

  bool get isEmpty => discount == null && voucher == null;

  /// Applying a discount is mutually exclusive with a voucher (replaces it).
  PricingSelection applyDiscount(DiscountMaster d) => PricingSelection(discount: d);

  /// Applying a voucher is mutually exclusive with a discount (replaces it).
  PricingSelection applyVoucher(VoucherMaster v) => PricingSelection(voucher: v);

  PricingSelection cleared() => none;

  /// Discount-before-tax amount for [subtotal]; 0 when nothing is applied.
  double amountFor(double subtotal) {
    final m = discount ?? voucher;
    if (m == null) return 0;
    return pricingAmount(m, subtotal);
  }
}