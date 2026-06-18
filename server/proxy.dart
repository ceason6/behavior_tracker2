import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Minimal static-file + Anthropic proxy server for the ABC Behavior Tracker
/// web build. It serves the compiled Flutter web app AND forwards Messages API
/// requests to Anthropic, so the browser never hits a CORS wall (and, optionally,
/// never has to hold the API key).
///
/// Usage:
///   flutter build web
///   dart run server/proxy.dart
///   # open http://localhost:8787
///
/// Environment variables:
///   PORT                port to listen on (default 8787)
///   WEB_DIR             directory of the built web app (default build/web)
///   ANTHROPIC_API_KEY   server-side key. When set, the proxy ALWAYS uses it and
///                       ignores any client x-api-key, so a stale browser-cached
///                       key can't override it. A client x-api-key is used only as
///                       a fallback when this is unset (e.g. local dev).
///   APP_PASSWORD        optional staff password. When set, every request must
///                       pass HTTP Basic auth (browser shows a login prompt);
///                       any username, password must match. When unset, the app
///                       is open. The /healthz probe is always exempt.
/// Shared, persistent store of ABC log entries so the pilot's users all see the
/// same data. Entries are keyed by an `id` field; writes are serialized and
/// persisted atomically (write-temp-then-rename) to survive crashes/restarts.
class LogStore {
  final File _file;
  List<Map<String, dynamic>> _logs = [];
  // When the store was last wiped (ms since epoch). Entries whose id encodes a
  // save-time older than this are rejected, so a client that still has stale
  // data cached can't re-push it after a reset.
  int _clearedAt = 0;
  Future<void> _chain = Future<void>.value();

  LogStore(this._file);

  int get clearedAt => _clearedAt;

  Future<void> load() async {
    try {
      if (await _file.exists()) {
        final data = jsonDecode(await _file.readAsString());
        if (data is List) {
          // Legacy format: a bare list of entries.
          _logs = data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        } else if (data is Map) {
          _clearedAt = (data['clearedAt'] as num?)?.toInt() ?? 0;
          _logs = ((data['logs'] as List?) ?? [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        }
      }
    } catch (e) {
      stderr.writeln('LogStore load error: ${e.runtimeType}');
    }
  }

  List<Map<String, dynamic>> all() => _logs;

  // Save-time is the millisecond prefix of the entry id ("<ms>-<rand>").
  int _saveTimeOf(Map<String, dynamic> entry) =>
      int.tryParse('${entry['id']}'.split('-').first) ?? 0;

  Future<void> upsert(Map<String, dynamic> entry) {
    final id = entry['id'];
    if (id == null) return Future<void>.value();
    // Reject stale re-pushes of entries created before the last reset.
    if (_saveTimeOf(entry) < _clearedAt) return Future<void>.value();
    return _serialize(() async {
      final idx = _logs.indexWhere((e) => e['id'] == id);
      if (idx >= 0) {
        _logs[idx] = entry;
      } else {
        _logs.add(entry);
      }
      await _persist();
    });
  }

  Future<void> remove(String id) =>
      _serialize(() async {
        _logs.removeWhere((e) => e['id'] == id);
        await _persist();
      });

  // Wipe everything and stamp the reset time so stale re-pushes are blocked.
  Future<void> clear(int now) =>
      _serialize(() async {
        _logs = [];
        _clearedAt = now;
        await _persist();
      });

  Future<void> _persist() async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
        jsonEncode({'clearedAt': _clearedAt, 'logs': _logs}), flush: true);
    await tmp.rename(_file.path);
  }

  // Serialize all mutations so concurrent requests can't corrupt the file.
  Future<void> _serialize(Future<void> Function() op) {
    final next = _chain.then((_) => op());
    _chain = next.catchError((_) {});
    return next;
  }
}

/// Picks the first writable directory for persistent data: $DATA_DIR, then
/// /data (the Render disk), then ./data (local dev).
String _resolveDataDir() {
  final configured = Platform.environment['DATA_DIR'];
  for (final candidate in [configured, '/data', 'data']) {
    if (candidate == null || candidate.isEmpty) continue;
    try {
      Directory(candidate).createSync(recursive: true);
      final probe = File('$candidate/.write_test');
      probe.writeAsStringSync('ok');
      probe.deleteSync();
      return candidate;
    } catch (_) {
      // try the next candidate
    }
  }
  return 'data';
}

