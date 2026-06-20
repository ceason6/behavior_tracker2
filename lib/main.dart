import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:fl_chart/fl_chart.dart';

import 'io_download.dart' if (dart.library.html) 'web_download.dart';

/// Two-digit zero-padded string for clock/date components.
String _two(int value) => value.toString().padLeft(2, '0');

/// Safe read of a string field from a persisted log entry. Returns '' when the
/// value is missing or not a string, so a malformed/legacy entry can't crash
/// the UI.
String _logStr(Map<String, dynamic> log, String key) {
  final value = log[key];
  return value is String ? value : '';
}

/// Safe parse of a log timestamp. Falls back to the epoch when the stored value
/// is missing or unparseable, so one bad entry can't take down a whole screen.
DateTime _logTimestamp(Map<String, dynamic> log) {
  final raw = log['timestamp'];
  if (raw is String) {
    return DateTime.tryParse(raw) ?? DateTime.fromMillisecondsSinceEpoch(0);
  }
  return DateTime.fromMillisecondsSinceEpoch(0);
}

String _dateKey(DateTime timestamp) {
  final local = timestamp.toLocal();
  return '${local.year}-${_two(local.month)}-${_two(local.day)}';
}

/// Time bucket granularities for the aggregate behavior charts.
enum TimeGranularity { daily, weekly, monthly, yearly }

extension TimeGranularityLabel on TimeGranularity {
  String get label {
    switch (this) {
      case TimeGranularity.daily:
        return 'Daily';
      case TimeGranularity.weekly:
        return 'Weekly';
      case TimeGranularity.monthly:
        return 'Monthly';
      case TimeGranularity.yearly:
        return 'Yearly';
    }
  }

  /// Singular noun used in summary captions, e.g. "Events per day".
  String get unit {
    switch (this) {
      case TimeGranularity.daily:
        return 'day';
      case TimeGranularity.weekly:
        return 'week';
      case TimeGranularity.monthly:
        return 'month';
      case TimeGranularity.yearly:
        return 'year';
    }
  }
}

/// Monday-anchored start of the week containing [d] (date-only).
DateTime _weekStart(DateTime d) {
  final dateOnly = DateTime(d.year, d.month, d.day);
  return dateOnly.subtract(Duration(days: dateOnly.weekday - 1));
}

/// A sortable bucket key for [timestamp] at the given [granularity].
/// Keys sort lexicographically into chronological order.
String _bucketKey(DateTime timestamp, TimeGranularity granularity) {
  final d = timestamp.toLocal();
  switch (granularity) {
    case TimeGranularity.daily:
      return '${d.year}-${_two(d.month)}-${_two(d.day)}';
    case TimeGranularity.weekly:
      final w = _weekStart(d);
      return '${w.year}-${_two(w.month)}-${_two(w.day)}';
    case TimeGranularity.monthly:
      return '${d.year}-${_two(d.month)}';
    case TimeGranularity.yearly:
      return '${d.year}';
  }
}

/// Short axis label for a [bucketKey] produced by [_bucketKey].
String _bucketLabel(String bucketKey, TimeGranularity granularity) {
  final parts = bucketKey.split('-');
  switch (granularity) {
    case TimeGranularity.daily:
      return '${parts[1]}/${parts[2]}';
    case TimeGranularity.weekly:
      return '${parts[1]}/${parts[2]}';
    case TimeGranularity.monthly:
      return '${parts[1]}/${parts[0].substring(2)}';
    case TimeGranularity.yearly:
      return parts[0];
  }
}

/// Resolves the Anthropic Messages endpoint.
///
/// - If built with `--dart-define=ANTHROPIC_PROXY=<url>`, calls `<url>/v1/messages`.
/// - On web (no override), calls the same-origin `/v1/messages` so a co-hosted
///   proxy (see server/proxy.dart) handles the request without CORS / key exposure.
/// - On mobile/desktop, calls the Anthropic API directly.
/// Bumped on each deploy so a loaded build is identifiable on-screen. If this
/// tag does NOT appear in an error message, the browser is running a stale
/// cached bundle (clear site data); if it DOES appear, the suffixed detail shows
/// the real underlying error.
const String kBuildTag = 'v38';

/// Master switch for the generative-AI features (FBA analysis + the "Generate
/// Description" helper). Turned OFF during the pilot so no student data is sent
/// to Anthropic until the FERPA data agreements are in place. Flip to true to
/// re-enable everywhere.
const bool kAiFeaturesEnabled = false;

/// Canonical school-period order (single source of truth for the dropdown and
/// for ordering period charts/tables chronologically through the day).
const List<String> kPeriodOrder = [
  'Bus a.m.', 'Advisory', 'First', 'Second', 'Third', 'Fourth', 'Lunch',
  'Fifth', 'Sixth', 'Seventh', 'Bus p.m.',
];

String _anthropicEndpoint() {
  const override = String.fromEnvironment('ANTHROPIC_PROXY');
  if (override.isNotEmpty) {
    return '${override.replaceAll(RegExp(r'/+$'), '')}/v1/messages';
  }
  if (kIsWeb) return '/v1/messages';
  return 'https://api.anthropic.com/v1/messages';
}

/// Endpoint for the shared ABC-log sync API (served by the same proxy).
String _logsEndpoint() {
  const override = String.fromEnvironment('ANTHROPIC_PROXY');
  if (override.isNotEmpty) {
    return '${override.replaceAll(RegExp(r'/+$'), '')}/api/logs';
  }
  if (kIsWeb) return '/api/logs';
  return 'http://localhost:8787/api/logs';
}

final Random _idRandom = Random();

/// A unique id for a log entry, stable across devices (timestamp + randomness).
/// Uses millisecondsSinceEpoch (microsecondsSinceEpoch throws on the web) and a
/// web-safe random bound (1<<32 misbehaves under JS bitwise ops).
String _generateLogId() =>
    '${DateTime.now().millisecondsSinceEpoch}-${_idRandom.nextInt(0x7fffffff)}';

/// Cached Unicode-capable theme for the PDF report. The pdf package's built-in
/// font only covers Latin-1, so even curly quotes, dashes and accents fail to
/// render. Noto Sans (base) handles all normal typography — Latin, Greek,
/// Cyrillic, punctuation, currency, symbols — and a monochrome emoji fallback
/// covers emoji cheaply (~1.5 MB total, fetched once per session). Non-Latin
/// scripts (CJK, Arabic, Hebrew, …) are intentionally not bundled to keep the
/// download light; they'd simply be omitted from the PDF, never crash it.
Future<pw.ThemeData>? _pdfUnicodeThemeFuture;

Future<pw.ThemeData> _pdfUnicodeTheme() {
  return _pdfUnicodeThemeFuture ??= () async {
    final base = await PdfGoogleFonts.notoSansRegular();
    final bold = await PdfGoogleFonts.notoSansBold();
    final italic = await PdfGoogleFonts.notoSansItalic();
    final boldItalic = await PdfGoogleFonts.notoSansBoldItalic();
    final emoji = await PdfGoogleFonts.notoEmojiRegular();
    return pw.ThemeData.withFont(
      base: base,
      bold: bold,
      italic: italic,
      boldItalic: boldItalic,
      fontFallback: [emoji],
    );
  }();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ABC Behavior Tracker',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const ABCLoggingScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class AnthropicClient {
  // Anthropic's most capable model; see https://platform.claude.com for options.
  static const String _model = 'claude-opus-4-8';

  static Future<String?> _message({
    required String apiKey,
    required String systemPrompt,
    required String userPrompt,
    required int maxTokens,
    bool thinking = false,
  }) async {
    final uri = Uri.parse(_anthropicEndpoint());
    final payload = <String, dynamic>{
      'model': _model,
      'max_tokens': maxTokens,
      'system': systemPrompt,
      'messages': [
        {'role': 'user', 'content': userPrompt},
      ],
      // Stream the response. A long non-streaming request leaves the connection
      // idle for tens of seconds, which mobile/edge networks drop ("Load
      // failed"). Streaming keeps bytes flowing so the connection stays alive.
      'stream': true,
      if (thinking) 'thinking': {'type': 'adaptive'},
    };

    final headers = {
      'content-type': 'application/json',
      'anthropic-version': '2023-06-01',
      // Only send a key if we have one. When empty (web), the same-origin
      // proxy injects the server-side key instead.
      if (apiKey.isNotEmpty) 'x-api-key': apiKey,
    };
    final bodyJson = jsonEncode(payload);

    // Anthropic occasionally returns a transient "Internal server error"
    // (api_error), more often on long requests with thinking. The official SDKs
    // retry these automatically; we do the same. Non-transient errors (auth,
    // billing, bad request) are thrown immediately.
    const maxAttempts = 4;
    for (var attempt = 1;; attempt++) {
      try {
        final response = await http.post(uri, headers: headers, body: bodyJson);
        if (response.statusCode != 200) {
          throw Exception('Anthropic API error: ${response.statusCode} ${response.body}');
        }
        // The body is UTF-8; decode from bytes (don't trust the content-type charset).
        final body = utf8.decode(response.bodyBytes);
        // Streaming responses are Server-Sent Events; a non-streaming response
        // is a single JSON object. Handle both so we work either way.
        if (body.contains('event:') || body.contains('data:')) {
          return _extractTextFromSse(body);
        }
        return _extractTextFromJson(body);
      } catch (e) {
        if (attempt >= maxAttempts || !_isTransientError('$e')) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 700 * attempt));
      }
    }
  }

  /// Transient, retryable failures: Anthropic 5xx / overloaded / internal
  /// server errors. Excludes auth (401), billing, and bad-request (400) errors.
  static bool _isTransientError(String error) {
    final m = error.toLowerCase();
    return m.contains('internal server error') ||
        m.contains('overloaded') ||
        m.contains('api_error') ||
        m.contains('error: 500') ||
        m.contains('error: 502') ||
        m.contains('error: 503') ||
        m.contains('error: 529');
  }

  /// Pulls the assistant text out of a non-streaming Messages response.
  static String? _extractTextFromJson(String body) {
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    final content = decoded['content'] as List<dynamic>?;
    if (content != null) {
      // Return the first text block (skipping any thinking blocks before it).
      for (final block in content) {
        if (block is Map && block['type'] == 'text') {
          return (block['text'] as String?)?.trim();
        }
      }
    }
    return null;
  }

  /// Concatenates the text deltas from a streamed (SSE) Messages response,
  /// ignoring thinking deltas. Throws on a mid-stream error event.
  static String? _extractTextFromSse(String body) {
    final buf = StringBuffer();
    for (final line in const LineSplitter().convert(body)) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data.isEmpty || data == '[DONE]') continue;
      Map<String, dynamic> obj;
      try {
        obj = jsonDecode(data) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      final type = obj['type'];
      if (type == 'content_block_delta') {
        final delta = obj['delta'];
        if (delta is Map && delta['type'] == 'text_delta') {
          buf.write(delta['text'] ?? '');
        }
      } else if (type == 'error') {
        throw Exception('Anthropic API error: ${jsonEncode(obj['error'])}');
      }
    }
    final text = buf.toString().trim();
    return text.isEmpty ? null : text;
  }

  /// Rewrites a single incident's notes into a concise clinical description.
  static Future<String?> generateDescription({required String apiKey, required String prompt}) {
    return _message(
      apiKey: apiKey,
      systemPrompt: 'You are a concise assistant that rewrites user notes into a neutral, clinical description.',
      userPrompt: prompt,
      maxTokens: 400,
    );
  }

  /// Analyzes a student's aggregated ABC data and returns a structured report.
  /// Uses adaptive thinking for higher-quality clinical reasoning.
  static Future<String?> generateAnalysis({
    required String apiKey,
    required String systemPrompt,
    required String userPrompt,
  }) {
    return _message(
      apiKey: apiKey,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      maxTokens: 4000,
      thinking: true,
    );
  }
}

class ABCLoggingScreen extends StatefulWidget {
  const ABCLoggingScreen({super.key});

  @override
  State<ABCLoggingScreen> createState() => _ABCLoggingScreenState();
}

class _ABCLoggingScreenState extends State<ABCLoggingScreen> {
  final _formKey = GlobalKey<FormState>();

  // Bumped on every reset so the dropdown form fields are rebuilt from scratch.
  // DropdownButtonFormField only honors `initialValue` when it is first created
  // (or on FormState.reset(), which fires before we null the selections), so a
  // changing key is what actually clears the dropdowns after a save.
  int _formResetKey = 0;

  String? selectedStudent;
  String? selectedPeriod;
  String? selectedAntecedent;
  String? selectedBehavior;
  String? selectedConsequence;
  String? selectedProactiveStrategy;
  String? selectedStaff;

  final antecedentDescController = TextEditingController();
  final behaviorDescController = TextEditingController();
  final consequenceDescController = TextEditingController();

