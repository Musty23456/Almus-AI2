import test from 'node:test';
import assert from 'node:assert/strict';
import { loadConfig } from './config.js';
import { createGeminiClient } from './gemini.js';

const SECRET = 'SECRET-KEY-123';
const baseConfig = () => ({ ...loadConfig({ GEMINI_API_KEY: SECRET }), upstreamTimeoutMs: 1000 });
const contents = [{ role: 'user', parts: [{ text: 'hi' }] }];

const reply = (status, body, headers = {}) =>
  new Response(typeof body === 'string' ? body : JSON.stringify(body), { status, headers });

const okBody = (text = 'Hello there') => ({
  candidates: [{ content: { parts: [{ text }] }, finishReason: 'STOP' }],
  usageMetadata: { promptTokenCount: 3, candidatesTokenCount: 5, totalTokenCount: 8 },
  modelVersion: 'gemini-test-1',
});

async function failure(promise) {
  try {
    await promise;
  } catch (e) {
    return e;
  }
  assert.fail('expected an error');
}

test('success: parses reply and usage, sends key in a header only', async () => {
  let seen;
  const fetchImpl = async (url, init) => {
    seen = { url, init };
    return reply(200, okBody());
  };
  const client = createGeminiClient({ config: baseConfig(), fetchImpl });
  const out = await client.generate(contents);
  assert.equal(out.reply, 'Hello there');
  assert.equal(out.model, 'gemini-test-1');
  assert.equal(out.usage.totalTokens, 8);
  assert.ok(!seen.url.includes(SECRET));
  assert.equal(seen.init.headers['x-goog-api-key'], SECRET);
  assert.ok(seen.url.includes('/models/gemini-flash-latest:generateContent'));
  assert.ok(JSON.parse(seen.init.body).systemInstruction);
});

test('429 maps to quota_or_rate_limit with retry-after', async () => {
  const fetchImpl = async () => reply(429, { error: { status: 'RESOURCE_EXHAUSTED' } }, { 'retry-after': '12' });
  const e = await failure(createGeminiClient({ config: baseConfig(), fetchImpl }).generate(contents));
  assert.equal(e.status, 429);
  assert.equal(e.code, 'quota_or_rate_limit');
  assert.equal(e.retryAfterSeconds, 12);
});

test('429 reads retryDelay from the error details', async () => {
  const body = { error: { details: [{ retryDelay: '7s' }] } };
  const e = await failure(createGeminiClient({ config: baseConfig(), fetchImpl: async () => reply(429, body) }).generate(contents));
  assert.equal(e.retryAfterSeconds, 7);
});

test('403 and key errors map to upstream_auth without leaking the key', async () => {
  for (const [status, body] of [[403, { error: { message: `bad ${SECRET}` } }], [400, { error: { message: `API key not valid ${SECRET}` } }]]) {
    const e = await failure(createGeminiClient({ config: baseConfig(), fetchImpl: async () => reply(status, body) }).generate(contents));
    assert.equal(e.code, 'upstream_auth');
    assert.ok(!e.message.includes(SECRET));
  }
});

test('404 maps to model_not_found, 5xx to upstream_unavailable', async () => {
  let e = await failure(createGeminiClient({ config: baseConfig(), fetchImpl: async () => reply(404, {}) }).generate(contents));
  assert.equal(e.code, 'model_not_found');
  e = await failure(createGeminiClient({ config: baseConfig(), fetchImpl: async () => reply(503, 'oops') }).generate(contents));
  assert.equal(e.code, 'upstream_unavailable');
  assert.equal(e.status, 503);
});

test('network failure maps to upstream_unreachable', async () => {
  const fetchImpl = async () => {
    throw new TypeError(`fetch failed for ${SECRET}`);
  };
  const e = await failure(createGeminiClient({ config: baseConfig(), fetchImpl }).generate(contents));
  assert.equal(e.code, 'upstream_unreachable');
  assert.ok(!e.message.includes(SECRET));
});

