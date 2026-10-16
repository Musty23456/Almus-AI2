import test from 'node:test';
import assert from 'node:assert/strict';
import { loadConfig } from './config.js';
import { classifyOpenAIError, createGroqProvider, createOpenRouterProvider, createGenericCompatProvider, normalizeModel } from './ai/adapters/openaiCompat.js';
import { createGeminiProvider } from './ai/adapters/gemini.js';
import { assertProvider } from './ai/registry.js';
import { computeBackoffMs } from './ai/backoff.js';
import { createHealthTracker } from './ai/health.js';
import { createRedactor } from './redact.js';
import { failureOf } from './testkit.test.js';

const KEY = 'SECRET-PROVIDER-KEY-999';
const hdr = (o = {}) => new Headers(o);
const res = (status, body, headers = {}) => new Response(typeof body === 'string' ? body : JSON.stringify(body), { status, headers });
const cfg = (env = {}) => ({ ...loadConfig({ APP_ACCESS_TOKEN: 't', GROQ_API_KEY: KEY, OPENROUTER_API_KEY: KEY, GEMINI_API_KEY: KEY, ...env }), upstreamTimeoutMs: 500 });
const chatOk = (text = 'hi') => ({ choices: [{ message: { content: text }, finish_reason: 'stop' }], usage: { prompt_tokens: 2, completion_tokens: 3, total_tokens: 5 }, model: 'm' });
const request = { messages: [{ role: 'user', content: 'hello' }], memoryContext: null, hasAttachments: false };

test('classifyOpenAIError maps every important status', () => {
  const c = (status, body = {}, h = {}) => classifyOpenAIError(status, hdr(h), JSON.stringify(body));
  assert.equal(c(401).category, 'auth');
  assert.equal(c(403, { error: { message: 'bad key' } }).category, 'auth');
  assert.equal(c(403, { error: { message: 'input flagged by moderation' } }).category, 'content_blocked');
  assert.equal(c(402).category, 'payment_required');
  const inflight = c(402, { error: { metadata: { limit_source: 'openrouter_in_flight_budget' } } }, { 'retry-after': '3' });
  assert.equal(inflight.category, 'rate_limited');
  assert.equal(inflight.retryAfterMs, 3000);
  assert.equal(c(404).category, 'model_not_found');
  assert.equal(c(413).category, 'context_too_large');
  assert.equal(c(400, { error: { message: 'Please reduce the length of the messages. context length exceeded' } }).category, 'context_too_large');
  assert.equal(c(400, { error: { message: 'nope' } }).category, 'bad_request');
  const rl = c(429, { error: { message: 'Rate limit reached' } }, { 'retry-after': '7' });
  assert.equal(rl.category, 'rate_limited');
  assert.equal(rl.retryAfterMs, 7000);
  assert.equal(rl.safeToRetry, true);
  assert.equal(c(429, { error: { message: 'Rate limit reached for requests per day (RPD)' } }).category, 'quota_exhausted');
  assert.equal(c(429, { error: { message: 'free-models-per-day limit' } }).category, 'quota_exhausted');
  assert.equal(c(429, {}, { 'retry-after': '3600' }).category, 'quota_exhausted');
  assert.equal(c(429, { error: { code: 'insufficient_quota' } }).category, 'quota_exhausted');
  assert.equal(c(503).safeToRetry, true);
  assert.equal(c(500).safeToRetry, false);
  assert.equal(c(500).category, 'unavailable');
  assert.equal(c(418).category, 'unknown');
});

test('Groq adapter: request shape, parsing, and the key stays in the header only', async () => {
  let seen;
  const fetchImpl = async (url, init) => { seen = { url, init, body: JSON.parse(init.body) }; return res(200, chatOk('groq says hi')); };
  const p = createGroqProvider({ config: cfg({ GROQ_MODEL: 'x' }), fetchImpl });
  assertProvider(p);
  const out = await p.generate(request, { model: 'some/model' });
  assert.equal(out.reply, 'groq says hi');
  assert.equal(out.usage.totalTokens, 5);
  assert.equal(seen.url, 'https://api.groq.com/openai/v1/chat/completions');
  assert.equal(seen.init.headers.authorization, `Bearer ${KEY}`);
  assert.ok(!seen.url.includes(KEY));
  assert.equal(seen.body.model, 'some/model');
  assert.equal(seen.body.messages[0].role, 'system');
  assert.ok('max_completion_tokens' in seen.body);
  assert.ok(!('max_tokens' in seen.body));
  assert.equal(seen.body.stream, false);
  assert.equal(seen.init.redirect, 'error');
});

