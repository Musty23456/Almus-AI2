import test from 'node:test';
import assert from 'node:assert/strict';
import { loadConfig, configProblems, configWarnings } from './config.js';
import { createServer } from './app.js';

const GEMINI_KEY = 'GEMINI-KEY-AAAA1111';
const GROQ_KEY = 'GROQ-KEY-BBBB2222';
const OR_KEY = 'OPENROUTER-KEY-CCCC3333';
const TOKEN = 'app-token-1234567890';

const json = (status, body, headers = {}) => new Response(JSON.stringify(body), { status, headers });
const geminiOk = (t = 'from gemini') => json(200, { candidates: [{ content: { parts: [{ text: t }] }, finishReason: 'STOP' }] });
const groqOk = (t = 'from groq') => json(200, { choices: [{ message: { content: t }, finish_reason: 'stop' }], model: 'groq-m' });
const GROQ_MODELS = { data: [{ id: 'groq-chat', context_window: 131072, active: true }, { id: 'whisper-x', context_window: 448, active: true }] };

/** Routes mocked upstream calls by host so one fetch stub can play every provider. */
function upstream(handlers, calls = []) {
  return async (url, init) => {
    const u = new URL(url);
    const key = u.host.includes('groq') ? 'groq' : u.host.includes('openrouter') ? 'openrouter' : 'gemini';
    calls.push({ key, path: u.pathname, body: init.body ? JSON.parse(init.body) : null, headers: init.headers });
    return handlers[key](u, init);
  };
}

async function withServer(env, fetchImpl, fn, logs = []) {
  const config = loadConfig({ GEMINI_API_KEY: GEMINI_KEY, GROQ_API_KEY: GROQ_KEY, GROQ_MODEL: 'groq-chat', APP_ACCESS_TOKEN: TOKEN, AI_BACKOFF_BASE_MS: '1', AI_BACKOFF_CAP_MS: '2', ...env });
  const server = createServer({ config, fetchImpl, logger: (l) => logs.push(l) });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    await fn(base);
  } finally {
    server.closeAllConnections?.();
    await new Promise((r) => server.close(r));
  }
}
const auth = { authorization: `Bearer ${TOKEN}` };
const chat = (base, body) => fetch(`${base}/v1/chat`, { method: 'POST', headers: { 'content-type': 'application/json', ...auth }, body: JSON.stringify(body) });
const msgs = { messages: [{ role: 'user', content: 'hello there' }] };

test('default request (no routing): Gemini answers, response names the provider, no other provider is contacted', async () => {
  const calls = [];
  await withServer({}, upstream({ gemini: () => geminiOk(), groq: () => groqOk() }, calls), async (base) => {
    const r = await chat(base, msgs);
    const j = await r.json();
    assert.equal(r.status, 200);
    assert.equal(j.reply, 'from gemini');
    assert.equal(j.provider, 'gemini');
    assert.equal(j.processing, 'remote');
    assert.equal(j.route.fallbackUsed, false);
    assert.deepEqual(calls.map((c) => c.key), ['gemini']);
  });
});

test('Gemini quota exhausted + fallback OFF: clear error, Groq never receives the message', async () => {
  const calls = [];
  const gemini429 = () => json(429, { error: { details: [{ violations: [{ quotaId: 'GenerateRequestsPerDayPerProjectPerModel' }] }] } });
  await withServer({ GROQ_COST_POLICY: 'free_only' }, upstream({ gemini: gemini429, groq: () => groqOk() }, calls), async (base) => {
    const r = await chat(base, msgs);
    const j = await r.json();
    assert.equal(r.status, 429);
    assert.equal(j.error.code, 'quota_or_rate_limit');
    assert.equal(j.error.details.fallbackSuggested, true);
    assert.ok(!calls.some((c) => c.key === 'groq'));
    assert.equal(calls.filter((c) => c.key === 'gemini').length, 1, 'quota errors are not retried');
  });
});

test('Gemini quota exhausted + user allowed Groq: Groq answers and the route reports the fallback', async () => {
  const calls = [];
  await withServer({ GROQ_COST_POLICY: 'free_only' }, upstream({ gemini: () => json(429, { error: { details: [{ violations: [{ quotaId: 'PerDay' }] }] } }), groq: () => groqOk('rescued') }, calls), async (base) => {
    const j = await (await chat(base, { ...msgs, memoryContext: 'LOCAL MEMORY NOTES: likes tea', routing: { fallback: { enabled: true, providers: ['groq'] } } })).json();
    assert.equal(j.reply, 'rescued');
    assert.equal(j.provider, 'groq');
    assert.equal(j.route.fallbackUsed, true);
    assert.deepEqual(j.route.omitted, ['memory']);
    const groqCall = calls.find((c) => c.key === 'groq');
    assert.equal(groqCall.body.model, 'groq-chat');
    assert.ok(!JSON.stringify(groqCall.body).includes('likes tea'), 'memory notes were not sent to the fallback');
    assert.equal(groqCall.headers.authorization, `Bearer ${GROQ_KEY}`);
  });
});

