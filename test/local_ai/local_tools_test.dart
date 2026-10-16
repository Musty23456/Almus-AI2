// Tests for the local tools: calculator, statistics, unit conversion, datetime, text.

import 'package:flutter_test/flutter_test.dart';
import 'package:almus_ai/local_ai/tools/calculator.dart';
import 'package:almus_ai/local_ai/tools/unit_conversion.dart';
import 'package:almus_ai/local_ai/tools/text_tools.dart';

void main() {
  group('Calculator', () {
    final calc = CalculatorTool();
    test('simple arithmetic', () async {
      final res = await calc.execute(CalculatorInput('2+3*4'));
      expect(res.result.value, 14);
    });
    test('parentheses', () async {
      final res = await calc.execute(CalculatorInput('(2+3)*4'));
      expect(res.result.value, 20);
    });
    test('functions', () async {
      final res = await calc.execute(CalculatorInput('sqrt(16)+sin(0)'));
      expect(res.result.value, 4);
    });
    test('division by zero', () async {
      expect(() async => await calc.execute(CalculatorInput('1/0')), throwsA(isA<CalculatorError>()));
    });
  });

  group('Unit conversion', () {
    final u = UnitConversionTool();
    test('km to m', () async {
      final res = await u.execute(UnitConversionInput(value: 1, from: 'km', to: 'm'));
      expect(res.result.value, 1000);
    });
    test('c to f', () async {
      final res = await u.execute(UnitConversionInput(value: 0, from: 'c', to: 'f'));
      expect(res.result.value, 32);
    });
  });

  group('Text tools', () {
    final t = TextTools();
    test('counts and transform', () async {
      final res = await t.execute(TextToolsInput(text: 'Hello world\\nThis is a test', transform: 'upper'));
      expect(res.result.words, 5);
      expect(res.result.lines, 2);
      expect(res.result.transformed, 'HELLO WORLD\\nTHIS IS A TEST');
    });
  });
}
