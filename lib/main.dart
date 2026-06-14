import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:fl_chart/fl_chart.dart';

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

class OpenAIClient {
  static Future<String?> generateDescription({required String apiKey, required String prompt}) async {
    final uri = Uri.parse('https://api.openai.com/v1/chat/completions');
    final body = jsonEncode({
      'model': 'gpt-3.5-turbo',
      'messages': [
        {'role': 'system', 'content': 'You are a concise assistant that rewrites user notes.'},
        {'role': 'user', 'content': prompt}
      ],
      'max_tokens': 200,
      'temperature': 0.2,
    });

    final response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: body,
    );

    if (response.statusCode == 200) {
      final Map<String, dynamic> decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final choices = decoded['choices'] as List<dynamic>?;
      if (choices != null && choices.isNotEmpty) {
        final message = choices[0]['message'] as Map<String, dynamic>?;
        return message != null ? (message['content'] as String?)?.trim() : null;
      }
      return null;
    } else {
      throw Exception('OpenAI API error: ${response.statusCode} ${response.body}');
    }
  }
}

class ABCLoggingScreen extends StatefulWidget {
  const ABCLoggingScreen({super.key});

  @override
  State<ABCLoggingScreen> createState() => _ABCLoggingScreenState();
}

class _ABCLoggingScreenState extends State<ABCLoggingScreen> {
  final _formKey = GlobalKey<FormState>();

  String? selectedStudent;
  String? selectedPeriod;
  String? selectedAntecedent;
  String? selectedBehavior;
  String? selectedConsequence;
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

  final List<String> students = ["CH", "EG", "IS", "LTG", "NR"];
  final List<String> periods = ["Bus a.m.", "Advisory", "First", "Second", "Third", "Fourth", "Lunch", "Fifth", "Sixth", "Seventh", "Bus p.m."];
  final List<String> antecedents = ["Given demand", "Told to wait", "Given corrective feedback", "Activity transition", "Unexpected change", "Divided attention", "Presence of a specific person", "Left alone", "Activity denied", "Activity interrupted", "Redirection"];
  final List<String> behaviors = ["Verbal aggression", "Threat", "Physical aggression", "Not in designated area", "Leaving building/campus", "Property destruction", "Property misuse", "Stealing"];
  final List<String> consequences = ["Verbal redirection", "Behavior ignored", "Removed from activity", "Removed item", "Reprimand", "Left alone", "Blocked", "Sent to take a break", "Given another activity", "Given preferred item", "Peer remarks", "Being followed by staff"];
  final List<String> staffMembers = ["RC", "KM", "MM", "KR"];

  @override
  void initState() {
    super.initState();
    _initSpeech();
    _loadSavedLogs();
  }

  Future<String?> _getStoredApiKey() async {
    try {
      return await _secureStorage.read(key: 'openai_api_key');
    } catch (_) {
      return null;
    }
  }

  Future<void> _storeApiKey(String key) async {
    await _secureStorage.write(key: 'openai_api_key', value: key.trim());
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
          title: const Text('OpenAI API Key'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(hintText: 'sk-...'),
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
    final apiKey = await _getStoredApiKey();
    if (apiKey == null || apiKey.isEmpty) {
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
      generated = await OpenAIClient.generateDescription(apiKey: apiKey, prompt: prompt);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('AI generation failed: $e')));
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
          'model': 'gpt-3.5-turbo',
          'timestamp': DateTime.now().toIso8601String(),
        };
      });
    }
  }

  Future<void> _initSpeech() async {
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
          parsed.add(Map<String, dynamic>.from(jsonDecode(jsonEntry) as Map<String, dynamic>));
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

  Map<String, dynamic> _buildLogEntry() {
    return {
      'student': selectedStudent ?? '',
      'period': selectedPeriod ?? '',
      'antecedent': selectedAntecedent ?? '',
      'antecedentDescription': antecedentDescController.text,
      'behavior': selectedBehavior ?? '',
      'behaviorDescription': behaviorDescController.text,
      'consequence': selectedConsequence ?? '',
      'consequenceDescription': consequenceDescController.text,
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
      selectedStudent = null;
      selectedPeriod = null;
      selectedAntecedent = null;
      selectedBehavior = null;
      selectedConsequence = null;
      selectedStaff = null;
      antecedentDescController.clear();
      behaviorDescController.clear();
      consequenceDescController.clear();
      selectedDateTime = DateTime.now();
      _lastAiMeta = null;
    });
  }

  Future<void> _saveLog() async {
    if (_formKey.currentState!.validate()) {
      final logEntry = _buildLogEntry();
      setState(() {
        _savedLogs.insert(0, logEntry);
        _lastAiMeta = null;
      });
      await _persistSavedLogs();
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('✅ ABC Event Saved!'),
          action: SnackBarAction(
            label: 'Log Another Behavior',
            onPressed: _resetForm,
          ),
        ),
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
        title: const Text('New ABC Behavior Log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'History',
            onPressed: _savedLogs.isNotEmpty ? _openHistoryScreen : null,
          ),
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
                initialValue: selectedPeriod,
                hint: const Text("Select Period"),
                items: periods.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
                onChanged: (v) => setState(() => selectedPeriod = v),
                validator: (v) => v == null ? "Required" : null,
              ),
              const SizedBox(height: 24),

              Text("Antecedent", style: sectionHeadingStyle),
              DropdownButtonFormField<String>(
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
              Text("Logged by", style: sectionHeadingStyle),
              DropdownButtonFormField<String>(
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
      appBar: AppBar(title: Text('Past Logs - $student')),
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
