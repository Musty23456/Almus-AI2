import test from 'node:test';
import assert from 'node:assert/strict';
import { buildOrchestrator, mockProvider, ok, fail, input, routing, failureOf, Category, fakeClock } from './testkit.test.js';

const allow = (ids, extra = {}) => routing({ fallback: { enabled: true, providers: ids, ...extra } });

test('successful request goes to the primary provider only', async () => {
  const a = mockProvider({ id: 'alpha' });
  const b = mockProvider({ id: 'beta' });
  const { orchestrator } = buildOrchestrator({ providers: [a, b] });
  const r = await orchestrator.generate(input(), { routing: routing() });
  assert.equal(r.reply, 'reply from alpha');
  assert.equal(r.provider, 'alpha');
  assert.equal(r.route.fallbackUsed, false);
  assert.equal(b.calls.length, 0);
});

test('rate limit: waits at least Retry-After (with jitter floor), retries once, then succeeds', async () => {
  const a = mockProvider({ id: 'alpha', script: [fail(Category.RATE_LIMITED, { retryAfterMs: 2000, safeToRetry: true }), ok('second try')] });
  const { orchestrator, clock } = buildOrchestrator({ providers: [a] });
  const r = await orchestrator.generate(input(), { routing: routing() });
  assert.equal(r.reply, 'second try');
  assert.equal(a.calls.length, 2);
  assert.equal(clock.sleeps.length, 1);
  assert.ok(clock.sleeps[0] >= 2000);
});

test('rate limit with a very long Retry-After is not waited for', async () => {
  const a = mockProvider({ id: 'alpha', script: [fail(Category.RATE_LIMITED, { retryAfterMs: 60000, safeToRetry: true })] });
  const { orchestrator, clock } = buildOrchestrator({ providers: [a] });
  const e = await failureOf(orchestrator.generate(input(), { routing: routing() }));
  assert.equal(e.status, 429);
  assert.equal(e.code, 'quota_or_rate_limit');
  assert.equal(e.retryAfterSeconds, 60);
  assert.equal(a.calls.length, 1);
  assert.equal(clock.sleeps.length, 0);
});

test('quota exhaustion is never retried on the same provider', async () => {
  const a = mockProvider({ id: 'alpha', script: [fail(Category.QUOTA_EXHAUSTED, { quotaWindow: 'day' })] });
  const { orchestrator } = buildOrchestrator({ providers: [a] });
  const e = await failureOf(orchestrator.generate(input(), { routing: routing() }));
  assert.equal(a.calls.length, 1);
  assert.equal(e.code, 'quota_or_rate_limit');
});

test('timeout is retried only when the provider is free-only (a retry could be billed twice otherwise)', async () => {
  const free = mockProvider({ id: 'alpha', costPolicy: 'free_only', script: [fail(Category.TIMEOUT), ok('late')] });
  assert.equal((await buildOrchestrator({ providers: [free] }).orchestrator.generate(input(), { routing: routing() })).reply, 'late');
  assert.equal(free.calls.length, 2);

  const paid = mockProvider({ id: 'alpha', costPolicy: 'metered', script: [fail(Category.TIMEOUT), ok('late')] });
  const e = await failureOf(buildOrchestrator({ providers: [paid] }).orchestrator.generate(input(), { routing: routing() }));
  assert.equal(paid.calls.length, 1);
  assert.equal(e.code, 'upstream_timeout');
});

test('503 (rejected before processing) is retried even on a metered provider; 500 is not', async () => {
  const a = mockProvider({ id: 'alpha', costPolicy: 'metered', script: [fail(Category.UNAVAILABLE, { status: 503, safeToRetry: true }), ok('back')] });
  assert.equal((await buildOrchestrator({ providers: [a] }).orchestrator.generate(input(), { routing: routing() })).reply, 'back');
  const b = mockProvider({ id: 'alpha', costPolicy: 'metered', script: [fail(Category.UNAVAILABLE, { status: 500 }), ok('back')] });
  await failureOf(buildOrchestrator({ providers: [b] }).orchestrator.generate(input(), { routing: routing() }));
  assert.equal(b.calls.length, 1);
});