test('Groq adapter: filters non-chat models from the live list and never hardcodes a model', async () => {
  const list = { data: [
    { id: 'whisper-large-v3', context_window: 448, active: true },
    { id: 'vendor/prompt-guard', context_window: 8192, active: true },
    { id: 'chat-small', context_window: 8192, active: true },
    { id: 'chat-big', context_window: 131072, active: true },
    { id: 'retired-chat', context_window: 999999, active: false },
  ] };
  const p = createGroqProvider({ config: cfg({ GROQ_MODEL: 'auto' }), fetchImpl: async () => res(200, list) });
  const models = await p.fetchModels();
  assert.equal(models.length, 5);
  assert.deepEqual(models.filter((m) => p.isModelAllowed(m)).map((m) => m.id).sort(), ['chat-big', 'chat-small']);
  assert.equal(p.pickAutoModel(models), 'chat-big');
  assert.equal(createGroqProvider({ config: cfg(), fetchImpl: async () => {} }).configuredModel, '', 'no default model is baked in');
});

test('OpenRouter adapter: data_collection=deny is sent; free-only filter hides paid models', async () => {
  let body;
  const p = createOpenRouterProvider({ config: cfg(), fetchImpl: async (u, init) => { body = JSON.parse(init.body); return res(200, chatOk()); } });
  await p.generate(request, { model: 'a/b:free' });
  assert.deepEqual(body.provider, { data_collection: 'deny' });
  assert.ok('max_tokens' in body);
  const list = { data: [
    { id: 'a/free:free', context_length: 1000, pricing: { prompt: '0', completion: '0' }, architecture: { output_modalities: ['text'] } },
    { id: 'a/paid', context_length: 9000, pricing: { prompt: '0.000003', completion: '0.000015' }, architecture: { output_modalities: ['text'] } },
    { id: 'a/unknownprice', context_length: 5000 },
    { id: 'a/image', pricing: { prompt: '0', completion: '0' }, architecture: { output_modalities: ['image'] } },
  ] };
  const q = createOpenRouterProvider({ config: cfg({ OPENROUTER_MODEL: 'auto' }), fetchImpl: async () => res(200, list) });
  const models = await q.fetchModels();
  assert.equal(q.costPolicy, 'free_only');
  assert.deepEqual(models.filter((m) => q.isModelAllowed(m)).map((m) => m.id), ['a/free:free']);
  assert.equal(q.pickAutoModel(models), 'a/free:free');
  const paidOk = createOpenRouterProvider({ config: cfg({ OPENROUTER_ALLOW_PAID: 'true' }), fetchImpl: async () => res(200, list) });
  assert.equal(paidOk.costPolicy, 'metered');
  assert.ok(paidOk.isModelAllowed(models.find((m) => m.id === 'a/paid')));
  const noDeny = createOpenRouterProvider({ config: cfg({ OPENROUTER_DATA_COLLECTION: 'allow' }), fetchImpl: async (u, init) => { body = JSON.parse(init.body); return res(200, chatOk()); } });
  await noDeny.generate(request, { model: 'x' });
  assert.ok(!('provider' in body));
});

test('OpenRouter key check reads remaining free requests', async () => {
  const p = createOpenRouterProvider({ config: cfg(), fetchImpl: async (u) => { assert.ok(u.endsWith('/key')); return res(200, { data: { free_model_daily_requests: { used: 3, limit: 50, remaining: 47 }, limit_remaining: null } }); } });
  assert.deepEqual(await p.check(), { freeRequestsRemainingToday: 47, creditLimitRemaining: null });
});

