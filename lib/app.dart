import 'package:flutter/material.dart';

import 'package:gundam_pos/ui/theme.dart';

/// Gundam POS app shell. See AppSession (slice 2) for the auth stage routing;
/// this file only owns the visual root + theme.
class PosApp extends StatelessWidget {
  const PosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gundam POS',
      debugShowCheckedModeBanner: false,
      theme: PosTheme.theme(),
      home: const _Bootstrap(),
    );
  }
}

/// Temporary boot placeholder (replaced by AppSession-driven routing in F3b
/// slice 2). Renders the CrustMeasure petrol/teal identity.
class _Bootstrap extends StatelessWidget {
  const _Bootstrap();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.primary,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.storefront, color: PosTheme.tealSoft, size: 72),
            const SizedBox(height: 16),
            Text('Gundam POS', style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text('Northstar outlet · connected fieldwork', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.white70)),
          ],
        ),
      ),
    );
  }
}