  final antecedentFocusNode = FocusNode();
  final behaviorFocusNode = FocusNode();
  final consequenceFocusNode = FocusNode();

  final SpeechToText _speech = SpeechToText();
  bool _speechEnabled = false;
  bool _isListening = false;
  TextEditingController? _activeController;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  Map<String, dynamic>? _lastAiMeta;

  List<Map<String, dynamic>> _savedLogs = [];
  DateTime selectedDateTime = DateTime.now();
  Timer? _syncTimer;
  // Destructive controls (Clear all data) show only when the app is opened with
  // ?admin=1, so the staff users can't wipe the shared data — only the
  // coordinator, who uses the admin URL.
  final bool _adminMode = Uri.base.queryParameters['admin'] == '1';

  final List<String> students = ["CH", "EG", "IS", "LTG", "NR"];
  final List<String> periods = kPeriodOrder;
  final List<String> antecedents = ["Given demand", "Told to wait", "Given corrective feedback", "Activity transition", "Unexpected change", "Divided attention", "Presence of a specific person", "Left alone", "Activity denied", "Activity interrupted", "Redirection"];
  final List<String> behaviors = ["Verbal aggression", "Threat", "Physical aggression", "Not in designated area", "Leaving building/campus", "Property destruction", "Property misuse", "Stealing", "Sleeping"];
  final List<String> consequences = ["Verbal redirection", "Behavior ignored", "Removed from activity", "Removed item", "Reprimand", "Left alone", "Blocked", "Sent to take a break", "Given another activity", "Given preferred item", "Peer remarks", "Being followed by staff"];
  final List<String> staffMembers = ["CE", "GQ", "KM", "KR", "MM", "RC"];
  final List<String> proactiveStrategies = [
    "Countdown Before Transitions",
    "None",
    "Offer Choices",
    "Other",
    "Positive Interaction",
    "Proactive Brief Break",
    "Provide Neutral Positive Interaction",
    "Reduce Unstructured Time",
    "Self-Monitoring Check-In",
    "Teach Expected Behavior",
    "Timed Work Intervals",
    "Transition Support",
    "Use of Clear Expectations",
  ];

  @override
  void initState() {
    super.initState();
    _initSpeech();
    // Load the local cache first (instant), then sync the shared data and poll
    // so entries from all pilot users stay in sync.
    _loadSavedLogs().then((_) => _syncFromServer());
    _syncTimer = Timer.periodic(const Duration(seconds: 15), (_) => _syncFromServer());
  }

  Future<String?> _getStoredApiKey() async {
    try {
      return await _secureStorage.read(key: 'anthropic_api_key');
    } catch (_) {
      return null;
    }
  }

  Future<void> _storeApiKey(String key) async {
    await _secureStorage.write(key: 'anthropic_api_key', value: key.trim());
  }

  Future<void> _promptForApiKey() async {
    final controller = TextEditingController();
    final existing = await _getStoredApiKey();
    if (existing != null) controller.text = existing;

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Anthropic API Key'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(hintText: 'sk-ant-...'),
            obscureText: true,
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                await _storeApiKey(controller.text);
                if (!dialogContext.mounted) return;
                Navigator.of(dialogContext).pop();
                ScaffoldMessenger.of(dialogContext).showSnackBar(const SnackBar(content: Text('API key saved')));
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    controller.dispose();
  }

  Future<void> _generateDescription() async {
    // On web the same-origin proxy supplies the server-side key; never send a
    // per-user/browser key (it would override the server key at the proxy).
    final apiKey = kIsWeb ? '' : (await _getStoredApiKey() ?? '');
    if (!kIsWeb && apiKey.isEmpty) {
      await _promptForApiKey();
      return;
    }

    final ante = antecedentDescController.text.trim();
    final beh = behaviorDescController.text.trim();
    final cons = consequenceDescController.text.trim();

    if (ante.isEmpty && beh.isEmpty && cons.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter some notes before generating a description.')),
      );
      return;
    }

    final buffer = StringBuffer();
    if (ante.isNotEmpty) buffer.writeln('Antecedent: $ante');
    if (beh.isNotEmpty) buffer.writeln('Behavior: $beh');
    if (cons.isNotEmpty) buffer.writeln('Consequence: $cons');

    final prompt = '''You are an assistant that rewrites incident notes into a concise, neutral, clinical description suitable for an ABC behavior log. Use no more than two sentences. Preserve factual content only.

${buffer.toString()}''';

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Generating description…')));

