import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gundam_pos/logic/print_format.dart';
import 'package:gundam_pos/logic/print_format_render.dart';
import 'package:gundam_pos/services/escpos.dart';
import 'package:gundam_pos/services/media_sync.dart';
import 'package:gundam_pos/services/print_broker.dart';
import 'package:gundam_pos/services/print_image.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// End-to-end lock for "an IMAGE block in a print format reaches the tablet and
/// prints": upload/manifest key == block `assetKey` == cached file, and the file
/// is found by `assetKey` at print time (or an honest labelled placeholder when
/// it is not). This is the seam three separate tests used to miss — media sync
/// downloaded by key, the renderer emitted an entry, the transport rasterised,
/// but nothing proved the three agreed on the SAME key.

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

/// A manifest + file backend keyed by asset key.
MockClient _backend(Map<String, List<int>> files) => MockClient((req) async {
      if (req.url.path.contains('/media/manifest')) {
        final entries = files.entries
            .map((e) => <String, Object?>{
                  'key': e.key,
                  'url': 'https://cdn.test/${e.key}',
                  'sha256': _sha(e.value),
                  'size': e.value.length,
                  'version': 1,
                  'kind': 'OTHER',
                })
            .toList();
        return http.Response(jsonEncode({'assets': entries}), 200,
            headers: {'content-type': 'application/json'});
      }
      final name = req.url.pathSegments.last;
      final bytes = files[name];
      if (bytes == null) return http.Response('missing', 404);
      return http.Response.bytes(bytes, 200);
    });

/// A real 1x1 PNG (70 bytes) so the production `FlutterPrintImageDecoder` in the
/// LAN-transport path decodes it too — no fake leaking into the end-to-end case.
final _logoBytes = <int>[
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
  0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 218, 99, 96, 96, 96, 248, 15,
  0, 1, 4, 1, 0, 128, 187, 209, 91, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
];

/// Flutter's decoder is faked to a synthetic bitmap (no dart:ui in tests).
class _FakeDecoder extends PrintImageDecoder {
  _FakeDecoder();
  @override
  Future<ImageBitmap?> decode(Uint8List bytes) async {
    final rgba = <int>[];
    for (final v in const [0, 100, 200, 255, 255, 0, 128, 127]) {
      rgba.addAll([v, v, v, 255]);
    }
    return ImageBitmap(width: 4, height: 2, rgba: rgba);
  }
}

/// A format payload exactly as the web builder publishes it: an IMAGE block
/// carries `assetKey` (the manifest key).
Map<String, dynamic> _formatWithImage(String assetKey) => {
      'formatId': 'f1',
      'name': 'Receipt',
      'ticketType': 'BILL',
      'version': 1,
      'widthMm': 80,
      'blocks': [
        {'id': 't', 'type': 'TEXT', 'text': 'CAFE'},
        {'id': 'i', 'type': 'IMAGE', 'assetKey': assetKey, 'maxHeightMm': 12},
      ],
    };

PrintJob _networkJob(List<String> lines, List<PrintableEntry> entries, {required int port}) => PrintJob(
      ticketType: 'BILL',
      lines: lines,
      entries: entries,
      printer: PrintPrinter(
        name: 'LAN',
        transport: 'NETWORK',
        host: '127.0.0.1',
        port: port,
        widthMm: 80,
        supportsRasterImage: true,
      ),
    );

