import test from 'node:test';
import assert from 'node:assert/strict';
import { loadConfig } from './config.js';
import { createServer } from './app.js';

const APP_TOKEN = 'app-token-123';
const LUXAND_TOKEN = 'LUXAND-SECRET-TOKEN-999';
const UUID = '123e4567-e89b-12d3-a456-426614174000';
// Smallest thing that starts like a JPEG (FF D8 FF). The code only checks the signature and size.
const JPEG_B64 = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 1, 2, 3]).toString('base64');

async function withServer(env, fetchImpl, fn, logs = []) {
  const config = loadConfig({ APP_ACCESS_TOKEN: APP_TOKEN, LUXAND_API_TOKEN: LUXAND_TOKEN, LUXAND_MIN_SIMILARITY: '0.8', ...env });
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

const call = (base, method, path, body, headers = {}) =>
  fetch(`${base}${path}`, {
    method,
    headers: { 'content-type': 'application/json', authorization: `Bearer ${APP_TOKEN}`, ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });

/** Records what the backend sends to Luxand and answers with a scripted response. */
function luxandMock(answer) {
  const seen = [];
  const impl = async (url, init) => {
    seen.push({ url: String(url), method: init.method, token: init.headers?.token, body: init.body });
    const a = typeof answer === 'function' ? answer(String(url), init) : answer;
    return new Response(JSON.stringify(a.json ?? {}), { status: a.status ?? 200 });
  };
  impl.seen = seen;
  return impl;
}

test('face routes need the app access token', async () => {
  const f = luxandMock({ json: { uuid: UUID } });
  await withServer({}, f, async (base) => {
    const res = await call(base, 'POST', '/v1/face/person', { photo: JPEG_B64 }, { authorization: 'Bearer wrong' });
    assert.equal(res.status, 401);
    assert.equal(f.seen.length, 0);
  });
});

test('face routes are refused when no APP_ACCESS_TOKEN is set, even with ALLOW_UNAUTHENTICATED', async () => {
  const f = luxandMock({ json: {} });
  await withServer({ APP_ACCESS_TOKEN: '', ALLOW_UNAUTHENTICATED: 'true' }, f, async (base) => {
    const res = await call(base, 'GET', '/v1/face/status', undefined, { authorization: '' });
    assert.equal(res.status, 503);
    assert.equal((await res.json()).error.code, 'face_requires_access_token');
  });
});

test('enroll sends the photo and a random label (no real name) with the Luxand token, returns only the uuid', async () => {
  const f = luxandMock({ json: { uuid: UUID, name: 'x' } });
  await withServer({}, f, async (base) => {
    const res = await call(base, 'POST', '/v1/face/person', { photo: JPEG_B64, name: 'Real Name' });
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { uuid: UUID });
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, 'https://api.luxand.cloud/v2/person');
    assert.equal(f.seen[0].token, LUXAND_TOKEN);
    const label = f.seen[0].body.get('name');
    assert.match(label, /^almus-[0-9a-f]{12}$/);
    assert.notEqual(label, 'Real Name');
    assert.equal(f.seen[0].body.get('store'), '1');
  });
});

test('verify: at or above the threshold is verified, below is not', async () => {
  for (const [similarity, expected] of [[0.95, true], [0.8, true], [0.79, false], [0, false]]) {
    const f = luxandMock({ json: { status: 'success', similarity } });
    await withServer({}, f, async (base) => {
      const res = await call(base, 'POST', `/v1/face/person/${UUID}/verify`, { photo: JPEG_B64 });
      assert.equal(res.status, 200);
      const json = await res.json();
      assert.equal(json.verified, expected);
      assert.equal('similarity' in json, false); // score hidden unless FACE_RETURN_SCORE=true
      assert.equal(f.seen[0].url, `https://api.luxand.cloud/photo/verify/${UUID}`);
    });
  }
});

test('verify fails closed on an answer it does not understand', async () => {
  for (const json of [{}, { similarity: 'high' }, { similarity: 1.5 }, { similarity: null }, null]) {
    await withServer({}, luxandMock({ json }), async (base) => {
      const res = await call(base, 'POST', `/v1/face/person/${UUID}/verify`, { photo: JPEG_B64 });
      assert.equal(res.status, 502);
      assert.equal((await res.json()).error.code, 'face_unexpected_response');
    });
  }
});

test('verify is disabled until a threshold is set (no built-in default)', async () => {
  const f = luxandMock({ json: { similarity: 0.99 } });
  await withServer({ LUXAND_MIN_SIMILARITY: '' }, f, async (base) => {
    const res = await call(base, 'POST', `/v1/face/person/${UUID}/verify`, { photo: JPEG_B64 });
    assert.equal(res.status, 503);
    assert.equal((await res.json()).error.code, 'face_not_calibrated');
    assert.equal(f.seen.length, 0);
    const st = await (await call(base, 'GET', '/v1/face/status')).json();
    assert.deepEqual(st, { available: true, calibrated: false });
  });
});

