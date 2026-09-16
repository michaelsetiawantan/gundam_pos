import 'package:flutter/material.dart';

import 'package:gundam_pos/ui/theme.dart';

/// Shared widgets for the CrustMeasure petrol/teal look. All targets >= 44px.
class PosLogo extends StatelessWidget {
  const PosLogo({super.key, this.size = 64, this.dark = true});

  final double size;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: dark ? PosTheme.teal : PosTheme.petrol,
        borderRadius: BorderRadius.circular(size * 0.24),
      ),
      child: Icon(Icons.storefront, color: dark ? PosTheme.petrol : Colors.white, size: size * 0.55),
    );
  }
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    if (message == null || message!.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: PosTheme.danger.withValues(alpha: 0.1),
        border: const Border(left: BorderSide(color: PosTheme.danger, width: 4)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        const Icon(Icons.error_outline, color: PosTheme.danger, size: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Text(message!, style: const TextStyle(color: PosTheme.danger, fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({super.key, required this.label, this.busy = false, this.icon, required this.onPressed});

  final String label;
  final bool busy;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: PosTheme.minTouch + 8,
      child: FilledButton(
        onPressed: busy ? null : onPressed,
        child: busy
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 3, color: PosTheme.petrol),
              )
            : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (icon != null) ...[
                  Icon(icon),
                  const SizedBox(width: 10),
                ],
                Text(label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ]),
      ),
    );
  }
}

/// Outlined action tile used on the home dashboard.
class HomeTile extends StatelessWidget {
  const HomeTile({super.key, required this.icon, required this.title, required this.subtitle, required this.onTap});

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          constraints: const BoxConstraints(minHeight: 132),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(color: PosTheme.tealSoft, borderRadius: BorderRadius.circular(12)),
                child: Icon(icon, color: PosTheme.petrol, size: 26),
              ),
              const SizedBox(height: 12),
              Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: PosTheme.ink)),
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(fontSize: 14, color: PosTheme.slate)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Branded header used on the auth screens.
class AuthHeader extends StatelessWidget {
  const AuthHeader({super.key, required this.title, required this.caption});

  final String title;
  final String caption;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      const PosLogo(dark: true, size: 72),
      const SizedBox(height: 18),
      Text(title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: PosTheme.petrol)),
      const SizedBox(height: 6),
      Text(caption, textAlign: TextAlign.center, style: const TextStyle(color: PosTheme.slate, fontSize: 15)),
      const SizedBox(height: 28),
    ]);
  }
}