void main() {
  late Directory dir;
  late MemoryMediaCacheStore store;
  final manifestUri = Uri.parse('https://srv.test/api/pos/media/manifest?tenantId=t1');
  final decoder = _FakeDecoder();

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('gundam-fmt-media-');
    store = MemoryMediaCacheStore();
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  MediaSync sync(MockClient client) => MediaSync(dir: dir, store: store, httpClient: client);

  test('manifest key == IMAGE block assetKey == the cached file', () async {
    final s = sync(_backend({'logo': _logoBytes}));
    await s.sync(manifestUri: manifestUri);

    // The renderer surfaces the block's assetKey verbatim — the ONE name the
    // cache was written under.
    final rendered = renderPrintFormat(
      format: PrintFormat.fromJson(_formatWithImage('logo')),
      ticketPayload: const {'tokens': <String, Object?>{}},
    );
    final imageEntries = rendered.entries.where((e) => e.kind == PrintableKind.image).toList();
    expect(imageEntries, hasLength(1));
    expect(imageEntries.single.assetKey, 'logo');

    // …and that same key resolves to the bytes the sync downloaded.
    expect(await s.bytesFor(imageEntries.single.assetKey!), _logoBytes);
  });

  test('a cached assetKey prints real GS v 0 bytes (no placeholder)', () async {
    final s = sync(_backend({'logo': _logoBytes}));
    await s.sync(manifestUri: manifestUri);

    final rendered = renderPrintFormat(
      format: PrintFormat.fromJson(_formatWithImage('logo')),
      ticketPayload: const {'tokens': <String, Object?>{}},
    );
    final result = await encodePrintJobWithImages(
      _networkJob(rendered.lines, rendered.entries, port: 9100),
      source: MediaSyncPrintImageSource(s),
      decoder: decoder,
    );

    expect(result.rasterImages, 1);
    expect(result.placeholderImages, 0);
    // GS v 0 at 80 mm → 72 bytes/row (576 dots). The block's 12 mm cap crops the
    // 4x2 source to 96 dots tall — the clamp is real, not ignored.
    expect(_indexOf(result.bytes, [0x1D, 0x76, 0x30, 0x00, 0x48, 0x00]), greaterThanOrEqualTo(0));
    expect(result.warnings.any((w) => w.contains('cropped')), isTrue);
    expect(_indexOf(result.bytes, '[IMAGE logo]'.codeUnits), -1);
  });

  test('an assetKey not in the cache prints an honest labelled placeholder', () async {
    final s = sync(_backend({'logo': _logoBytes}));
    await s.sync(manifestUri: manifestUri); // caches ONLY `logo`

    final rendered = renderPrintFormat(
      format: PrintFormat.fromJson(_formatWithImage('banner')), // never uploaded
      ticketPayload: const {'tokens': <String, Object?>{}},
    );
    final result = await encodePrintJobWithImages(
      _networkJob(rendered.lines, rendered.entries, port: 9100),
      source: MediaSyncPrintImageSource(s),
      decoder: decoder,
    );

    expect(result.placeholderImages, 1);
    expect(result.rasterImages, 0);
    expect(_indexOf(result.bytes, '[IMAGE banner]'.codeUnits), greaterThanOrEqualTo(0));
    expect(result.warnings.any((w) => w.contains('placeholder')), isTrue);
  });

  test('the LAN :9100 transport rasterises a cached image block end-to-end', () async {
    final s = sync(_backend({'logo': _logoBytes}));
    await s.sync(manifestUri: manifestUri);
    // Building the bridge registers it for the router-const LAN transport.
    final source = MediaSyncPrintImageSource(s);

    final rendered = renderPrintFormat(
      format: PrintFormat.fromJson(_formatWithImage('logo')),
      ticketPayload: const {'tokens': <String, Object?>{}},
    );

    // A real loopback printer socket: what the transport actually puts on the wire.
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final received = <int>[];
    final done = server.first.then((sock) async {
      await for (final chunk in sock) {
        received.addAll(chunk);
      }
    });

    await NetworkPrintTransport(imageSourceProvider: () => source).send(
      _networkJob(rendered.lines, rendered.entries, port: server.port),
    );
    await done;
    await server.close();

    expect(_indexOf(received, [0x1D, 0x76, 0x30, 0x00]), greaterThanOrEqualTo(0)); // GS v 0
    expect(_indexOf(received, '[IMAGE logo]'.codeUnits), -1); // NOT a placeholder
  });
}

/// Locate a byte sub-sequence; returns its start index or -1.
int _indexOf(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}
