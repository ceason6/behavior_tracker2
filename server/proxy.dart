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
Future<void> main() async {
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8787;
  final webDir = Platform.environment['WEB_DIR'] ?? 'build/web';
  final serverKey = (Platform.environment['ANTHROPIC_API_KEY'] ?? '').trim();
  final appPassword = Platform.environment['APP_PASSWORD'];

  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln('ABC Behavior Tracker proxy listening on http://localhost:$port');
  stdout.writeln('Serving web app from: $webDir');
  if (serverKey.isNotEmpty) {
    final last4 = serverKey.length >= 4 ? serverKey.substring(serverKey.length - 4) : serverKey;
    stdout.writeln('Server-side key: using ANTHROPIC_API_KEY (ends ...$last4).');
  } else {
    stdout.writeln('WARNING: ANTHROPIC_API_KEY not set — AI calls will fail unless the client sends its own key.');
  }
  if (appPassword != null && appPassword.isNotEmpty) {
    stdout.writeln('Access gate: ON (APP_PASSWORD set — Basic auth required).');
  } else {
    stdout.writeln('WARNING: APP_PASSWORD not set — the app is OPEN. Set APP_PASSWORD to require a login.');
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
      await _serveStatic(req, webDir);
    } catch (e, st) {
      // Log the full error + stack to the server console (Render logs) and return
      // enough detail to diagnose from the client, too.
      stderr.writeln('Request error on ${req.method} ${req.uri.path}: $e');
      stderr.writeln(st);
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        req.response.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
        req.response.add(utf8.encode(jsonEncode({
          'error': '$e',
          'errorType': e.runtimeType.toString(),
          'where': st.toString().split('\n').take(4).join(' <- '),
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
  res.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.headers.set('Access-Control-Allow-Headers', 'Content-Type, x-api-key, anthropic-version');
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
    req.response.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
    // Pipe the upstream bytes straight through (no decode/re-encode round-trip).
    await req.response.addStream(resp);
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
