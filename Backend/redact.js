/**
 * Secret redaction (Phase 4). Used on every log line and on any text that could ever reach a client.
 * Two layers: (1) exact configured secrets, (2) generic credential-looking patterns, so a key that was
 * never configured (for example one echoed back by an upstream error) is still masked.
 */
const MASK = '[redacted]';

const PATTERNS = [
  /\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/gi,
  /\bsk-[A-Za-z0-9_-]{8,}/g,
  /\bgsk_[A-Za-z0-9]{8,}/g,
  /\bAIza[0-9A-Za-z_-]{10,}/g,
  /((?:api[_-]?key|access[_-]?token|secret|authorization|x-goog-api-key)["']?\s*[=:]\s*["']?)[^\s"',;&]{4,}/gi,
];

/** Returns a function that masks the given secrets (min length 6, to avoid masking common words) and key-like patterns. */
export function createRedactor(secrets = []) {
  const exact = [...new Set(secrets.filter((s) => typeof s === 'string' && s.length >= 6))].sort((a, b) => b.length - a.length);
  return function redact(text) {
    if (typeof text !== 'string' || text.length === 0) return text;
    let out = text;
    for (const secret of exact) {
      if (out.includes(secret)) out = out.split(secret).join(MASK);
    }
    out = out.replace(PATTERNS[0], `Bearer ${MASK}`);
    out = out.replace(PATTERNS[1], MASK).replace(PATTERNS[2], MASK).replace(PATTERNS[3], MASK);
    out = out.replace(PATTERNS[4], `$1${MASK}`);
    return out;
  };
}

/** Collects every secret value the configuration holds so they can be redacted. */
export function secretsOf(config) {
  const list = [config.accessToken, config.geminiApiKey, config.face?.token];
  for (const p of Object.values(config.providers ?? {})) list.push(p?.apiKey);
  return list.filter(Boolean);
}
