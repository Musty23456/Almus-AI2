import { ApiError } from './errors.js';
import { buildSystemText } from './ai/messages.js';

const FALLBACK_CODES = new Set(['quota_or_rate_limit', 'model_not_found', 'upstream_unavailable', 'upstream_timeout']);

function retryAfterFrom(res, parsed) {
  const header = Number.parseInt(res.headers?.get?.('retry-after') ?? '', 10);
  if (Number.isFinite(header) && header > 0) return Math.min(header, 3600);
  const details = parsed?.error?.details;
  if (Array.isArray(details)) {
    for (const d of details) {
      const m = /^(\d+(?:\.\d+)?)s$/.exec(d?.retryDelay ?? '');
      if (m) return Math.min(Math.ceil(Number(m[1])), 3600);
    }
  }
  return undefined;
}

/**
 * Gemini reports both per-minute and per-day limits as HTTP 429. A per-day quota will not recover within a retry
 * window, so it must not be retried. Returns 'day' when the error details name a per-day quota.
 */
function quotaWindowFrom(parsed) {
  const details = parsed?.error?.details;
  if (Array.isArray(details)) {
    for (const d of details) {
      const violations = Array.isArray(d?.violations) ? d.violations : [];
      for (const v of violations) {
        if (/perday/i.test(String(v?.quotaId ?? ''))) return 'day';
      }
    }
  }
  return /per\s*day|daily/i.test(String(parsed?.error?.message ?? '')) ? 'day' : undefined;
}

