const DEFAULT_SYSTEM_PROMPT =
  'You are Almus, a friendly, capable personal AI assistant living in an Android app. ' +
  'Reply in the same language the user writes in (for example English or Hausa). ' +
  'Keep answers clear and reasonably short for a phone screen unless the user asks for detail. ' +
  'Be honest when you are unsure, and do not invent facts. ' +
  'You have no memory of earlier conversations. The only personal facts you may rely on are the ones the user states in this chat and any "LOCAL MEMORY NOTES" block in these instructions. ' +
  'Never claim to remember something that is not provided.';

function int(value, fallback, min, max) {
  const n = Number.parseInt(value ?? '', 10);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, n));
}

function float(value, fallback, min, max) {
  const n = Number.parseFloat(value ?? '');
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, n));
}

const MODEL_PATTERN = /^[A-Za-z0-9._-]{1,100}$/;

/** Reads every setting from environment variables. Nothing is hardcoded in the code paths. */
export function loadConfig(env = process.env) {
  return {
    port: int(env.PORT, 8080, 1, 65535),

    // Secrets (server side only).
    geminiApiKey: (env.GEMINI_API_KEY ?? '').trim(),
    accessToken: (env.APP_ACCESS_TOKEN ?? '').trim(),
    allowUnauthenticated: env.ALLOW_UNAUTHENTICATED === 'true',

    // Model selection. Change these in the hosting dashboard, no code edit needed.
    geminiModel: (env.GEMINI_MODEL ?? 'gemini-flash-latest').trim(),
    geminiFallbackModel: (env.GEMINI_FALLBACK_MODEL ?? '').trim(),
    geminiBaseUrl: (env.GEMINI_BASE_URL ?? 'https://generativelanguage.googleapis.com/v1beta').replace(/\/+$/, ''),

    systemPrompt: (env.SYSTEM_PROMPT ?? '').trim() || DEFAULT_SYSTEM_PROMPT,
    maxOutputTokens: int(env.MAX_OUTPUT_TOKENS, 2048, 64, 8192),
    temperature: float(env.TEMPERATURE, 0.7, 0, 2),
    upstreamTimeoutMs: int(env.UPSTREAM_TIMEOUT_MS, 25000, 1000, 120000),

    // Request limits and abuse protection.
    maxBodyBytes: int(env.MAX_BODY_BYTES, 65536, 1024, 1048576),
    maxMessages: int(env.MAX_MESSAGES, 100, 1, 500),
    maxMessageChars: int(env.MAX_MESSAGE_CHARS, 4000, 100, 20000),
    maxContextChars: int(env.MAX_CONTEXT_CHARS, 12000, 500, 200000),
    maxMemoryChars: int(env.MAX_MEMORY_CHARS, 3000, 200, 20000),
    rateLimitPerMinute: int(env.RATE_LIMIT_PER_MINUTE, 20, 1, 1000),
    dailyRequestLimit: int(env.DAILY_REQUEST_LIMIT, 300, 1, 1000000),
    trustProxy: env.TRUST_PROXY === 'true',
  };
}

/** Returns a list of human-readable configuration problems (never includes secret values). */
export function configProblems(config) {
  const problems = [];
  if (!config.geminiApiKey) problems.push('GEMINI_API_KEY is not set.');
  if (!config.accessToken && !config.allowUnauthenticated) {
    problems.push('APP_ACCESS_TOKEN is not set (or set ALLOW_UNAUTHENTICATED=true for local testing only).');
  }
  if (!MODEL_PATTERN.test(config.geminiModel)) problems.push('GEMINI_MODEL is empty or has invalid characters.');
  if (config.geminiFallbackModel && !MODEL_PATTERN.test(config.geminiFallbackModel)) {
    problems.push('GEMINI_FALLBACK_MODEL has invalid characters.');
  }
  return problems;
}
