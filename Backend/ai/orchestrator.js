import { computeBackoffMs, abortableSleep } from './backoff.js';
import { CATEGORY_LABEL, Category, POLICY, ProviderError } from './errors.js';
import { buildSystemText, estimateRequestTokens, trimMessages, withAttachments } from './messages.js';

/** An error whose fields are all safe to show to a client (fixed templates, provider display names, categories). */
export class OrchestratorError extends Error {
  constructor({ status, code, message, retryAfterSeconds, details }) {
    super(message);
    this.name = 'OrchestratorError';
    this.status = status;
    this.code = code;
    this.retryAfterSeconds = retryAfterSeconds;
    this.details = details;
  }
}

/** Legacy-compatible client error for a single provider failure (the same codes the Phase 2/3 app already understands). */
function describe(category, name) {
  switch (category) {
    case Category.RATE_LIMITED:
      return [429, 'quota_or_rate_limit', `${name} is rate limiting requests. Wait a little and try again.`];
    case Category.QUOTA_EXHAUSTED:
      return [429, 'quota_or_rate_limit', `${name} has no quota left right now. Try again later.`];
    case Category.TIMEOUT:
      return [504, 'upstream_timeout', `${name} took too long to answer. Please try again.`];
    case Category.UNAVAILABLE:
      return [503, 'upstream_unavailable', `${name} is temporarily unavailable. Please try again shortly.`];
    case Category.NETWORK:
      return [502, 'upstream_unreachable', `The backend could not reach ${name}. Please try again shortly.`];
    case Category.AUTH:
      return [502, 'upstream_auth', `${name} rejected the backend's credentials. The server's API key or project needs attention.`];
    case Category.PAYMENT_REQUIRED:
      return [502, 'upstream_payment_required', `The ${name} account has no credit left.`];
    case Category.MODEL_NOT_FOUND:
      return [502, 'model_not_found', `${name} does not offer the selected model. Choose another model or change it on the server.`];
    case Category.CONTEXT_TOO_LARGE:
      return [422, 'context_too_large', `This conversation is too large for ${name}.`];
    case Category.BAD_REQUEST:
      return [502, 'upstream_bad_request', `${name} could not process this request.`];
    case Category.INVALID_RESPONSE:
      return [502, 'invalid_upstream_response', `${name} returned an answer the backend could not use.`];
    case Category.CONTENT_BLOCKED:
      return [422, 'blocked', `${name} declined to answer this message. Try rephrasing it.`];
    case Category.UNSUPPORTED:
      return [422, 'unsupported_capability', `${name} does not support this kind of request.`];
    default:
      return [502, 'upstream_error', `${name} returned an unexpected error.`];
  }
}

