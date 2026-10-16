import { Category, ProviderError } from './errors.js';

const MAX_RESPONSE_CHARS = 4_000_000;

/** Seconds ("12") or an HTTP date -> milliseconds. Returns undefined when absent or unusable. */
export function parseRetryAfterMs(value, nowMs = Date.now()) {
  if (value === undefined || value === null) return undefined;
  const text = String(value).trim();
  if (!text) return undefined;
  if (/^\d+(\.\d+)?$/.test(text)) return Math.min(Number(text) * 1000, 3_600_000);
  const date = Date.parse(text);
  if (Number.isFinite(date)) return Math.min(Math.max(0, date - nowMs), 3_600_000);
  return undefined;
}

/** Groq-style reset durations such as "2m59.56s" or "7.66s". */
export function parseDurationMs(value) {
  const text = String(value ?? '').trim();
  if (!text) return undefined;
  const re = /(\d+(?:\.\d+)?)(ms|h|m|s)/g;
  let total = 0;
  let found = false;
  let m;
  while ((m = re.exec(text)) !== null) {
    found = true;
    const n = Number(m[1]);
    total += m[2] === 'ms' ? n : m[2] === 's' ? n * 1000 : m[2] === 'm' ? n * 60_000 : n * 3_600_000;
  }
  return found ? Math.min(Math.round(total), 3_600_000) : undefined;
}

/**
 * One HTTP call with a timeout and an optional caller cancellation signal. Never throws anything but ProviderError.
 * Returns { status, ok, headers, text }. The response body is capped so a misbehaving upstream cannot exhaust memory.
 */
export async function providerFetch({ fetchImpl, url, method = 'GET', headers = {}, body, timeoutMs, signal }) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const onAbort = () => controller.abort();
  if (signal) {
    if (signal.aborted) controller.abort();
    else signal.addEventListener('abort', onAbort, { once: true });
  }
  try {
    const res = await fetchImpl(url, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: controller.signal,
      redirect: 'error', // never follow a redirect with credentials attached
    });
    const text = await res.text();
    if (text.length > MAX_RESPONSE_CHARS) throw new ProviderError(Category.INVALID_RESPONSE, { status: res.status });
    return { status: res.status, ok: res.ok, headers: res.headers, text };
  } catch (err) {
    if (err instanceof ProviderError) throw err;
    if (signal?.aborted) throw new ProviderError(Category.CANCELLED);
    if (err?.name === 'AbortError') throw new ProviderError(Category.TIMEOUT);
    throw new ProviderError(Category.NETWORK);
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener?.('abort', onAbort);
  }
}

export function tryParseJson(text) {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}