test('score is returned only for calibration when FACE_RETURN_SCORE=true', async () => {
  await withServer({ FACE_RETURN_SCORE: 'true' }, luxandMock({ json: { similarity: 0.87654 } }), async (base) => {
    const json = await (await call(base, 'POST', `/v1/face/person/${UUID}/verify`, { photo: JPEG_B64 })).json();
    assert.equal(json.similarity, 0.877);
  });
});

test('Luxand errors never leak the Luxand token or body, and 401 from Luxand is not shown as the app token being wrong', async () => {
  const logs = [];
  await withServer({}, luxandMock({ status: 401, json: { message: `bad token ${LUXAND_TOKEN}` } }), async (base) => {
    const res = await call(base, 'POST', '/v1/face/person', { photo: JPEG_B64 });
    const text = await res.text();
    assert.equal(res.status, 502);
    assert.ok(!text.includes(LUXAND_TOKEN));
  }, logs);
  assert.ok(!logs.join('\n').includes(LUXAND_TOKEN));
  assert.ok(!logs.join('\n').includes(JPEG_B64));
});

test('"no face found" from Luxand becomes a 422 the app can explain', async () => {
  await withServer({}, luxandMock({ status: 400, json: { message: 'no face' } }), async (base) => {
    const res = await call(base, 'POST', '/v1/face/person', { photo: JPEG_B64 });
    assert.equal(res.status, 422);
    assert.equal((await res.json()).error.code, 'face_not_usable');
  });
});

test('delete: 200 and 404 count as deleted, a Luxand failure is reported (never a false "deleted")', async () => {
  for (const [status, expectedStatus] of [[200, 200], [404, 200], [500, 502]]) {
    const f = luxandMock({ status, json: {} });
    await withServer({}, f, async (base) => {
      const res = await call(base, 'DELETE', `/v1/face/person/${UUID}`);
      assert.equal(res.status, expectedStatus);
      if (expectedStatus === 200) assert.deepEqual(await res.json(), { deleted: true });
      assert.equal(f.seen[0].method, 'DELETE');
      assert.equal(f.seen[0].url, `https://api.luxand.cloud/person/${UUID}`);
    });
  }
});

test('add photo goes to the person endpoint', async () => {
  const f = luxandMock({ json: {} });
  await withServer({}, f, async (base) => {
    const res = await call(base, 'POST', `/v1/face/person/${UUID}/photos`, { photo: JPEG_B64 });
    assert.equal(res.status, 200);
    assert.equal(f.seen[0].url, `https://api.luxand.cloud/v2/person/${UUID}`);
    assert.ok(f.seen[0].body.get('photo'));
  });
});

test('bad input is rejected before anything is sent to Luxand', async () => {
  const f = luxandMock({ json: { uuid: UUID } });
  await withServer({}, f, async (base) => {
    const notJpeg = Buffer.from('hello world, not a picture').toString('base64');
    const cases = [
      ['POST', '/v1/face/person', { photo: notJpeg }, 400],
      ['POST', '/v1/face/person', { photo: '' }, 400],
      ['POST', '/v1/face/person', { photo: 'not base64 !!' }, 400],
      ['POST', '/v1/face/person', { nophoto: 1 }, 400],
      ['POST', '/v1/face/person/not-a-uuid/verify', { photo: JPEG_B64 }, 400],
      ['POST', '/v1/face/person/../x/verify', { photo: JPEG_B64 }, 404],
      ['GET', '/v1/face/person', undefined, 405],
      ['PUT', `/v1/face/person/${UUID}`, undefined, 405],
    ];
    for (const [method, path, body, status] of cases) {
      const res = await call(base, method, path, body);
      assert.equal(res.status, status, `${method} ${path}`);
    }
    assert.equal(f.seen.length, 0);
  });
});

test('oversized photo is rejected', async () => {
  const f = luxandMock({ json: { uuid: UUID } });
  await withServer({ FACE_MAX_PHOTO_BYTES: '20000' }, f, async (base) => {
    const big = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff]), Buffer.alloc(30000)]).toString('base64');
    const res = await call(base, 'POST', '/v1/face/person', { photo: big });
    assert.equal(res.status, 400);
    assert.equal(f.seen.length, 0);
  });
});

test('not configured: routes say so and send nothing', async () => {
  const f = luxandMock({ json: {} });
  await withServer({ LUXAND_API_TOKEN: '' }, f, async (base) => {
    const st = await (await call(base, 'GET', '/v1/face/status')).json();
    assert.deepEqual(st, { available: false, calibrated: true });
    const res = await call(base, 'POST', '/v1/face/person', { photo: JPEG_B64 });
    assert.equal(res.status, 503);
    assert.equal(f.seen.length, 0);
  });
});

test('face requests have their own per-minute limit', async () => {
  await withServer({ FACE_RATE_LIMIT_PER_MINUTE: '2' }, luxandMock({ json: {} }), async (base) => {
    assert.equal((await call(base, 'GET', '/v1/face/status')).status, 200);
    assert.equal((await call(base, 'GET', '/v1/face/status')).status, 200);
    assert.equal((await call(base, 'GET', '/v1/face/status')).status, 429);
  });
});
