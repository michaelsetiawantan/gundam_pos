/// POS activation + session credential store. Credentials are NEVER kept as
/// plain text in app logs; the opaque device token and session identity live
/// in platform secure storage (Keychain / Keystore). `InMemorySessionStore` is
/// the test double; `SecureSessionStore` is the production implementation.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class PosContext {
  const PosContext({
    this.deviceToken,
    this.groupId,
    this.tenantId,
    this.shortcode,
    this.sessionId,
    this.userId,
    this.userEmail,
    this.userName,
    this.outletId,
    this.outletName,
    this.deviceId,
    this.sessionCookie,
  });

  final String? deviceToken;
  final String? groupId;
  final String? tenantId;
  final String? shortcode;
  final String? sessionId;
  final String? userId;
  final String? userEmail;
  final String? userName;
  final String? outletId;
  final String? outletName;
  final String? deviceId;
  /// The `gundam_auth` JWT session cookie, if the deployment issues one. The
  /// server's session guard reads this cookie; forwarded verbatim by the client.
  final String? sessionCookie;

  bool get activated => deviceToken != null && groupId != null && tenantId != null;
  bool get loggedIn => sessionId != null && userId != null;

  PosContext withSession(Map<String, dynamic> r) => PosContext(
        deviceId: deviceId,
        deviceToken: deviceToken,
        groupId: groupId,
        tenantId: tenantId,
        shortcode: shortcode,
        sessionId: (r['sessionId'] ?? sessionId) as String?,
        userId: _nest(r['user'], 'id') ?? userId,
        userEmail: _nest(r['user'], 'email') ?? userEmail,
        userName: _nest(r['user'], 'fullName') ?? userName,
        outletId: _nest(r['outlet'], 'id') ?? tenantId,
        outletName: _nest(r['outlet'], 'name') ?? outletName,
        // The server may issue the session cookie in a later body field.
        sessionCookie: r['sessionCookie'] as String? ?? sessionCookie,
      );

  PosContext withRedeem(Map<String, dynamic> r) => PosContext(
        deviceId: deviceId,
        deviceToken: r['deviceToken'] as String? ?? deviceToken,
        groupId: r['groupId'] as String? ?? groupId,
        tenantId: r['tenantId'] as String? ?? tenantId,
        shortcode: r['shortcode'] as String? ?? shortcode,
        sessionId: sessionId,
        userId: userId,
        userEmail: userEmail,
        userName: userName,
        outletId: outletId,
        outletName: outletName,
        sessionCookie: sessionCookie,
      );

  PosContext copyWith({String? deviceId, String? deviceToken}) => PosContext(
        deviceId: deviceId ?? this.deviceId,
        deviceToken: deviceToken ?? this.deviceToken,
        groupId: groupId,
        tenantId: tenantId,
        shortcode: shortcode,
        sessionId: sessionId,
        userId: userId,
        userEmail: userEmail,
        userName: userName,
        outletId: outletId,
        outletName: outletName,
        sessionCookie: sessionCookie,
      );

  static String? _nest(dynamic m, String key) {
    if (m is Map) return m[key] as String?;
    return null;
  }
}

abstract class SessionStore {
  Future<PosContext> load();
  Future<void> save(PosContext ctx);
  Future<void> clear();
}

const _kToken = 'gundam_device_token';
const _kGroup = 'gundam_group_id';
const _kTenant = 'gundam_tenant_id';
const _kShortcode = 'gundam_shortcode';
const _kSession = 'gundam_session_id';
const _kUser = 'gundam_user_id';
const _kEmail = 'gundam_user_email';
const _kName = 'gundam_user_name';
const _kOutletName = 'gundam_outlet_name';
const _kDeviceId = 'gundam_device_id';
const _kSessionCookie = 'gundam_session_cookie';

/// Production store backed by platform secure storage.
class SecureSessionStore implements SessionStore {
  SecureSessionStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<PosContext> load() async {
    final all = await _storage.readAll();
    return PosContext(
      deviceToken: all[_kToken],
      groupId: all[_kGroup],
      tenantId: all[_kTenant],
      shortcode: all[_kShortcode],
      sessionId: all[_kSession],
      userId: all[_kUser],
      userEmail: all[_kEmail],
      userName: all[_kName],
      outletName: all[_kOutletName],
      deviceId: all[_kDeviceId],
      sessionCookie: all[_kSessionCookie],
    );
  }

  @override
  Future<void> save(PosContext ctx) async {
    final toWrite = <String, String>{
      if (ctx.deviceToken != null) _kToken: ctx.deviceToken!,
      if (ctx.groupId != null) _kGroup: ctx.groupId!,
      if (ctx.tenantId != null) _kTenant: ctx.tenantId!,
      if (ctx.shortcode != null) _kShortcode: ctx.shortcode!,
      if (ctx.sessionId != null) _kSession: ctx.sessionId!,
      if (ctx.userId != null) _kUser: ctx.userId!,
      if (ctx.userEmail != null) _kEmail: ctx.userEmail!,
      if (ctx.userName != null) _kName: ctx.userName!,
      if (ctx.outletName != null) _kOutletName: ctx.outletName!,
      if (ctx.deviceId != null) _kDeviceId: ctx.deviceId!,
      if (ctx.sessionCookie != null) _kSessionCookie: ctx.sessionCookie!,
    };
    for (final e in toWrite.entries) {
      await _storage.write(key: e.key, value: e.value);
    }
  }

  @override
  Future<void> clear() async => _storage.deleteAll();
}

/// In-memory fake for unit tests.
class InMemorySessionStore implements SessionStore {
  PosContext? _ctx;

  @override
  Future<PosContext> load() async => _ctx ?? const PosContext();

  @override
  Future<void> save(PosContext ctx) async => _ctx = ctx;

  @override
  Future<void> clear() async => _ctx = null;
}

const _kServerAddress = 'gundam_server_base_url';

/// Persists the operator-entered runtime server address. Lives in the SAME
/// device secure storage as the activation state, so it survives restart.
abstract class ServerAddressStore {
  Future<String?> load();
  Future<void> save(String address);
}

/// Production store backed by platform secure storage (Keychain / Keystore).
class SecureServerAddressStore implements ServerAddressStore {
  SecureServerAddressStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> load() => _storage.read(key: _kServerAddress);

  @override
  Future<void> save(String address) => _storage.write(key: _kServerAddress, value: address);
}

/// In-memory fake for unit tests.
class InMemoryServerAddressStore implements ServerAddressStore {
  String? _value;

  @override
  Future<String?> load() async => _value;

  @override
  Future<void> save(String address) async => _value = address;
}