test('timeout maps to upstream_timeout (504)', async () => {
  const fetchImpl = (url, init) =>
    new Promise((_, reject) => {
      init.signal.addEventListener('abort', () => reject(Object.assign(new Error('aborted'), { name: 'AbortError' })));
    });
  const config = { ...baseConfig(), upstreamTimeoutMs: 30 };
  const e = await failure(createGeminiClient({ config, fetchImpl }).generate(contents));
  assert.equal(e.status, 504);
  assert.equal(e.code, 'upstream_timeout');
});

test('invalid or empty upstream responses are reported clearly', async () => {
  let e = await failure(createGeminiClient({ config: baseConfig(), fetchImpl: async () => reply(200, 'not json') }).generate(contents));
  assert.equal(e.code, 'invalid_upstream_response');
  e = await failure(createGeminiClient({ config: baseConfig(), fetchImpl: async () => reply(200, { candidates: [] }) }).generate(contents));
  assert.equal(e.code, 'invalid_upstream_response');
  e = await failure(
    createGeminiClient({ config: baseConfig(), fetchImpl: async () => reply(200, { candidates: [{ content: { parts: [] }, finishReason: 'MAX_TOKENS' }] }) }).generate(contents),
  );
  assert.equal(e.code, 'empty_response');
});

test('blocked prompts return 422', async () => {
  let e = await failure(createGeminiClient({ config: baseConfig(), fetchImpl: async () => reply(200, { promptFeedback: { blockReason: 'SAFETY' } }) }).generate(contents));
  assert.equal(e.status, 422);
  e = await failure(
    createGeminiClient({ config: baseConfig(), fetchImpl: async () => reply(200, { candidates: [{ finishReason: 'SAFETY' }] }) }).generate(contents),
  );
  assert.equal(e.code, 'blocked');
});

test('fallback model is used when the primary is rate limited', async () => {
  const urls = [];
  const fetchImpl = async (url) => {
    urls.push(url);
    return urls.length === 1 ? reply(429, {}) : reply(200, okBody('from fallback'));
  };
  const config = { ...baseConfig(), geminiModel: 'primary-model', geminiFallbackModel: 'backup-model' };
  const out = await createGeminiClient({ config, fetchImpl }).generate(contents);
  assert.equal(out.reply, 'from fallback');
  assert.ok(urls[0].includes('primary-model'));
  assert.ok(urls[1].includes('backup-model'));
});

test('listModels returns only generateContent models', async () => {
  const body = {
    models: [
      { name: 'models/b', supportedGenerationMethods: ['generateContent'] },
      { name: 'models/a', supportedGenerationMethods: ['generateContent', 'countTokens'] },
      { name: 'models/embed', supportedGenerationMethods: ['embedContent'] },
    ],
  };
  const names = await createGeminiClient({ config: baseConfig(), fetchImpl: async () => reply(200, body) }).listModels();
  assert.deepEqual(names, ['a', 'b']);
});

test('memory notes are added to the system instruction only when provided', async () => {
  const bodies = [];
  const fetchImpl = async (url, init) => {
    bodies.push(JSON.parse(init.body));
    return reply(200, okBody());
  };
  const client = createGeminiClient({ config: baseConfig(), fetchImpl });
  await client.generate(contents);
  await client.generate(contents, { memoryContext: 'LOCAL MEMORY NOTES\n- [fact] likes tea' });
  const plain = bodies[0].systemInstruction.parts[0].text;
  const withMemory = bodies[1].systemInstruction.parts[0].text;
  assert.ok(!plain.includes('LOCAL MEMORY NOTES\n'));
  assert.ok(withMemory.startsWith(plain));
  assert.ok(withMemory.includes('- [fact] likes tea'));
  // Memory never leaks into the conversation contents.
  assert.ok(!JSON.stringify(bodies[1].contents).includes('likes tea'));
});