test('a fallback whose cost is not declared free is refused even with user consent (no surprise bills)', async () => {
  const calls = [];
  await withServer({}, upstream({ gemini: () => json(429, { error: { details: [{ violations: [{ quotaId: 'PerDay' }] }] } }), groq: () => groqOk() }, calls), async (base) => {
    const r = await chat(base, { ...msgs, routing: { fallback: { enabled: true, providers: ['groq'] } } });
    assert.equal(r.status, 429);
    assert.ok(!calls.some((c) => c.key === 'groq'));
  });
});

test('user can choose Groq as the main provider', async () => {
  const calls = [];
  await withServer({}, upstream({ gemini: () => geminiOk(), groq: () => groqOk() }, calls), async (base) => {
    const j = await (await chat(base, { ...msgs, routing: { provider: 'groq' } })).json();
    assert.equal(j.provider, 'groq');
    assert.ok(!calls.some((c) => c.key === 'gemini'));
  });
});

test('Groq-only backend works (no Gemini key at all)', async () => {
  await withServer({ GEMINI_API_KEY: '' }, upstream({ groq: () => groqOk('solo') }), async (base) => {
    const h = await (await fetch(`${base}/health`)).json();
    assert.equal(h.geminiConfigured, false);
    assert.equal(h.aiConfigured, true);
    assert.equal((await (await chat(base, msgs)).json()).reply, 'solo');
  });
});

test('routing validation: unknown fields, unknown providers and bad types are refused', async () => {
  await withServer({}, upstream({ gemini: () => geminiOk() }), async (base) => {
    const bad = [
      { routing: 'groq' },
      { routing: { evil: 1 } },
      { routing: { provider: 'nope' } },
      { routing: { provider: 'Bad Id' } },
      { routing: { fallback: { enabled: 'yes' } } },
      { routing: { fallback: { enabled: true, providers: ['nope'] } } },
      { routing: { fallback: { enabled: true, apiKey: 'x' } } },
      { routing: { models: { groq: 'bad model name!' } } },
    ];
    for (const extra of bad) {
      const r = await chat(base, { ...msgs, ...extra });
      assert.equal(r.status, 400, JSON.stringify(extra));
    }
    const unconfigured = await chat(base, { ...msgs, routing: { provider: 'openrouter' } });
    assert.equal(unconfigured.status, 400);
    assert.equal((await unconfigured.json()).error.code, 'provider_not_configured');
  });
});

test('GET /v1/providers needs the token, lists providers, and verifies nothing by itself', async () => {
  const calls = [];
  await withServer({}, upstream({ gemini: () => geminiOk(), groq: () => groqOk() }, calls), async (base) => {
    assert.equal((await fetch(`${base}/v1/providers`)).status, 401);
    const j = await (await fetch(`${base}/v1/providers`, { headers: auth })).json();
    assert.equal(calls.length, 0, 'listing makes no upstream calls');
    const by = Object.fromEntries(j.providers.map((p) => [p.id, p]));
    assert.equal(by.gemini.configured, true);
    assert.equal(by.gemini.state, 'unknown');
    assert.equal(by.gemini.verified, false);
    assert.equal(by.groq.model, 'groq-chat');
    assert.equal(by.openrouter.state, 'unconfigured');
    assert.equal(by.openrouter.processing, 'remote');
    assert.equal(j.primaryDefault, 'gemini');
    assert.ok(!JSON.stringify(j).includes(GEMINI_KEY) && !JSON.stringify(j).includes(GROQ_KEY));
  });
});

test('POST /v1/providers/check performs real checks and reports honest states', async () => {
  const handlers = {
    gemini: () => json(200, { models: [{ name: 'models/gemini-x', supportedGenerationMethods: ['generateContent'], inputTokenLimit: 1000 }] }),
    groq: () => json(401, { error: { message: 'Invalid API Key' } }),
  };
  await withServer({}, upstream(handlers), async (base) => {
    const post = (body) => fetch(`${base}/v1/providers/check`, { method: 'POST', headers: { 'content-type': 'application/json', ...auth }, body: body === undefined ? undefined : JSON.stringify(body) });
    assert.equal((await fetch(`${base}/v1/providers/check`, { method: 'POST' })).status, 401);
    const j = await (await post()).json();
    const by = Object.fromEntries(j.providers.map((p) => [p.id, p]));
    assert.equal(by.gemini.state, 'healthy');
    assert.equal(by.gemini.verified, true);
    assert.equal(by.groq.state, 'misconfigured');
    assert.equal(by.groq.lastErrorCategory, 'auth');
    assert.ok(!JSON.stringify(j).includes('Invalid API Key'), 'upstream text is not passed through');
    assert.equal((await post({ provider: 'nope' })).status, 400);
    assert.equal((await post({ provider: 'gemini' })).status, 200);
  });
});

