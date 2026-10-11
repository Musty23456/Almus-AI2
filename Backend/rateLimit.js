const MINUTE_MS = 60_000;
const DAY_MS = 86_400_000;

/**
 * In-memory limiter: a per-client fixed window plus a global daily cap that protects your
 * free Gemini quota. State resets when the server restarts, which is fine for a personal app.
 */
export function createRateLimiter({ perMinute, dailyLimit, now = () => Date.now() }) {
  const windows = new Map();
  let dayStart = Math.floor(now() / DAY_MS) * DAY_MS;
  let dailyCount = 0;

  function prune(t) {
    for (const [key, w] of windows) {
      if (t - w.start >= MINUTE_MS) windows.delete(key);
    }
  }

  return {
    checkClient(key) {
      const t = now();
      if (windows.size > 5000) prune(t);
      let w = windows.get(key);
      if (!w || t - w.start >= MINUTE_MS) {
        w = { start: t, count: 0 };
        windows.set(key, w);
      }
      w.count += 1;
      if (w.count > perMinute) {
        return { ok: false, retryAfterSeconds: Math.max(1, Math.ceil((w.start + MINUTE_MS - t) / 1000)) };
      }
      return { ok: true };
    },

    takeDaily() {
      const t = now();
      const today = Math.floor(t / DAY_MS) * DAY_MS;
      if (today !== dayStart) {
        dayStart = today;
        dailyCount = 0;
      }
      if (dailyCount >= dailyLimit) {
        return { ok: false, retryAfterSeconds: Math.max(1, Math.ceil((dayStart + DAY_MS - t) / 1000)) };
      }
      dailyCount += 1;
      return { ok: true };
    },
  };
}
