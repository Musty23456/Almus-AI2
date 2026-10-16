import { GATEWAY_MODEL_PATTERN, PROVIDER_ID_PATTERN, configuredProviderIds } from '../config.js';
import { createGeminiProvider } from './adapters/gemini.js';
import { createGenericCompatProvider, createGroqProvider, createOpenRouterProvider } from './adapters/openaiCompat.js';

const REQUIRED_FIELDS = ['id', 'displayName', 'configured', 'costPolicy', 'fallbackEligible', 'capabilities', 'limits'];
const REQUIRED_METHODS = ['isModelAllowed', 'pickAutoModel', 'fetchModels', 'check', 'generate'];

/**
 * Validates the provider contract. This is the whole "interface" a new adapter must satisfy; see docs/PROVIDERS.md.
 * Throws a plain Error describing the first problem (operator-facing, at start-up).
 */
export function assertProvider(p) {
  if (!p || typeof p !== 'object') throw new Error('provider must be an object');
  for (const f of REQUIRED_FIELDS) {
    if (p[f] === undefined) throw new Error(`provider is missing "${f}"`);
  }
  if (!PROVIDER_ID_PATTERN.test(p.id)) throw new Error(`provider id "${String(p.id).slice(0, 40)}" is invalid`);
  for (const m of REQUIRED_METHODS) {
    if (typeof p[m] !== 'function') throw new Error(`provider "${p.id}" is missing the method "${m}"`);
  }
  if (!['free_only', 'metered', 'unknown'].includes(p.costPolicy)) throw new Error(`provider "${p.id}" has an invalid costPolicy`);
  return p;
}

/** Builds every built-in provider from configuration. Unconfigured providers are still listed (as "not configured"). */
export function buildProviders(config, fetchImpl) {
  const list = [createGeminiProvider({ config, fetchImpl }), createGroqProvider({ config, fetchImpl }), createOpenRouterProvider({ config, fetchImpl })];
  const compat = config.providers.compat;
  if (compat.baseUrl || compat.apiKey) list.push(createGenericCompatProvider({ config, fetchImpl }));
  return list;
}

/**
 * Holds the providers, the live model-list cache and model resolution. Chat code and the orchestrator only ever
 * talk to this object, never to a specific vendor.
 */
export function createProviderRegistry({ config, fetchImpl = globalThis.fetch, extraProviders = [], now = () => Date.now() }) {
  const providers = new Map();
  const modelCache = new Map(); // id -> { at, models }

  function register(provider) {
    assertProvider(provider);
    if (providers.has(provider.id)) throw new Error(`provider "${provider.id}" is already registered`);
    providers.set(provider.id, provider);
  }
  for (const p of buildProviders(config, fetchImpl)) register(p);
  for (const p of extraProviders) register(p);

  const api = {
    register,
    get: (id) => providers.get(id) ?? null,
    all: () => [...providers.values()],
    ids: () => [...providers.keys()],
    configuredIds: () => [...providers.values()].filter((p) => p.configured).map((p) => p.id),

    cachedModels(id) {
      return modelCache.get(id)?.models ?? null;
    },

    /** Live model list from the provider's own API, cached for config.modelCacheMs. Throws ProviderError. */
    async listModels(id, { signal, force = false } = {}) {
      const provider = providers.get(id);
      if (!provider) return [];
      const hit = modelCache.get(id);
      if (!force && hit && now() - hit.at < config.modelCacheMs) return hit.models;
      const models = await provider.fetchModels({ signal });
      modelCache.set(id, { at: now(), models });
      return models;
    },

    /**
     * Decides which model to use for a provider. Order: the user's choice (validated against the provider's live list),
     * then the operator's configured model ("auto" = chosen from the live list), else none.
     * Never invents a model name.
     */
    async resolveModel(id, { userModel = null, signal } = {}) {
      const provider = providers.get(id);
      if (!provider) return { ok: false, code: 'unknown_provider' };
      // Adapters that enforce "free models only" by price must verify the model against the live list first.
      const freeOnly = provider.enforcesFreeModels === true;
      if (userModel) {
        if (!config.allowUserModelSelection) return { ok: false, code: 'model_selection_disabled' };
        if (!GATEWAY_MODEL_PATTERN.test(userModel)) return { ok: false, code: 'invalid_model' };
        let models = null;
        try {
          models = await api.listModels(id, { signal });
        } catch {
          models = null;
        }
        if (models) {
          const found = models.find((m) => m.id === userModel);
          if (!found) return { ok: false, code: 'unknown_model' };
          if (!provider.isModelAllowed(found)) return { ok: false, code: 'model_not_allowed' };
        } else if (freeOnly) {
          return { ok: false, code: 'model_unverified' };
        }
        return { ok: true, model: userModel, source: 'user' };
      }
      const configured = provider.configuredModel;
      if (configured === 'auto') {
        let models;
        try {
          models = await api.listModels(id, { signal });
        } catch (err) {
          return { ok: false, code: 'model_list_unavailable', error: err };
        }
        const picked = provider.pickAutoModel(models);
        return picked ? { ok: true, model: picked, source: 'auto' } : { ok: false, code: 'no_usable_model' };
      }
      if (configured) {
        if (freeOnly) {
          let models = null;
          try {
            models = await api.listModels(id, { signal });
          } catch {
            return { ok: false, code: 'model_unverified' };
          }
          const found = models.find((m) => m.id === configured);
          if (found && !provider.isModelAllowed(found)) return { ok: false, code: 'model_not_allowed' };
        }
        return { ok: true, model: configured, source: 'configured' };
      }
      return { ok: false, code: 'no_model' };
    },
  };
  return api;
}

export { configuredProviderIds };