Future<void> main() async {
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8787;
  final webDir = Platform.environment['WEB_DIR'] ?? 'build/web';
  final serverKey = (Platform.environment['ANTHROPIC_API_KEY'] ?? '').trim();
  final appPassword = Platform.environment['APP_PASSWORD'];
  // When set, every request (except /healthz) must carry a matching
  // X-Origin-Auth header. Cloudflare injects it via a Transform Rule, so the
  // raw onrender.com URL (which lacks it) is blocked and only traffic that came
  // through Cloudflare Access reaches the app. Inert until set.
  final originSecret = (Platform.environment['ORIGIN_SHARED_SECRET'] ?? '').trim();

  final dataDir = _resolveDataDir();
  final store = LogStore(File('$dataDir/logs.json'));
  await store.load();

  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln('ABC Behavior Tracker proxy listening on http://localhost:$port');
  stdout.writeln('Serving web app from: $webDir');
  stdout.writeln('Shared log store: $dataDir/logs.json (${store.all().length} entries loaded).');
  if (serverKey.isNotEmpty) {
    final last4 = serverKey.length >= 4 ? serverKey.substring(serverKey.length - 4) : serverKey;
    stdout.writeln('Server-side key: using ANTHROPIC_API_KEY (ends ...$last4).');
  } else {
    stdout.writeln('WARNING: ANTHROPIC_API_KEY not set — AI calls will fail unless the client sends its own key.');
  }
  if (appPassword != null && appPassword.isNotEmpty) {
    stdout.writeln('Access gate: ON (APP_PASSWORD set — Basic auth required).');
  } else {
    stdout.writeln('WARNING: APP_PASSWORD not set — the app is OPEN unless ORIGIN_SHARED_SECRET is set.');
  }
  if (originSecret.isNotEmpty) {
    stdout.writeln('Origin lock: ON (requires X-Origin-Auth header — Cloudflare-only access).');
  }

  await for (final req in server) {
    try {
      _setCors(req.response);
      if (req.method == 'OPTIONS') {
        req.response.statusCode = HttpStatus.noContent;
        await req.response.close();
        continue;
      }
      // Unauthenticated health probe (so the access gate doesn't break Render's
      // health check).
      if (req.uri.path == '/healthz') {
        req.response.statusCode = HttpStatus.ok;
        req.response.write('ok');
        await req.response.close();
        continue;
      }
      // Origin lock: block anything that didn't come through Cloudflare (which
      // injects the secret header). This kills the raw onrender.com back door.
      if (originSecret.isNotEmpty) {
        final provided = req.headers.value('x-origin-auth');
        if (provided == null || !_constantTimeEquals(provided, originSecret)) {
          req.response.statusCode = HttpStatus.forbidden;
          req.response.write('Forbidden.');
          await req.response.close();
          continue;
        }
      }
      // Password gate (Basic auth) — applies to the app and the proxy alike.
      if (!_authorized(req, appPassword)) {
        req.response.statusCode = HttpStatus.unauthorized;
        req.response.headers.set(
          'WWW-Authenticate',
          'Basic realm="ABC Behavior Tracker", charset="UTF-8"',
        );
        req.response.write('Authentication required.');
        await req.response.close();
        continue;
      }
      if (req.method == 'POST' && req.uri.path == '/v1/messages') {
        await _proxyMessages(req, serverKey);
        continue;
      }
      if (req.uri.path == '/api/logs') {
        await _handleLogs(req, store);
        continue;
      }
      await _serveStatic(req, webDir);
    } catch (e, st) {
      // FERPA: never log or return the exception message or request body — they
      // can contain student data. Log only the error TYPE, path, and stack
      // frames (code locations, no data), and return a generic error.
      stderr.writeln('Request error on ${req.method} ${req.uri.path}: ${e.runtimeType}');
      stderr.writeln(st);
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        req.response.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
        req.response.add(utf8.encode(jsonEncode({
          'error': 'Internal server error',
          'errorType': e.runtimeType.toString(),
        })));
        await req.response.close();
      } catch (_) {
        // Response may already be (partly) committed; nothing more we can do.
      }
    }
  }
}

/// True if the request may proceed. When [password] is unset the gate is off.
/// Otherwise the request must carry HTTP Basic credentials whose password
/// matches (the username is ignored).
bool _authorized(HttpRequest req, String? password) {
  if (password == null || password.isEmpty) return true;
  final header = req.headers.value('authorization');
  if (header == null || !header.toLowerCase().startsWith('basic ')) return false;
  String decoded;
  try {
    decoded = utf8.decode(base64.decode(header.substring(6).trim()));
  } catch (_) {
    return false;
  }
  final sep = decoded.indexOf(':');
  final supplied = sep >= 0 ? decoded.substring(sep + 1) : decoded;
  return _constantTimeEquals(supplied, password);
}

/// Length-independent? No — but content-comparison is constant time for equal
/// lengths, which is enough to avoid leaking the password byte-by-byte.
bool _constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

void _setCors(HttpResponse res) {
  res.headers.set('Access-Control-Allow-Origin', '*');
  res.headers.set('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS');
  res.headers.set('Access-Control-Allow-Headers', 'Content-Type, x-api-key, anthropic-version');
}

