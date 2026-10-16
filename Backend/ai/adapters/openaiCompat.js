import { Category, ProviderError } from '../errors.js';
import { parseRetryAfterMs, providerFetch, tryParseJson } from '../http.js';
import { buildSystemText } from '../messages.js';

const NON_CHAT_MODEL = /whisper|orpheus|tts|guard|safeguard|embed|moderat|transcri|speech|rerank/i;
const DAILY_QUOTA = /per[\s-]?day|\bTPD\b|\bRPD\b|daily/i;
const MODERATION = /moderation|flagged|content[\s_-]?policy|safety/i;
const CONTEXT_HINT = /context[\s_-]?(length|window)|too (large|long)|maximum.*tokens|reduce the length/i;

function numberOrNull(v) {
  return Number.isFinite(v) ? v : null;
}

function priceIsZero(v) {
  if (v === undefined || v === null) return null;
  const n = Number(v);
  return Number.isFinite(n) ? n === 0 : null;
}

/** Turns one entry of a /models response into the neutral shape used for routing and for the settings screen. */
export function normalizeModel(raw) {
  const id = String(raw?.id ?? '');
  const prompt = priceIsZero(raw?.pricing?.prompt);
  const completion = priceIsZero(raw?.pricing?.completion);
  const free = prompt === null || completion === null ? null : prompt && completion;
  return {
    id,
    name: typeof raw?.name === 'string' ? raw.name : null,
    contextTokens: numberOrNull(raw?.context_window ?? raw?.context_length ?? raw?.top_provider?.context_length),
    maxOutputTokens: numberOrNull(raw?.max_completion_tokens ?? raw?.top_provider?.max_completion_tokens),
    inputModalities: Array.isArray(raw?.architecture?.input_modalities) ? raw.architecture.input_modalities : null,
    outputModalities: Array.isArray(raw?.architecture?.output_modalities) ? raw.architecture.output_modalities : null,
    free,
    active: raw?.active === false ? false : true,
  };
}

/**
 * Classifies an HTTP error from an OpenAI-style API. Pure function so it can be unit tested for every status.
 * Never reads or keeps upstream text beyond pattern matching.
 */
export function classifyOpenAIError(status, headers, bodyText) {
  const json = tryParseJson(bodyText);
  const err = json?.error ?? {};
  const message = String(err.message ?? '');
  const code = String(err.code ?? '');
  const type = String(err.type ?? '');
  const retryAfterMs = parseRetryAfterMs(headers?.get?.('retry-after'));
  const metaSource = String(err.metadata?.limit_source ?? '');

  if (status === 402) {
    if (metaSource === 'openrouter_in_flight_budget') {
      return new ProviderError(Category.RATE_LIMITED, { status, retryAfterMs, safeToRetry: true });
    }
    return new ProviderError(Category.PAYMENT_REQUIRED, { status });
  }
  if (status === 401 || /invalid_api_key|authentication/i.test(`${code} ${type}`)) return new ProviderError(Category.AUTH, { status });
  if (status === 403) {
    if (MODERATION.test(`${message} ${JSON.stringify(err.metadata ?? {})}`)) return new ProviderError(Category.CONTENT_BLOCKED, { status });
    return new ProviderError(Category.AUTH, { status });
  }
  if (status === 404 || /model_not_found|model_decommissioned|model_not_available/i.test(code)) {
    return new ProviderError(Category.MODEL_NOT_FOUND, { status });
  }
  if (status === 413 || /context_length_exceeded/i.test(code)) return new ProviderError(Category.CONTEXT_TOO_LARGE, { status });
  if (status === 429) {
    if (/insufficient_quota/i.test(code)) return new ProviderError(Category.QUOTA_EXHAUSTED, { status, quotaWindow: 'day' });
    const daily = DAILY_QUOTA.test(`${message} ${code}`) || (retryAfterMs !== undefined && retryAfterMs >= 600_000);
    if (daily) return new ProviderError(Category.QUOTA_EXHAUSTED, { status, retryAfterMs, quotaWindow: 'day' });
    return new ProviderError(Category.RATE_LIMITED, { status, retryAfterMs, quotaWindow: 'minute', safeToRetry: true });
  }
  if (status === 400 || status === 422) {
    if (CONTEXT_HINT.test(message)) return new ProviderError(Category.CONTEXT_TOO_LARGE, { status });
    return new ProviderError(Category.BAD_REQUEST, { status });
  }
  if (status === 408) return new ProviderError(Category.UNAVAILABLE, { status });
  if (status === 503 || status === 529) return new ProviderError(Category.UNAVAILABLE, { status, retryAfterMs, safeToRetry: true });
  if (status >= 500) return new ProviderError(Category.UNAVAILABLE, { status });
  return new ProviderError(Category.UNKNOWN, { status });
}