test('invalid credentials: no retry, provider becomes misconfigured, later requests do not hit it', async () => {
  const a = mockProvider({ id: 'alpha', script: [fail(Category.AUTH, { status: 401 })] });
  const { orchestrator, health } = buildOrchestrator({ providers: [a] });
  const e = await failureOf(orchestrator.generate(input(), { routing: routing() }));
  assert.equal(e.code, 'upstream_auth');
  assert.equal(a.calls.length, 1);
  assert.equal(health.snapshot('alpha').state, 'misconfigured');
  const e2 = await failureOf(orchestrator.generate(input(), { routing: routing() }));
  assert.equal(e2.code, 'upstream_auth');
  assert.equal(a.calls.length, 1, 'a permanent auth error must not be retried as if it were an outage');
});

test('fallback when the user allowed it: primary fails, allowed provider answers, route says so', async () => {
  const a = mockProvider({ id: 'alpha', script: [fail(Category.QUOTA_EXHAUSTED)] });
  const b = mockProvider({ id: 'beta' });
  const { orchestrator } = buildOrchestrator({ providers: [a, b] });
  const r = await orchestrator.generate(input(), { routing: allow(['beta']) });
  assert.equal(r.provider, 'beta');
  assert.equal(r.route.fallbackUsed, true);
  assert.deepEqual(r.route.failed, [{ provider: 'alpha', category: 'quota_exhausted' }]);
});

test('disabled fallback: nothing is sent to another provider and the error suggests enabling it', async () => {
  const a = mockProvider({ id: 'alpha', script: [fail(Category.QUOTA_EXHAUSTED)] });
  const b = mockProvider({ id: 'beta' });
  const { orchestrator } = buildOrchestrator({ providers: [a, b] });
  const e = await failureOf(orchestrator.generate(input('private text'), { routing: routing() }));
  assert.equal(b.calls.length, 0);
  assert.equal(e.details.fallbackSuggested, true);
  assert.match(e.message, /fallback is off/i);
});

test('fallback only reaches providers the user named; others never see the message', async () => {
  const a = mockProvider({ id: 'alpha', script: [fail(Category.UNAVAILABLE, { status: 500 })] });
  const b = mockProvider({ id: 'beta' });
  const c = mockProvider({ id: 'gamma' });
  const { orchestrator } = buildOrchestrator({ providers: [a, b, c] });
  const r = await orchestrator.generate(input(), { routing: allow(['gamma']) });
  assert.equal(r.provider, 'gamma');
  assert.equal(b.calls.length, 0);
});

test('operator can exclude a provider from fallback entirely', async () => {
  const a = mockProvider({ id: 'alpha', script: [fail(Category.QUOTA_EXHAUSTED)] });
  const b = mockProvider({ id: 'beta', fallbackEligible: false });
  const { orchestrator } = buildOrchestrator({ providers: [a, b] });
  const e = await failureOf(orchestrator.generate(input(), { routing: allow(['beta']) }));
  assert.equal(b.calls.length, 0);
  assert.equal(e.code, 'quota_or_rate_limit');
});

test('memory notes are withheld from a fallback provider unless the user allowed it, and the response says so', async () => {
  const mk = () => [mockProvider({ id: 'alpha', script: [fail(Category.QUOTA_EXHAUSTED)] }), mockProvider({ id: 'beta' })];
  let [a, b] = mk();
  let { orchestrator } = buildOrchestrator({ providers: [a, b] });
  let r = await orchestrator.generate(input('q', { memoryContext: 'LOCAL MEMORY NOTES: likes tea' }), { routing: allow(['beta']) });
  assert.deepEqual(r.route.omitted, ['memory']);
  assert.equal(b.calls[0].request.memoryContext, null);
  assert.ok(!b.calls[0].request.system.includes('likes tea'));

  [a, b] = mk();
  ({ orchestrator } = buildOrchestrator({ providers: [a, b] }));
  r = await orchestrator.generate(input('q', { memoryContext: 'LOCAL MEMORY NOTES: likes tea' }), { routing: allow(['beta'], { shareMemory: true }) });
  assert.deepEqual(r.route.omitted, []);
  assert.ok(b.calls[0].request.system.includes('likes tea'));
});