    String? generated;
    try {
      generated = await AnthropicClient.generateDescription(apiKey: apiKey, prompt: prompt);
    } catch (e) {
      if (!mounted) return;
      final msg = '$e'.toLowerCase();
      final isAuth = msg.contains('401') ||
          msg.contains('authentication_error') ||
          msg.contains('invalid x-api-key') ||
          msg.contains('invalid_api_key') ||
          msg.contains('incorrect api key') ||
          msg.contains('invalid authentication');
      final isBilling = msg.contains('credit balance') || msg.contains('plans & billing');
      if (isAuth) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid Anthropic API key — please update it.')),
        );
        await _promptForApiKey();
      } else if (isBilling) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Anthropic account out of credits — add credits at console.anthropic.com.')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('AI generation failed: $e')));
      }
      return;
    }

    if (!mounted) return;
    if (generated == null || generated.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No response from AI')));
      return;
    }

    // Don't silently overwrite the user's notes: show the result and let them
    // explicitly choose to apply it to the Behavior description.
    final description = generated;
    final apply = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('AI-generated description'),
          content: SingleChildScrollView(child: Text(description)),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Discard')),
            ElevatedButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Use for Behavior'),
            ),
          ],
        );
      },
    );

    if (apply == true && mounted) {
      setState(() {
        behaviorDescController.text = description;
        _lastAiMeta = {
          'generated': true,
          'model': 'claude-opus-4-8',
          'timestamp': DateTime.now().toIso8601String(),
        };
      });
    }
  }

  Future<void> _initSpeech() async {
    try {
      _speechEnabled = await _speech.initialize(
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
            if (mounted) setState(() => _isListening = false);
          }
        },
        onError: (errorNotification) {
          if (mounted) setState(() => _isListening = false);
        },
      );
    } catch (error) {
      // Voice input may be unavailable on some platforms (e.g. desktop);
      // the app stays fully usable without it.
      _speechEnabled = false;
      debugPrint('Speech recognition unavailable: $error');
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadSavedLogs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawLogs = prefs.getStringList('behavior_logs') ?? <String>[];
      final parsed = <Map<String, dynamic>>[];
      for (final jsonEntry in rawLogs) {
        // Decode each entry independently so a single corrupt record doesn't
        // wipe out access to every other saved log.
        try {
          final entry = Map<String, dynamic>.from(jsonDecode(jsonEntry) as Map<String, dynamic>);
          // Legacy entries (pre-sync) have no id; give them one so they sync.
          entry['id'] ??= _generateLogId();
          parsed.add(entry);
        } catch (error) {
          debugPrint('Warning: skipping unreadable log entry: $error');
        }
      }
      if (!mounted) return;
      setState(() {
        _savedLogs = parsed;
      });
    } catch (error) {
      // Shared preferences may not be available immediately on hot restart.
      if (!mounted) return;
      debugPrint('Warning: unable to load saved logs: $error');
    }
  }

  Future<void> _persistSavedLogs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encodedLogs = _savedLogs.map((entry) => jsonEncode(entry)).toList();
      await prefs.setStringList('behavior_logs', encodedLogs);
    } catch (error) {
      debugPrint('Warning: unable to persist saved logs: $error');
    }
  }

  /// Pulls the shared log list from the server and merges it with local data.
  /// The server is authoritative; any local-only entries (not yet accepted by
  /// the server, e.g. saved while offline) are kept and re-pushed.
  Future<void> _syncFromServer() async {
    try {
      final resp = await http.get(Uri.parse(_logsEndpoint()));
      if (resp.statusCode != 200) return;
      final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final serverLogs = (data['logs'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final serverIds = serverLogs.map((e) => e['id']).toSet();
      final clearedAt = (data['clearedAt'] as num?)?.toInt() ?? 0;
      // Save-time is the millisecond prefix of the id ("<ms>-<rand>").
      int saveTimeOf(Map<String, dynamic> e) =>
          int.tryParse('${e['id']}'.split('-').first) ?? 0;
      // Keep local-only entries to re-push — but drop any created before the
      // last reset, so a wipe sticks instead of being resurrected from cache.
      final localOnly = _savedLogs
          .where((e) =>
              e['id'] != null &&
              !serverIds.contains(e['id']) &&
              saveTimeOf(e) >= clearedAt)
          .toList();
      if (!mounted) return;
      setState(() {
        _savedLogs = [...serverLogs, ...localOnly];
      });
      await _persistSavedLogs();
      // Retry any entries the server hasn't recorded yet.
      for (final entry in localOnly) {
        _pushEntry(entry);
      }
    } catch (_) {
      // Offline or transient — keep showing the local cache; next tick retries.
    }
  }

  /// Sends one entry to the shared store. Silently no-ops on failure; the next
  /// sync tick will retry it (the entry stays in the local cache meanwhile).
  Future<void> _pushEntry(Map<String, dynamic> entry) async {
    try {
      await http.post(
        Uri.parse(_logsEndpoint()),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(entry),
      );
    } catch (_) {
      // Ignore; _syncFromServer retries unsynced entries.
    }
  }

  /// Wipes ALL shared data (server + this device) after confirmation. The server
  /// records the reset time so other devices' cached entries can't re-push.
  Future<void> _resetAllData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear ALL data?'),
        content: const Text(
            'This permanently deletes every logged event for ALL users. '
            'Use it to start a fresh pilot. This cannot be undone.\n\n'
            'Tip: export a CSV backup first.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete everything'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final resp = await http.delete(Uri.parse(_logsEndpoint()));
      if (resp.statusCode != 200) {
        throw Exception('server returned ${resp.statusCode}');
      }
      if (!mounted) return;
      setState(() => _savedLogs = []);
      await _persistSavedLogs();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All data cleared.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not clear data: $e')),
      );
    }
  }

  /// Generates a batch of realistic DUMMY events (admin/testing only) spread
  /// across students, periods, behaviors and the last few weeks, then pushes
  /// them to the shared store. Use "Clear all data" before the real pilot.
  Future<void> _loadSampleData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Load sample data?'),
        content: const Text(
            'Adds ~60 fake events (for testing the dashboard). They sync to the '
            'shared store like real entries.\n\nRemember to use "Clear all data" '
            'before the real pilot starts.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add sample data')),
        ],
      ),
    );
    if (confirmed != true) return;
    final rng = Random();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final now = DateTime.now();
    String pick(List<String> l) => l[rng.nextInt(l.length)];
    final generated = <Map<String, dynamic>>[];
    for (var i = 0; i < 60; i++) {
      var day = now.subtract(Duration(days: rng.nextInt(21)));
      // Bias toward weekdays (school days).
      if (day.weekday > 5) day = day.subtract(Duration(days: day.weekday - 5));
      final ts = DateTime(day.year, day.month, day.day, 8 + rng.nextInt(8), rng.nextInt(60));
      generated.add({
        'id': '${nowMs + i}-${rng.nextInt(0x7fffffff)}',
        'student': pick(students),
        'period': pick(periods),
        'antecedent': pick(antecedents),
        'antecedentDescription': '',
        'behavior': pick(behaviors),
        'behaviorDescription': '',
        'consequence': pick(consequences),
        'consequenceDescription': '',
        'proactiveStrategy': pick(proactiveStrategies),
        'staff': pick(staffMembers),
        'timestamp': ts.toIso8601String(),
        'ai': <String, dynamic>{},
      });
    }
    setState(() => _savedLogs.insertAll(0, generated));
    await _persistSavedLogs();
    for (final e in generated) {
      _pushEntry(e);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Added ${generated.length} sample events.')),
    );
  }

  /// Pulls the latest shared data, then downloads all entries as a CSV file.
  Future<void> _exportData() async {
    await _syncFromServer();
    final logs = _sortedLogs();
    if (logs.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No data to export yet.')),
      );
      return;
    }
    final csv = _logsToCsv(logs);
    final n = DateTime.now();
    final stamp = '${n.year}${_two(n.month)}${_two(n.day)}_${_two(n.hour)}${_two(n.minute)}';
    final filename = 'abc_tracker_export_$stamp.csv';
    if (kIsWeb) {
      downloadTextFile(filename, csv, 'text/csv;charset=utf-8');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Exported ${logs.length} entries to $filename')),
      );
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Export is available in the web app.')),
      );
    }
  }

  static const List<String> _csvColumns = [
    'timestamp', 'student', 'period',
    'antecedent', 'antecedentDescription',
    'behavior', 'behaviorDescription',
    'consequence', 'consequenceDescription',
    'proactiveStrategy', 'staff', 'id',
  ];

  String _logsToCsv(List<Map<String, dynamic>> logs) {
    String cell(String v) {
      final escaped = v.replaceAll('"', '""');
      return RegExp('[",\n\r]').hasMatch(v) ? '"$escaped"' : escaped;
    }
    // Leading BOM so Excel reads the UTF-8 (curly quotes, accents) correctly.
    final sb = StringBuffer('﻿');
    sb.writeln(_csvColumns.map(cell).join(','));
    for (final log in logs) {
      sb.writeln(_csvColumns.map((c) => cell('${log[c] ?? ''}')).join(','));
    }
    return sb.toString();
  }

  Map<String, dynamic> _buildLogEntry() {
    return {
      'id': _generateLogId(),
      'student': selectedStudent ?? '',
      'period': selectedPeriod ?? '',
      'antecedent': selectedAntecedent ?? '',
      'antecedentDescription': antecedentDescController.text,
      'behavior': selectedBehavior ?? '',
      'behaviorDescription': behaviorDescController.text,
      'consequence': selectedConsequence ?? '',
      'consequenceDescription': consequenceDescController.text,
      'proactiveStrategy': selectedProactiveStrategy ?? '',
      'staff': selectedStaff ?? '',
      'timestamp': selectedDateTime.toIso8601String(),
      'ai': _lastAiMeta ?? {},
    };
  }

  String _formatDateTime(DateTime dateTime) {
    final local = dateTime.toLocal();
    return '${local.year}-${_two(local.month)}-${_two(local.day)} '
        '${_two(local.hour)}:${_two(local.minute)}';
  }

  List<Map<String, dynamic>> _sortedLogs([List<Map<String, dynamic>>? logs]) {
    final entries = (logs ?? _savedLogs).toList();
    entries.sort((a, b) => _logTimestamp(b).compareTo(_logTimestamp(a)));
    return entries;
  }

  List<Map<String, dynamic>> _studentLogs(String student) {
    return _sortedLogs(_savedLogs.where((log) => log['student'] == student).toList());
  }

  Future<void> _openHistoryScreen() async {
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (context) => HistoryScreen(allLogs: _sortedLogs()),
    ));
  }

  Future<void> _openSchoolDashboard() async {
    String? apiKey;
    // Only needed for the (currently hidden) AI analysis on mobile/desktop.
    if (!kIsWeb) {
      try {
        apiKey = await _secureStorage.read(key: 'anthropic_api_key');
      } catch (_) {}
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (context) => SchoolDashboardScreen(
        allLogs: List.of(_savedLogs),
        apiKey: apiKey ?? '',
        periodOrder: periods,
      ),
    ));
  }

  Future<void> _openStudentHistoryScreen(String student) async {
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (context) => StudentHistoryScreen(
        student: student,
        studentLogs: _studentLogs(student),
      ),
    ));
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    if (_activeController == null) return;
    setState(() {
      _activeController!.text = result.recognizedWords;
      _activeController!.selection = TextSelection.fromPosition(
        TextPosition(offset: _activeController!.text.length),
      );
    });
    if (result.finalResult) {
      setState(() {
        _isListening = false;
      });
    }
  }

  Future<void> _startListening(TextEditingController controller) async {
    if (!_speechEnabled) {
      await _initSpeech();
      if (!mounted) return;
      if (!_speechEnabled) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Voice input unavailable')),
        );
        return;
      }
    }
    if (_isListening && _activeController == controller) {
      await _speech.stop();
      setState(() {
        _isListening = false;
      });
      return;
    }
    _activeController = controller;
    await _speech.listen(
      onResult: _onSpeechResult,
      listenOptions: SpeechListenOptions(listenFor: const Duration(seconds: 30)),
    );
    setState(() {
      _isListening = true;
    });
  }

  Future<void> _pickDateTime() async {
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: selectedDateTime,
      firstDate: DateTime(2024),
      lastDate: DateTime(2027),
    );
    if (pickedDate == null || !mounted) return;
    final TimeOfDay? pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(selectedDateTime),
    );
    if (pickedTime != null) {
      setState(() {
        selectedDateTime = DateTime(
          pickedDate.year,
          pickedDate.month,
          pickedDate.day,
          pickedTime.hour,
          pickedTime.minute,
        );
      });
    }
  }

  void _resetForm() {
    _formKey.currentState?.reset();
    setState(() {
      _formResetKey++;
      selectedStudent = null;
      selectedPeriod = null;
      selectedAntecedent = null;
      selectedBehavior = null;
      selectedConsequence = null;
      selectedProactiveStrategy = null;
      selectedStaff = null;
      antecedentDescController.clear();
      behaviorDescController.clear();
      consequenceDescController.clear();
      selectedDateTime = DateTime.now();
      _lastAiMeta = null;
    });
  }

  Future<void> _saveLog() async {
    if (!_formKey.currentState!.validate()) return;
    try {
      final logEntry = _buildLogEntry();
      setState(() {
        _savedLogs.insert(0, logEntry);
      });
      await _persistSavedLogs();
      // Push to the shared store so the other pilot users see it.
      _pushEntry(logEntry);
      if (!mounted) return;

      // Clear the form automatically so it's ready for the next entry.
      _resetForm();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ ABC Event Saved!')),
      );
    } catch (e) {
      // Never fail silently — surface the problem so it can't look like a no-op.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save the event: $e')),
      );
    }
  }

  /// Builds a microphone toggle that reflects whether this field is actively
  /// being dictated into.
  Widget _micButton(TextEditingController controller) {
    final active = _isListening && _activeController == controller;
    return IconButton(
      icon: Icon(active ? Icons.mic : Icons.mic_none),
      color: active ? Colors.red : null,
      tooltip: active ? 'Stop dictation' : 'Dictate',
      onPressed: () => _startListening(controller),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sectionHeadingStyle = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w700,
      color: Colors.grey[900],
    );

    return Scaffold(
      appBar: AppBar(
        title: Text('New ABC Behavior Log  ($kBuildTag)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.insights),
            tooltip: 'School dashboard',
            onPressed: _savedLogs.isNotEmpty ? _openSchoolDashboard : null,
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'History',
            onPressed: _savedLogs.isNotEmpty ? _openHistoryScreen : null,
          ),
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Export all data (CSV)',
            onPressed: _exportData,
          ),
          if (_adminMode)
            IconButton(
              icon: const Icon(Icons.science),
              tooltip: 'Load sample data (testing)',
              onPressed: _loadSampleData,
            ),
          if (_adminMode)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Clear all data (start fresh)',
              onPressed: _resetAllData,
            ),
          if (kAiFeaturesEnabled)
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: 'Generative AI settings',
              onPressed: _promptForApiKey,
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Student", style: sectionHeadingStyle),
              DropdownButtonFormField<String>(
                key: ValueKey('student-$_formResetKey'),
                initialValue: selectedStudent,
                hint: const Text("Select Student"),
                items: students.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                onChanged: (v) => setState(() => selectedStudent = v),
                validator: (v) => v == null ? "Required" : null,
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: OutlinedButton(
                  onPressed: selectedStudent != null && _studentLogs(selectedStudent!).isNotEmpty
                      ? () => _openStudentHistoryScreen(selectedStudent!)
                      : null,
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: theme.colorScheme.primary),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('View Past Logs'),
                ),
              ),
              const SizedBox(height: 16),

              Text("Date & time", style: sectionHeadingStyle),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.event),
                  label: Text(_formatDateTime(selectedDateTime)),
                  onPressed: _pickDateTime,
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: theme.colorScheme.primary),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              Text("School Period", style: sectionHeadingStyle),
              DropdownButtonFormField<String>(
                key: ValueKey('period-$_formResetKey'),
                initialValue: selectedPeriod,
                hint: const Text("Select Period"),
                items: periods.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
                onChanged: (v) => setState(() => selectedPeriod = v),
                validator: (v) => v == null ? "Required" : null,
              ),
              const SizedBox(height: 24),

              Text("Antecedent", style: sectionHeadingStyle),
              DropdownButtonFormField<String>(
                key: ValueKey('antecedent-$_formResetKey'),
                initialValue: selectedAntecedent,
                hint: const Text("What happened before?"),
                items: antecedents.map((a) => DropdownMenuItem(value: a, child: Text(a))).toList(),
                onChanged: (v) => setState(() => selectedAntecedent = v),
              ),
              TextFormField(
                controller: antecedentDescController,
                focusNode: antecedentFocusNode,
                decoration: InputDecoration(
                  labelText: "Description",
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.keyboard_alt),
                        onPressed: () => antecedentFocusNode.requestFocus(),
                      ),
                      _micButton(antecedentDescController),
                    ],
                  ),
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 24),

              Text("Behavior", style: sectionHeadingStyle),
              DropdownButtonFormField<String>(
                key: ValueKey('behavior-$_formResetKey'),
                initialValue: selectedBehavior,
                hint: const Text("What did the student do?"),
                items: behaviors.map((b) => DropdownMenuItem(value: b, child: Text(b))).toList(),
                onChanged: (v) => setState(() => selectedBehavior = v),
                validator: (v) => v == null ? "Required" : null,
              ),
              TextFormField(
                controller: behaviorDescController,
                focusNode: behaviorFocusNode,
                decoration: InputDecoration(
                  labelText: "Description",
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.keyboard_alt),
                        onPressed: () => behaviorFocusNode.requestFocus(),
                      ),
                      _micButton(behaviorDescController),
                    ],
                  ),
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 24),

              Text("Consequence", style: sectionHeadingStyle),
              DropdownButtonFormField<String>(
                key: ValueKey('consequence-$_formResetKey'),
                initialValue: selectedConsequence,
                hint: const Text("What happened after?"),
                items: consequences.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                onChanged: (v) => setState(() => selectedConsequence = v),
              ),
              TextFormField(
                controller: consequenceDescController,
                focusNode: consequenceFocusNode,
                decoration: InputDecoration(
                  labelText: "Description",
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.keyboard_alt),
                        onPressed: () => consequenceFocusNode.requestFocus(),
                      ),
                      _micButton(consequenceDescController),
                    ],
                  ),
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 24),

              Text("Proactive Strategies", style: sectionHeadingStyle),
              DropdownButtonFormField<String>(
                key: ValueKey('proactive-$_formResetKey'),
                initialValue: selectedProactiveStrategy,
                isExpanded: true,
                hint: const Text("Select a proactive strategy"),
                items: proactiveStrategies
                    .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                    .toList(),
                onChanged: (v) => setState(() => selectedProactiveStrategy = v),
              ),
              const SizedBox(height: 24),
              Text("Logged by", style: sectionHeadingStyle),
              DropdownButtonFormField<String>(
                key: ValueKey('staff-$_formResetKey'),
                initialValue: selectedStaff,
                hint: const Text("Select Staff"),
                items: staffMembers.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                onChanged: (v) => setState(() => selectedStaff = v),
              ),
              const SizedBox(height: 32),

              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _saveLog,
                  child: const Text("Save ABC Event"),
                ),
              ),
              if (kAiFeaturesEnabled) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.smart_toy),
                    label: const Text('Generate Description (AI)'),
                    onPressed: _generateDescription,
                  ),
                ),
              ],
              if (_savedLogs.isNotEmpty) ...[
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 16),
                Text(
                  'Saved behavior logs',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: Colors.grey[900]),
                ),
                const SizedBox(height: 12),
                ..._savedLogs.map((log) {
                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${_logStr(log, 'student')} • ${_logStr(log, 'behavior')}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 4),
                          Text('When: ${_formatDateTime(_logTimestamp(log))}'),
                          if (_logStr(log, 'antecedentDescription').isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text('Antecedent: ${_logStr(log, 'antecedentDescription')}'),
                          ],
                          if (_logStr(log, 'behaviorDescription').isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text('Behavior: ${_logStr(log, 'behaviorDescription')}'),
                          ],
                          if (_logStr(log, 'consequenceDescription').isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text('Consequence: ${_logStr(log, 'consequenceDescription')}'),
                          ],
                          if (_logStr(log, 'proactiveStrategy').isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text('Proactive strategy: ${_logStr(log, 'proactiveStrategy')}'),
                          ],
                          if (_logStr(log, 'staff').isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text('Logged by: ${_logStr(log, 'staff')}'),
                          ],
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _speech.stop();
    antecedentDescController.dispose();
    behaviorDescController.dispose();
    consequenceDescController.dispose();
    antecedentFocusNode.dispose();
    behaviorFocusNode.dispose();
    consequenceFocusNode.dispose();
    super.dispose();
  }
}

class HistoryScreen extends StatelessWidget {
  final List<Map<String, dynamic>> allLogs;

  const HistoryScreen({super.key, required this.allLogs});

