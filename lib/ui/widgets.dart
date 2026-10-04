import 'package:flutter/material.dart';

import 'package:gundam_pos/api/api_client.dart';
import 'package:gundam_pos/state/app_session.dart';
import 'package:gundam_pos/ui/theme.dart';

/// Operator-editable runtime server address. Shows the address in use, lets the
/// operator type a new one (host / host:port / http(s):// URL), probes it and
/// reports the result honestly. Used on activation, login and More.
class ServerAddressField extends StatefulWidget {
  const ServerAddressField({super.key, required this.session, this.probe, this.compact = false});

  final AppSession session;

  /// Injectable probe (tests); defaults to a real HTTP probe.
  final ServerProbe? probe;

  /// Tighter copy for the More screen.
  final bool compact;

  @override
  State<ServerAddressField> createState() => _ServerAddressFieldState();
}

class _ServerAddressFieldState extends State<ServerAddressField> {
  late final TextEditingController _addr = TextEditingController(text: widget.session.serverAddress);
  ServerProbeResult? _result;
  bool _busy = false;

  @override
  void dispose() {
    _addr.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final result = await widget.session.setServerAddress(_addr.text, probe: widget.probe);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = result;
      // Only reflect the persisted value back once it was accepted.
      if (result.ok) _addr.text = widget.session.serverAddress;
    });
  }

  /// Live warning derived from the address currently in the field.
  bool get _insecure {
    final n = normalizeServerAddress(_addr.text);
    return n != null && isInsecureServerUrl(n);
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _addr,
          enabled: !_busy,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.url,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _save(),
          decoration: const InputDecoration(
            labelText: 'Server address',
            hintText: 'host, host:port or http(s)://host:port',
            prefixIcon: Icon(Icons.dns_outlined),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save & test'),
        ),
        if (result != null) ...[
          const SizedBox(height: 8),
          Text(
            '${result.message}${result.detail == null ? '' : ' (${result.detail})'}',
            style: TextStyle(
              color: result.ok ? PosTheme.petrol : PosTheme.danger,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        if (_insecure) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: PosTheme.tealSoft,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              'Heads up: plain http on a non-local host. Some clients refuse Secure session '
              'cookies on insecure origins, so login may fail until the server allows it.',
              style: TextStyle(color: PosTheme.petrol, fontSize: 12),
            ),
          ),
        ],
        if (!widget.compact) ...[
          const SizedBox(height: 6),
          const Text(
            'Type the web server address the tablet should reach (over VPN or the cloud).',
            style: TextStyle(color: PosTheme.slate, fontSize: 12),
          ),
        ],
      ],
    );
  }
}


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
          // No forced minimum height: the dashboard fits the screen, so a tile
          // must accept whatever space the grid gives it (a hard minHeight is
          // what used to push the page into scrolling).
          padding: const EdgeInsets.all(12),
          // Scale the content down instead of overflowing when the licence
          // banner squeezes the grid: the dashboard NEVER scrolls and a tile
          // never shows a striped overflow.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 210,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(color: PosTheme.tealSoft, borderRadius: BorderRadius.circular(10)),
                    child: Icon(icon, color: PosTheme.petrol, size: 30),
                  ),
                  const SizedBox(height: 8),
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: PosTheme.ink)),
                  const SizedBox(height: 2),
                  // Ellipsised: a long label must never overflow the fixed tile again
                  // (it did once an extra Home tile made the grid taller/narrower).
                  Text(subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: PosTheme.slate)),
                ],
              ),
            ),
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