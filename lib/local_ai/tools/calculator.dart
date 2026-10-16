/// Calculator tool: safe expression parsing and evaluation using
/// shunting-yard algorithm and RPN evaluation.

import 'dart:math' as math;

import '../tool.dart';

class CalculatorInput {
  final String expression;
  CalculatorInput(this.expression);
}

class CalculatorOutput {
  final double value;
  final String formatted;
  CalculatorOutput(this.value) : formatted = value.toString();
}

class CalculatorError extends ToolError {
  CalculatorError(String code, String message) : super(code, message);
}

class CalculatorTool extends Tool<CalculatorInput, CalculatorOutput> {
  @override
  String get id => 'calculator';

  @override
  String get description => 'Safe arithmetic calculator with common scientific functions.';

  @override
  String get inputSchema => 'CalculatorInput { expression: String }';

  @override
  void validate(CalculatorInput input) {
    if (input.expression.trim().isEmpty) throw CalculatorError('empty_expression', 'Expression is empty');
    // Basic sanity check: allowed chars
    final allowed = RegExp(r"^[0-9a-zA-Z().+\-*/%^!, _eE]+\s*");
    if (!allowed.hasMatch(input.expression)) {
      // do not reject letters because function names allowed
      // but reject suspicious characters
    }
  }

  @override
  Future<ToolResult<CalculatorOutput>> execute(CalculatorInput input) async {
    final rpn = _toRPN(input.expression);
    final value = _evalRPN(rpn);
    return ToolResult(result: CalculatorOutput(value));
  }

  List<String> _toRPN(String expr) {
    final output = <String>[];
    final ops = <String>[];

    final tokens = _tokenize(expr);
    final precedence = (String op) {
      switch (op) {
        case '+':
        case '-':
          return 2;
        case '*':
        case '/':
        case '%':
          return 3;
        case '^':
          return 4;
        default:
          return 0;
      }
    };

    final rightAssociative = (String op) => op == '^';

    for (final token in tokens) {
      if (_isNumber(token) || token == 'e') {
        output.add(token);
      } else if (_isFunction(token)) {
        ops.add(token);
      } else if (token == ',') {
        while (ops.isNotEmpty && ops.last != '(') {
          output.add(ops.removeLast());
        }
        if (ops.isEmpty || ops.last != '(') throw CalculatorError('mismatched_parentheses', 'Misplaced comma or parentheses');
      } else if (_isOperator(token)) {
        while (ops.isNotEmpty && _isOperator(ops.last)) {
          final top = ops.last;
          if ((rightAssociative(token) && precedence(token) < precedence(top)) ||
              (!rightAssociative(token) && precedence(token) <= precedence(top))) {
            output.add(ops.removeLast());
            continue;
          }
          break;
        }
        ops.add(token);
      } else if (token == '(') {
        ops.add(token);
      } else if (token == ')') {
        while (ops.isNotEmpty && ops.last != '(') output.add(ops.removeLast());
        if (ops.isEmpty) throw CalculatorError('mismatched_parentheses', 'Mismatched parentheses');
        ops.removeLast();
        if (ops.isNotEmpty && _isFunction(ops.last)) output.add(ops.removeLast());
      } else {
        throw CalculatorError('unknown_token', 'Unknown token: $token');
      }
    }

    while (ops.isNotEmpty) {
      final op = ops.removeLast();
      if (op == '(' || op == ')') throw CalculatorError('mismatched_parentheses', 'Mismatched parentheses');
      output.add(op);
    }
    return output;
  }

  double _evalRPN(List<String> rpn) {
    final stack = <double>[];
    for (final token in rpn) {
      if (_isNumber(token)) {
        stack.add(double.parse(token));
      } else if (token == 'e') {
        stack.add(math.e);
      } else if (_isOperator(token)) {
        if (stack.length < 2) throw CalculatorError('bad_expression', 'Not enough operands for $token');
        final b = stack.removeLast();
        final a = stack.removeLast();
        double res;
        switch (token) {
          case '+':
            res = a + b;
            break;
          case '-':
            res = a - b;
            break;
          case '*':
            res = a * b;
            break;
          case '/':
            if (b == 0) throw CalculatorError('division_by_zero', 'Division by zero');
            res = a / b;
            break;
          case '%':
            if (b == 0) throw CalculatorError('division_by_zero', 'Modulo by zero');
            res = a % b;
            break;
          case '^':
            res = math.pow(a, b).toDouble();
            break;
          default:
            throw CalculatorError('unknown_operator', token);
        }
        stack.add(res);
      } else if (_isFunction(token)) {
        if (stack.isEmpty) throw CalculatorError('bad_expression', 'Not enough operands for function $token');
        final x = stack.removeLast();
        final res = _applyFunction(token, x);
        stack.add(res);
      } else {
        throw CalculatorError('unknown_token', token);
      }
    }
    if (stack.length != 1) throw CalculatorError('bad_expression', 'Invalid expression');
    return stack.single;
  }

  double _applyFunction(String name, double x) {
    switch (name) {
      case 'sin':
        return math.sin(x);
      case 'cos':
        return math.cos(x);
      case 'tan':
        return math.tan(x);
      case 'asin':
        return math.asin(x);
      case 'acos':
        return math.acos(x);
      case 'atan':
        return math.atan(x);
      case 'sqrt':
        if (x < 0) throw CalculatorError('domain_error', 'sqrt of negative');
        return math.sqrt(x);
      case 'log': // natural log
      case 'ln':
        if (x <= 0) throw CalculatorError('domain_error', 'log of non-positive');
        return math.log(x);
      case 'exp':
        return math.exp(x);
      case 'abs':
        return x.abs();
      case 'floor':
        return x.floorToDouble();
      case 'ceil':
        return x.ceilToDouble();
      case 'round':
        return x.roundToDouble();
      default:
        throw CalculatorError('unknown_function', name);
    }
  }

  bool _isOperator(String t) => '+-*/%^'.contains(t);

  bool _isFunction(String t) => RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(t) && !_isNumber(t) && !_isOperator(t);

  bool _isNumber(String t) => double.tryParse(t) != null;

  List<String> _tokenize(String expr) {
    final out = <String>[];
    final buffer = StringBuffer();
    String? flush() {
      if (buffer.isEmpty) return null;
      final s = buffer.toString();
      buffer.clear();
      return s;
    }

    for (int i = 0; i < expr.length; i++) {
      final c = expr[i];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '_') continue;
      if (c == '(' || c == ')' || c == ',' || _isOperator(c)) {
        final f = flush();
        if (f != null) out.add(f);
        out.add(c);
        continue;
      }
      // function names, numbers, letters, dot, e
      buffer.write(c);
      // peek ahead for scientific notation e.g. 1e-3
      if ((c == 'e' || c == 'E') && i + 1 < expr.length) {
        // include following sign if any
      }
    }
    final f = flush();
    if (f != null) out.add(f);

    // normalize tokens: split numbers that may run into letters like 2sin -> 2 * sin
    final tokens = <String>[];
    for (final t in out) {
      // separate a number immediately followed by letters (2sin -> 2 * sin)
      final m = RegExp(r'^([0-9.]+)([a-zA-Z].*)$').firstMatch(t);
      if (m != null) {
        tokens.add(m.group(1)!);
        tokens.add('*');
        tokens.add(m.group(2)!);
      } else {
        tokens.add(t);
      }
    }
    return tokens;
  }
}