  Map<String, List<Map<String, dynamic>>> _groupLogsByDate() {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final log in allLogs) {
      final key = _dateKey(_logTimestamp(log));
      grouped.putIfAbsent(key, () => []).add(log);
    }
    return grouped;
  }

  String _formatTime(Map<String, dynamic> log) {
    final date = _logTimestamp(log).toLocal();
    return '${_two(date.hour)}:${_two(date.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _groupLogsByDate();
    final dates = grouped.keys.toList()..sort((a, b) => b.compareTo(a));

    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: allLogs.isEmpty
          ? const Center(child: Text('No saved events yet.'))
          : ListView(
              padding: const EdgeInsets.all(16.0),
              children: dates.expand((date) {
                final logsForDate = grouped[date]!;
                return [
                  Text(date, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  ...logsForDate.map((log) {
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${_logStr(log, 'student')} • ${_logStr(log, 'behavior')}', style: const TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            Text('Time: ${_formatTime(log)}'),
                            if (_logStr(log, 'antecedentDescription').isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text('Antecedent: ${_logStr(log, 'antecedentDescription')}'),
                            ],
                            if (_logStr(log, 'behaviorDescription').isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text('Behavior: ${_logStr(log, 'behaviorDescription')}'),
                            ],
                            if (_logStr(log, 'consequenceDescription').isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text('Consequence: ${_logStr(log, 'consequenceDescription')}'),
                            ],
                            if (_logStr(log, 'proactiveStrategy').isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text('Proactive strategy: ${_logStr(log, 'proactiveStrategy')}'),
                            ],
                            if (_logStr(log, 'staff').isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text('Logged by: ${_logStr(log, 'staff')}'),
                            ],
                          ],
                        ),
                      ),
                    );
                  }),
                  const SizedBox(height: 18),
                ];
              }).toList(),
            ),
    );
  }
}

class StudentHistoryScreen extends StatefulWidget {
  final String student;
  final List<Map<String, dynamic>> studentLogs;

  const StudentHistoryScreen({super.key, required this.student, required this.studentLogs});

  @override
  State<StudentHistoryScreen> createState() => _StudentHistoryScreenState();
}

class _StudentHistoryScreenState extends State<StudentHistoryScreen> {
  TimeGranularity _granularity = TimeGranularity.daily;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  String get student => widget.student;
  List<Map<String, dynamic>> get studentLogs => widget.studentLogs;

  String _formatDateTime(Map<String, dynamic> log) {
    final date = _logTimestamp(log).toLocal();
    return '${date.year}-${_two(date.month)}-${_two(date.day)} '
        '${_two(date.hour)}:${_two(date.minute)}';
  }

