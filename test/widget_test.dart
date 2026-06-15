// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:behavior_tracker/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('ABC screen shows Save button', (WidgetTester tester) async {
    // Build the app and wait for frames.
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    // Verify the main ABC screen shows the Save button and voice entry controls.
    expect(find.text('Save ABC Event'), findsOneWidget);
    expect(find.text('View Past Logs'), findsOneWidget);
    // Mic buttons show the idle icon until a field is actively being dictated.
    expect(find.byIcon(Icons.mic_none), findsNWidgets(3));

    // Fill required fields and save the event.
    await tester.tap(find.widgetWithText(DropdownButtonFormField<String>, 'Select Student'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('IS').last);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(DropdownButtonFormField<String>, 'Select Period'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('First').last);
    await tester.pumpAndSettle();

    final behaviorDropdown = find.widgetWithText(DropdownButtonFormField<String>, 'What did the student do?');
    await tester.ensureVisible(behaviorDropdown);
    await tester.pumpAndSettle();
    await tester.tap(behaviorDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Verbal aggression').last);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Save ABC Event'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save ABC Event'));
    await tester.pumpAndSettle();

    expect(find.text('✅ ABC Event Saved!'), findsOneWidget);

    // The form clears automatically after saving, so the dropdown hints return.
    expect(find.text('Select Student'), findsOneWidget);
    expect(find.widgetWithText(DropdownButtonFormField<String>, 'What did the student do?'), findsOneWidget);
  });
}
