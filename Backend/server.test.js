import test from 'node:test';
import assert from 'node:assert/strict';
import { loadConfig } from './config.js';
import { createServer } from './app.js';

const SECRET = 'GEMINI-SECRET-XYZ';
const TOKEN = 'app-token-123';

async function withServer(envOverrides, fetchImpl, fn, logs = []) {
  const config = loadConfig({ GEMINI_API_KEY: SECRET, APP_ACCESS_TOKEN: TOKEN, ...envOverrides });
  const server = createServer({ config, fetchImpl, logger: (l) => logs.push(l) });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    await fn(base);
  } finally {
    server.closeAllConnections?.();
    await new Promise((resolve) => server.close(resolve));
  }
}

const geminiOk = (text = 'Hi from Gemini') => async () =>
  new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text }] }, finishReason: 'STOP' }] }), { status: 200 });

const post = (base, body, headers = {}) =>
  fetch(`${base}/v1/chat`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${TOKEN}`, ...headers },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });

const valid = { messages: [{ role: 'user', content: 'hello' }] };

test('GET /health works without a token and hides secrets', async () => {
  await withServer({}, geminiOk(), async (base) => {
    const res = await fetch(`${base}/health`);
    assert.equal(res.status, 200);
    const text = await res.text();
    const json = JSON.parse(text);
    assert.equal(json.status, 'ok');
    assert.equal(json.geminiConfigured, true);
    assert.ok(!text.includes(SECRET) && !text.includes(TOKEN));
  });
});

test('POST /v1/chat returns a reply', async () => {
  await withServer({}, geminiOk('Sannu!'), async (base) => {
    const res = await post(base, valid);
    assert.equal(res.status, 200);
    const json = await res.json();
    assert.equal(json.reply, 'Sannu!');
  });
});

test('requires a valid access token', async () => {
  await withServer({}, geminiOk(), async (base) => {
    let res = await post(base, valid, { authorization: 'Bearer wrong' });
    assert.equal(res.status, 401);
    res = await fetch(`${base}/v1/chat`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(valid) });
    assert.equal(res.status, 401);
    assert.equal((await res.json()).error.code, 'unauthorized');
  });
});

test('reports server_not_configured when secrets are missing', async () => {
  await withServer({ GEMINI_API_KEY: '' }, geminiOk(), async (base) => {
    const res = await post(base, valid);
    assert.equal(res.status, 503);
    assert.equal((await res.json()).error.code, 'server_not_configured');
  });
  await withServer({ APP_ACCESS_TOKEN: '' }, geminiOk(), async (base) => {
    assert.equal((await post(base, valid)).status, 503);
  });
});

test('validation errors return 400 with helpful messages', async () => {
  await withServer({}, geminiOk(), async (base) => {
    let res = await post(base, '{not json');
    assert.equal(res.status, 400);
    assert.equal((await res.json()).error.code, 'invalid_json');
    res = await post(base, { messages: [] });
    assert.equal(res.status, 400);
    assert.match((await res.json()).error.message, /non-empty array/);
    res = await post(base, { messages: [{ role: 'assistant', content: 'x' }] });
    assert.equal(res.status, 400);
  });
});

test('rejects other content types (415) and oversized bodies (413)', async () => {
  await withServer({ MAX_BODY_BYTES: '1024' }, geminiOk(), async (base) => {
    let res = await post(base, 'hello', { 'content-type': 'text/plain' });
    assert.equal(res.status, 415);
    res = await post(base, { messages: [{ role: 'user', content: 'a'.repeat(5000) }] });
    assert.equal(res.status, 413);
  });
});

test('unknown routes and wrong methods', async () => {
  await withServer({}, geminiOk(), async (base) => {
    assert.equal((await fetch(`${base}/nope`)).status, 404);
    assert.equal((await fetch(`${base}/v1/chat`)).status, 405);
  });
});

test('per-client rate limit returns 429 with Retry-After', async () => {
  await withServer({ RATE_LIMIT_PER_MINUTE: '2' }, geminiOk(), async (base) => {
    assert.equal((await post(base, valid)).status, 200);
    assert.equal((await post(base, valid)).status, 200);
    const res = await post(base, valid);
    assert.equal(res.status, 429);
    assert.ok(Number(res.headers.get('retry-after')) >= 1);
    assert.equal((await res.json()).error.code, 'rate_limited');
  });
});

test('daily request limit protects the free quota', async () => {
  let calls = 0;
  const fetchImpl = async () => {
    calls += 1;
    return geminiOk()();
  };
  await withServer({ DAILY_REQUEST_LIMIT: '1' }, fetchImpl, async (base) => {
    assert.equal((await post(base, valid)).status, 200);
    const res = await post(base, valid);
    assert.equal(res.status, 429);
    assert.equal((await res.json()).error.code, 'daily_limit_reached');
    assert.equal(calls, 1);
  });
});

test('upstream failures are translated without leaking secrets or logging them', async () => {
  const logs = [];
  const fetchImpl = async () => new Response(JSON.stringify({ error: { message: `key ${SECRET}` } }), { status: 403 });
  await withServer({}, fetchImpl, async (base) => {
    const res = await post(base, valid);
    const text = await res.text();
    assert.equal(res.status, 502);
    assert.ok(text.includes('upstream_auth'));
    assert.ok(!text.includes(SECRET));
  }, logs);
  assert.ok(logs.length > 0);
  assert.ok(logs.every((l) => !l.includes(SECRET) && !l.includes(TOKEN) && !l.includes('hello')));
});

test('unexpected exceptions return a generic 500', async () => {
  const fetchImpl = async () => {
    throw new Error(`boom ${SECRET}`);
  };
  await withServer({}, fetchImpl, async (base) => {
    const res = await post(base, valid);
    assert.equal(res.status, 502);
    assert.ok(!(await res.text()).includes(SECRET));
  });
});

test('GET /v1/models requires the token and lists models', async () => {
  const fetchImpl = async () =>
    new Response(JSON.stringify({ models: [{ name: 'models/x', supportedGenerationMethods: ['generateContent'] }] }), { status: 200 });
  await withServer({}, fetchImpl, async (base) => {
    assert.equal((await fetch(`${base}/v1/models`)).status, 401);
    const res = await fetch(`${base}/v1/models`, { headers: { authorization: `Bearer ${TOKEN}` } });
    assert.equal(res.status, 200);
    const json = await res.json();
    assert.deepEqual(json.models, ['x']);
    assert.equal(json.configuredModel, 'gemini-flash-latest');
  });
});

test('memoryContext reaches Gemini as a system instruction and is never logged', async () => {
  const logs = [];
  let sent;
  const fetchImpl = async (url, init) => {
    sent = JSON.parse(init.body);
    return new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text: 'ok' }] }, finishReason: 'STOP' }] }), { status: 200 });
  };
  await withServer({}, fetchImpl, async (base) => {
    const res = await post(base, { ...valid, memoryContext: 'LOCAL MEMORY NOTES\n- [preference] short answers please' });
    assert.equal(res.status, 200);
    assert.ok(sent.systemInstruction.parts[0].text.includes('short answers please'));
    assert.ok(!JSON.stringify(sent.contents).includes('short answers please'));
  }, logs);
  assert.ok(!logs.join('\n').includes('short answers'));
});

test('requests without memoryContext still work and bad memoryContext is rejected', async () => {
  await withServer({}, geminiOk(), async (base) => {
    assert.equal((await post(base, valid)).status, 200);
    const bad = await post(base, { ...valid, memoryContext: 42 });
    assert.equal(bad.status, 400);
    const tooLong = await post(base, { ...valid, memoryContext: 'x'.repeat(4000) });
    assert.equal(tooLong.status, 400);
    assert.equal((await tooLong.json()).error.code, 'memory_too_long');
  });
});