test('attached file text is never sent to a fallback provider without consent (the fallback is skipped instead)', async () => {
  const att = [{ name: 'a.txt', kind: 'text', text: 'SECRET FILE BODY', truncated: false }];
  let a = mockProvider({ id: 'alpha', script: [fail(Category.QUOTA_EXHAUSTED)] });
  let b = mockProvider({ id: 'beta' });
  let { orchestrator } = buildOrchestrator({ providers: [a, b] });
  const e = await failureOf(orchestrator.generate(input('summarise', { attachments: att }), { routing: allow(['beta']) }));
  assert.equal(b.calls.length, 0);
  assert.ok(a.calls[0].request.messages.at(-1).content.includes('SECRET FILE BODY'), 'the primary does get the file');
  assert.equal(e.code, 'quota_or_rate_limit');

  a = mockProvider({ id: 'alpha', script: [fail(Category.QUOTA_EXHAUSTED)] });
  b = mockProvider({ id: 'beta' });
  ({ orchestrator } = buildOrchestrator({ providers: [a, b] }));
  const r = await orchestrator.generate(input('summarise', { attachments: att }), { routing: allow(['beta'], { shareAttachments: true }) });
  assert.equal(r.attachmentsUsed, 1);
  assert.ok(b.calls[0].request.messages.at(-1).content.includes('SECRET FILE BODY'));
});

test('a metered fallback provider is refused unless the operator allows paid fallback', async () => {
  const a = mockProvider({ id: 'alpha', script: [fail(Category.QUOTA_EXHAUSTED)] });
  const b = mockProvider({ id: 'beta', costPolicy: 'metered' });
  const { orchestrator } = buildOrchestrator({ providers: [a, b] });
  await failureOf(orchestrator.generate(input(), { routing: allow(['beta']) }));
  assert.equal(b.calls.length, 0);

  const a2 = mockProvider({ id: 'alpha', script: [fail(Category.QUOTA_EXHAUSTED)] });
  const b2 = mockProvider({ id: 'beta', costPolicy: 'metered' });
  const r = await buildOrchestrator({ providers: [a2, b2], env: { AI_FALLBACK_ALLOW_PAID: 'true' } }).orchestrator.generate(input(), { routing: allow(['beta']) });
  assert.equal(r.provider, 'beta');
});

test('content blocked by a provider is not sent to another provider', async () => {
  const a = mockProvider({ id: 'alpha', script: [fail(Category.CONTENT_BLOCKED)] });
  const b = mockProvider({ id: 'beta' });
  const { orchestrator } = buildOrchestrator({ providers: [a, b] });
  const e = await failureOf(orchestrator.generate(input(), { routing: allow(['beta']) }));
  assert.equal(e.code, 'blocked');
  assert.equal(b.calls.length, 0);
});

test('unsupported capability: a provider without image support is skipped, a capable one is used', async () => {
  const a = mockProvider({ id: 'alpha', images: false });
  const b = mockProvider({ id: 'beta', images: true });
  const { orchestrator } = buildOrchestrator({ providers: [a, b] });
  const r = await orchestrator.generate(input(), { routing: { ...allow(['beta']), requires: { images: true } } });
  assert.equal(r.provider, 'beta');
  const { orchestrator: o2 } = buildOrchestrator({ providers: [mockProvider({ id: 'alpha' })] });
  const e = await failureOf(o2.generate(input(), { routing: { ...routing(), requires: { images: true } } }));
  assert.equal(e.code, 'unsupported_capability');
});