  Map<String, List<Map<String, dynamic>>> _groupLogsByDate() {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final log in studentLogs) {
      final key = _dateKey(_logTimestamp(log));
      grouped.putIfAbsent(key, () => []).add(log);
    }
    return grouped;
  }

  Map<String, Map<String, int>> _buildFrequencyByDate() {
    final frequency = <String, Map<String, int>>{};
    for (final log in studentLogs) {
      final dateKey = _dateKey(_logTimestamp(log));
      final rawBehavior = _logStr(log, 'behavior');
      final behavior = rawBehavior.isNotEmpty ? rawBehavior : 'Unspecified';
      frequency.putIfAbsent(dateKey, () => <String, int>{});
      frequency[dateKey]![behavior] = (frequency[dateKey]![behavior] ?? 0) + 1;
    }
    return frequency;
  }

  Map<String, int> _buildOverallFrequency() {
    final overall = <String, int>{};
    for (final log in studentLogs) {
      final rawBehavior = _logStr(log, 'behavior');
      final behavior = rawBehavior.isNotEmpty ? rawBehavior : 'Unspecified';
      overall[behavior] = (overall[behavior] ?? 0) + 1;
    }
    return overall;
  }

  Map<String, int> _buildFrequencyByPeriod() {
    final frequency = <String, int>{};
    for (final log in studentLogs) {
      final rawPeriod = _logStr(log, 'period');
      final period = rawPeriod.isNotEmpty ? rawPeriod : 'Unspecified';
      frequency[period] = (frequency[period] ?? 0) + 1;
    }
    return frequency;
  }

  /// Counts how often each proactive strategy was used. Logs without a recorded
  /// strategy are not counted.
  Map<String, int> _buildProactiveStrategyFrequency() {
    final frequency = <String, int>{};
    for (final log in studentLogs) {
      final strategy = _logStr(log, 'proactiveStrategy');
      if (strategy.isEmpty) continue;
      frequency[strategy] = (frequency[strategy] ?? 0) + 1;
    }
    return frequency;
  }

  Widget _buildProactiveStrategyTable(BuildContext context) {
    final theme = Theme.of(context);
    final subtitleStyle = theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600);
    final labelStyle = theme.textTheme.bodyMedium?.copyWith(color: Colors.grey[700]);
    final frequency = _buildProactiveStrategyFrequency();

    if (frequency.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(14.0),
          child: Text('No proactive strategies recorded yet.', style: labelStyle),
        ),
      );
    }

    final entries = frequency.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final total = entries.fold<int>(0, (sum, e) => sum + e.value);
    final maxStrategy = entries.isEmpty ? 0 : entries.first.value;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Strategies used by frequency', style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2.0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(width: 190, child: Text('Strategy', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
                  SizedBox(width: 56, child: Text('Count', textAlign: TextAlign.right, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
                  SizedBox(width: 72, child: Text('Share', textAlign: TextAlign.right, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
                ],
              ),
            ),
            const Divider(),
            ...entries.map((entry) {
              final share = total > 0 ? (entry.value / total) * 100 : 0.0;
              final isTop = entry.value == maxStrategy && maxStrategy > 0;
              final rowLabel = isTop ? labelStyle?.copyWith(color: Colors.red, fontWeight: FontWeight.w700) : labelStyle;
              final rowNum = isTop ? subtitleStyle?.copyWith(color: Colors.red, fontWeight: FontWeight.w700) : subtitleStyle;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 1.0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(width: 190, child: Text(entry.key, maxLines: 2, overflow: TextOverflow.ellipsis, style: rowLabel)),
                    SizedBox(width: 56, child: Text(entry.value.toString(), textAlign: TextAlign.right, style: rowNum)),
                    SizedBox(width: 72, child: Text('${share.toStringAsFixed(1)}%', textAlign: TextAlign.right, style: rowNum)),
                  ],
                ),
              );
            }),
            const SizedBox(height: 12),
            Text('Total strategies recorded: $total', style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[700])),
          ],
        ),
      ),
    );
  }

  String _nowStamp() {
    final n = DateTime.now().toLocal();
    return '${n.year}-${_two(n.month)}-${_two(n.day)} ${_two(n.hour)}:${_two(n.minute)}';
  }

  /// Builds a printable / downloadable PDF summary report for this student.
  Future<Uint8List> _buildReportPdf() async {
    // Use Unicode fonts so any symbol renders (emoji, CJK, Arabic, etc.). If the
    // fonts can't be fetched (e.g. offline), fall back to the built-in font so
    // plain reports still generate, and allow a retry next time.
    pw.ThemeData? theme;
    try {
      theme = await _pdfUnicodeTheme();
    } catch (_) {
      _pdfUnicodeThemeFuture = null;
      theme = null;
    }
    final doc = pw.Document(theme: theme);

    final overall = _buildOverallFrequency();
    final overallEntries = overall.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final totalEvents = overall.values.fold<int>(0, (s, v) => s + v);

    final strategies = _buildProactiveStrategyFrequency();
    final strategyEntries = strategies.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final totalStrategies = strategies.values.fold<int>(0, (s, v) => s + v);

    final byPeriod = _buildFrequencyByPeriod();
    final periodEntries = byPeriod.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    final dailyData = <String, int>{};
    for (final log in studentLogs) {
      final key = _dateKey(_logTimestamp(log));
      dailyData[key] = (dailyData[key] ?? 0) + 1;
    }
    final dailyEntries = dailyData.entries.toList()..sort((a, b) => b.key.compareTo(a.key));

    final sectionStyle = pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold);
    String share(int value, int total) => total > 0 ? '${(value / total * 100).toStringAsFixed(1)}%' : '0.0%';

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.all(28),
        build: (context) => [
          pw.Text('ABC Behavior Report', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 4),
          pw.Text('Student: $student', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          pw.Text('Generated: ${_nowStamp()}'),
          pw.Text('Total events: $totalEvents'),
          pw.Divider(),
          pw.SizedBox(height: 8),

          pw.Text('Behavior Summary', style: sectionStyle),
          pw.SizedBox(height: 6),
          if (overallEntries.isEmpty)
            pw.Text('No behaviors recorded.')
          else
            pw.TableHelper.fromTextArray(
              headers: ['Behavior', 'Count', 'Share'],
              data: overallEntries.map((e) => [e.key, e.value.toString(), share(e.value, totalEvents)]).toList(),
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              cellAlignment: pw.Alignment.centerLeft,
            ),
          pw.SizedBox(height: 16),

          pw.Text('Proactive Strategies Used', style: sectionStyle),
          pw.SizedBox(height: 6),
          if (strategyEntries.isEmpty)
            pw.Text('No proactive strategies recorded.')
          else
            pw.TableHelper.fromTextArray(
              headers: ['Strategy', 'Count', 'Share'],
              data: strategyEntries.map((e) => [e.key, e.value.toString(), share(e.value, totalStrategies)]).toList(),
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              cellAlignment: pw.Alignment.centerLeft,
            ),
          pw.SizedBox(height: 16),

          pw.Text('Frequency by School Period', style: sectionStyle),
          pw.SizedBox(height: 6),
          if (periodEntries.isEmpty)
            pw.Text('No periods recorded.')
          else
            pw.TableHelper.fromTextArray(
              headers: ['Period', 'Count'],
              data: periodEntries.map((e) => [e.key, e.value.toString()]).toList(),
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              cellAlignment: pw.Alignment.centerLeft,
            ),
          pw.SizedBox(height: 16),

          pw.Text('Daily Frequency', style: sectionStyle),
          pw.SizedBox(height: 6),
          pw.TableHelper.fromTextArray(
            headers: ['Date', 'Events'],
            data: dailyEntries.map((e) => [e.key, e.value.toString()]).toList(),
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            cellAlignment: pw.Alignment.centerLeft,
          ),
          pw.SizedBox(height: 16),

          pw.Text('Detailed Logs', style: sectionStyle),
          pw.SizedBox(height: 6),
          ...studentLogs.map((log) {
            final lines = <pw.Widget>[
              pw.Text('${_logStr(log, 'behavior')}  •  ${_formatDateTime(log)}',
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
            ];
            void add(String label, String key) {
              final v = _logStr(log, key);
              if (v.isNotEmpty) lines.add(pw.Text('$label: $v'));
            }
            add('Period', 'period');
            add('Antecedent', 'antecedentDescription');
            add('Behavior', 'behaviorDescription');
            add('Consequence', 'consequenceDescription');
            add('Proactive strategy', 'proactiveStrategy');
            add('Logged by', 'staff');
            return pw.Container(
              margin: const pw.EdgeInsets.only(bottom: 8),
              padding: const pw.EdgeInsets.all(8),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(width: 0.5, color: PdfColors.grey400),
                borderRadius: pw.BorderRadius.circular(4),
              ),
              child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: lines),
            );
          }),
        ],
      ),
    );

    return doc.save();
  }

  Future<void> _printReport() async {
    try {
      await Printing.layoutPdf(onLayout: (format) => _buildReportPdf());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not print report: $e')));
    }
  }

  Future<void> _shareReport() async {
    try {
      final bytes = await _buildReportPdf();
      final safeName = student.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
      await Printing.sharePdf(bytes: bytes, filename: 'ABC_Report_$safeName.pdf');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not share report: $e')));
    }
  }

  String _combineLabel(String value, String description) {
    if (value.isEmpty && description.isEmpty) return '-';
    if (description.isEmpty) return value;
    if (value.isEmpty) return description;
    return '$value ($description)';
  }

  /// Assembles this student's aggregated ABC data into a prompt for the model.
  String _buildAnalysisPrompt() {
    final buf = StringBuffer();
    buf.writeln('Student: $student');
    buf.writeln('Total ABC events: ${studentLogs.length}');
    if (studentLogs.isNotEmpty) {
      final stamps = studentLogs.map(_logTimestamp).toList()..sort();
      buf.writeln('Date range: ${_dateKey(stamps.first)} to ${_dateKey(stamps.last)}');
    }
    buf.writeln();

    Map<String, int> countBy(String key) {
      final m = <String, int>{};
      for (final log in studentLogs) {
        final v = _logStr(log, key);
        final label = v.isNotEmpty ? v : 'Unspecified';
        m[label] = (m[label] ?? 0) + 1;
      }
      return m;
    }

    void section(String title, Map<String, int> m) {
      buf.writeln('$title:');
      if (m.isEmpty) {
        buf.writeln('- none recorded');
      } else {
        final entries = m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
        for (final e in entries) {
          buf.writeln('- ${e.key}: ${e.value}');
        }
      }
      buf.writeln();
    }

    section('Behavior frequency', _buildOverallFrequency());
    section('Antecedent frequency', countBy('antecedent'));
    section('Consequence frequency', countBy('consequence'));
    section('Frequency by school period', _buildFrequencyByPeriod());
    section('Proactive strategies used', _buildProactiveStrategyFrequency());

    final daily = <String, int>{};
    for (final log in studentLogs) {
      final k = _dateKey(_logTimestamp(log));
      daily[k] = (daily[k] ?? 0) + 1;
    }
    final dailyEntries = daily.entries.toList()..sort((a, b) => b.key.compareTo(a.key));
    buf.writeln('Events per day (most recent first):');
    for (final e in dailyEntries) {
      buf.writeln('- ${e.key}: ${e.value}');
    }
    buf.writeln();

    buf.writeln('Individual ABC records (most recent first):');
    final limit = studentLogs.length > 50 ? 50 : studentLogs.length;
    for (var i = 0; i < limit; i++) {
      final log = studentLogs[i];
      final period = _logStr(log, 'period');
      final strategy = _logStr(log, 'proactiveStrategy');
      final staff = _logStr(log, 'staff');
      final parts = [
        _formatDateTime(log),
        'Period: ${period.isNotEmpty ? period : '-'}',
        'Antecedent: ${_combineLabel(_logStr(log, 'antecedent'), _logStr(log, 'antecedentDescription'))}',
        'Behavior: ${_combineLabel(_logStr(log, 'behavior'), _logStr(log, 'behaviorDescription'))}',
        'Consequence: ${_combineLabel(_logStr(log, 'consequence'), _logStr(log, 'consequenceDescription'))}',
        'Proactive strategy: ${strategy.isNotEmpty ? strategy : '-'}',
        'Staff: ${staff.isNotEmpty ? staff : '-'}',
      ];
      buf.writeln('${i + 1}. ${parts.join(' | ')}');
    }
    if (studentLogs.length > limit) {
      buf.writeln('(${studentLogs.length - limit} older records omitted)');
    }
    return buf.toString();
  }

  Future<String?> _promptForApiKey() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Anthropic API Key'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'sk-ant-...'),
          obscureText: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null && result.isNotEmpty) {
      try {
        await _secureStorage.write(key: 'anthropic_api_key', value: result);
      } catch (_) {}
    }
    return result;
  }

  Future<void> _openAiAnalysis() async {
    String? apiKey;
    // On web the same-origin proxy supplies the server-side key, and we must
    // NOT send a per-user/browser key (it would override the server key at the
    // proxy). Only read/prompt for a key on mobile/desktop, which call Anthropic
    // directly.
    if (!kIsWeb) {
      try {
        apiKey = await _secureStorage.read(key: 'anthropic_api_key');
      } catch (_) {}
      if (apiKey == null || apiKey.isEmpty) {
        if (!mounted) return;
        apiKey = await _promptForApiKey();
        if (apiKey == null || apiKey.isEmpty) return;
      }
    }
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StudentAiAnalysisScreen(
        student: student,
        apiKey: apiKey ?? '',
        userPrompt: _buildAnalysisPrompt(),
      ),
    ));
  }

  Widget _buildBehaviorByPeriodChart(Map<String, int> frequencyByPeriod, BuildContext context) {
    if (frequencyByPeriod.isEmpty) {
      return const SizedBox.shrink();
    }

    // Order periods by the school schedule (kPeriodOrder); unknown periods last.
    final periods = frequencyByPeriod.keys.toList()
      ..sort((a, b) {
        final ia = kPeriodOrder.indexOf(a);
        final ib = kPeriodOrder.indexOf(b);
        return (ia == -1 ? 999 : ia).compareTo(ib == -1 ? 999 : ib);
      });
    final counts = periods.map((p) => frequencyByPeriod[p]!).toList();
    final maxCount = counts.isNotEmpty ? counts.reduce((a, b) => a > b ? a : b) : 0;
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Behavior Frequency by School Period',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 250,
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  maxY: (maxCount.toDouble() + 2).ceilToDouble(),
                  barTouchData: BarTouchData(
                    enabled: true,
                    touchTooltipData: BarTouchTooltipData(
                      getTooltipColor: (group) => Colors.blueGrey.shade900,
                      getTooltipItem: (group, groupIndex, rod, rodIndex) {
                        final period =
                            (group.x >= 0 && group.x < periods.length) ? periods[group.x] : '';
                        return BarTooltipItem(
                          '$period\n',
                          const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                          children: [
                            TextSpan(
                              text: '${rod.toY.toInt()}',
                              style: const TextStyle(color: Colors.white, fontSize: 12),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  titlesData: FlTitlesData(
                    show: true,
                    leftTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: true, reservedSize: 40),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          final index = value.toInt();
                          if (index < 0 || index >= periods.length) {
                            return const Text('');
                          }
                          final period = periods[index];
                          return Transform.rotate(
                            angle: -0.3,
                            child: Text(
                              period.length > 12 ? '${period.substring(0, 12)}...' : period,
                              style: const TextStyle(fontSize: 9),
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        },
                        reservedSize: 70,
                      ),
                    ),
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  ),
                  gridData: const FlGridData(show: true, drawHorizontalLine: true, drawVerticalLine: false),
                  barGroups: List.generate(
                    periods.length,
                    (index) => BarChartGroupData(
                      x: index,
                      barRods: [
                        BarChartRodData(
                          toY: counts[index].toDouble(),
                          color: Colors.indigo,
                          width: 20,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Count by period',
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[700]),
            ),
            const SizedBox(height: 8),
            ...periods.asMap().entries.map((e) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(child: Text(e.value, style: theme.textTheme.bodySmall)),
                    Text(counts[e.key].toString(), style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  /// Total event counts bucketed by the current [_granularity], sorted
  /// chronologically (bucket keys sort lexicographically into time order).
  List<MapEntry<String, int>> _eventCountsByBucket() {
    final data = <String, int>{};
    for (final log in studentLogs) {
      final key = _bucketKey(_logTimestamp(log), _granularity);
      data[key] = (data[key] ?? 0) + 1;
    }
    return data.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
  }

  /// Thins x-axis labels to ~7 evenly spaced entries so dense ranges stay legible.
  bool _showLabelAt(int index, int total) {
    if (total <= 0) return false;
    final step = (total / 7).ceil().clamp(1, total);
    return index % step == 0;
  }

  Widget _granularitySelector() {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<TimeGranularity>(
        showSelectedIcon: false,
        segments: TimeGranularity.values
            .map((g) => ButtonSegment<TimeGranularity>(value: g, label: Text(g.label)))
            .toList(),
        selected: {_granularity},
        onSelectionChanged: (selection) {
          setState(() => _granularity = selection.first);
        },
      ),
    );
  }

  Widget _buildAggregateFrequencyChart(BuildContext context) {
    final entries = _eventCountsByBucket();
    if (entries.isEmpty) return const SizedBox.shrink();

    final keys = entries.map((e) => e.key).toList();
    final counts = entries.map((e) => e.value).toList();
    final maxCount = counts.reduce((a, b) => a > b ? a : b);
    final theme = Theme.of(context);
    final n = keys.length;
    final barWidth = n > 24 ? 6.0 : (n > 12 ? 10.0 : 18.0);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_granularity.label} Behavior Frequency',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 250,
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  maxY: (maxCount.toDouble() + 2).ceilToDouble(),
                  barTouchData: BarTouchData(
                    enabled: true,
                    touchTooltipData: BarTouchTooltipData(
                      getTooltipColor: (group) => Colors.blueGrey.shade900,
                      getTooltipItem: (group, groupIndex, rod, rodIndex) {
                        final label =
                            (group.x >= 0 && group.x < keys.length) ? _bucketLabel(keys[group.x], _granularity) : '';
                        return BarTooltipItem(
                          '$label\n',
                          const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                          children: [
                            TextSpan(
                              text: '${rod.toY.toInt()}',
                              style: const TextStyle(color: Colors.white, fontSize: 12),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  titlesData: FlTitlesData(
                    show: true,
                    leftTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: true, reservedSize: 40),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          final index = value.toInt();
                          if (index < 0 || index >= keys.length || (keys.length > 16 && !_showLabelAt(index, keys.length))) {
                            return const Text('');
                          }
                          return Transform.rotate(
                            angle: -0.3,
                            child: Text(
                              _bucketLabel(keys[index], _granularity),
                              style: const TextStyle(fontSize: 9),
                              textAlign: TextAlign.center,
                            ),
                          );
                        },
                        reservedSize: 44,
                      ),
                    ),
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  ),
                  gridData: const FlGridData(show: true, drawHorizontalLine: true, drawVerticalLine: false),
                  barGroups: List.generate(
                    keys.length,
                    (index) => BarChartGroupData(
                      x: index,
                      barRods: [
                        BarChartRodData(
                          toY: counts[index].toDouble(),
                          color: Colors.indigo,
                          width: barWidth,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Events per ${_granularity.unit}',
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[700]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAggregateTrendChart(BuildContext context) {
    final entries = _eventCountsByBucket();
    if (entries.isEmpty) return const SizedBox.shrink();

    final keys = entries.map((e) => e.key).toList();
    final counts = entries.map((e) => e.value.toDouble()).toList();
    final maxCount = counts.reduce((a, b) => a > b ? a : b);
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_granularity.label} Behavior Trend',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 250,
              child: LineChart(
                LineChartData(
                  gridData: const FlGridData(show: true, drawHorizontalLine: true, drawVerticalLine: false),
                  titlesData: FlTitlesData(
                    show: true,
                    leftTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: true, reservedSize: 40),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          final index = value.toInt();
                          if (index < 0 || index >= keys.length || (keys.length > 16 && !_showLabelAt(index, keys.length))) {
                            return const Text('');
                          }
                          return Text(
                            _bucketLabel(keys[index], _granularity),
                            style: const TextStyle(fontSize: 9),
                            textAlign: TextAlign.center,
                          );
                        },
                        reservedSize: 40,
                      ),
                    ),
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  ),
                  borderData: FlBorderData(show: true),
                  lineBarsData: [
                    LineChartBarData(
                      spots: List.generate(
                        keys.length,
                        (index) => FlSpot(index.toDouble(), counts[index]),
                      ),
                      isCurved: true,
                      color: Colors.indigo,
                      barWidth: 2,
                      dotData: const FlDotData(show: true),
                      belowBarData: BarAreaData(
                        show: true,
                        color: Colors.indigo.withValues(alpha: 0.3),
                      ),
                    ),
                  ],
                  minY: 0,
                  maxY: (maxCount + 2).ceilToDouble(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Total events over time (per ${_granularity.unit})',
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[700]),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _groupLogsByDate();
    final frequency = _buildFrequencyByDate();
    final overallFrequency = _buildOverallFrequency();
    final dates = grouped.keys.toList()..sort((a, b) => b.compareTo(a));
    final theme = Theme.of(context);
    final subtitleStyle = theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600);
    final frequencyLabelStyle = theme.textTheme.bodyMedium?.copyWith(color: Colors.grey[700]);

    // Headline stats for this student (mirrors the school dashboard tiles).
    String maxKey(Map<String, int> m) => m.isEmpty
        ? '-'
        : (m.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
    final topBehavior = maxKey(overallFrequency);
    final peakPeriod = maxKey(_buildFrequencyByPeriod());
    const wdNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final wdCounts = <String, int>{};
    for (final log in studentLogs) {
      final k = wdNames[_logTimestamp(log).toLocal().weekday - 1];
      wdCounts[k] = (wdCounts[k] ?? 0) + 1;
    }
    final highestDay = maxKey(wdCounts);
    Widget statTile(String value, String label) => Card(
          child: Container(
            width: 158,
            padding: const EdgeInsets.all(12.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(label, style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[700])),
              ],
            ),
          ),
        );

    // Daily count table (reused; shown right after the stat tiles).
    Widget dayCard(String date) {
      final dateFrequency = frequency[date]!;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(10.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(date, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              ...dateFrequency.entries.map((entry) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(child: Text(entry.key, style: frequencyLabelStyle)),
                        const SizedBox(width: 16),
                        Text(entry.value.toString(), style: subtitleStyle),
                      ],
                    ),
                  )),
            ],
          ),
        ),
      );
    }

    // dates is sorted most-recent-first.
    final dailyRecent = <Widget>[
      Text('Daily Behavior Frequency — most recent day',
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
      const SizedBox(height: 12),
      if (dates.isNotEmpty) dayCard(dates.first),
    ];
    final dailyOlder = <Widget>[
      if (dates.length > 1) ...[
        Text('Daily Behavior Frequency — earlier days',
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        ...dates.skip(1).map(dayCard),
        const SizedBox(height: 24),
      ],
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text('Past Logs - $student'),
        actions: studentLogs.isEmpty
            ? null
            : [
                if (kAiFeaturesEnabled)
                  IconButton(
                    icon: const Icon(Icons.psychology),
                    tooltip: 'AI behavior analysis',
                    onPressed: _openAiAnalysis,
                  ),
                IconButton(
                  icon: const Icon(Icons.print),
                  tooltip: 'Print report',
                  onPressed: _printReport,
                ),
                IconButton(
                  icon: const Icon(Icons.ios_share),
                  tooltip: 'Download / share report',
                  onPressed: _shareReport,
                ),
              ],
      ),
      body: studentLogs.isEmpty
          ? Center(child: Text('No past logs for $student yet.'))
          : ListView(
              padding: const EdgeInsets.all(16.0),
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    statTile('${studentLogs.length}', 'Total events'),
                    statTile(topBehavior, 'Top behavior'),
                    statTile(peakPeriod, 'Peak Escalation Period'),
                    statTile(highestDay, 'Highest Incident Day'),
                  ],
                ),
                const SizedBox(height: 24),
                ...dailyRecent,
                const SizedBox(height: 24),
                Text('Overall Behavior Summary', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(10.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Total occurrences by behavior', style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 12),
                        Builder(
                          builder: (context) {
                            final totalCount = overallFrequency.values.fold<int>(0, (sum, value) => sum + value);
                            return Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 2.0),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox(width: 190, child: Text('Behavior', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
                                      SizedBox(width: 56, child: Text('Count', textAlign: TextAlign.right, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
                                      SizedBox(width: 72, child: Text('Share', textAlign: TextAlign.right, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
                                    ],
                                  ),
                                ),
                                const Divider(),
                                ...(() {
                                  final sorted = overallFrequency.entries.toList()
                                    ..sort((a, b) => b.value.compareTo(a.value));
                                  final maxCount = sorted.isEmpty ? 0 : sorted.first.value;
                                  return sorted.map((entry) {
                                    final share = totalCount > 0 ? (entry.value / totalCount) * 100 : 0.0;
                                    final isTop = entry.value == maxCount && maxCount > 0;
                                    final labelStyle = isTop
                                        ? frequencyLabelStyle?.copyWith(color: Colors.red, fontWeight: FontWeight.w700)
                                        : frequencyLabelStyle;
                                    final numStyle = isTop
                                        ? subtitleStyle?.copyWith(color: Colors.red, fontWeight: FontWeight.w700)
                                        : subtitleStyle;
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 1.0),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          SizedBox(width: 190, child: Text(entry.key, maxLines: 2, overflow: TextOverflow.ellipsis, style: labelStyle)),
                                          SizedBox(width: 56, child: Text(entry.value.toString(), textAlign: TextAlign.right, style: numStyle)),
                                          SizedBox(width: 72, child: Text('${share.toStringAsFixed(1)}%', textAlign: TextAlign.right, style: numStyle)),
                                        ],
                                      ),
                                    );
                                  });
                                })(),
                                const SizedBox(height: 12),
                                Text('Total events: $totalCount', style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[700])),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text('Proactive Strategies Used', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                _buildProactiveStrategyTable(context),
                const SizedBox(height: 24),
                _buildBehaviorByPeriodChart(_buildFrequencyByPeriod(), context),
                const SizedBox(height: 24),
                Text('Behavior Frequency & Trend', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                _granularitySelector(),
                const SizedBox(height: 16),
                _buildAggregateFrequencyChart(context),
                const SizedBox(height: 24),
                _buildAggregateTrendChart(context),
                const SizedBox(height: 24),
                ...dailyOlder,
                Text('Detailed Logs', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                ...studentLogs.map((log) {
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${_logStr(log, 'behavior')} • ${_formatDateTime(log)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          if (_logStr(log, 'antecedentDescription').isNotEmpty) ...[
                            Text('Antecedent: ${_logStr(log, 'antecedentDescription')}'),
                            const SizedBox(height: 4),
                          ],
                          if (_logStr(log, 'behaviorDescription').isNotEmpty) ...[
                            Text('Behavior: ${_logStr(log, 'behaviorDescription')}'),
                            const SizedBox(height: 4),
                          ],
                          if (_logStr(log, 'consequenceDescription').isNotEmpty) ...[
                            Text('Consequence: ${_logStr(log, 'consequenceDescription')}'),
                            const SizedBox(height: 4),
                          ],
                          if (_logStr(log, 'proactiveStrategy').isNotEmpty) ...[
                            Text('Proactive strategy: ${_logStr(log, 'proactiveStrategy')}'),
                            const SizedBox(height: 4),
                          ],
                          if (_logStr(log, 'staff').isNotEmpty) ...[
                            Text('Logged by: ${_logStr(log, 'staff')}'),
                          ],
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
    );
  }
}

class StudentAiAnalysisScreen extends StatefulWidget {
  final String student;
  final String apiKey;
  final String userPrompt;
  // Optional overrides so this screen can also render a school-wide analysis.
  final String? title;
  final String? systemPromptOverride;

  const StudentAiAnalysisScreen({
    super.key,
    required this.student,
    required this.apiKey,
    required this.userPrompt,
    this.title,
    this.systemPromptOverride,
  });

  @override
  State<StudentAiAnalysisScreen> createState() => _StudentAiAnalysisScreenState();
}

class _StudentAiAnalysisScreenState extends State<StudentAiAnalysisScreen> {
  static const String _systemPrompt = '''You are a board-certified behavior analyst (BCBA) supporting a school team. Using ONLY the ABC (antecedent-behavior-consequence) data provided, produce a structured behavior report with these clearly labeled sections:

1. Summary — a concise overview in 2-4 sentences.
2. Patterns — notable patterns across antecedents, behaviors, consequences, school periods/times, and trends over time.
3. Functional Behavior Assessment — for the most significant behavior(s), state the hypothesized function(s) (escape/avoidance, attention, access to tangibles, or sensory/automatic) and cite the specific ABC evidence supporting each hypothesis.
4. Predicted Escalations — the antecedents, periods, and conditions most likely to precede escalation, plus early warning signs, based on the data.
5. Evidence-Based Interventions — specific, evidence-based, function-matched strategies (antecedent modifications, teaching replacement behaviors, reinforcement schedules, etc.), each with a one-line rationale tied to the hypothesized function.

Be concise and practical, and base every statement on the provided data. If the data are insufficient to support a conclusion, say so explicitly rather than speculating. End with a one-line disclaimer that this is AI-generated decision support and not a substitute for a comprehensive FBA conducted by a qualified professional.''';

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  late String _apiKey = widget.apiKey;

  bool _loading = true;
  String? _result;
  String? _error;
  bool _authError = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  bool _looksLikeAuthError(String message) {
    final m = message.toLowerCase();
    return m.contains('401') ||
        m.contains('authentication_error') ||
        m.contains('invalid x-api-key') ||
        m.contains('invalid_api_key') ||
        m.contains('incorrect api key') ||
        m.contains('invalid authentication');
  }

  bool _looksLikeBillingError(String message) {
    final m = message.toLowerCase();
    // Match only Anthropic's genuine low-balance message; avoid broad words like
    // "insufficient" that also appear in unrelated errors (and in AI output).
    return m.contains('credit balance') || m.contains('plans & billing');
  }

  Future<void> _run() async {
    // On web an empty key is fine — the same-origin proxy supplies the
    // server-side key. On mobile/desktop a key is required.
    if (!kIsWeb && _apiKey.isEmpty) {
      setState(() {
        _loading = false;
        _authError = true;
        _error = 'No Anthropic API key set.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _authError = false;
    });
    try {
      final text = await AnthropicClient.generateAnalysis(
        apiKey: _apiKey,
        systemPrompt: widget.systemPromptOverride ?? _systemPrompt,
        userPrompt: widget.userPrompt,
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (text == null || text.isEmpty) {
          _error = 'No response from AI.';
        } else {
          _result = text;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _authError = _looksLikeAuthError('$e');
        final detail = '\n\n($kBuildTag) $e';
        if (_authError) {
          _error = 'Your Anthropic API key is missing or invalid.$detail';
        } else if (_looksLikeBillingError('$e')) {
          _error = 'Your Anthropic account is out of credits. Add credits at '
              'console.anthropic.com (Plans & Billing), then retry.$detail';
        } else {
          _error = '$e$detail';
        }
      });
    }
  }

  Future<void> _updateApiKey() async {
    final controller = TextEditingController(text: _apiKey);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Anthropic API Key'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'sk-ant-...'),
          obscureText: true,
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null && result.isNotEmpty) {
      try {
        await _secureStorage.write(key: 'anthropic_api_key', value: result);
      } catch (_) {}
      if (!mounted) return;
      setState(() => _apiKey = result);
      _run();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? 'AI Analysis - ${widget.student}'),
        actions: [
          if (_result != null)
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: 'Copy',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _result!));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Analysis copied to clipboard')),
                );
              },
            ),
          IconButton(
            icon: const Icon(Icons.key),
            tooltip: 'Set API key',
            onPressed: _loading ? null : _updateApiKey,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Regenerate',
            onPressed: _loading ? null : _run,
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Analyzing ABC data…'),
                ],
              ),
            )
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(_authError ? Icons.vpn_key : Icons.error_outline, color: Colors.red, size: 40),
                        const SizedBox(height: 12),
                        Text(
                          _authError
                              ? '$_error\n\nEnter a valid Anthropic API key to run the analysis.'
                              : 'AI analysis failed:\n$_error',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        if (_authError)
                          ElevatedButton.icon(
                            icon: const Icon(Icons.key),
                            onPressed: _updateApiKey,
                            label: const Text('Enter API key'),
                          )
                        else
                          ElevatedButton(onPressed: _run, child: const Text('Retry')),
                      ],
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16.0),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12.0),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.amber.shade200),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline, size: 18, color: Colors.amber.shade800),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'AI-generated decision support based on the recorded ABC data. '
                              'Not a substitute for a comprehensive FBA by a qualified professional.',
                              style: TextStyle(fontSize: 12, color: Colors.grey[800]),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    MarkdownBody(
                      data: _result ?? '',
                      selectable: true,
                      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                        p: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                      ),
                    ),
                  ],
                ),
    );
  }
}

