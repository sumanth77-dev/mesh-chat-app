// This file intentionally left minimal.
// Widget tests for RelayX require physical WiFi Direct hardware.
// Run integration tests on real devices instead.

import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Placeholder test — mesh requires real device testing',
      (WidgetTester tester) async {
    // RelayX uses WiFi Direct which cannot be tested in a simulator.
    // See testing instructions in README.md.
    expect(true, isTrue);
  });
}
