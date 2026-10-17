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
/** Model ids of OpenAI-compatible gateways may contain "/", ":" and "@" (for example "vendor/model:free"). */
export const GATEWAY_MODEL_PATTERN = /^[A-Za-z0-9._:/@+-]{1,120}$/;
export const PROVIDER_ID_PATTERN = /^[a-z0-9_-]{1,32}$/;

const COST_POLICIES = new Set(['free_only', 'metered', 'unknown']);

function bool(value, fallback) {
  if (value === undefined || value === null || String(value).trim() === '') return fallback;
  return String(value).trim().toLowerCase() === 'true';
}

function optionalInt(value, min, max) {
  const n = Number.parseInt(value ?? '', 10);
  if (!Number.isFinite(n)) return null;
  return Math.min(max, Math.max(min, n));
}

function csv(value) {
  return String(value ?? '')
    .split(',')
    .map((x) => x.trim().toLowerCase())
    .filter(Boolean);
}

function trimUrl(value, fallback) {
  return String(value ?? '').trim().replace(/\/+$/, '') || fallback;
}

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
    maxBodyBytes: int(env.MAX_BODY_BYTES, 400000, 1024, 1048576),
    maxMessages: int(env.MAX_MESSAGES, 100, 1, 500),
    maxMessageChars: int(env.MAX_MESSAGE_CHARS, 4000, 100, 20000),
    maxContextChars: int(env.MAX_CONTEXT_CHARS, 12000, 500, 200000),
    // Phase 3: text the app extracted from attached files (the app never uploads the files themselves).
    maxAttachments: int(env.MAX_ATTACHMENTS, 5, 1, 10),
    maxAttachmentChars: int(env.MAX_ATTACHMENT_CHARS, 30000, 100, 200000),
    maxAttachmentTotalChars: int(env.MAX_ATTACHMENT_TOTAL_CHARS, 60000, 100, 400000),
    maxMemoryChars: int(env.MAX_MEMORY_CHARS, 3000, 200, 20000),
    rateLimitPerMinute: int(env.RATE_LIMIT_PER_MINUTE, 20, 1, 1000),
    dailyRequestLimit: int(env.DAILY_REQUEST_LIMIT, 300, 1, 1000000),
    trustProxy: env.TRUST_PROXY === 'true',

    // ---- Phase 4: multi-provider orchestration ----
    // Which provider answers when the app does not choose one, and the order tried when the user allowed fallback.
    primaryProvider: (env.AI_PRIMARY_PROVIDER ?? 'gemini').trim().toLowerCase(),
    fallbackOrder: csv(env.AI_FALLBACK_ORDER),
    // A fallback provider that may charge money is refused unless the operator explicitly allows it.
    allowPaidFallback: bool(env.AI_FALLBACK_ALLOW_PAID, false),
    maxAttemptsPerProvider: int(env.AI_MAX_ATTEMPTS_PER_PROVIDER, 2, 1, 3),
    maxTotalAttempts: int(env.AI_MAX_TOTAL_ATTEMPTS, 4, 1, 8),
    backoffBaseMs: int(env.AI_BACKOFF_BASE_MS, 400, 1, 10000),
    backoffCapMs: int(env.AI_BACKOFF_CAP_MS, 4000, 1, 30000),
    maxRetryWaitMs: int(env.AI_MAX_RETRY_WAIT_MS, 5000, 0, 30000),
    requestDeadlineMs: int(env.AI_REQUEST_DEADLINE_MS, 50000, 2000, 110000),
    breakerThreshold: int(env.AI_BREAKER_THRESHOLD, 3, 1, 20),
    breakerBaseMs: int(env.AI_BREAKER_BASE_MS, 15000, 100, 600000),
    breakerMaxMs: int(env.AI_BREAKER_MAX_MS, 120000, 100, 3600000),
    quotaCooldownMs: int(env.AI_QUOTA_COOLDOWN_MS, 900000, 1000, 86400000),
    healthCheckMinIntervalMs: int(env.AI_HEALTH_CHECK_MIN_INTERVAL_MS, 10000, 0, 600000),
    modelCacheMs: int(env.AI_MODEL_CACHE_MS, 600000, 0, 86400000),
    allowUserModelSelection: bool(env.AI_ALLOW_USER_MODEL_SELECTION, true),
    checkRateLimitPerMinute: int(env.CHECK_RATE_LIMIT_PER_MINUTE, 6, 1, 100),

    // ---- Phase 6b: Luxand.cloud 1:1 face verification (optional). The token stays on the server. ----
    face: {
      token: (env.LUXAND_API_TOKEN ?? '').trim(),
      baseUrl: trimUrl(env.LUXAND_BASE_URL, 'https://api.luxand.cloud'),
      // No default on purpose: the operator must measure a threshold. null = matching disabled.
      minSimilarity: (() => {
        const n = Number.parseFloat(env.LUXAND_MIN_SIMILARITY ?? '');
        return Number.isFinite(n) && n > 0 && n <= 1 ? n : null;
      })(),
      // Only for calibration. Leave false in normal use.
      returnScore: bool(env.FACE_RETURN_SCORE, false),
      maxBodyBytes: int(env.FACE_MAX_BODY_BYTES, 1500000, 50000, 6000000),
      maxPhotoBytes: int(env.FACE_MAX_PHOTO_BYTES, 1000000, 20000, 4000000),
      perMinute: int(env.FACE_RATE_LIMIT_PER_MINUTE, 10, 1, 100),
      dailyLimit: int(env.FACE_DAILY_LIMIT, 200, 1, 100000),
      timeoutMs: int(env.FACE_UPSTREAM_TIMEOUT_MS, 20000, 1000, 60000),
    },

    // Per-provider settings. API keys are read here and nowhere else.
    providers: {
      gemini: {
        apiKey: (env.GEMINI_API_KEY ?? '').trim(),
        fallbackEligible: bool(env.GEMINI_FALLBACK_ELIGIBLE, true),
        // The operator states the billing situation; the code cannot know it. 'free' => free_only, anything else is unknown.
        billing: (env.GEMINI_BILLING ?? 'unknown').trim().toLowerCase(),
        maxInputTokens: optionalInt(env.GEMINI_MAX_INPUT_TOKENS, 100, 10000000),
        rpmLimit: optionalInt(env.GEMINI_RPM_LIMIT, 1, 100000),
      },
      groq: {
        apiKey: (env.GROQ_API_KEY ?? '').trim(),
        // '' = no model chosen (provider reports "needs a model"), 'auto' = pick from the live model list, else an exact id.
        model: (env.GROQ_MODEL ?? '').trim(),
        baseUrl: trimUrl(env.GROQ_BASE_URL, 'https://api.groq.com/openai/v1'),
        fallbackEligible: bool(env.GROQ_FALLBACK_ELIGIBLE, true),
        costPolicy: (env.GROQ_COST_POLICY ?? 'unknown').trim().toLowerCase(),
        maxInputTokens: optionalInt(env.GROQ_MAX_INPUT_TOKENS, 100, 10000000),
        rpmLimit: optionalInt(env.GROQ_RPM_LIMIT, 1, 100000),
      },
      openrouter: {
        apiKey: (env.OPENROUTER_API_KEY ?? '').trim(),
        model: (env.OPENROUTER_MODEL ?? '').trim(),
        baseUrl: trimUrl(env.OPENROUTER_BASE_URL, 'https://openrouter.ai/api/v1'),
        fallbackEligible: bool(env.OPENROUTER_FALLBACK_ELIGIBLE, true),
        // Paid models share the same key. Unless this is true, only models whose published price is zero are usable.
        allowPaid: bool(env.OPENROUTER_ALLOW_PAID, false),
        // "deny" asks OpenRouter to avoid hosts that may store prompts. It can leave fewer models available.
        dataCollection: (env.OPENROUTER_DATA_COLLECTION ?? 'deny').trim().toLowerCase(),
        maxInputTokens: optionalInt(env.OPENROUTER_MAX_INPUT_TOKENS, 100, 10000000),
        rpmLimit: optionalInt(env.OPENROUTER_RPM_LIMIT, 1, 100000),
      },
      // Any other OpenAI-compatible service (Cerebras, Mistral, Together, a self-hosted Ollama, ...).
      compat: {
        id: (env.OPENAI_COMPAT_ID ?? 'compat').trim().toLowerCase(),
        displayName: (env.OPENAI_COMPAT_NAME ?? '').trim(),
        apiKey: (env.OPENAI_COMPAT_API_KEY ?? '').trim(),
        baseUrl: trimUrl(env.OPENAI_COMPAT_BASE_URL, ''),
        model: (env.OPENAI_COMPAT_MODEL ?? '').trim(),
        costPolicy: (env.OPENAI_COMPAT_COST_POLICY ?? 'unknown').trim().toLowerCase(),
        fallbackEligible: bool(env.OPENAI_COMPAT_FALLBACK_ELIGIBLE, true),
        // Some local servers need no key. Only allowed together with an http://localhost style address.
        keyOptional: bool(env.OPENAI_COMPAT_KEY_OPTIONAL, false),
        maxInputTokens: optionalInt(env.OPENAI_COMPAT_MAX_INPUT_TOKENS, 100, 10000000),
        rpmLimit: optionalInt(env.OPENAI_COMPAT_RPM_LIMIT, 1, 100000),
      },
    },
  };
}

