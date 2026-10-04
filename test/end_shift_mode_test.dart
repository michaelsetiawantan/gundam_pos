import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/money.dart' as money;
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/shift_controller.dart';

OutletPaymentMethod _m(String id, String name, money.PayType type) => OutletPaymentMethod(
      id: id,
      masterId: 'master-$id',
      displayName: name,
      code: id.toUpperCase(),
      type: type,
      enabled: true,
    );

void main() {
  group('END SHIFT — mode parse + field count', () {
    test('endCountModeFrom maps server codes; unknown → onlyCash', () {
      expect(endCountModeFrom('ONLY_CASH'), EndCountMode.onlyCash);
      expect(endCountModeFrom('CASH_CASHLESS'), EndCountMode.cashCashless);
      expect(endCountModeFrom('CROSSCHECK_PER_METHOD'), EndCountMode.crosscheckPerMethod);
      expect(endCountModeFrom('WAT'), EndCountMode.onlyCash);
      expect(endCountModeFrom(null), EndCountMode.onlyCash);
    });

    test('ShiftConfig parses endCountMode from the OUTLET payload; default onlyCash', () {
      expect(ShiftConfig.fromJson({'endCountMode': 'CASH_CASHLESS'}).endCountMode, EndCountMode.cashCashless);
      expect(ShiftConfig.fromJson({'shiftType': 'MANUAL'}).endCountMode, EndCountMode.onlyCash);
    });

    test('endCountFields: 1 / 2 / N inputs per mode', () {
      final methods = [_m('pm-cash', 'Cash', money.PayType.cash), _m('pm-qris', 'QRIS', money.PayType.nonCash), _m('pm-visa', 'Visa', money.PayType.nonCash)];

      final only = endCountFields(EndCountMode.onlyCash, methods);
      expect(only, hasLength(1));
      expect(only.single.key, 'countedTotal');

      final two = endCountFields(EndCountMode.cashCashless, methods);
      expect(two.map((f) => f.key).toList(), ['cash', 'cashless']);

      final per = endCountFields(EndCountMode.crosscheckPerMethod, methods);
      expect(per, hasLength(3));
      expect(per.map((f) => f.outletMethodId).toList(), ['pm-cash', 'pm-qris', 'pm-visa']);
      expect(per.first.type, 'CASH');
      expect(per[1].type, 'NON_CASH');
    });
  });

  group('END SHIFT — close payload', () {
    test('ONLY_CASH keeps the legacy countedTotal body', () {
      final body = ShiftController.buildClosePayload(EndCountMode.onlyCash, countedTotal: 545000);
      expect(body, {'countedTotal': 545000});
    });

    test('CASH_CASHLESS sends mode + cash + cashless', () {
      final body = ShiftController.buildClosePayload(EndCountMode.cashCashless, cash: 100, cashless: 200);
      expect(body, {'mode': 'CASH_CASHLESS', 'cash': 100, 'cashless': 200});
    });

    test('CROSSCHECK_PER_METHOD sends a perMethod array', () {
      final body = ShiftController.buildClosePayload(
        EndCountMode.crosscheckPerMethod,
        perMethod: [
          {'outletMethodId': 'pm-cash', 'counted': 45000},
          {'outletMethodId': 'pm-qris', 'counted': 30000},
        ],
      );
      expect(body['mode'], 'CROSSCHECK_PER_METHOD');
      expect((body['perMethod'] as List), hasLength(2));
    });
  });
}