/// Date-range presets for the dashboard filter.
enum _RangePreset { today, yesterday, thisWeek, lastWeek, yearToDate, custom }

String _rangePresetLabel(_RangePreset r) {
  switch (r) {
    case _RangePreset.today:
      return 'Today';
    case _RangePreset.yesterday:
      return 'Yesterday';
    case _RangePreset.thisWeek:
      return 'This Week';
    case _RangePreset.lastWeek:
      return 'Last Week';
    case _RangePreset.yearToDate:
      return 'Year to Date';
    case _RangePreset.custom:
      return 'Custom';
  }
}

/// School-wide aggregate dashboard: behaviors across ALL students, viewable by
/// day/week/month/year, by school period, and by day of week — plus an
/// (AI-flag-gated) school-level pattern/escalation analysis.
class SchoolDashboardScreen extends StatefulWidget {
  final List<Map<String, dynamic>> allLogs;
  final String apiKey;
  // Canonical school-period order (so the period heatmap reads in schedule order).
  final List<String> periodOrder;

  const SchoolDashboardScreen({
    super.key,
    required this.allLogs,
    required this.apiKey,
    this.periodOrder = const [],
  });

  @override
  State<SchoolDashboardScreen> createState() => _SchoolDashboardScreenState();
}

class _SchoolDashboardScreenState extends State<SchoolDashboardScreen> {
  TimeGranularity _granularity = TimeGranularity.daily;
  _RangePreset _range = _RangePreset.yearToDate;
  DateTimeRange? _customRange;
  bool _bw = false; // B&W (print-friendly) mode: grayscale instead of color.

  /// Start/end (inclusive) of the currently selected date filter.
  (DateTime, DateTime) _rangeBounds() {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    switch (_range) {
      case _RangePreset.today:
        return (todayStart, now);
      case _RangePreset.yesterday:
        return (todayStart.subtract(const Duration(days: 1)),
            todayStart.subtract(const Duration(seconds: 1)));
      case _RangePreset.thisWeek:
        return (_weekStart(now), now);
      case _RangePreset.lastWeek:
        final thisWeekStart = _weekStart(now);
        return (thisWeekStart.subtract(const Duration(days: 7)),
            thisWeekStart.subtract(const Duration(seconds: 1)));
      case _RangePreset.yearToDate:
        return (DateTime(now.year, 1, 1), now);
      case _RangePreset.custom:
        final r = _customRange;
        if (r == null) return (DateTime(now.year, 1, 1), now);
        return (DateTime(r.start.year, r.start.month, r.start.day),
            DateTime(r.end.year, r.end.month, r.end.day, 23, 59, 59));
    }
  }

