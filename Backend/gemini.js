import { ApiError } from './errors.js';

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
  async function request(method, url, body) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), config.upstreamTimeoutMs);
    try {
      const res = await fetchImpl(url, {
        method,
        headers: { 'content-type': 'application/json', 'x-goog-api-key': config.geminiApiKey },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: controller.signal,
      });
      const text = await res.text();
      return { res, text };
    } catch (err) {
      if (err?.name === 'AbortError') {
        throw new ApiError(504, 'upstream_timeout', 'Gemini took too long to respond. Please try again.');
      }
      throw new ApiError(502, 'upstream_unreachable', 'The backend could not reach the Gemini API. Please try again shortly.');
    } finally {
      clearTimeout(timer);
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
        { retryAfterSeconds: retryAfterFrom(res, parsed) },
      );
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

  /** The system prompt, plus the user's memory notes when the app sent any. */
  function systemText(memoryContext) {
    return memoryContext ? `${config.systemPrompt}\n\n${memoryContext}` : config.systemPrompt;
  }

  async function generateWith(model, contents, memoryContext) {
    const url = `${config.geminiBaseUrl}/models/${encodeURIComponent(model)}:generateContent`;
    const body = {
      systemInstruction: { parts: [{ text: systemText(memoryContext) }] },
      contents,
      generationConfig: { maxOutputTokens: config.maxOutputTokens, temperature: config.temperature },
    };
    const { res, text } = await request('POST', url, body);
    if (!res.ok) throw errorFor(res, text);
    return parseSuccess(text, model);
  }

  return {
    /** Tries the primary model, then the optional fallback model for quota/availability problems. */
    async generate(contents, { memoryContext = null } = {}) {
      try {
        return await generateWith(config.geminiModel, contents, memoryContext);
      } catch (err) {
        const canFallback =
          err instanceof ApiError &&
          FALLBACK_CODES.has(err.code) &&
          config.geminiFallbackModel &&
          config.geminiFallbackModel !== config.geminiModel;
        if (!canFallback) throw err;
        return generateWith(config.geminiFallbackModel, contents, memoryContext);
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
  };
}