function tryParse(text) {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

/**
 * Minimal Gemini REST client (no SDK). The API key is sent in a header, never in a URL,
 * and is never included in any error message or log line.
 */
export function createGeminiClient({ config, fetchImpl = globalThis.fetch }) {
  async function request(method, url, body, { signal, timeoutMs } = {}) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs ?? config.upstreamTimeoutMs);
    const onExternalAbort = () => controller.abort();
    if (signal) {
      if (signal.aborted) controller.abort();
      else signal.addEventListener('abort', onExternalAbort, { once: true });
    }
    try {
      const res = await fetchImpl(url, {
        method,
        headers: { 'content-type': 'application/json', 'x-goog-api-key': config.geminiApiKey },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: controller.signal,
        redirect: 'error', // Phase 4: never follow a redirect with the API key attached
      });
      const text = await res.text();
      return { res, text };
    } catch (err) {
      if (signal?.aborted) {
        throw new ApiError(499, 'cancelled', 'The request was cancelled.');
      }
      if (err?.name === 'AbortError') {
        throw new ApiError(504, 'upstream_timeout', 'Gemini took too long to respond. Please try again.');
      }
      throw new ApiError(502, 'upstream_unreachable', 'The backend could not reach the Gemini API. Please try again shortly.');
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener?.('abort', onExternalAbort);
    }
  }

  function errorFor(res, text) {
    const parsed = tryParse(text);
    const status = res.status;
    if (status === 429) {
      return new ApiError(
        429,
        'quota_or_rate_limit',
        'Gemini rate limit or free-tier quota reached. Wait a little and try again. If it keeps happening, today\'s quota may be used up.',
        { retryAfterSeconds: retryAfterFrom(res, parsed), details: { quotaWindow: quotaWindowFrom(parsed) } },
      );
    }
    if (status === 413) {
      return new ApiError(502, 'context_too_large', 'Gemini says the request is too large.');
    }
    if (status === 401 || status === 403) {
      return new ApiError(502, 'upstream_auth', 'Gemini rejected the backend\'s API key or project. Check GEMINI_API_KEY and your Google AI Studio project.');
    }
    if (status === 400) {
      const msg = String(parsed?.error?.message ?? '').toLowerCase();
      if (msg.includes('api key')) {
        return new ApiError(502, 'upstream_auth', 'Gemini rejected the backend\'s API key. Check GEMINI_API_KEY.');
      }
      return new ApiError(502, 'upstream_bad_request', 'Gemini could not process this request.');
    }
    if (status === 404) {
      return new ApiError(502, 'model_not_found', 'The configured Gemini model was not found or is no longer available. Change GEMINI_MODEL on the server.');
    }
    if (status >= 500) {
      return new ApiError(503, 'upstream_unavailable', 'Gemini is temporarily unavailable. Please try again shortly.');
    }
    return new ApiError(502, 'upstream_error', `Gemini returned an unexpected status (${status}).`);
  }

  function parseSuccess(text, model) {
    const json = tryParse(text);
    if (!json || typeof json !== 'object') {
      throw new ApiError(502, 'invalid_upstream_response', 'Gemini returned a response the backend could not understand.');
    }
    if (json.promptFeedback?.blockReason) {
      throw new ApiError(422, 'blocked', 'Gemini declined to answer this message. Try rephrasing it.');
    }
    const candidate = Array.isArray(json.candidates) ? json.candidates[0] : undefined;
    if (!candidate) {
      throw new ApiError(502, 'invalid_upstream_response', 'Gemini returned no answer.');
    }
    const parts = Array.isArray(candidate.content?.parts) ? candidate.content.parts : [];
    const reply = parts
      .map((p) => (typeof p?.text === 'string' ? p.text : ''))
      .join('')
      .trim();
    if (!reply) {
      const reason = String(candidate.finishReason ?? '');
      if (['SAFETY', 'PROHIBITED_CONTENT', 'BLOCKLIST', 'SPII', 'RECITATION'].includes(reason)) {
        throw new ApiError(422, 'blocked', 'Gemini declined to answer this message. Try rephrasing it.');
      }
      throw new ApiError(502, 'empty_response', 'Gemini returned an empty answer. Please try again.');
    }
    const usage = json.usageMetadata ?? {};
    return {
      reply,
      model: typeof json.modelVersion === 'string' ? json.modelVersion : model,
      finishReason: candidate.finishReason ?? null,
      usage: {
        promptTokens: Number.isFinite(usage.promptTokenCount) ? usage.promptTokenCount : null,
        outputTokens: Number.isFinite(usage.candidatesTokenCount) ? usage.candidatesTokenCount : null,
        totalTokens: Number.isFinite(usage.totalTokenCount) ? usage.totalTokenCount : null,
      },
    };
  }

  function systemText(memoryContext, hasAttachments) {
    return buildSystemText({ systemPrompt: config.systemPrompt, memoryContext, hasAttachments });
  }

  async function generateWith(model, contents, memoryContext, hasAttachments, opts = {}) {
    const url = `${config.geminiBaseUrl}/models/${encodeURIComponent(model)}:generateContent`;
    const body = {
      systemInstruction: { parts: [{ text: systemText(memoryContext, hasAttachments) }] },
      contents,
      generationConfig: { maxOutputTokens: config.maxOutputTokens, temperature: config.temperature },
    };
    const { res, text } = await request('POST', url, body, opts);
    if (!res.ok) throw errorFor(res, text);
    return parseSuccess(text, model);
  }

  return {
    /** Tries the primary model, then the optional fallback model for quota/availability problems. */
    async generate(contents, { memoryContext = null, hasAttachments = false, model = null, signal, timeoutMs } = {}) {
      const opts = { signal, timeoutMs };
      // Phase 4: an explicit model (chosen by the user) is used as-is, with no hidden second model.
      if (model) return generateWith(model, contents, memoryContext, hasAttachments, opts);
      try {
        return await generateWith(config.geminiModel, contents, memoryContext, hasAttachments, opts);
      } catch (err) {
        const canFallback =
          err instanceof ApiError &&
          FALLBACK_CODES.has(err.code) &&
          config.geminiFallbackModel &&
          config.geminiFallbackModel !== config.geminiModel;
        if (!canFallback) throw err;
        return generateWith(config.geminiFallbackModel, contents, memoryContext, hasAttachments, opts);
      }
    },

    /** Lists model names this key can use for text generation (helps choosing GEMINI_MODEL). */
    async listModels() {
      const { res, text } = await request('GET', `${config.geminiBaseUrl}/models?pageSize=200`);
      if (!res.ok) throw errorFor(res, text);
      const json = tryParse(text);
      if (!json || !Array.isArray(json.models)) {
        throw new ApiError(502, 'invalid_upstream_response', 'Gemini returned a model list the backend could not understand.');
      }
      return json.models
        .filter((m) => Array.isArray(m.supportedGenerationMethods) && m.supportedGenerationMethods.includes('generateContent'))
        .map((m) => String(m.name ?? '').replace(/^models\//, ''))
        .filter(Boolean)
        .sort();
    },

    /** Like listModels() but with context sizes, for capability-aware routing (Phase 4). */
    async listModelsDetailed({ signal } = {}) {
      const { res, text } = await request('GET', `${config.geminiBaseUrl}/models?pageSize=200`, undefined, { signal });
      if (!res.ok) throw errorFor(res, text);
      const json = tryParse(text);
      if (!json || !Array.isArray(json.models)) {
        throw new ApiError(502, 'invalid_upstream_response', 'Gemini returned a model list the backend could not understand.');
      }
      return json.models
        .filter((m) => Array.isArray(m.supportedGenerationMethods) && m.supportedGenerationMethods.includes('generateContent'))
        .map((m) => ({
          id: String(m.name ?? '').replace(/^models\//, ''),
          name: typeof m.displayName === 'string' ? m.displayName : null,
          contextTokens: Number.isFinite(m.inputTokenLimit) ? m.inputTokenLimit : null,
          maxOutputTokens: Number.isFinite(m.outputTokenLimit) ? m.outputTokenLimit : null,
        }))
        .filter((m) => m.id)
        .sort((a, b) => a.id.localeCompare(b.id));
    },
  };
}
