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
const String kBuildTag = 'v16';

/// Master switch for the generative-AI features (FBA analysis + the "Generate
/// Description" helper). Turned OFF during the pilot so no student data is sent
/// to Anthropic until the FERPA data agreements are in place. Flip to true to
/// re-enable everywhere.
const bool kAiFeaturesEnabled = false;

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

  final List<String> students = ["CH", "EG", "IS", "LTG", "NR"];
  final List<String> periods = ["Bus a.m.", "Advisory", "First", "Second", "Third", "Fourth", "Lunch", "Fifth", "Sixth", "Seventh", "Bus p.m."];
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
      final localOnly =
          _savedLogs.where((e) => e['id'] != null && !serverIds.contains(e['id'])).toList();
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
            icon: const Icon(Icons.history),
            tooltip: 'History',
            onPressed: _savedLogs.isNotEmpty ? _openHistoryScreen : null,
          ),
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Export all data (CSV)',
            onPressed: _exportData,
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

    final entries = frequency.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    final total = entries.fold<int>(0, (sum, e) => sum + e.value);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Strategies used by frequency', style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(child: Text('Strategy', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
                  const SizedBox(width: 16),
                  Text('Count', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(width: 24),
                  Text('Share', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            const Divider(),
            ...entries.map((entry) {
              final share = total > 0 ? (entry.value / total) * 100 : 0.0;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(child: Text(entry.key, style: labelStyle)),
                    const SizedBox(width: 16),
                    Text(entry.value.toString(), style: subtitleStyle),
                    const SizedBox(width: 24),
                    Text('${share.toStringAsFixed(1)}%', style: subtitleStyle),
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
    final strategyEntries = strategies.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
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

    final periods = frequencyByPeriod.keys.toList();
    final counts = frequencyByPeriod.values.toList();
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
                  barTouchData: BarTouchData(enabled: true),
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
                  barTouchData: BarTouchData(enabled: true),
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
                          if (index < 0 || index >= keys.length || !_showLabelAt(index, keys.length)) {
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
                          if (index < 0 || index >= keys.length || !_showLabelAt(index, keys.length)) {
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
                Text('Overall Behavior Summary', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14.0),
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
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(child: Text('Behavior', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
                                      const SizedBox(width: 16),
                                      Text('Count', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                                      const SizedBox(width: 24),
                                      Text('Share', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                                    ],
                                  ),
                                ),
                                const Divider(),
                                ...overallFrequency.entries.map((entry) {
                                  final share = totalCount > 0 ? (entry.value / totalCount) * 100 : 0.0;
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 2.0),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Expanded(child: Text(entry.key, style: frequencyLabelStyle)),
                                        const SizedBox(width: 16),
                                        Text(entry.value.toString(), style: subtitleStyle),
                                        const SizedBox(width: 24),
                                        Text('${share.toStringAsFixed(1)}%', style: subtitleStyle),
                                      ],
                                    ),
                                  );
                                }),
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
                Text('Daily Behavior Frequency', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                ...dates.map((date) {
                  final dateFrequency = frequency[date]!;
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(date, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 8),
                          ...dateFrequency.entries.map((entry) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2.0),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(child: Text(entry.key, style: frequencyLabelStyle)),
                                  const SizedBox(width: 16),
                                  Text(entry.value.toString(), style: subtitleStyle),
                                ],
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 24),
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

  const StudentAiAnalysisScreen({
    super.key,
    required this.student,
    required this.apiKey,
    required this.userPrompt,
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
        systemPrompt: _systemPrompt,
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
        title: Text('AI Analysis - ${widget.student}'),
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