function extractText(message) {
  const content = message?.content;
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) return content.map((p) => (typeof p?.text === 'string' ? p.text : '')).join('');
  return '';
}

/**
 * A provider adapter for any service that speaks the OpenAI "chat completions" protocol.
 * Groq, OpenRouter and the operator-defined generic provider are all created from this one factory, so a new
 * compatible service is configuration, not code.
 */
export function createOpenAICompatProvider(o) {
  const {
    id,
    displayName,
    baseUrl,
    apiKey,
    keyOptional = false,
    configuredModel = '',
    fetchImpl = globalThis.fetch,
    config,
    costPolicy = 'unknown',
    fallbackEligible = true,
    docsUrl = null,
    dataNote = '',
    limitsNote = 'Limits depend on the provider and your plan and can change. Check the provider dashboard.',
    maxInputTokens = null,
    rpmLimit = null,
    tokenParam = 'max_tokens',
    extraBody = () => ({}),
    extraHeaders = {},
    freeOnly = false,
    keyCheckPath = null,
    parseKeyCheck = null,
    isChatModel = (m) => !NON_CHAT_MODEL.test(m.id),
  } = o;

  function authHeaders() {
    const h = { 'content-type': 'application/json', accept: 'application/json', ...extraHeaders };
    if (apiKey) h.authorization = `Bearer ${apiKey}`;
    return h;
  }

  async function call(path, { method = 'GET', body, signal, timeoutMs } = {}) {
    const res = await providerFetch({
      fetchImpl,
      url: `${baseUrl}${path}`,
      method,
      headers: authHeaders(),
      body,
      timeoutMs: timeoutMs ?? config.upstreamTimeoutMs,
      signal,
    });
    if (!res.ok) throw classifyOpenAIError(res.status, res.headers, res.text);
    const json = tryParseJson(res.text);
    if (json === undefined || json === null || typeof json !== 'object') throw new ProviderError(Category.INVALID_RESPONSE, { status: res.status });
    return json;
  }

  const provider = {
    id,
    displayName,
    kind: 'openai-compatible',
    configured: Boolean(baseUrl) && (Boolean(apiKey) || keyOptional),
    configuredModel,
    costPolicy: freeOnly ? 'free_only' : costPolicy,
    enforcesFreeModels: freeOnly,
    fallbackEligible,
    docsUrl,
    dataNote,
    limitsNote,
    capabilities: { text: true, systemPrompt: true, extractedTextAttachments: true, images: false, streaming: false },
    limits: { maxInputTokens, rpmLimit },

    /** Models this server may use: chat-capable, still active and, for free-only providers, priced at zero. */
    isModelAllowed(model) {
      if (!model || !model.id) return false;
      if (model.active === false) return false;
      if (model.outputModalities && !model.outputModalities.includes('text')) return false;
      if (!isChatModel(model)) return false;
      if (freeOnly && model.free !== true) return false;
      return true;
    },

    /** Deterministic "auto" choice from the LIVE list: allowed models, largest context first, then id. Nothing hardcoded. */
    pickAutoModel(models) {
      const usable = models.filter((m) => provider.isModelAllowed(m));
      usable.sort((a, b) => (b.contextTokens ?? 0) - (a.contextTokens ?? 0) || a.id.localeCompare(b.id));
      return usable[0]?.id ?? null;
    },

    async fetchModels({ signal } = {}) {
      const json = await call('/models', { signal });
      const list = Array.isArray(json.data) ? json.data : Array.isArray(json.models) ? json.models : null;
      if (!list) throw new ProviderError(Category.INVALID_RESPONSE);
      return list.map(normalizeModel).filter((m) => m.id);
    },

    async check({ signal } = {}) {
      if (keyCheckPath) {
        const json = await call(keyCheckPath, { signal });
        return parseKeyCheck ? parseKeyCheck(json) : {};
      }
      const models = await provider.fetchModels({ signal });
      return { modelCount: models.length };
    },

    async generate(request, { model, signal, timeoutMs } = {}) {
      if (!model) throw new ProviderError(Category.MODEL_NOT_FOUND);
      const system = buildSystemText({
        systemPrompt: config.systemPrompt,
        memoryContext: request.memoryContext ?? null,
        hasAttachments: request.hasAttachments === true,
      });
      const body = {
        model,
        messages: [{ role: 'system', content: system }, ...request.messages.map((m) => ({ role: m.role, content: m.content }))],
        [tokenParam]: request.maxOutputTokens ?? config.maxOutputTokens,
        temperature: request.temperature ?? config.temperature,
        stream: false,
        ...extraBody(),
      };
      const json = await call('/chat/completions', { method: 'POST', body, signal, timeoutMs });
      if (json.error) {
        const numeric = Number(json.error.code);
        throw classifyOpenAIError(Number.isFinite(numeric) && numeric >= 400 ? numeric : 502, undefined, JSON.stringify({ error: json.error }));
      }
      const choice = Array.isArray(json.choices) ? json.choices[0] : undefined;
      if (!choice) throw new ProviderError(Category.INVALID_RESPONSE);
      const finish = choice.finish_reason ?? null;
      // Some reasoning models put their thinking inline; it is not part of the answer.
      const reply = extractText(choice.message).replace(/<think>[\s\S]*?<\/think>/gi, '').trim();
      if (!reply) {
        if (finish === 'content_filter') throw new ProviderError(Category.CONTENT_BLOCKED);
        throw new ProviderError(Category.INVALID_RESPONSE);
      }
      const u = json.usage ?? {};
      return {
        reply,
        model: typeof json.model === 'string' ? json.model : model,
        finishReason: finish,
        usage: {
          promptTokens: numberOrNull(u.prompt_tokens),
          outputTokens: numberOrNull(u.completion_tokens),
          totalTokens: numberOrNull(u.total_tokens),
        },
      };
    },
  };
  return provider;
}

