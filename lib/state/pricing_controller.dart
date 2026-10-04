import 'package:flutter/foundation.dart';

import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/api/pos_api.dart';
import 'package:gundam_pos/logic/cart.dart';
import 'package:gundam_pos/logic/discount_voucher.dart' as dv;
import 'package:gundam_pos/models/config_models.dart';

/// The ONE place the bill's discount/voucher lives. Tablet proposes, server
/// decides (POST /api/pos/orders/[id]/pricing); [selection] holds exactly what
/// the server returned — never a locally computed amount. Shared by order entry
/// (apply while taking the order) and payment (settle), so both screens read the
/// same state and the payable preview can never drift from the server.
class PricingController extends ChangeNotifier {
  PricingController({
    required this.posApi,
    required this.orderId,
    required this.config,
    required this.cart,
  });

  final PosApi posApi;
  final String orderId;
  final TenantConfig config;
  final Cart cart;

  /// Server-confirmed choice: at most ONE discount OR ONE voucher per bill.
  dv.PricingSelection selection = dv.PricingSelection.none;

  /// True while a below-threshold choice is queued: the bill is AWAITING
  /// APPROVAL and no discount/voucher is applied yet.
  bool pending = false;
  bool busy = false;
  String? error;

  /// The applied master (discount or voucher), else null.
  dv.PricingMaster? get applied => selection.discount ?? selection.voucher;

  /// Discount-before-tax amount for [subtotal]; 0 when nothing is applied.
  double amountFor(double subtotal) => selection.amountFor(subtotal);

  List<String> get _lineCategoryIds => [
        for (final l in cart.lines)
          if (config.itemById(l.itemId)?.categoryId case final c?) c,
      ];

  /// Discounts offered for the current cart (active, unexpired, eligible).
  List<dv.DiscountMaster> get availableDiscounts => dv.eligibleDiscounts(
        discounts: config.discounts,
        lineCategoryIds: _lineCategoryIds,
        parentById: config.categoryParentId,
      );

  /// Vouchers offered for the current cart (active, unexpired, eligible, in quota).
  List<dv.VoucherMaster> get availableVouchers => dv.eligibleVouchers(
        vouchers: config.vouchers,
        lineCategoryIds: _lineCategoryIds,
        parentById: config.categoryParentId,
      );

  Future<bool> applyDiscount(dv.DiscountMaster d) => _setChoice(discountId: d.id);
  Future<bool> applyVoucher(dv.VoucherMaster v) => _setChoice(voucherId: v.id);

  /// Clear the bill's discount/voucher through the server (ids sent null).
  Future<bool> cancelPricing() => _setChoice();

  /// Tablet proposes; server decides. A below-threshold caller gets a PENDING
  /// approval — nothing is applied locally. On success we ADOPT the server ids.
  Future<bool> _setChoice({String? discountId, String? voucherId}) async {
    busy = true;
    pending = false;
    error = null;
    notifyListeners();
    try {
      final r = await posApi.setPricing(orderId, discountId: discountId, voucherId: voucherId);
      if (r['approval'] != null) {
        selection = dv.PricingSelection.none;
        pending = true;
      } else {
        final o = r['order'] as Map<String, dynamic>? ?? const {};
        _adopt(o['discountId'] as String?, o['voucherId'] as String?);
      }
      return true;
    } on PosApiException catch (e) {
      error = _message(e);
      return false;
    } on PosNetworkException {
      error = 'No network — discount/voucher not changed.';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Adopt the pricing the SERVER already holds for this order (`discountId` /
  /// `voucherId` on the order row). Needed because a discount can be applied
  /// WITHOUT this tablet doing it — e.g. an approval authorised on the POS by an
  /// approver's credentials, or from another device. Without this the payment
  /// screen and bill preview showed NO discount while the server already had one.
  void adoptFromOrder(Map<String, dynamic> order) {
    final d = order['discountId'] as String?;
    final v = order['voucherId'] as String?;
    if (d == null && v == null && selection.isEmpty) return; // nothing to change
    _adopt(d, v);
    notifyListeners();
  }

  /// Map the confirmed id back to the server-shipped master. Any locally
  /// computed amount is discarded — the money-flow derives from this.
  void _adopt(String? discountId, String? voucherId) {
    if (discountId != null) {
      final d = _discountById(discountId);
      selection = d == null ? dv.PricingSelection.none : dv.PricingSelection(discount: d);
    } else if (voucherId != null) {
      final v = _voucherById(voucherId);
      selection = v == null ? dv.PricingSelection.none : dv.PricingSelection(voucher: v);
    } else {
      selection = dv.PricingSelection.none;
    }
  }

  dv.DiscountMaster? _discountById(String id) {
    for (final d in config.discounts) {
      if (d.id == id) return d;
    }
    return null;
  }

  dv.VoucherMaster? _voucherById(String id) {
    for (final v in config.vouchers) {
      if (v.id == id) return v;
    }
    return null;
  }

  /// Readable message for each server pricing error code.
  String _message(PosApiException e) {
    switch (e.code) {
      case 'discount_expired':
      case 'voucher_expired':
        return 'That discount or voucher has expired.';
      case 'discount_inactive':
      case 'voucher_inactive':
        return 'That discount or voucher is no longer active.';
      case 'voucher_exhausted':
        return 'That voucher has no uses left.';
      case 'discount_not_eligible':
      case 'voucher_not_eligible':
        return 'That discount or voucher does not apply to the items on this bill.';
      case 'discount_and_voucher_mutually_exclusive':
        return 'A bill can have only one discount OR one voucher.';
      case 'discount_not_found':
      case 'voucher_not_found':
        return 'That discount or voucher is no longer available.';
      case 'order_closed':
        return 'This bill is already closed.';
      default:
        return e.isRateLimited
            ? 'Too many attempts. Wait and retry.'
            : 'Could not change the discount/voucher (${e.code}).';
    }
  }
}
