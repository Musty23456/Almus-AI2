/**
 * An error that is safe to show to API clients.
 * Messages must never contain secrets, user content or upstream response bodies.
 */
export class ApiError extends Error {
  constructor(status, code, message, extra = {}) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.code = code;
    this.retryAfterSeconds = extra.retryAfterSeconds;
    /** Optional machine-readable, secret-free hints for clients (Phase 4). */
    this.details = extra.details;
  }
}

export const bad = (message, code = 'invalid_request') => new ApiError(400, code, message);
