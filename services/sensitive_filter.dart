/// How risky it is to keep a piece of text as a permanent memory.
enum Sensitivity {
  /// Nothing risky was detected.
  none,

  /// Personal topics (health, religion, money...). Allowed only after the
  /// user explicitly confirms. Never suggested automatically.
  sensitive,

  /// Secrets or identity/payment numbers. Never stored.
  blocked,
}

class SensitivityResult {
  const SensitivityResult(this.level, [this.reason = '']);

  final Sensitivity level;

  /// Short user-facing reason, e.g. "health" or "a password".
  final String reason;

  static const SensitivityResult clear = SensitivityResult(Sensitivity.none);
}

class _Rule {
  _Rule(this.reason, String pattern)
      : regex = RegExp(pattern, caseSensitive: false, unicode: true);

  final String reason;
  final RegExp regex;
}

final List<_Rule> _blockedRules = <_Rule>[
  _Rule(
    'a password, PIN or secret key',
    r'\b(?:password|passcode|passphrase|cvv|cvc|otp|api[ _-]?key|secret[ _-]?key|access[ _-]?token|private[ _-]?key|seed phrase|pin (?:number|code))\b',
  ),
  _Rule('a card or account number', r'(?:\d[ -]?){13,19}'),
  _Rule('an ID number', r'\b\d{3}-\d{2}-\d{4}\b'),
  _Rule(
    'an ID or account number',
    r"\b(?:bvn|nin|ssn|passport|driver'?s? licen[cs]e|national id|id number|account number|iban|routing number)\b",
  ),
  _Rule('a secret key', r'\b(?:sk|pk)-[A-Za-z0-9]{16,}'),
  _Rule('a secret key', r'AIza[0-9A-Za-z_\-]{20,}'),
  _Rule('a secret key', r'\b[A-Za-z0-9_\-]{32,}\b'),
];

final List<_Rule> _sensitiveRules = <_Rule>[
  _Rule(
    'health',
    r'\b(?:diagnos\w*|medical|medication|illness|disease|disorder|cancer|diabet\w*|hiv\b|aids\b|pregnan\w*|depress\w*|anxiety|therap(?:y|ist)|mental health|surgery|disabilit\w*|allerg\w*|epilep\w*|asthma|hypertension|rashin lafiya|ciwon)',
  ),
  _Rule(
    'religion',
    r'\b(?:muslim|christian|islam\w*|church|mosque|religio\w*|atheist|jewish|hindu|buddhis\w*|addini|musulm\w*)',
  ),
  _Rule('politics', r'\b(?:politic\w*|vote\b|voted|voting|election|party member)'),
  _Rule('sexuality', r'\b(?:gay\b|lesbian|bisexual|transgender|lgbt\w*|sexual\w*|sex life)'),
  _Rule(
    'money',
    r'\b(?:salary|income|debt|loan|bankrupt\w*|net worth|credit score|mortgage|bashi|owe money|savings)',
  ),
  _Rule(
    'legal or immigration',
    r'\b(?:arrest\w*|lawsuit|sued\b|criminal|convict\w*|prison|jail|police record|immigration|asylum|visa status)',
  ),
  _Rule('your home address', r'\b(?:home address|my address|street address|i live at)\b'),
  _Rule('ethnicity', r'\b(?:racial|ethnic\w*)'),
];

/// Best-effort check with simple patterns. It cannot catch everything, which
/// is why nothing is ever saved without the user's confirmation.
SensitivityResult checkSensitivity(String text) {
  for (final _Rule rule in _blockedRules) {
    if (rule.regex.hasMatch(text)) {
      return SensitivityResult(Sensitivity.blocked, rule.reason);
    }
  }
  for (final _Rule rule in _sensitiveRules) {
    if (rule.regex.hasMatch(text)) {
      return SensitivityResult(Sensitivity.sensitive, rule.reason);
    }
  }
  return SensitivityResult.clear;
}
