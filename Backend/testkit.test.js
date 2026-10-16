// Shared helpers for the Phase 4 tests (this file contains no tests itself, and is excluded from the Docker image).
import { loadConfig } from './config.js';
import { Category, ProviderError } from './ai/errors.js';
import { createProviderRegistry } from './ai/registry.js';
import { createHealthTracker } from './ai/health.js';
import { createOrchestrator } from './ai/orchestrator.js';

/** A fake clock; `sleep` advances it, so backoff tests run instantly and deterministically. */
export function fakeClock(start = 1_700_000_000_000) {
  const clock = {
    t: start,
    sleeps: [],
    now: () => clock.t,
    sleep: async (ms, signal) => {
      if (signal?.aborted) throw Object.assign(new Error('aborted'), { name: 'AbortError' });
      clock.sleeps.push(ms);
      clock.t += ms;
    },
    advance: (ms) => {
      clock.t += ms;
    },
  };
  return clock;
}

export const ok = (reply = 'hello') => ({ ok: true, reply });
export const fail = (category, info = {}) => ({ error: new ProviderError(category, info) });

/**
 * A scriptable provider adapter. `script` is consumed one entry per generate() call; when it runs out the last entry
 * repeats. Every call is recorded in `calls` so tests can assert exactly what was sent where.
 */
export function mockProvider({
  id,
  name = id.toUpperCase(),
  script = [ok(`reply from ${id}`)],
  configured = true,
  costPolicy = 'free_only',
  fallbackEligible = true,
  images = false,
  configuredModel = `${id}-model`,
  models = null,
  limits = { maxInputTokens: null, rpmLimit: null },
  check = async () => ({ modelCount: 1 }),
  enforcesFreeModels = false,
}) {
  const calls = [];
  let i = 0;
  const modelList = models ?? [{ id: configuredModel, name: null, contextTokens: null, maxOutputTokens: null, free: true, active: true }];
  const p = {
    id,
    displayName: name,
    kind: 'mock',
    configured,
    configuredModel,
    costPolicy,
    enforcesFreeModels,
    fallbackEligible,
    capabilities: { text: true, systemPrompt: true, extractedTextAttachments: true, images, streaming: false },
    limits,
    calls,
    isModelAllowed: (m) => Boolean(m?.id) && (!enforcesFreeModels || m.free === true),
    pickAutoModel: (list) => list[0]?.id ?? null,
    fetchModels: async () => modelList,
    check,
    async generate(request, opts) {
      calls.push({ request, model: opts?.model, signal: opts?.signal });
      const step = script[Math.min(i, script.length - 1)];
      i += 1;
      const entry = typeof step === 'function' ? await step(request, opts) : step;
      if (entry.error) throw entry.error;
      return { reply: entry.reply, model: opts?.model ?? configuredModel, finishReason: 'STOP', usage: { promptTokens: 1, outputTokens: 1, totalTokens: 2 } };
    },
  };
  return p;
}

/** Builds an orchestrator over mock providers. Defaults: alpha is primary, fallback order beta then gamma. */
export function buildOrchestrator({ providers, env = {}, clock = fakeClock(), random = () => 0.5, logs = [] }) {
  const config = loadConfig({
    APP_ACCESS_TOKEN: 't',
    AI_PRIMARY_PROVIDER: providers[0].id,
    AI_FALLBACK_ORDER: providers.slice(1).map((p) => p.id).join(','),
    ...env,
  });
  const registry = createProviderRegistry({ config, fetchImpl: async () => { throw new Error('no network in tests'); }, extraProviders: providers, now: clock.now });
  const health = createHealthTracker({
    now: clock.now,
    threshold: config.breakerThreshold,
    breakerBaseMs: config.breakerBaseMs,
    breakerMaxMs: config.breakerMaxMs,
    quotaCooldownMs: config.quotaCooldownMs,
  });
  const orchestrator = createOrchestrator({ registry, health, config, now: clock.now, sleep: clock.sleep, random, logger: (l) => logs.push(l) });
  return { orchestrator, registry, health, config, clock, logs };
}

export const input = (text = 'hello', extra = {}) => ({
  messages: [{ role: 'user', content: text }],
  memoryContext: null,
  attachments: [],
  ...extra,
});

export const routing = (over = {}) => ({
  provider: null,
  models: {},
  ...over,
  fallback: { enabled: false, providers: [], shareMemory: false, shareAttachments: false, ...(over.fallback ?? {}) },
});

export async function failureOf(promise) {
  try {
    await promise;
  } catch (e) {
    return e;
  }
  throw new Error('expected the promise to reject');
}

export { Category, ProviderError };
