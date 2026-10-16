import { POLICY } from './errors.js';

/**
 * Per-provider health (Phase 4). The point is honesty: a provider is only reported as working after a real
 * health check or a real request succeeded; "configured" never means "available".
 *
 * States: unconfigured | unknown | healthy | degraded | rate_limited | quota_exhausted | unavailable | misconfigured
 *
 * - rate_limited / quota_exhausted: cooldown until the provider's own retry time (or a configured default).
 * - unavailable: circuit breaker. After `threshold` consecutive failures the provider is skipped for a growing
 *   cool-down (base * 2^n, capped), then given another chance.
 * - misconfigured: authentication or model problems. Sticky: nothing retries it automatically, because waiting
 *   cannot fix a wrong key. Only a successful explicit check (after the operator fixed the setting) clears it.
 */
export function createHealthTracker({ now = () => Date.now(), threshold = 3, breakerBaseMs = 15000, breakerMaxMs = 120000, quotaCooldownMs = 900000 } = {}) {
  const records = new Map();

  function rec(id) {
    let r = records.get(id);
    if (!r) {
      r = {
        state: 'unknown',
        consecutiveFailures: 0,
        breakerOpenings: 0,
        cooldownUntil: 0,
        lastCheckedAt: null,
        lastSuccessAt: null,
        lastFailureAt: null,
        lastCategory: null,
      };
      records.set(id, r);
    }
    return r;
  }

  function effectiveState(r) {
    if (['rate_limited', 'quota_exhausted', 'unavailable'].includes(r.state) && r.cooldownUntil <= now()) {
      return 'degraded'; // cool-down over, but nothing has confirmed recovery yet
    }
    return r.state;
  }

  return {
    /** May a request be sent to this provider right now? */
    canAttempt(id) {
      const r = rec(id);
      if (r.state === 'misconfigured') return { ok: false, reason: 'misconfigured', category: r.lastCategory };
      if (['rate_limited', 'quota_exhausted', 'unavailable'].includes(r.state) && r.cooldownUntil > now()) {
        return { ok: false, reason: 'cooling_down', retryAfterMs: r.cooldownUntil - now(), category: r.lastCategory, state: r.state };
      }
      return { ok: true };
    },

    recordSuccess(id) {
      const r = rec(id);
      r.state = 'healthy';
      r.consecutiveFailures = 0;
      r.breakerOpenings = 0;
      r.cooldownUntil = 0;
      r.lastSuccessAt = now();
      r.lastCategory = null;
    },

    recordFailure(id, category, { retryAfterMs } = {}) {
      const r = rec(id);
      const effect = POLICY[category]?.health ?? 'failure';
      r.lastFailureAt = now();
      r.lastCategory = category;
      if (effect === 'none') return;
      if (effect === 'misconfigured') {
        r.state = 'misconfigured';
        return;
      }
      if (effect === 'cooldown') {
        const quota = category === 'quota_exhausted' || category === 'payment_required';
        r.state = quota ? 'quota_exhausted' : 'rate_limited';
        r.cooldownUntil = now() + (retryAfterMs ?? (quota ? quotaCooldownMs : breakerBaseMs));
        return;
      }
      r.consecutiveFailures += 1;
      if (r.consecutiveFailures >= threshold) {
        r.state = 'unavailable';
        r.cooldownUntil = now() + Math.min(breakerMaxMs, breakerBaseMs * 2 ** r.breakerOpenings);
        r.breakerOpenings += 1;
      } else if (r.state !== 'misconfigured') {
        r.state = 'degraded';
      }
    },

    /** Result of an explicit health check (a real call to the provider). */
    recordCheck(id, ok, category = null) {
      const r = rec(id);
      r.lastCheckedAt = now();
      if (ok) {
        // A successful key/model-list check proves the key works, not that quota is free: keep an active cool-down.
        const coolingDown = ['rate_limited', 'quota_exhausted'].includes(r.state) && r.cooldownUntil > now();
        if (!coolingDown) {
          r.state = 'healthy';
          r.consecutiveFailures = 0;
          r.breakerOpenings = 0;
          r.cooldownUntil = 0;
          r.lastCategory = null;
        }
        r.lastSuccessAt = now();
        return;
      }
      this.recordFailure(id, category ?? 'unknown');
    },

    /** Operator fixed a setting and asked for a re-check: forget the sticky misconfiguration. */
    clearMisconfiguration(id) {
      const r = rec(id);
      if (r.state === 'misconfigured') r.state = 'unknown';
    },

    markUnconfigured(id) {
      rec(id).state = 'unconfigured';
    },

    /** Safe-to-send snapshot (no secrets, no upstream text). */
    snapshot(id) {
      const r = rec(id);
      const state = effectiveState(r);
      const remaining = r.cooldownUntil > now() ? r.cooldownUntil - now() : 0;
      return {
        state,
        verified: state === 'healthy' && r.lastSuccessAt !== null,
        lastCheckedAt: r.lastCheckedAt ? new Date(r.lastCheckedAt).toISOString() : null,
        lastSuccessAt: r.lastSuccessAt ? new Date(r.lastSuccessAt).toISOString() : null,
        lastErrorCategory: r.lastCategory,
        retryAfterSeconds: remaining > 0 ? Math.ceil(remaining / 1000) : null,
      };
    },
  };
}