export function createOrchestrator({
  registry,
  health,
  config,
  now = () => Date.now(),
  sleep = abortableSleep,
  random = Math.random,
  logger = () => {},
}) {
  const windows = new Map(); // provider id -> request timestamps (self-imposed requests-per-minute budget)
  const lastCheck = new Map();
  const checkDetails = new Map();

  function throttleTake(provider) {
    const rpm = provider.limits?.rpmLimit;
    if (!rpm) return { ok: true };
    const t = now();
    const list = (windows.get(provider.id) ?? []).filter((x) => t - x < 60_000);
    if (list.length >= rpm) {
      windows.set(provider.id, list);
      return { ok: false, retryAfterMs: list[0] + 60_000 - t };
    }
    list.push(t);
    windows.set(provider.id, list);
    return { ok: true };
  }

  function toProviderError(raw) {
    return raw instanceof ProviderError ? raw : new ProviderError(Category.UNKNOWN);
  }

  function nameOf(id) {
    return registry.get(id)?.displayName ?? id;
  }

  function defaultRouting() {
    return { provider: null, models: {}, fallback: { enabled: false, providers: [], shareMemory: false, shareAttachments: false } };
  }

  /** Primary first, then (only if the user allowed fallback) the allowed, eligible providers in the operator's order. */
  function planCandidates(policy) {
    const configured = registry.configuredIds();
    if (configured.length === 0) {
      throw new OrchestratorError({ status: 503, code: 'server_not_configured', message: 'No AI provider is configured on the backend.' });
    }
    const primaryId = policy.provider ?? (configured.includes(config.primaryProvider) ? config.primaryProvider : configured[0]);
    if (!configured.includes(primaryId)) {
      throw new OrchestratorError({ status: 400, code: 'provider_not_configured', message: 'The selected AI provider is not configured on the backend.' });
    }
    const candidates = [{ id: primaryId, role: 'primary' }];
    const skipped = [];
    if (policy.fallback.enabled) {
      const preferred = config.fallbackOrder.length > 0 ? config.fallbackOrder : configured;
      const ordered = [...new Set([...preferred, ...configured])].filter((id) => id !== primaryId && configured.includes(id));
      for (const id of ordered) {
        const p = registry.get(id);
        if (!p.fallbackEligible) skipped.push({ provider: id, reason: 'not_fallback_eligible' });
        else if (!policy.fallback.providers.includes(id)) skipped.push({ provider: id, reason: 'not_allowed_by_user' });
        else candidates.push({ id, role: 'fallback' });
      }
    }
    return { primaryId, candidates, skipped, configured };
  }

  /** Would some other configured provider be allowed to help if the user switched fallback on? */
  function fallbackSuggestionExists(primaryId, configured) {
    return configured.some((id) => {
      if (id === primaryId) return false;
      const p = registry.get(id);
      return p.fallbackEligible && (p.costPolicy === 'free_only' || config.allowPaidFallback);
    });
  }

  function prepare(role, input, policy) {
    const shareMemory = role === 'primary' || policy.fallback.shareMemory;
    const shareFiles = role === 'primary' || policy.fallback.shareAttachments;
    const hasFiles = input.attachments.length > 0;
    const useMemory = Boolean(input.memoryContext) && shareMemory;
    const useFiles = hasFiles && shareFiles;
    const base = trimMessages(input.messages, config.maxContextChars);
    const messages = useFiles ? withAttachments(base, input.attachments) : base;
    const system = buildSystemText({ systemPrompt: config.systemPrompt, memoryContext: useMemory ? input.memoryContext : null, hasAttachments: useFiles });
    return {
      request: {
        messages,
        system,
        memoryContext: useMemory ? input.memoryContext : null,
        hasAttachments: useFiles,
        maxOutputTokens: config.maxOutputTokens,
        temperature: config.temperature,
      },
      omitted: Boolean(input.memoryContext) && !useMemory ? ['memory'] : [],
      blockedByPrivacy: hasFiles && !useFiles,
      attachmentsUsed: useFiles ? input.attachments.length : 0,
    };
  }

  function effectiveInputLimit(provider, model) {
    const info = registry.cachedModels(provider.id)?.find((m) => m.id === model);
    const fromModel = info?.contextTokens ? info.contextTokens - (info.maxOutputTokens ?? config.maxOutputTokens) : null;
    const caps = [provider.limits?.maxInputTokens, fromModel].filter((x) => Number.isFinite(x) && x > 0);
    return caps.length ? Math.min(...caps) : null;
  }

  function finalError({ trail, skipped, policy, primaryId, configured }) {
    const failures = trail.filter((t) => t.outcome !== 'success');
    const failedIds = [...new Set(failures.map((f) => f.provider))];
    const safeDetails = {
      attempts: failures.map((f) => ({ provider: f.provider, category: f.outcome })),
      skipped: skipped.map((s) => ({ provider: s.provider, reason: s.reason })),
      fallbackEnabled: policy.fallback.enabled,
    };
    const retryValues = failures.map((f) => f.retryAfterMs).filter(Boolean);
    let status;
    let code;
    let message;
    let category;
    let retryAfterMs = retryValues.length ? Math.min(...retryValues) : undefined;

    if (failures.length === 0) {
      // Nothing could even be tried. Explain the primary provider's situation first.
      const s = skipped.find((x) => x.provider === primaryId && x.role !== 'fallback') ?? skipped[0];
      const name = nameOf(s?.provider ?? primaryId);
      retryAfterMs = s?.retryAfterMs;
      if (s?.reason === 'cooling_down' || s?.reason === 'misconfigured') {
        category = s.category ?? Category.UNKNOWN;
        [status, code, message] = describe(category, name);
        if (s.reason === 'cooling_down') message += ' (The backend is holding off new requests to it for a moment.)';
      } else if (s?.reason === 'no_model') {
        [status, code, message] = [503, 'provider_needs_model', `${name} has no model selected. Choose one in Settings → AI providers, or set the model on the server.`];
      } else if (s?.reason === 'model_list_unavailable' || s?.reason === 'model_unverified') {
        [status, code, message] = [503, 'model_unverified', `${name}'s model list could not be checked right now, so no model was selected. Try again shortly.`];
      } else if (s?.reason === 'no_usable_model') {
        [status, code, message] = [503, 'provider_needs_model', `${name} offers no model this server is allowed to use (for example only paid models while paid use is off).`];
      } else if (s?.reason === 'context_too_large') {
        [status, code, message] = [422, 'context_too_large', `This conversation is too large for ${name}.`];
      } else if (s?.reason === 'unsupported_capability') {
        [status, code, message] = [422, 'unsupported_capability', `No configured provider supports this kind of request.`];
      } else if (s?.reason === 'local_rate_limit') {
        [status, code, message] = [429, 'rate_limited', `The backend is holding requests to ${name} to stay within its configured limit.`];
      } else if (s?.reason === 'attachments_not_shared') {
        [status, code, message] = [503, 'fallback_blocked_by_privacy', `A fallback provider could have answered, but your settings do not allow sending attached file text to it.`];
      } else {
        [status, code, message] = [503, 'no_provider_available', 'No AI provider is available for this request.'];
      }
    } else if (failedIds.length === 1) {
      const last = failures[failures.length - 1];
      category = last.outcome;
      [status, code, message] = describe(category, nameOf(last.provider));
    } else {
      status = 503;
      code = 'all_providers_failed';
      const parts = failedIds.map((id) => {
        const last = [...failures].reverse().find((f) => f.provider === id);
        return `${nameOf(id)} (${CATEGORY_LABEL[last.outcome] ?? 'failed'})`;
      });
      message = `None of the allowed AI providers could answer: ${parts.join('; ')}.`;
      category = failures[failures.length - 1].outcome;
    }

    const canHelp = failures.length > 0 ? POLICY[failures[failures.length - 1].outcome]?.fallback === true : false;
    const suggest = !policy.fallback.enabled && canHelp && fallbackSuggestionExists(primaryId, configured);
    if (suggest) message += ' Automatic fallback is off. You can allow another provider in Settings → AI providers.';
    return new OrchestratorError({
      status,
      code,
      message,
      retryAfterSeconds: retryAfterMs ? Math.max(1, Math.ceil(retryAfterMs / 1000)) : undefined,
      details: { ...safeDetails, category: category ?? null, fallbackSuggested: suggest },
    });
  }

  async function generate(input, { routing = null, signal } = {}) {
    const policy = routing ?? defaultRouting();
    const started = now();
    const deadline = started + config.requestDeadlineMs;
    const { primaryId, candidates, skipped, configured } = planCandidates(policy);
    const trail = [];
    let totalAttempts = 0;

    const cancelled = () => new OrchestratorError({ status: 499, code: 'cancelled', message: 'The request was cancelled.' });

    outer: for (const cand of candidates) {
      const provider = registry.get(cand.id);
      const id = provider.id;
      const prepared = prepare(cand.role, input, policy);

      // ---- gates that depend only on the request and the settings -------------------------------------------
      if (prepared.blockedByPrivacy) {
        skipped.push({ provider: id, role: cand.role, reason: 'attachments_not_shared' });
        continue;
      }
      if (cand.role === 'fallback' && provider.costPolicy !== 'free_only' && !config.allowPaidFallback) {
        skipped.push({ provider: id, role: cand.role, reason: 'paid_fallback_not_allowed' });
        continue;
      }

      const resolved = await registry.resolveModel(id, { userModel: policy.models[id] ?? null, signal });
      if (!resolved.ok) {
        const userError = ['unknown_model', 'model_not_allowed', 'invalid_model', 'model_selection_disabled'].includes(resolved.code);
        if (userError && cand.role === 'primary') {
          throw new OrchestratorError({
            status: 400,
            code: resolved.code,
            message: `The selected model is not available from ${provider.displayName}. Pick one from the list in Settings → AI providers.`,
          });
        }
        skipped.push({ provider: id, role: cand.role, reason: resolved.code === 'unknown_model' ? 'unknown_model' : resolved.code });
        continue;
      }
      const model = resolved.model;

      const estimated = estimateRequestTokens(prepared.request) + config.maxOutputTokens;
      const limit = effectiveInputLimit(provider, model);
      if (limit !== null && estimated > limit) {
        skipped.push({ provider: id, role: cand.role, reason: 'context_too_large' });
        continue;
      }
      if (policy.requires?.images && !provider.capabilities.images) {
        skipped.push({ provider: id, role: cand.role, reason: 'unsupported_capability' });
        continue;
      }

      // ---- attempts ------------------------------------------------------------------------------------------
      for (let attempt = 1; attempt <= config.maxAttemptsPerProvider; attempt += 1) {
        if (signal?.aborted) throw cancelled();
        if (totalAttempts >= config.maxTotalAttempts) break outer;
        const remaining = deadline - now();
        if (remaining < 1500) break outer;
        if (attempt === 1) {
          const h = health.canAttempt(id);
          if (!h.ok) {
            skipped.push({ provider: id, role: cand.role, reason: h.reason, retryAfterMs: h.retryAfterMs, category: h.category });
            break;
          }
          const th = throttleTake(provider);
          if (!th.ok) {
            skipped.push({ provider: id, role: cand.role, reason: 'local_rate_limit', retryAfterMs: th.retryAfterMs });
            break;
          }
        }
        totalAttempts += 1;
        const t0 = now();
        try {
          const out = await provider.generate(prepared.request, { model, signal, timeoutMs: Math.min(config.upstreamTimeoutMs, remaining - 500) });
          health.recordSuccess(id);
          trail.push({ provider: id, outcome: 'success', ms: now() - t0 });
          const failed = [...new Map(trail.filter((t) => t.outcome !== 'success').map((t) => [t.provider, t.outcome])).entries()].map(([p, c]) => ({
            provider: p,
            category: c,
          }));
          logger(`ai ok provider=${id} role=${cand.role} attempts=${trail.length} fallback=${cand.role === 'fallback'}`);
          return {
            reply: out.reply,
            model: out.model ?? model,
            finishReason: out.finishReason ?? null,
            usage: out.usage ?? {},
            provider: id,
            providerName: provider.displayName,
            attachmentsUsed: prepared.attachmentsUsed,
            route: {
              role: cand.role,
              primary: primaryId,
              fallbackUsed: cand.role === 'fallback',
              attempts: trail.length,
              failed,
              omitted: prepared.omitted,
              modelSource: resolved.source,
            },
          };
        } catch (raw) {
          const err = toProviderError(raw);
          trail.push({ provider: id, outcome: err.category, ms: now() - t0, retryAfterMs: err.retryAfterMs });
          logger(`ai fail provider=${id} role=${cand.role} attempt=${attempt} category=${err.category}${err.status ? ` status=${err.status}` : ''}`);
          if (err.category === Category.CANCELLED || signal?.aborted) throw cancelled();
          health.recordFailure(id, err.category, { retryAfterMs: err.retryAfterMs });
          if (err.category === Category.CONTENT_BLOCKED) {
            const [status, code, message] = describe(err.category, provider.displayName);
            throw new OrchestratorError({ status, code, message, details: { category: err.category, attempts: [{ provider: id, category: err.category }], skipped: [], fallbackEnabled: policy.fallback.enabled, fallbackSuggested: false } });
          }
          const pol = POLICY[err.category] ?? POLICY[Category.UNKNOWN];
          const retryable = pol.retry === 'yes' && attempt < config.maxAttemptsPerProvider && (err.safeToRetry || provider.costPolicy === 'free_only');
          if (retryable) {
            const wait = computeBackoffMs({ attempt, baseMs: config.backoffBaseMs, capMs: config.backoffCapMs, retryAfterMs: err.retryAfterMs, random });
            if (wait <= config.maxRetryWaitMs && now() + wait + 1500 < deadline) {
              try {
                await sleep(wait, signal);
              } catch {
                throw cancelled();
              }
              continue;
            }
          }
          break; // next candidate (if the failure allows it and the user permitted one)
        }
      }
    }
    throw finalError({ trail, skipped, policy, primaryId, configured });
  }

  // ---- status & health checks -------------------------------------------------------------------------------

  function publicModel(provider) {
    const cached = registry.cachedModels(provider.id);
    const configured = provider.configuredModel;
    if (configured === 'auto') {
      const picked = cached ? provider.pickAutoModel(cached) : null;
      return { model: picked, modelSource: 'auto', modelListed: picked ? true : null };
    }
    if (configured) {
      return { model: configured, modelSource: 'configured', modelListed: cached ? cached.some((m) => m.id === configured) : null };
    }
    return { model: null, modelSource: 'none', modelListed: null };
  }

  function statusFor(id) {
    const provider = registry.get(id);
    if (!provider) return null;
    if (!provider.configured) health.markUnconfigured(id);
    const snap = health.snapshot(id);
    const m = publicModel(provider);
    const limit = effectiveInputLimit(provider, m.model);
    return {
      id: provider.id,
      name: provider.displayName,
      kind: provider.kind,
      configured: provider.configured,
      ...snap,
      state: provider.configured ? snap.state : 'unconfigured',
      verified: provider.configured && snap.verified,
      ...m,
      capabilities: { ...provider.capabilities, maxInputTokens: limit },
      processing: 'remote',
      costPolicy: provider.costPolicy,
      fallbackEligible: provider.fallbackEligible,
      dataNote: provider.dataNote ?? '',
      limitsNote: provider.limitsNote ?? '',
      docsUrl: provider.docsUrl ?? null,
      notes: checkDetails.get(id) ?? {},
      isDefaultPrimary: id === (registry.configuredIds().includes(config.primaryProvider) ? config.primaryProvider : registry.configuredIds()[0]),
    };
  }

  async function checkProvider(id, { signal } = {}) {
    const provider = registry.get(id);
    if (!provider) return null;
    if (!provider.configured) return statusFor(id);
    const last = lastCheck.get(id);
    if (last !== undefined && now() - last < config.healthCheckMinIntervalMs) {
      return { ...statusFor(id), cached: true };
    }
    lastCheck.set(id, now());
    health.clearMisconfiguration(id);
    try {
      const details = await provider.check({ signal });
      checkDetails.set(id, details ?? {});
      try {
        await registry.listModels(id, { signal, force: true });
      } catch {
        // The key works; the model list can be retried later.
      }
      health.recordCheck(id, true);
    } catch (raw) {
      const err = toProviderError(raw);
      if (err.category === Category.CANCELLED) throw new OrchestratorError({ status: 499, code: 'cancelled', message: 'The request was cancelled.' });
      health.recordCheck(id, false, err.category);
      logger(`ai check provider=${id} category=${err.category}`);
    }
    return statusFor(id);
  }

  async function modelsFor(id, { signal } = {}) {
    const provider = registry.get(id);
    if (!provider || !provider.configured) return null;
    const models = await registry.listModels(id, { signal });
    return models
      .filter((m) => provider.isModelAllowed(m))
      .slice(0, 200)
      .map((m) => ({ id: m.id, name: m.name, contextTokens: m.contextTokens, maxOutputTokens: m.maxOutputTokens, free: m.free ?? null }));
  }

  return { generate, statusFor, checkProvider, modelsFor, planCandidates };
}