test('response parsing: array content, <think> blocks, empty and filtered answers', async () => {
  const mk = (body) => createGroqProvider({ config: cfg(), fetchImpl: async () => res(200, body) });
  assert.equal((await mk({ choices: [{ message: { content: [{ type: 'text', text: 'A' }, { type: 'text', text: 'B' }] } }] }).generate(request, { model: 'm' })).reply, 'AB');
  assert.equal((await mk(chatOk('<think>hidden</think>Visible')).generate(request, { model: 'm' })).reply, 'Visible');
  assert.equal((await failureOf(mk({ choices: [{ message: { content: '' }, finish_reason: 'length' }] }).generate(request, { model: 'm' }))).category, 'invalid_response');
  assert.equal((await failureOf(mk({ choices: [{ message: { content: '' }, finish_reason: 'content_filter' }] }).generate(request, { model: 'm' }))).category, 'content_blocked');
  assert.equal((await failureOf(mk({ choices: [] }).generate(request, { model: 'm' }))).category, 'invalid_response');
  assert.equal((await failureOf(mk({ error: { code: 429, message: 'slow down' } }).generate(request, { model: 'm' }))).category, 'rate_limited');
  assert.equal((await failureOf(mk('not json').generate(request, { model: 'm' }))).category, 'invalid_response');
});

test('transport failures: timeout, network error, cancellation; messages never contain the key', async () => {
  const slow = createGroqProvider({ config: cfg(), fetchImpl: (u, init) => new Promise((_, rej) => init.signal.addEventListener('abort', () => rej(Object.assign(new Error('x'), { name: 'AbortError' })))) });
  assert.equal((await failureOf(slow.generate(request, { model: 'm', timeoutMs: 20 }))).category, 'timeout');
  const down = createGroqProvider({ config: cfg(), fetchImpl: async () => { throw new TypeError(`fetch failed ${KEY}`); } });
  const e = await failureOf(down.generate(request, { model: 'm' }));
  assert.equal(e.category, 'network');
  assert.ok(!e.message.includes(KEY));
  const controller = new AbortController();
  const hang = createGroqProvider({ config: cfg(), fetchImpl: (u, init) => new Promise((_, rej) => init.signal.addEventListener('abort', () => rej(Object.assign(new Error('x'), { name: 'AbortError' })))) });
  const pending = failureOf(hang.generate(request, { model: 'm', signal: controller.signal, timeoutMs: 5000 }));
  controller.abort();
  assert.equal((await pending).category, 'cancelled');
});

test('generic compat provider: needs address and key; plain http only for localhost', () => {
  const p = createGenericCompatProvider({ config: cfg({ OPENAI_COMPAT_ID: 'local', OPENAI_COMPAT_BASE_URL: 'http://localhost:11434/v1', OPENAI_COMPAT_KEY_OPTIONAL: 'true' }), fetchImpl: async () => {} });
  assert.equal(p.id, 'local');
  assert.equal(p.configured, true);
  assert.equal(createGenericCompatProvider({ config: cfg({ OPENAI_COMPAT_BASE_URL: 'https://x.example/v1' }), fetchImpl: async () => {} }).configured, false);
});

test('Gemini adapter: errors map to categories; per-day quota is recognised and not retryable', async () => {
  const run = (status, body, headers) => failureOf(createGeminiProvider({ config: cfg(), fetchImpl: async () => res(status, body, headers) }).generate(request, { model: null }));
  assert.equal((await run(401, {})).category, 'auth');
  assert.equal((await run(404, {})).category, 'model_not_found');
  assert.equal((await run(503, {})).category, 'unavailable');
  assert.equal((await run(413, {})).category, 'context_too_large');
  const minute = await run(429, { error: { details: [{ retryDelay: '7s' }] } });
  assert.equal(minute.category, 'rate_limited');
  assert.equal(minute.retryAfterMs, 7000);
  const daily = await run(429, { error: { details: [{ '@type': 'type.googleapis.com/google.rpc.QuotaFailure', violations: [{ quotaId: 'GenerateRequestsPerDayPerProjectPerModel-FreeTier' }] }] } });
  assert.equal(daily.category, 'quota_exhausted');
  assert.equal(daily.quotaWindow, 'day');
  const ok = await createGeminiProvider({ config: cfg(), fetchImpl: async () => res(200, { candidates: [{ content: { parts: [{ text: 'gem' }] }, finishReason: 'STOP' }] }) }).generate(request, { model: null });
  assert.equal(ok.reply, 'gem');
});

