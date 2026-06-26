import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_teststand_inspector/src/properties_view.dart';
import 'package:labwright_teststand_inspector/src/property_outline.dart';

void main() {
  Future<void> pump(WidgetTester tester, PropertyNode root) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: PropertiesView(root: root))));

  testWidgets('shows an "overridden" marker on a %INSTOVRD node', (tester) async {
    final root = PropertyNode(
      name: 'Data',
      children: [
        PropertyNode(
          name: 'TS',
          attributes: const {'%INSTOVRD': '5046297'},
          children: const [],
        ),
      ],
    );
    await pump(tester, root);
    // The distinct title marker renders (the RichText title carries it).
    expect(find.textContaining('overridden', findRichText: true), findsOneWidget);
  });

  testWidgets('a plain node shows no override marker', (tester) async {
    final root = PropertyNode(
      name: 'Data',
      children: [
        PropertyNode(name: 'Mode', value: 'Normal', children: const []),
      ],
    );
    await pump(tester, root);
    expect(find.textContaining('overridden', findRichText: true), findsNothing);
  });
}
