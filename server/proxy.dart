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
///   PORT                  port to listen on (default 8787)
///   WEB_DIR               directory of the built web app (default build/web)
///   ANTHROPIC_API_KEY     optional server-side key; used when the client request
///                         does not include an x-api-key header.
///   ANTHROPIC_API_KEY_FILE  optional path to a file containing the server-side
///                         key. Read fresh on every request, so rotating the key
///                         is as simple as overwriting this file — no restart
///                         needed (hot reload). Takes precedence over
///                         ANTHROPIC_API_KEY when the file exists and is non-empty.
Future<void> main() async {
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8787;
  final webDir = Platform.environment['WEB_DIR'] ?? 'build/web';
  final envKey = Platform.environment['ANTHROPIC_API_KEY'];
  final keyFile = Platform.environment['ANTHROPIC_API_KEY_FILE'];

  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln('ABC Behavior Tracker proxy listening on http://localhost:$port');
  stdout.writeln('Serving web app from: $webDir');
  if (keyFile != null && keyFile.isNotEmpty) {
    stdout.writeln('Server-side key: reading from $keyFile on each request (hot reload).');
  } else if (envKey != null && envKey.isNotEmpty) {
    stdout.writeln('Server-side key: using ANTHROPIC_API_KEY for unauthenticated requests.');
  }

  await for (final req in server) {
    try {
      _setCors(req.response);
      if (req.method == 'OPTIONS') {
        req.response.statusCode = HttpStatus.noContent;
        await req.response.close();
        continue;
      }
      if (req.method == 'POST' && req.uri.path == '/v1/messages') {
        await _proxyMessages(req, keyFile, envKey);
        continue;
      }
      await _serveStatic(req, webDir);
    } catch (e) {
      req.response.statusCode = HttpStatus.internalServerError;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'error': '$e'}));
      await req.response.close();
    }
  }
}

/// Resolves the server-side key fresh per request: the key file (if set and
/// readable) wins, otherwise the env var. Reading the file each call is what
/// makes key rotation zero-downtime — overwrite the file and the next request
/// uses the new key.
String? _serverKey(String? keyFile, String? envKey) {
  if (keyFile != null && keyFile.isNotEmpty) {
    try {
      final f = File(keyFile);
      if (f.existsSync()) {
        final v = f.readAsStringSync().trim();
        if (v.isNotEmpty) return v;
      }
    } catch (_) {
      // fall through to env key
    }
  }
  return (envKey != null && envKey.isNotEmpty) ? envKey : null;
}

void _setCors(HttpResponse res) {
  res.headers.set('Access-Control-Allow-Origin', '*');
  res.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.headers.set('Access-Control-Allow-Headers', 'Content-Type, x-api-key, anthropic-version');
}

Future<void> _proxyMessages(HttpRequest req, String? keyFile, String? envKey) async {
  final body = await utf8.decoder.bind(req).join();
  // Client-supplied key wins; otherwise resolve the server-side key fresh
  // (hot-reloaded from the key file) so rotations take effect without a restart.
  final apiKey = req.headers.value('x-api-key') ?? _serverKey(keyFile, envKey);
  final version = req.headers.value('anthropic-version') ?? '2023-06-01';

  final client = HttpClient();
  try {
    final upstream = await client.postUrl(Uri.parse('https://api.anthropic.com/v1/messages'));
    upstream.headers.set('Content-Type', 'application/json');
    upstream.headers.set('anthropic-version', version);
    if (apiKey != null) upstream.headers.set('x-api-key', apiKey);
    upstream.write(body);
    final resp = await upstream.close();
    final respBody = await utf8.decoder.bind(resp).join();
    req.response.statusCode = resp.statusCode;
    req.response.headers.contentType = ContentType.json;
    req.response.write(respBody);
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
