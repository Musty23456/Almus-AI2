/**
 * Error taxonomy shared by every provider adapter (Phase 4).
 *
 * Adapters translate whatever their upstream returns into a ProviderError with ONE category. Everything else
 * (retry, fallback, health, client message) is decided from the category in POLICY, so adding a provider never
 * means touching the retry logic.
 */
export const Category = Object.freeze({
  RATE_LIMITED: 'rate_limited', // temporary; the provider asked us to slow down
  QUOTA_EXHAUSTED: 'quota_exhausted', // daily / monthly allowance used up; will not recover within a retry window
  TIMEOUT: 'timeout',
  UNAVAILABLE: 'unavailable', // 5xx
  NETWORK: 'network', // could not connect / connection dropped
  AUTH: 'auth', // permanent until an operator fixes the key
  PAYMENT_REQUIRED: 'payment_required', // no credit left; retrying could never help and must never spend money
  MODEL_NOT_FOUND: 'model_not_found',
  CONTEXT_TOO_LARGE: 'context_too_large',
  BAD_REQUEST: 'bad_request',
  INVALID_RESPONSE: 'invalid_response',
  CONTENT_BLOCKED: 'content_blocked', // the provider's safety system declined; trying elsewhere would sidestep it
  UNSUPPORTED: 'unsupported_capability',
  CANCELLED: 'cancelled',
  UNKNOWN: 'unknown',
});

/**
 * retry:    'yes'       retry the same provider (still bounded) when the failure is safe to repeat
 *           'no'        never retry
 * fallback: may another provider be tried (only when the user allowed it)
 * health:   how the failure affects the provider's tracked health
 */
export const POLICY = Object.freeze({
  [Category.RATE_LIMITED]: { retry: 'yes', fallback: true, health: 'cooldown' },
  [Category.QUOTA_EXHAUSTED]: { retry: 'no', fallback: true, health: 'cooldown' },
  [Category.TIMEOUT]: { retry: 'yes', fallback: true, health: 'failure' },
  [Category.UNAVAILABLE]: { retry: 'yes', fallback: true, health: 'failure' },
  [Category.NETWORK]: { retry: 'yes', fallback: true, health: 'failure' },
  [Category.AUTH]: { retry: 'no', fallback: true, health: 'misconfigured' },
  [Category.PAYMENT_REQUIRED]: { retry: 'no', fallback: true, health: 'cooldown' },
  [Category.MODEL_NOT_FOUND]: { retry: 'no', fallback: true, health: 'misconfigured' },
  [Category.CONTEXT_TOO_LARGE]: { retry: 'no', fallback: true, health: 'none' },
  [Category.BAD_REQUEST]: { retry: 'no', fallback: true, health: 'none' },
  [Category.INVALID_RESPONSE]: { retry: 'no', fallback: true, health: 'failure' },
  [Category.CONTENT_BLOCKED]: { retry: 'no', fallback: false, health: 'none' },
  [Category.UNSUPPORTED]: { retry: 'no', fallback: true, health: 'none' },
  [Category.CANCELLED]: { retry: 'no', fallback: false, health: 'none' },
  [Category.UNKNOWN]: { retry: 'no', fallback: true, health: 'failure' },
});

export class ProviderError extends Error {
  /**
   * @param {string} category one of Category
   * @param {object} [info]
   * @param {number} [info.status] upstream HTTP status (for logs only)
   * @param {number} [info.retryAfterMs] how long the provider asked us to wait
   * @param {'minute'|'day'} [info.quotaWindow]
   * @param {boolean} [info.safeToRetry] true only when the request was certainly rejected before any work was done
   */
  constructor(category, info = {}) {
    // The message never contains upstream text: it is a fixed label, so it cannot leak keys or user content.
    super(`provider error: ${category}`);
    this.name = 'ProviderError';
    this.category = category;
    this.status = info.status;
    this.retryAfterMs = Number.isFinite(info.retryAfterMs) && info.retryAfterMs > 0 ? Math.round(info.retryAfterMs) : undefined;
    this.quotaWindow = info.quotaWindow;
    this.safeToRetry = info.safeToRetry === true;
  }
}

export const isProviderError = (e) => e instanceof ProviderError;

/** Plain-language label for a category, used in messages shown to the person using the app. */
export const CATEGORY_LABEL = Object.freeze({
  [Category.RATE_LIMITED]: 'is rate limiting requests',
  [Category.QUOTA_EXHAUSTED]: 'has no quota left',
  [Category.TIMEOUT]: 'took too long to answer',
  [Category.UNAVAILABLE]: 'is temporarily unavailable',
  [Category.NETWORK]: 'could not be reached',
  [Category.AUTH]: 'rejected the server\'s credentials',
  [Category.PAYMENT_REQUIRED]: 'has no credit left',
  [Category.MODEL_NOT_FOUND]: 'does not offer the selected model',
  [Category.CONTEXT_TOO_LARGE]: 'cannot take a request this large',
  [Category.BAD_REQUEST]: 'could not process the request',
  [Category.INVALID_RESPONSE]: 'sent an unusable answer',
  [Category.CONTENT_BLOCKED]: 'declined to answer this message',
  [Category.UNSUPPORTED]: 'does not support this kind of request',
  [Category.CANCELLED]: 'was cancelled',
  [Category.UNKNOWN]: 'failed',
});