  /// All logs filtered to the selected date range — every chart/table/stat on
  /// this screen reads from here, so they all stay in sync with the filter.
  List<Map<String, dynamic>> get logs {
    final (start, end) = _rangeBounds();
    return widget.allLogs.where((l) {
      final t = _logTimestamp(l).toLocal();
      return !t.isBefore(start) && !t.isAfter(end);
    }).toList();
  }

  static const String _schoolSystemPrompt = '''You are a board-certified behavior analyst (BCBA) supporting a school team. Using ONLY the aggregated, de-identified school-wide ABC (antecedent-behavior-consequence) data provided (counts across all students), produce a structured report with these clearly labeled sections:

1. Summary — a concise 2-4 sentence overview of the school-wide behavior picture.
2. School-Wide Patterns — notable patterns across behaviors, school periods/times, day of week, and trends over time.
3. Predicted Escalations — the periods, days, and conditions most likely to precede increases in behavior, plus early warning signs, based on the data.
4. School-Level Recommendations — specific, evidence-based proactive strategies at the school/schedule/environment level (e.g. transition supports, staffing during high-risk periods), each tied to a pattern in the data.

Be concise and base every statement on the provided data. If the data are insufficient to support a conclusion, say so explicitly. End with a one-line disclaimer that this is AI-generated decision support and not a substitute for professional judgment.''';

  Map<String, int> _countBy(String key) {
    final m = <String, int>{};
    for (final log in logs) {
      final v = _logStr(log, key);
      final label = v.isNotEmpty ? v : 'Unspecified';
      m[label] = (m[label] ?? 0) + 1;
    }
    return m;
  }

  List<MapEntry<String, int>> _sortedDesc(Map<String, int> m) =>
      m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

  List<MapEntry<String, int>> _eventCountsByBucket() {
    final data = <String, int>{};
    for (final log in logs) {
      final k = _bucketKey(_logTimestamp(log), _granularity);
      data[k] = (data[k] ?? 0) + 1;
    }
    return data.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
  }

  /// Counts by day of week, in Monday..Sunday order (days with no data omitted).
  List<MapEntry<String, int>> _countsByWeekday() {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final counts = List<int>.filled(7, 0);
    for (final log in logs) {
      counts[_logTimestamp(log).toLocal().weekday - 1]++;
    }
    final out = <MapEntry<String, int>>[];
    for (var i = 0; i < 7; i++) {
      if (counts[i] > 0) out.add(MapEntry(names[i], counts[i]));
    }
    return out;
  }

  /// Per-day behavior breakdown across all students: date -> {behavior: count}.
  Map<String, Map<String, int>> _behaviorsByDate() {
    final byDate = <String, Map<String, int>>{};
    for (final log in logs) {
      final date = _dateKey(_logTimestamp(log));
      final b = _logStr(log, 'behavior');
      final behavior = b.isNotEmpty ? b : 'Unspecified';
      final day = byDate.putIfAbsent(date, () => <String, int>{});
      day[behavior] = (day[behavior] ?? 0) + 1;
    }
    return byDate;
  }

  int _uniqueStudents() =>
      logs.map((l) => _logStr(l, 'student')).where((s) => s.isNotEmpty).toSet().length;

  // A symbol per behavior so they're identifiable even in black-and-white.
  static const List<String> _symbols = [
    '●', '■', '▲', '◆', '★', '✚', '▼', '◯', '□', '△', '▽', '✖',
  ];

  /// Behaviors ordered by overall frequency (stable order for legend + bars).
  List<String> _behaviorOrder() => _sortedDesc(_countBy('behavior')).map((e) => e.key).toList();

  /// Color per behavior on a red->blue gradient by frequency rank: the most
  /// frequent behavior is red, cooling through orange/yellow/green to blue as
  /// the counts decrease.
  Map<String, Color> _behaviorColors(List<String> order) {
    final map = <String, Color>{};
    final n = order.length;
    for (var i = 0; i < n; i++) {
      final t = n <= 1 ? 0.0 : i / (n - 1);
      map[order[i]] = _bw
          ? Color.lerp(const Color(0xFF222222), const Color(0xFFBDBDBD), t)!
          : HSVColor.fromAHSV(1.0, t * 240.0, 0.72, 0.88).toColor();
    }
    return map;
  }

  Map<String, String> _behaviorSymbols(List<String> order) =>
      {for (var i = 0; i < order.length; i++) order[i]: _symbols[i % _symbols.length]};

  /// bucket -> behavior -> count, at the current granularity.
  Map<String, Map<String, int>> _bucketBehaviorCounts() {
    final m = <String, Map<String, int>>{};
    for (final log in logs) {
      final k = _bucketKey(_logTimestamp(log), _granularity);
      final b = _logStr(log, 'behavior');
      final behavior = b.isNotEmpty ? b : 'Unspecified';
      final bucket = m.putIfAbsent(k, () => <String, int>{});
      bucket[behavior] = (bucket[behavior] ?? 0) + 1;
    }
    return m;
  }

  /// student -> {bucketKey -> count}, at the current granularity (for the
  /// per-student trend overlay).
  Map<String, Map<String, int>> _studentBucketCounts() {
    final m = <String, Map<String, int>>{};
    for (final log in logs) {
      final s = _logStr(log, 'student');
      final student = s.isNotEmpty ? s : 'Unspecified';
      final k = _bucketKey(_logTimestamp(log), _granularity);
      final byBucket = m.putIfAbsent(student, () => <String, int>{});
      byBucket[k] = (byBucket[k] ?? 0) + 1;
    }
    return m;
  }

  /// behavior -> {category -> count}, where category is read from [key]
  /// (e.g. 'period') or, when [key] is 'weekday', the day of week.
  Map<String, Map<String, int>> _behaviorBy(String key) {
    final m = <String, Map<String, int>>{};
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    for (final log in logs) {
      final b = _logStr(log, 'behavior');
      final behavior = b.isNotEmpty ? b : 'Unspecified';
      final String cat;
      if (key == 'weekday') {
        cat = names[_logTimestamp(log).toLocal().weekday - 1];
      } else if (key == 'date') {
        cat = _dateKey(_logTimestamp(log));
      } else {
        final v = _logStr(log, key);
        cat = v.isNotEmpty ? v : 'Unspecified';
      }
      final row = m.putIfAbsent(behavior, () => <String, int>{});
      row[cat] = (row[cat] ?? 0) + 1;
    }
    return m;
  }

  String _dateRange() {
    if (logs.isEmpty) return '-';
    final stamps = logs.map(_logTimestamp).toList()..sort();
    return '${_dateKey(stamps.first)} to ${_dateKey(stamps.last)}';
  }

  bool _showLabelAt(int index, int total) {
    if (total <= 0) return false;
    final step = (total / 7).ceil().clamp(1, total);
    return index % step == 0;
  }