test('Gemini adapter: billing declared by the operator drives costPolicy', () => {
  const policy = (billing) => createGeminiProvider({ config: cfg({ GEMINI_BILLING: billing }), fetchImpl: async () => {} }).costPolicy;
  assert.equal(policy('free'), 'free_only');
  assert.equal(policy('paid'), 'metered');
  assert.equal(policy('unknown'), 'unknown');
});

test('assertProvider rejects an incomplete adapter with a precise message', () => {
  assert.throws(() => assertProvider({ id: 'x' }), /missing/);
  assert.throws(() => assertProvider({ id: 'Bad Id!', displayName: 'x', configured: true, costPolicy: 'unknown', fallbackEligible: true, capabilities: {}, limits: {} }), /invalid/);
});

test('backoff: full jitter stays within the cap and never undercuts Retry-After', () => {
  for (let attempt = 1; attempt <= 8; attempt += 1) {
    const v = computeBackoffMs({ attempt, baseMs: 400, capMs: 4000, random: () => 0.999 });
    assert.ok(v < 4000 + 1 && v >= 0);
  }
  assert.equal(computeBackoffMs({ attempt: 1, baseMs: 400, capMs: 4000, random: () => 0 }), 0);
  assert.equal(computeBackoffMs({ attempt: 1, baseMs: 400, capMs: 4000, retryAfterMs: 2500, random: () => 0 }), 2500);
});

test('health tracker: rate limit cool-down, quota cool-down, sticky auth failure, success clears', () => {
  let t = 0;
  const h = createHealthTracker({ now: () => t, quotaCooldownMs: 1000 });
  h.recordFailure('p', 'rate_limited', { retryAfterMs: 5000 });
  assert.equal(h.canAttempt('p').ok, false);
  assert.equal(h.snapshot('p').retryAfterSeconds, 5);
  t += 5001;
  assert.equal(h.canAttempt('p').ok, true);
  assert.equal(h.snapshot('p').state, 'degraded');
  assert.equal(h.snapshot('p').verified, false);
  h.recordFailure('p', 'quota_exhausted');
  assert.equal(h.snapshot('p').state, 'quota_exhausted');
  t += 1001;
  h.recordSuccess('p');
  assert.equal(h.snapshot('p').verified, true);
  h.recordFailure('p', 'auth');
  t += 10_000_000;
  assert.equal(h.canAttempt('p').ok, false, 'auth failures do not heal with time');
  h.clearMisconfiguration('p');
  assert.equal(h.canAttempt('p').ok, true);
  h.recordFailure('p', 'bad_request');
  h.recordFailure('p', 'context_too_large');
  assert.equal(h.snapshot('p').consecutiveFailures, undefined);
});

test('redactor masks configured secrets and key-shaped strings', () => {
  const r = createRedactor(['my-secret-token-value']);
  const out = r('x my-secret-token-value y Bearer abcdefghijklmnop z sk-abcdefghijkl gsk_abcdefghijkl AIzaSyABCDEFGHIJKLMN api_key=hunter2hunter2');
  for (const leak of ['my-secret-token-value', 'abcdefghijklmnop', 'sk-abcdefghijkl', 'gsk_abcdefghijkl', 'AIzaSyABCDEFGHIJKLMN', 'hunter2hunter2']) {
    assert.ok(!out.includes(leak), `leaked ${leak}`);
  }
  assert.equal(r('plain text'), 'plain text');
});

test('normalizeModel treats missing or unparsable prices as "not known to be free"', () => {
  assert.equal(normalizeModel({ id: 'a' }).free, null);
  assert.equal(normalizeModel({ id: 'a', pricing: { prompt: '0', completion: '0' } }).free, true);
  assert.equal(normalizeModel({ id: 'a', pricing: { prompt: '0', completion: '0.1' } }).free, false);
});