/** True for http://localhost style addresses, the only plain-http endpoints accepted (so keys never cross the internet unencrypted). */
export function isLocalHttpUrl(value) {
  try {
    const u = new URL(value);
    return u.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(u.hostname);
  } catch {
    return false;
  }
}

function urlProblem(name, value) {
  if (!value) return `${name} is empty.`;
  let u;
  try {
    u = new URL(value);
  } catch {
    return `${name} is not a valid URL.`;
  }
  if (u.username || u.password) return `${name} must not contain credentials.`;
  if (u.search || u.hash) return `${name} must not contain a query or fragment.`;
  if (u.protocol !== 'https:' && !isLocalHttpUrl(value)) return `${name} must use https:// (plain http is accepted only for localhost).`;
  return null;
}

/** Providers that have everything they need to be called (a key, and for the generic one an address). */
export function configuredProviderIds(config) {
  const ids = [];
  const p = config.providers ?? {};
  if (p.gemini?.apiKey) ids.push('gemini');
  if (p.groq?.apiKey) ids.push('groq');
  if (p.openrouter?.apiKey) ids.push('openrouter');
  if (p.compat?.baseUrl && (p.compat.apiKey || p.compat.keyOptional)) ids.push(p.compat.id || 'compat');
  return ids;
}

/** Returns a list of human-readable configuration problems (never includes secret values). */
export function configProblems(config) {
  const problems = [];
  const p = config.providers ?? {};
  if (configuredProviderIds(config).length === 0) {
    problems.push('No AI provider is configured (set GEMINI_API_KEY, GROQ_API_KEY, OPENROUTER_API_KEY or OPENAI_COMPAT_*).');
  }
  if (!config.accessToken && !config.allowUnauthenticated) {
    problems.push('APP_ACCESS_TOKEN is not set (or set ALLOW_UNAUTHENTICATED=true for local testing only).');
  }
  if (!MODEL_PATTERN.test(config.geminiModel)) problems.push('GEMINI_MODEL is empty or has invalid characters.');
  if (config.geminiFallbackModel && !MODEL_PATTERN.test(config.geminiFallbackModel)) {
    problems.push('GEMINI_FALLBACK_MODEL has invalid characters.');
  }
  if (!PROVIDER_ID_PATTERN.test(config.primaryProvider)) problems.push('AI_PRIMARY_PROVIDER has invalid characters.');
  if (p.gemini?.billing && !['free', 'paid', 'unknown'].includes(p.gemini.billing)) problems.push('GEMINI_BILLING must be free, paid or unknown.');
  for (const [key, label] of [['groq', 'GROQ'], ['openrouter', 'OPENROUTER'], ['compat', 'OPENAI_COMPAT']]) {
    const c = p[key];
    if (!c) continue;
    if (c.model && c.model !== 'auto' && !GATEWAY_MODEL_PATTERN.test(c.model)) problems.push(`${label}_MODEL has invalid characters.`);
    if (c.costPolicy !== undefined && !COST_POLICIES.has(c.costPolicy)) problems.push(`${label}_COST_POLICY must be free_only, metered or unknown.`);
    const used = key === 'compat' ? Boolean(c.baseUrl || c.apiKey) : Boolean(c.apiKey);
    if (used) {
      const issue = urlProblem(`${label}_BASE_URL`, c.baseUrl);
      if (issue) problems.push(issue);
    }
  }
  if (p.compat && (p.compat.baseUrl || p.compat.apiKey)) {
    if (!PROVIDER_ID_PATTERN.test(p.compat.id)) problems.push('OPENAI_COMPAT_ID has invalid characters.');
    if (['gemini', 'groq', 'openrouter'].includes(p.compat.id)) problems.push('OPENAI_COMPAT_ID must differ from the built-in provider ids.');
    if (!p.compat.baseUrl) problems.push('OPENAI_COMPAT_BASE_URL is not set.');
    if (p.compat.baseUrl && !p.compat.apiKey && !(p.compat.keyOptional && isLocalHttpUrl(p.compat.baseUrl))) {
      problems.push('OPENAI_COMPAT_API_KEY is not set (a missing key is only accepted for a localhost address with OPENAI_COMPAT_KEY_OPTIONAL=true).');
    }
  }
  if (p.openrouter && !['allow', 'deny'].includes(p.openrouter.dataCollection)) problems.push('OPENROUTER_DATA_COLLECTION must be allow or deny.');
  return problems;
}

/** Non-fatal advice for the operator (printed at start-up). Never includes secret values. */
export function configWarnings(config) {
  const warnings = [];
  if (config.accessToken && config.accessToken.length < 16) warnings.push('APP_ACCESS_TOKEN is shorter than 16 characters; use a long random string.');
  if (config.allowUnauthenticated) warnings.push('ALLOW_UNAUTHENTICATED=true: every endpoint is open. Use only for local testing.');
  const ids = configuredProviderIds(config);
  if (ids.length > 0 && !ids.includes(config.primaryProvider)) {
    warnings.push(`AI_PRIMARY_PROVIDER "${config.primaryProvider}" is not configured; "${ids[0]}" will answer instead.`);
  }
  for (const id of config.fallbackOrder) {
    if (!ids.includes(id)) warnings.push(`AI_FALLBACK_ORDER lists "${id}", which is not configured.`);
  }
  return warnings;
}
