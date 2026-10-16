import { ApiError } from '../../errors.js';
import { createGeminiClient } from '../../gemini.js';
import { Category, ProviderError } from '../errors.js';

/** Maps the verified Phase 2/3 Gemini client's ApiError codes onto the provider-neutral categories. */
export function fromGeminiApiError(err) {
  if (!(err instanceof ApiError)) return new ProviderError(Category.UNKNOWN);
  const retryAfterMs = err.retryAfterSeconds ? err.retryAfterSeconds * 1000 : undefined;
  switch (err.code) {
    case 'quota_or_rate_limit': {
      const daily = err.details?.quotaWindow === 'day' || (retryAfterMs !== undefined && retryAfterMs >= 600_000);
      return new ProviderError(daily ? Category.QUOTA_EXHAUSTED : Category.RATE_LIMITED, {
        status: 429,
        retryAfterMs,
        quotaWindow: daily ? 'day' : 'minute',
        safeToRetry: !daily,
      });
    }
    case 'upstream_auth':
      return new ProviderError(Category.AUTH, { status: 502 });
    case 'model_not_found':
      return new ProviderError(Category.MODEL_NOT_FOUND, { status: 404 });
    case 'context_too_large':
      return new ProviderError(Category.CONTEXT_TOO_LARGE, { status: 413 });
    case 'upstream_unavailable':
      return new ProviderError(Category.UNAVAILABLE, { status: 503, safeToRetry: true });
    case 'upstream_timeout':
      return new ProviderError(Category.TIMEOUT, { status: 504 });
    case 'upstream_unreachable':
      return new ProviderError(Category.NETWORK, { status: 502 });
    case 'upstream_bad_request':
      return new ProviderError(Category.BAD_REQUEST, { status: 400 });
    case 'blocked':
      return new ProviderError(Category.CONTENT_BLOCKED, { status: 422 });
    case 'invalid_upstream_response':
    case 'empty_response':
      return new ProviderError(Category.INVALID_RESPONSE, { status: 502 });
    case 'cancelled':
      return new ProviderError(Category.CANCELLED);
    default:
      return new ProviderError(Category.UNKNOWN, { status: err.status });
  }
}

/**
 * The existing Gemini integration (Phase 2/3), wrapped as a provider adapter. The HTTP client, error handling and
 * secret handling are the verified originals; this file only translates requests and errors.
 */
export function createGeminiProvider({ config, fetchImpl = globalThis.fetch }) {
  const settings = config.providers.gemini;
  const client = createGeminiClient({ config, fetchImpl });
  const costPolicy = settings.billing === 'free' ? 'free_only' : settings.billing === 'paid' ? 'metered' : 'unknown';

  async function wrap(fn) {
    try {
      return await fn();
    } catch (err) {
      throw fromGeminiApiError(err);
    }
  }

  return {
    id: 'gemini',
    displayName: 'Google Gemini',
    kind: 'gemini',
    configured: Boolean(settings.apiKey),
    configuredModel: config.geminiModel,
    costPolicy,
    fallbackEligible: settings.fallbackEligible,
    docsUrl: 'https://ai.google.dev/gemini-api/docs',
    dataNote:
      'On a free Gemini tier Google may use prompts to improve its products. Paid tiers are handled under different terms: check Google\'s current terms for your account.',
    limitsNote: 'Limits depend on the Google project\'s tier and the model and are shown in Google AI Studio. They can change.',
    capabilities: { text: true, systemPrompt: true, extractedTextAttachments: true, images: false, streaming: false },
    limits: { maxInputTokens: settings.maxInputTokens, rpmLimit: settings.rpmLimit },
    isModelAllowed: () => true,
    pickAutoModel: () => null,
    fetchModels: ({ signal } = {}) => wrap(() => client.listModelsDetailed({ signal })),
    async check({ signal } = {}) {
      const models = await wrap(() => client.listModelsDetailed({ signal }));
      return { modelCount: models.length };
    },
    async generate(request, { model, signal, timeoutMs } = {}) {
      const contents = request.messages.map((m) => ({ role: m.role === 'assistant' ? 'model' : 'user', parts: [{ text: m.content }] }));
      return wrap(() =>
        client.generate(contents, {
          memoryContext: request.memoryContext ?? null,
          hasAttachments: request.hasAttachments === true,
          // The configured model keeps Phase 2's own optional fallback model; an explicit user choice does not.
          model: model && model !== config.geminiModel ? model : null,
          signal,
          timeoutMs,
        }),
      );
    },
  };
}