  Widget _granularitySelector() {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<TimeGranularity>(
        showSelectedIcon: false,
        segments: TimeGranularity.values
            .map((g) => ButtonSegment<TimeGranularity>(value: g, label: Text(g.label)))
            .toList(),
        selected: {_granularity},
        onSelectionChanged: (selection) => setState(() => _granularity = selection.first),
      ),
    );
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: _customRange,
    );
    if (picked == null) return;
    setState(() {
      _range = _RangePreset.custom;
      _customRange = picked;
    });
  }

  /// Date-range filter that controls the whole dashboard (graph + tables + tiles).
  Widget _rangeSelector() {
    final theme = Theme.of(context);
    final (start, end) = _rangeBounds();
    final showsCustom = _range == _RangePreset.custom && _customRange != null;
    return Row(
      children: [
        const Icon(Icons.date_range, size: 18),
        const SizedBox(width: 6),
        DropdownButton<_RangePreset>(
          value: _range,
          isDense: true,
          items: _RangePreset.values
              .map((r) => DropdownMenuItem(value: r, child: Text(_rangePresetLabel(r))))
              .toList(),
          onChanged: (r) {
            if (r == null) return;
            if (r == _RangePreset.custom) {
              _pickCustomRange();
            } else {
              setState(() => _range = r);
            }
          },
        ),
        const SizedBox(width: 10),
        Expanded(
          child: GestureDetector(
            onTap: showsCustom ? _pickCustomRange : null,
            child: Text(
              showsCustom
                  ? '${_dateKey(start)} → ${_dateKey(end)}  (tap to change)'
                  : '${_dateKey(start)} → ${_dateKey(end)}',
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[700]),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilterChip(
          label: const Text('B&W'),
          tooltip: 'Grayscale for black-and-white printing',
          selected: _bw,
          onSelected: (v) => setState(() => _bw = v),
        ),
      ],
    );
  }

  /// Legend: a colored swatch (frequency gradient) with the behavior's symbol
  /// overlaid (so it still reads in B&W) + the behavior name.
  Widget _legend(List<String> behaviors, Map<String, Color> colors, Map<String, String> symbols) {
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: behaviors
          .map((b) => Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 16,
                  height: 16,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors[b],
                    border: Border.all(color: Colors.black26),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: Text(symbols[b] ?? '',
                      style: TextStyle(
                          fontSize: 10,
                          color: (colors[b] ?? Colors.grey).computeLuminance() < 0.5
                              ? Colors.white
                              : Colors.black)),
                ),
                const SizedBox(width: 4),
                Text(b, style: const TextStyle(fontSize: 11)),
              ]))
          .toList(),
    );
  }

  /// Grouped bar chart: each behavior is its own bar, placed side by side within
  /// each time bucket. Colored by a frequency gradient (red = most), with a
  /// symbol legend so it still reads in B&W.
  Widget _buildGroupedTimeChart(
    BuildContext context,
    List<String> behaviors,
    Map<String, Color> colors,
    Map<String, String> symbols,
  ) {
    final byBucket = _bucketBehaviorCounts();
    final keys = byBucket.keys.toList()..sort();
    if (keys.isEmpty) return const SizedBox.shrink();
    double maxV = 0;
    for (final k in keys) {
      for (final b in behaviors) {
        final c = (byBucket[k]![b] ?? 0).toDouble();
        if (c > maxV) maxV = c;
      }
    }
    final theme = Theme.of(context);
    final density = keys.length * behaviors.length;
    final rodW = density > 120 ? 3.0 : (density > 60 ? 4.5 : 7.0);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${_granularity.label} behaviors (each behavior side by side)',
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('Tip: use Weekly/Monthly if Daily looks crowded.',
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[600])),
            const SizedBox(height: 16),
            SizedBox(
              height: 260,
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  maxY: (maxV + 1).ceilToDouble(),
                  barTouchData: BarTouchData(
                    enabled: true,
                    touchTooltipData: BarTouchTooltipData(
                      getTooltipItem: (group, groupIndex, rod, rodIndex) {
                        if (rod.toY <= 0) return null;
                        final behavior =
                            (rodIndex >= 0 && rodIndex < behaviors.length) ? behaviors[rodIndex] : '';
                        final bucket = (group.x >= 0 && group.x < keys.length)
                            ? _bucketLabel(keys[group.x], _granularity)
                            : '';
                        return BarTooltipItem(
                          '$behavior\n',
                          const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                          children: [
                            TextSpan(
                              text: '${rod.toY.toInt()} on $bucket',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.normal, fontSize: 11),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  titlesData: FlTitlesData(
                    show: true,
                    leftTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: true, reservedSize: 40),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          final i = value.toInt();
                          if (i < 0 || i >= keys.length || !_showLabelAt(i, keys.length)) {
                            return const Text('');
                          }
                          return Transform.rotate(
                            angle: -0.3,
                            child: Text(_bucketLabel(keys[i], _granularity),
                                style: const TextStyle(fontSize: 9), textAlign: TextAlign.center),
                          );
                        },
                        reservedSize: 44,
                      ),
                    ),
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  ),
                  gridData: const FlGridData(show: true, drawHorizontalLine: true, drawVerticalLine: false),
                  barGroups: List.generate(keys.length, (i) {
                    final counts = byBucket[keys[i]]!;
                    return BarChartGroupData(
                      x: i,
                      barsSpace: 1.0,
                      barRods: [
                        for (final b in behaviors)
                          BarChartRodData(
                            toY: (counts[b] ?? 0).toDouble(),
                            color: colors[b],
                            width: rodW,
                            borderRadius: BorderRadius.zero,
                            borderSide: const BorderSide(color: Colors.black12, width: 0.3),
                          ),
                      ],
                    );
                  }),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _legend(behaviors, colors, symbols),
          ],
        ),
      ),
    );
  }

  /// Line chart overlaying every student's event count per time bucket, so you
  /// can compare students' trends at a glance (one colored line each).
  Widget _buildStudentTrendOverlay(BuildContext context) {
    final byStudent = _studentBucketCounts();
    if (byStudent.isEmpty) return const SizedBox.shrink();
    final keys = (<String>{for (final m in byStudent.values) ...m.keys}.toList())..sort();
    if (keys.isEmpty) return const SizedBox.shrink();
    final students = byStudent.keys.toList()..sort();
    final theme = Theme.of(context);
    final studentColor = <String, Color>{
      for (var i = 0; i < students.length; i++)
        students[i]: HSVColor.fromAHSV(1.0, (i * 360.0 / students.length) % 360.0, 0.65, 0.85).toColor(),
    };
    double maxY = 0;
    for (final s in students) {
      for (final k in keys) {
        final v = (byStudent[s]![k] ?? 0).toDouble();
        if (v > maxY) maxY = v;
      }
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('All students — ${_granularity.label.toLowerCase()} trend',
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            SizedBox(
              height: 260,
              child: LineChart(
                LineChartData(
                  minY: 0,
                  maxY: (maxY + 1).ceilToDouble(),
                  gridData: const FlGridData(show: true, drawHorizontalLine: true, drawVerticalLine: false),
                  titlesData: FlTitlesData(
                    show: true,
                    leftTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: true, reservedSize: 40),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          final i = value.toInt();
                          if (i < 0 || i >= keys.length || !_showLabelAt(i, keys.length)) {
                            return const Text('');
                          }
                          return Text(_bucketLabel(keys[i], _granularity),
                              style: const TextStyle(fontSize: 9), textAlign: TextAlign.center);
                        },
                        reservedSize: 40,
                      ),
                    ),
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  ),
                  borderData: FlBorderData(show: true),
                  lineBarsData: [
                    for (final s in students)
                      LineChartBarData(
                        spots: [
                          for (var i = 0; i < keys.length; i++)
                            FlSpot(i.toDouble(), (byStudent[s]![keys[i]] ?? 0).toDouble()),
                        ],
                        isCurved: true,
                        curveSmoothness: 0.35,
                        color: studentColor[s],
                        barWidth: 2,
                        // Dots on so single-day ranges (Today/Yesterday) still
                        // show a visible point per student, not a blank chart.
                        dotData: const FlDotData(show: true),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 14,
              runSpacing: 6,
              children: students
                  .map((s) => Row(mainAxisSize: MainAxisSize.min, children: [
                        Container(width: 14, height: 4, color: studentColor[s]),
                        const SizedBox(width: 4),
                        Text(s, style: const TextStyle(fontSize: 11)),
                      ]))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  /// A grayscale grid (copier-friendly): [rows] down the side, [cols] across the
  /// top, cell shade scaled to [valueAt], with row/column/grand totals. Optional
  /// [rowSymbols] prefixes each row label with a B&W symbol.
  Widget _heatmap(
    BuildContext context, {
    required String title,
    required List<String> rows,
    required List<String> cols,
    required int Function(String row, String col) valueAt,
    Map<String, String>? rowSymbols,
    bool verticalColHeaders = false,
  }) {
    final theme = Theme.of(context);
    if (rows.isEmpty || cols.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(14.0),
          child: Text('$title — no data yet.',
              style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey[700])),
        ),
      );
    }
    final rowTotals = <String, int>{};
    final colTotals = <String, int>{for (final c in cols) c: 0};
    var grand = 0;
    var maxV = 0;
    for (final r in rows) {
      var rt = 0;
      for (final c in cols) {
        final v = valueAt(r, c);
        rt += v;
        colTotals[c] = colTotals[c]! + v;
        if (v > maxV) maxV = v;
      }
      rowTotals[r] = rt;
      grand += rt;
    }
    final maxRowTotal = rowTotals.values.fold<int>(0, (m, v) => v > m ? v : m);
    final maxColTotal = colTotals.values.fold<int>(0, (m, v) => v > m ? v : m);
    // Grayscale ramp: empty = white, low = light gray, high = near-black.
    // Color gradient matching the Overview: high = red, low = blue (empty =
    // white). In B&W mode, a grayscale ramp instead (copier-friendly).
    Color cellColor(int v) {
      if (v <= 0) return Colors.white;
      final t = (v / (maxV == 0 ? 1 : maxV)).clamp(0.0, 1.0);
      if (_bw) {
        return Color.lerp(const Color(0xFFEEEEEE), const Color(0xFF222222),
            t.clamp(0.15, 1.0))!;
      }
      final hue = (1 - t) * 240.0; // 240=blue (low) -> 0=red (high)
      final sat = 0.30 + 0.55 * t; // paler for low counts
      return HSVColor.fromAHSV(1.0, hue, sat, 0.96).toColor();
    }

    const cellH = 34.0, rowLabelW = 140.0, totalW = 52.0;
    const totalBg = Color(0xFFE0E0E0);
    // Narrower columns + a taller header band when the column labels are
    // rotated vertical (used for the long date labels).
    final cellW = verticalColHeaders ? 30.0 : 48.0;
    final headerH = verticalColHeaders ? 78.0 : cellH;

    Widget headerCell(String s, double w, {bool vertical = false}) => SizedBox(
          width: w,
          height: headerH,
          child: Center(
            child: vertical
                ? RotatedBox(
                    quarterTurns: 3,
                    child: Text(s,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700)),
                  )
                : Text(s,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700)),
          ),
        );
    Widget dataCell(int v) {
      final bg = cellColor(v);
      final fg = bg.computeLuminance() < 0.5 ? Colors.white : Colors.black87;
      return Container(
        width: cellW - 2,
        height: cellH - 2,
        margin: const EdgeInsets.all(1),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: bg, border: Border.all(color: Colors.black12, width: 0.5)),
        child: Text(v > 0 ? '$v' : '',
            style: TextStyle(fontSize: 11, color: fg, fontWeight: FontWeight.w600)),
      );
    }
    Widget totalCell(int v, double w, {bool highlight = false}) => Container(
          width: w - 2,
          height: cellH - 2,
          margin: const EdgeInsets.all(1),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: highlight ? const Color(0xFFFFEBEE) : totalBg,
            border: Border.all(color: Colors.black26, width: 0.5),
          ),
          child: Text('$v',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: highlight ? Colors.red : Colors.black87)),
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('${_bw ? 'Darker' : 'Red'} = more frequent · Total column/row included',
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[600])),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    SizedBox(width: rowLabelW, height: headerH),
                    ...cols.map((c) => headerCell(c, cellW, vertical: verticalColHeaders)),
                    headerCell('Total', totalW),
                  ]),
                  ...rows.map((r) => Row(children: [
                        SizedBox(
                          width: rowLabelW,
                          child: Padding(
                            padding: const EdgeInsets.only(right: 6.0),
                            child: Text(
                                rowSymbols != null ? '${rowSymbols[r] ?? ''}  $r' : r,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11)),
                          ),
                        ),
                        ...cols.map((c) => dataCell(valueAt(r, c))),
                        totalCell(rowTotals[r] ?? 0, totalW,
                            highlight: (rowTotals[r] ?? 0) == maxRowTotal && maxRowTotal > 0),
                      ])),
                  Row(children: [
                    const SizedBox(
                      width: rowLabelW,
                      child: Padding(
                        padding: EdgeInsets.only(right: 6.0),
                        child: Text('Total',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                      ),
                    ),
                    ...cols.map((c) => totalCell(colTotals[c] ?? 0, cellW,
                        highlight: (colTotals[c] ?? 0) == maxColTotal && maxColTotal > 0)),
                    totalCell(grand, totalW),
                  ]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _buildSchoolPrompt() {
    final buf = StringBuffer();
    buf.writeln('School-wide aggregated ABC data (de-identified; counts across all students).');
    buf.writeln('Total events: ${logs.length}');
    buf.writeln('Students with data: ${_uniqueStudents()}');
    buf.writeln('Date range: ${_dateRange()}');
    buf.writeln();
    void section(String title, List<MapEntry<String, int>> entries) {
      buf.writeln('$title:');
      if (entries.isEmpty) {
        buf.writeln('- none recorded');
      } else {
        for (final e in entries) {
          buf.writeln('- ${e.key}: ${e.value}');
        }
      }
      buf.writeln();
    }
    section('Behavior frequency', _sortedDesc(_countBy('behavior')));
    section('Antecedent frequency', _sortedDesc(_countBy('antecedent')));
    section('Consequence frequency', _sortedDesc(_countBy('consequence')));
    section('Frequency by school period', _sortedDesc(_countBy('period')));
    section('Frequency by day of week', _countsByWeekday());
    buf.writeln('Events per ${_granularity.unit} (${_granularity.label}):');
    for (final e in _eventCountsByBucket()) {
      buf.writeln('- ${e.key}: ${e.value}');
    }
    buf.writeln();
    buf.writeln('Behaviors by day (date: behavior counts):');
    final byDate = _behaviorsByDate();
    final days = byDate.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final d in days) {
      final parts = (byDate[d]!.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
          .map((e) => '${e.key}: ${e.value}')
          .join(', ');
      buf.writeln('- $d -> $parts');
    }
    buf.writeln();
    return buf.toString();
  }

  void _openSchoolAi() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StudentAiAnalysisScreen(
        student: 'School',
        apiKey: widget.apiKey,
        title: 'School AI Analysis',
        systemPromptOverride: _schoolSystemPrompt,
        userPrompt: _buildSchoolPrompt(),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.allLogs.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('School Dashboard')),
        body: const Center(child: Text('No behavior data yet.')),
      );
    }
    final behaviorRows = _behaviorOrder();
    final colors = _behaviorColors(behaviorRows);
    final symbols = _behaviorSymbols(behaviorRows);
    final behaviorTotals = _sortedDesc(_countBy('behavior'));

    final periodMap = _behaviorBy('period');
    final presentPeriods = <String>{for (final m in periodMap.values) ...m.keys};
    final periodCols = [
      ...widget.periodOrder.where(presentPeriods.contains),
      ...presentPeriods.where((p) => !widget.periodOrder.contains(p)),
    ];

    final weekdayMap = _behaviorBy('weekday');
    const wdOrder = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final presentWd = <String>{for (final m in weekdayMap.values) ...m.keys};
    final weekdayCols = wdOrder.where(presentWd.contains).toList();

    final dateMap = _behaviorBy('date');
    final dateCols = (<String>{for (final m in dateMap.values) ...m.keys}.toList())..sort();

    // Headline stats.
    final topBehavior = behaviorTotals.isNotEmpty ? behaviorTotals.first : null;
    final periodTotals = _sortedDesc(_countBy('period'));
    final busiestPeriod = periodTotals.isNotEmpty ? periodTotals.first.key : '-';
    final weekdayTotals = _countsByWeekday()..sort((a, b) => b.value.compareTo(a.value));
    final busiestDay = weekdayTotals.isNotEmpty ? weekdayTotals.first.key : '-';

    Widget statTile(String value, String label) => Card(
          child: Container(
            width: 158,
            padding: const EdgeInsets.all(12.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(label, style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[700])),
              ],
            ),
          ),
        );

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('School Dashboard'),
          actions: [
            if (kAiFeaturesEnabled)
              IconButton(
                icon: const Icon(Icons.psychology),
                tooltip: 'AI school analysis',
                onPressed: _openSchoolAi,
              ),
          ],
          bottom: const TabBar(
            tabs: [Tab(text: 'Overview'), Tab(text: 'Patterns'), Tab(text: 'Daily')],
          ),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  statTile('${logs.length}', 'Total events'),
                  statTile(topBehavior != null ? '${topBehavior.value}' : '-',
                      topBehavior != null ? 'Top: ${topBehavior.key}' : 'Top behavior'),
                  statTile(busiestPeriod, 'Peak Escalation Period'),
                  statTile(busiestDay, 'Highest Incident Day'),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: _rangeSelector(),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  // Overview: behaviors over time, stacked by type.
                  ListView(
                    padding: const EdgeInsets.all(16.0),
                    children: [
                      _granularitySelector(),
                      const SizedBox(height: 16),
                      _buildGroupedTimeChart(context, behaviorRows, colors, symbols),
                      const SizedBox(height: 16),
                      _buildStudentTrendOverlay(context),
                    ],
                  ),
                  // Patterns: hotspot heatmaps.
                  ListView(
                    padding: const EdgeInsets.all(16.0),
                    children: [
                      _heatmap(context,
                          title: 'Behavior × period',
                          rows: behaviorRows,
                          cols: periodCols,
                          valueAt: (r, c) => periodMap[r]?[c] ?? 0,
                          rowSymbols: symbols),
                      const SizedBox(height: 16),
                      _heatmap(context,
                          title: 'Behavior × day of week',
                          rows: behaviorRows,
                          cols: weekdayCols,
                          valueAt: (r, c) => weekdayMap[r]?[c] ?? 0,
                          rowSymbols: symbols),
                    ],
                  ),
                  // Daily: behavior by date.
                  ListView(
                    padding: const EdgeInsets.all(16.0),
                    children: [
                      _heatmap(context,
                          title: 'Behavior × date',
                          rows: behaviorRows,
                          cols: dateCols,
                          valueAt: (r, c) => dateMap[r]?[c] ?? 0,
                          rowSymbols: symbols,
                          verticalColHeaders: true),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
