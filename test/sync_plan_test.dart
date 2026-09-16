import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/sync_planner.dart';

void main() {
  group('planSync (server version.ts mirror)', () {
    const server = {
      'MASTER': 4,
      'OUTLET': 2,
      'FORMAT': 0,
      'MEDIA': 1,
    };

    test('matching per-domain versions → nothing to resync', () {
      final plan = planSync(server, {'MASTER': 4, 'OUTLET': 2, 'FORMAT': 0, 'MEDIA': 1});
      expect(plan.needsFull, isEmpty);
      expect(plan.upToDate, hasLength(4));
    });

    test('stale MASTER forces full resync of MASTER only', () {
      final plan = planSync(server, {'MASTER': 3, 'OUTLET': 2, 'FORMAT': 0, 'MEDIA': 1});
      expect(plan.needsFull, ['MASTER']);
    });

    test('missing domain → full resync (FORMAT at v0 matches client 0)', () {
      final plan = planSync(server, {'MASTER': 4});
      expect(plan.needsFull, containsAll(['OUTLET', 'MEDIA']));
      // FORMAT server version is 0 == client 0 → already in sync (server rule).
      expect(plan.needsFull, isNot(contains('FORMAT')));
      expect(plan.upToDate, containsAll(['MASTER', 'FORMAT']));
    });

    test('empty client → resync only domains whose server version > 0', () {
      final plan = planSync(server, const {});
      expect(plan.needsFull, ['MASTER', 'OUTLET', 'MEDIA']);
      expect(plan.needsFull, isNot(contains('FORMAT')));
      expect(plan.upToDate, ['FORMAT']);
    });

    test('server with nonzero versions and empty client → all resync', () {
      final allNonZero = {'MASTER': 4, 'OUTLET': 2, 'FORMAT': 3, 'MEDIA': 1};
      final plan = planSync(allNonZero, const {});
      expect(plan.needsFull, hasLength(4));
      expect(plan.upToDate, isEmpty);
    });

    test('server with zero versions and empty client → all up to date', () {
      final plan = planSync(const {}, const {});
      expect(plan.needsFull, isEmpty);
      expect(plan.upToDate, hasLength(4));
    });
  });
}