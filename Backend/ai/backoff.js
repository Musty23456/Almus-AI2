/**
 * Exponential backoff with "full jitter": the wait before retry n is a random value between 0 and
 * min(cap, base * 2^(n-1)). Randomness stops many clients retrying in lock-step. When the provider sent a
 * Retry-After value we never wait LESS than it asked.
 *
 * @param {object} p
 * @param {number} p.attempt        1 for the wait before the first retry
 * @param {number} p.baseMs
 * @param {number} p.capMs
 * @param {number} [p.retryAfterMs]
 * @param {() => number} [p.random] injectable for tests, returns [0, 1)
 */
export function computeBackoffMs({ attempt, baseMs, capMs, retryAfterMs, random = Math.random }) {
  const ceiling = Math.min(capMs, baseMs * 2 ** Math.max(0, attempt - 1));
  const jittered = Math.floor(random() * ceiling);
  return retryAfterMs ? Math.max(jittered, retryAfterMs) : jittered;
}

/** setTimeout-based sleep that ends early (rejecting with an AbortError) when the signal aborts. */
export function abortableSleep(ms, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(Object.assign(new Error('aborted'), { name: 'AbortError' }));
      return;
    }
    const timer = setTimeout(() => {
      signal?.removeEventListener?.('abort', onAbort);
      resolve();
    }, ms);
    function onAbort() {
      clearTimeout(timer);
      reject(Object.assign(new Error('aborted'), { name: 'AbortError' }));
    }
    signal?.addEventListener?.('abort', onAbort, { once: true });
  });
}