test('context limits: a provider too small for the request is skipped without being contacted', async () => {
  const a = mockProvider({ id: 'alpha', script: [fail(Category.QUOTA_EXHAUSTED)] });
  const small = mockProvider({ id: 'beta', limits: { maxInputTokens: 50, rpmLimit: null } });
  const big = mockProvider({ id: 'gamma' });
  const { orchestrator } = buildOrchestrator({ providers: [a, small, big] });
  const r = await orchestrator.generate(input('x'.repeat(2000)), { routing: allow(['beta', 'gamma']) });
  assert.equal(small.calls.length, 0);
  assert.equal(r.provider, 'gamma');
});

test('all providers failing gives one clear, sanitized error naming each provider', async () => {
  const a = mockProvider({ id: 'alpha', name: 'Alpha', script: [fail(Category.QUOTA_EXHAUSTED)] });
  const b = mockProvider({ id: 'beta', name: 'Beta', script: [fail(Category.AUTH)] });
  const { orchestrator } = buildOrchestrator({ providers: [a, b] });
  const e = await failureOf(orchestrator.generate(input(), { routing: allow(['beta']) }));
  assert.equal(e.status, 503);
  assert.equal(e.code, 'all_providers_failed');
  assert.match(e.message, /Alpha/);
  assert.match(e.message, /Beta/);
  assert.deepEqual(e.details.attempts.map((x) => x.provider), ['alpha', 'beta']);
});

test('retries are bounded: attempts per provider and in total', async () => {
  const a = mockProvider({ id: 'alpha', script: [fail(Category.RATE_LIMITED, { safeToRetry: true })] });
  const b = mockProvider({ id: 'beta', script: [fail(Category.RATE_LIMITED, { safeToRetry: true })] });
  const c = mockProvider({ id: 'gamma', script: [fail(Category.RATE_LIMITED, { safeToRetry: true })] });
  const { orchestrator } = buildOrchestrator({ providers: [a, b, c] });
  await failureOf(orchestrator.generate(input(), { routing: allow(['beta', 'gamma']) }));
  assert.equal(a.calls.length, 2);
  assert.equal(b.calls.length, 2);
  assert.equal(c.calls.length, 0, 'AI_MAX_TOTAL_ATTEMPTS (4) stops further attempts');
});

test('outage and recovery: breaker opens, provider is skipped, then recovers after the cool-down', async () => {
  const a = mockProvider({ id: 'alpha', costPolicy: 'metered', script: [fail(Category.UNAVAILABLE, { status: 500 }), fail(Category.UNAVAILABLE, { status: 500 }), fail(Category.UNAVAILABLE, { status: 500 }), ok('recovered')] });
  const { orchestrator, health, clock } = buildOrchestrator({ providers: [a] });
  for (let i = 0; i < 3; i += 1) await failureOf(orchestrator.generate(input(), { routing: routing() }));
  assert.equal(health.snapshot('alpha').state, 'unavailable');
  const callsBefore = a.calls.length;
  const e = await failureOf(orchestrator.generate(input(), { routing: routing() }));
  assert.equal(a.calls.length, callsBefore, 'an open breaker sends nothing upstream');
  assert.equal(e.code, 'upstream_unavailable');
  clock.advance(20_000);
  const r = await orchestrator.generate(input(), { routing: routing() });
  assert.equal(r.reply, 'recovered');
  assert.equal(health.snapshot('alpha').state, 'healthy');
  assert.equal(health.snapshot('alpha').verified, true);
});

test('fallback keeps working while the primary is cooling down, and skips it without a call', async () => {
  const a = mockProvider({ id: 'alpha', script: [fail(Category.QUOTA_EXHAUSTED, { retryAfterMs: 30_000 })] });
  const b = mockProvider({ id: 'beta' });
  const { orchestrator } = buildOrchestrator({ providers: [a, b] });
  await orchestrator.generate(input(), { routing: allow(['beta']) });
  await orchestrator.generate(input(), { routing: allow(['beta']) });
  assert.equal(a.calls.length, 1);
  assert.equal(b.calls.length, 2);
});