/** Groq: OpenAI-compatible. Model names are never hardcoded; set GROQ_MODEL, or "auto" to choose from the live list. */
export function createGroqProvider({ config, fetchImpl }) {
  const s = config.providers.groq;
  return createOpenAICompatProvider({
    id: 'groq',
    displayName: 'Groq',
    baseUrl: s.baseUrl,
    apiKey: s.apiKey,
    configuredModel: s.model,
    fetchImpl,
    config,
    costPolicy: s.costPolicy,
    fallbackEligible: s.fallbackEligible,
    maxInputTokens: s.maxInputTokens,
    rpmLimit: s.rpmLimit,
    tokenParam: 'max_completion_tokens',
    docsUrl: 'https://console.groq.com/docs/rate-limits',
    dataNote:
      'Groq states it does not retain inference inputs/outputs by default, but may log them for up to 30 days for reliability or abuse checks unless Zero Data Retention is enabled. Data is held in the United States.',
    limitsNote: 'Free-plan limits are per model (requests and tokens per minute and per day) and are shown on Groq\'s limits page. Small token-per-minute caps can make long requests fail.',
  });
}

/** OpenRouter: one key, many hosts and models, some free and some paid. Paid models are blocked unless explicitly allowed. */
export function createOpenRouterProvider({ config, fetchImpl }) {
  const s = config.providers.openrouter;
  return createOpenAICompatProvider({
    id: 'openrouter',
    displayName: 'OpenRouter',
    baseUrl: s.baseUrl,
    apiKey: s.apiKey,
    configuredModel: s.model,
    fetchImpl,
    config,
    costPolicy: 'metered',
    freeOnly: !s.allowPaid,
    fallbackEligible: s.fallbackEligible,
    maxInputTokens: s.maxInputTokens,
    rpmLimit: s.rpmLimit,
    tokenParam: 'max_tokens',
    extraBody: () => (s.dataCollection === 'deny' ? { provider: { data_collection: 'deny' } } : {}),
    docsUrl: 'https://openrouter.ai/docs/api-reference/limits',
    dataNote:
      'OpenRouter forwards requests to third-party model hosts, each with its own logging and training policy. This server asks for hosts that do not collect data when OPENROUTER_DATA_COLLECTION=deny (the default), which can leave fewer models available.',
    limitsNote: 'Free models have a per-minute and a per-day request cap that depends on how many credits the account ever bought. Paid models spend credits.',
    keyCheckPath: '/key',
    parseKeyCheck: (json) => {
      const d = json?.data ?? {};
      const free = d.free_model_daily_requests ?? {};
      return {
        freeRequestsRemainingToday: numberOrNull(free.remaining),
        creditLimitRemaining: numberOrNull(d.limit_remaining),
      };
    },
  });
}

/** Any other OpenAI-compatible service, defined entirely by environment variables. */
export function createGenericCompatProvider({ config, fetchImpl }) {
  const s = config.providers.compat;
  return createOpenAICompatProvider({
    id: s.id,
    displayName: s.displayName || s.id,
    baseUrl: s.baseUrl,
    apiKey: s.apiKey,
    keyOptional: s.keyOptional,
    configuredModel: s.model,
    fetchImpl,
    config,
    costPolicy: s.costPolicy,
    fallbackEligible: s.fallbackEligible,
    maxInputTokens: s.maxInputTokens,
    rpmLimit: s.rpmLimit,
    dataNote: 'Custom OpenAI-compatible service. Check that service\'s own privacy and retention terms.',
  });
}
