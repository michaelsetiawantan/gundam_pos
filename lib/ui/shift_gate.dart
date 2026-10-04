import 'package:flutter/material.dart';

import 'package:gundam_pos/logic/shift_window.dart';
import 'package:gundam_pos/models/config_models.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/ui/shift_screen.dart';

/// PRD: no table / order / money operation without an OPEN shift. Returns true
/// when a shift is open; otherwise shows the blocking message and a direct path
/// to Start Shift (the cashier is never left guessing). The server enforces the
/// same rule with `shift_required` (409) — this only makes the POS honest and
/// stops the cashier from reaching a dead end. Read-only screens must NOT call
/// this (browsing Open Tables / Today's stays allowed).
Future<bool> ensureShiftOpen(
  BuildContext context,
  AppSession session,
  TenantConfig config,
) async {
  if (session.shiftController.isOpen) return true;
  final startLabel = ShiftGate(config.shift).startLabel;
  final start = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Start a shift first'),
      content: Text(
        'You must start a shift before opening a table or taking an order. '
        'Tap "$startLabel" to count the opening cash, then try again.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(startLabel)),
      ],
    ),
  );
  if (start == true && context.mounted) {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ShiftScreen(session: session, config: config)),
    );
  }
  return false;
}