test('cancellation stops the work and is not treated as a provider failure', async () => {
  const controller = new AbortController();
  const a = mockProvider({ id: 'alpha', script: [async () => { controller.abort(); return fail(Category.CANCELLED); }] });
  const b = mockProvider({ id: 'beta' });
  const { orchestrator, health } = buildOrchestrator({ providers: [a, b] });
  const e = await failureOf(orchestrator.generate(input(), { routing: allow(['beta']), signal: controller.signal }));
  assert.equal(e.code, 'cancelled');
  assert.equal(b.calls.length, 0);
  assert.equal(health.snapshot('alpha').state, 'unknown');
  assert.ok(a.calls[0].signal, 'the signal is handed to the adapter');
});

test('a user-chosen model must exist in the provider live list', async () => {
  const a = mockProvider({ id: 'alpha', models: [{ id: 'real-model', free: true, active: true }] });
  const { orchestrator } = buildOrchestrator({ providers: [a] });
  const r = await orchestrator.generate(input(), { routing: routing({ models: { alpha: 'real-model' } }) });
  assert.equal(a.calls[0].model, 'real-model');
  assert.equal(r.route.modelSource, 'user');
  const e = await failureOf(orchestrator.generate(input(), { routing: routing({ models: { alpha: 'made-up' } }) }));
  assert.equal(e.status, 400);
  assert.equal(e.code, 'unknown_model');
});

test('a paid model cannot be selected on a provider that enforces free-only use', async () => {
  const a = mockProvider({ id: 'alpha', enforcesFreeModels: true, models: [{ id: 'cheap:free', free: true, active: true }, { id: 'pricey', free: false, active: true }] });
  const { orchestrator } = buildOrchestrator({ providers: [a] });
  const e = await failureOf(orchestrator.generate(input(), { routing: routing({ models: { alpha: 'pricey' } }) }));
  assert.equal(e.code, 'model_not_allowed');
  assert.equal(a.calls.length, 0);
});

test('own requests-per-minute budget stops calls before the provider would reject them', async () => {
  const a = mockProvider({ id: 'alpha', limits: { maxInputTokens: null, rpmLimit: 1 } });
  const { orchestrator } = buildOrchestrator({ providers: [a] });
  await orchestrator.generate(input(), { routing: routing() });
  const e = await failureOf(orchestrator.generate(input(), { routing: routing() }));
  assert.equal(e.code, 'rate_limited');
  assert.equal(a.calls.length, 1);
});

test('error output never contains upstream text or message content', async () => {
  const a = mockProvider({ id: 'alpha', script: [fail(Category.UNKNOWN)] });
  const { orchestrator, logs } = buildOrchestrator({ providers: [a] });
  const e = await failureOf(orchestrator.generate(input('MY PRIVATE WORDS'), { routing: routing() }));
  assert.ok(!JSON.stringify(e.details).includes('PRIVATE'));
  assert.ok(logs.every((l) => !l.includes('PRIVATE')));
});

test('health checks: unknown until checked, healthy after a real check, misconfigured after a failed one', async () => {
  let behave = 'ok';
  const a = mockProvider({ id: 'alpha', check: async () => { if (behave === 'bad') throw new (await import('./ai/errors.js')).ProviderError(Category.AUTH); return { modelCount: 3 }; } });
  const clock = fakeClock();
  const { orchestrator } = buildOrchestrator({ providers: [a], clock });
  let s = orchestrator.statusFor('alpha');
  assert.equal(s.state, 'unknown');
  assert.equal(s.verified, false, 'configured is not the same as available');
  s = await orchestrator.checkProvider('alpha');
  assert.equal(s.state, 'healthy');
  assert.equal(s.verified, true);
  behave = 'bad';
  clock.advance(60_000);
  s = await orchestrator.checkProvider('alpha');
  assert.equal(s.state, 'misconfigured');
  assert.equal(s.verified, false);
  const unconfigured = mockProvider({ id: 'beta', configured: false });
  const o2 = buildOrchestrator({ providers: [a, unconfigured] }).orchestrator;
  assert.equal(o2.statusFor('beta').state, 'unconfigured');
});