test('GET /v1/providers/:id/models lists only usable models from the live API', async () => {
  await withServer({}, upstream({ gemini: () => geminiOk(), groq: () => json(200, GROQ_MODELS) }), async (base) => {
    const j = await (await fetch(`${base}/v1/providers/groq/models`, { headers: auth })).json();
    assert.deepEqual(j.models.map((m) => m.id), ['groq-chat']);
    assert.equal((await fetch(`${base}/v1/providers/nope/models`, { headers: auth })).status, 404);
    assert.equal((await fetch(`${base}/v1/providers/openrouter/models`, { headers: auth })).status, 404);
    assert.equal((await fetch(`${base}/v1/providers/groq/models`)).status, 401);
  });
});

test('health checks are rate limited separately and tightly', async () => {
  await withServer({ CHECK_RATE_LIMIT_PER_MINUTE: '2' }, upstream({ gemini: () => json(200, { models: [] }), groq: () => json(200, GROQ_MODELS) }), async (base) => {
    const post = () => fetch(`${base}/v1/providers/check`, { method: 'POST', headers: auth });
    assert.equal((await post()).status, 200);
    assert.equal((await post()).status, 200);
    assert.equal((await post()).status, 429);
  });
});

test('recovery after an outage over HTTP: failures, breaker, then success', async () => {
  let mode = 'down';
  const calls = [];
  await withServer({ AI_BREAKER_BASE_MS: '100', AI_BREAKER_THRESHOLD: '2', GEMINI_BILLING: 'paid' }, upstream({ gemini: () => (mode === 'down' ? json(500, {}) : geminiOk('back online')) }, calls), async (base) => {
    assert.equal((await chat(base, msgs)).status, 503);
    assert.equal((await chat(base, msgs)).status, 503);
    const n = calls.length;
    assert.equal((await chat(base, msgs)).status, 503);
    assert.equal(calls.length, n, 'breaker open: no upstream call');
    mode = 'up';
    await new Promise((r) => setTimeout(r, 150));
    const j = await (await chat(base, msgs)).json();
    assert.equal(j.reply, 'back online');
  });
});

test('client disconnect cancels the upstream call', async () => {
  let aborted = false;
  let started;
  const startedP = new Promise((r) => { started = r; });
  const fetchImpl = (url, init) => new Promise((_, reject) => {
    started();
    init.signal.addEventListener('abort', () => { aborted = true; reject(Object.assign(new Error('x'), { name: 'AbortError' })); });
  });
  await withServer({}, fetchImpl, async (base) => {
    const ctl = new AbortController();
    const p = chat(base, msgs).catch(() => null);
    const q = fetch(`${base}/v1/chat`, { method: 'POST', signal: ctl.signal, headers: { 'content-type': 'application/json', ...auth }, body: JSON.stringify(msgs) }).catch(() => null);
    await startedP;
    ctl.abort();
    await q;
    await new Promise((r) => setTimeout(r, 100));
    assert.equal(aborted, true);
    void p;
  });
});

test('secrets never appear in responses or logs, even when upstream echoes them', async () => {
  const logs = [];
  const echo = () => json(500, { error: { message: `boom ${GEMINI_KEY} ${GROQ_KEY} Bearer ${TOKEN}` } });
  await withServer({ GEMINI_BILLING: 'paid' }, upstream({ gemini: echo, groq: echo }), async (base) => {
    for (const body of [msgs, { ...msgs, routing: { fallback: { enabled: true, providers: ['groq'] } } }]) {
      const text = await (await chat(base, body)).text();
      for (const s of [GEMINI_KEY, GROQ_KEY, TOKEN]) assert.ok(!text.includes(s));
    }
    await fetch(`${base}/v1/providers`, { headers: auth });
  }, logs);
  assert.ok(logs.length > 0);
  for (const l of logs) for (const s of [GEMINI_KEY, GROQ_KEY, TOKEN, 'hello there']) assert.ok(!l.includes(s), l);
});

test('configuration validation', () => {
  const p = (env) => configProblems(loadConfig({ APP_ACCESS_TOKEN: 't', ...env }));
  assert.ok(p({}).some((x) => /No AI provider/.test(x)));
  assert.deepEqual(p({ GROQ_API_KEY: 'k' }), []);
  assert.ok(p({ GROQ_API_KEY: 'k', GROQ_BASE_URL: 'http://api.example.com/v1' }).some((x) => /https/.test(x)));
  assert.ok(p({ GROQ_API_KEY: 'k', GROQ_BASE_URL: 'https://user:pw@api.example.com/v1' }).some((x) => /credentials/.test(x)));
  assert.ok(p({ GROQ_API_KEY: 'k', GROQ_MODEL: 'bad model!' }).some((x) => /GROQ_MODEL/.test(x)));
  assert.ok(p({ OPENAI_COMPAT_BASE_URL: 'https://x.example/v1' }).some((x) => /OPENAI_COMPAT_API_KEY/.test(x)));
  assert.deepEqual(p({ OPENAI_COMPAT_BASE_URL: 'http://localhost:11434/v1', OPENAI_COMPAT_KEY_OPTIONAL: 'true' }), []);
  assert.ok(configWarnings(loadConfig({ GROQ_API_KEY: 'k', AI_PRIMARY_PROVIDER: 'gemini', APP_ACCESS_TOKEN: 'short' })).length >= 2);
});