/// Shared ABC-log API used to sync entries across the pilot's users.
///   GET    /api/logs        -> {"logs": [...]}
///   POST   /api/logs        -> upsert one entry (JSON body with an `id`)
///   DELETE /api/logs?id=ID  -> remove one entry
Future<void> _handleLogs(HttpRequest req, LogStore store) async {
  void writeJson(Object data) {
    req.response.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
    req.response.add(utf8.encode(jsonEncode(data)));
  }

  if (req.method == 'GET') {
    writeJson({'logs': store.all(), 'clearedAt': store.clearedAt});
    await req.response.close();
    return;
  }
  if (req.method == 'POST') {
    final raw = await utf8.decoder.bind(req).join();
    final entry = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    await store.upsert(entry);
    writeJson({'ok': true});
    await req.response.close();
    return;
  }
  if (req.method == 'DELETE') {
    final id = req.uri.queryParameters['id'];
    if (id != null) {
      await store.remove(id);
    } else {
      // No id => wipe everything (used by the in-app "Reset data" button).
      await store.clear(DateTime.now().millisecondsSinceEpoch);
    }
    writeJson({'ok': true});
    await req.response.close();
    return;
  }
  req.response.statusCode = HttpStatus.methodNotAllowed;
  await req.response.close();
}

Future<void> _proxyMessages(HttpRequest req, String serverKey) async {
  final body = await utf8.decoder.bind(req).join();
  // The server-side key always wins when set, so a stale browser-cached
  // x-api-key can never override it. Fall back to a client key only when no
  // server key is configured (e.g. local dev).
  final apiKey = serverKey.isNotEmpty ? serverKey : req.headers.value('x-api-key');
  final version = req.headers.value('anthropic-version') ?? '2023-06-01';

  final client = HttpClient();
  try {
    final upstream = await client.postUrl(Uri.parse('https://api.anthropic.com/v1/messages'));
    upstream.headers.set('Content-Type', 'application/json; charset=utf-8');
    upstream.headers.set('anthropic-version', version);
    if (apiKey != null) upstream.headers.set('x-api-key', apiKey);
    // Write UTF-8 bytes, not a String: IOSink.write defaults to Latin-1, which
    // throws on any character above code point 255 (e.g. curly quotes/emoji that
    // iOS smart punctuation inserts). Encoding to UTF-8 bytes handles all input.
    upstream.add(utf8.encode(body));
    final resp = await upstream.close();
    req.response.statusCode = resp.statusCode;
    // Disable dart:io's output buffering so each flushed chunk goes out
    // immediately rather than being aggregated.
    req.response.bufferOutput = false;
    // Preserve the upstream content type (text/event-stream when streaming, else
    // JSON) and discourage any intermediary from buffering the stream, so bytes
    // reach the browser continuously and the connection never goes idle.
    req.response.headers.contentType =
        resp.headers.contentType ?? ContentType('application', 'json', charset: 'utf-8');
    req.response.headers.set('Cache-Control', 'no-cache');
    req.response.headers.set('X-Accel-Buffering', 'no');
    // Forward each chunk and flush immediately. addStream() lets dart:io buffer
    // the whole response, which defeats streaming (the client would see one
    // burst at the end and an idle connection until then). Flushing per chunk
    // pushes each SSE event out as it arrives, keeping the connection active.
    await for (final chunk in resp) {
      req.response.add(chunk);
      await req.response.flush();
    }
    await req.response.close();
  } finally {
    client.close();
  }
}

Future<void> _serveStatic(HttpRequest req, String webDir) async {
  var path = req.uri.path;
  if (path == '/' || path.isEmpty) path = '/index.html';
  var file = File('$webDir$path');
  if (!await file.exists()) {
    // Single-page-app fallback to index.html.
    file = File('$webDir/index.html');
  }
  if (!await file.exists()) {
    req.response.statusCode = HttpStatus.notFound;
    req.response.write('Web build not found. Run `flutter build web` first.');
    await req.response.close();
    return;
  }
  // Never let the browser pin the app shell or the service worker, or a new
  // deploy won't reach users until they manually clear their cache. Forcing
  // revalidation on these two files lets the service worker pick up new builds.
  final fileName = path.substring(path.lastIndexOf('/') + 1);
  if (fileName.isEmpty || fileName == 'index.html' || fileName == 'flutter_service_worker.js') {
    req.response.headers.set('Cache-Control', 'no-cache, no-store, must-revalidate');
  }
  final ext = path.contains('.') ? path.substring(path.lastIndexOf('.')) : '';
  req.response.headers.contentType = _contentTypeFor(ext);
  await req.response.addStream(file.openRead());
  await req.response.close();
}

ContentType _contentTypeFor(String ext) {
  switch (ext) {
    case '.html':
      return ContentType.html;
    case '.js':
    case '.mjs':
      return ContentType('application', 'javascript', charset: 'utf-8');
    case '.json':
      return ContentType.json;
    case '.css':
      return ContentType('text', 'css', charset: 'utf-8');
    case '.png':
      return ContentType('image', 'png');
    case '.jpg':
    case '.jpeg':
      return ContentType('image', 'jpeg');
    case '.svg':
      return ContentType('image', 'svg+xml');
    case '.wasm':
      return ContentType('application', 'wasm');
    case '.ttf':
      return ContentType('font', 'ttf');
    case '.otf':
      return ContentType('font', 'otf');
    case '.woff':
      return ContentType('font', 'woff');
    case '.woff2':
      return ContentType('font', 'woff2');
    default:
      return ContentType.binary;
  }
}
