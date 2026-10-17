import http from 'node:http';
import crypto from 'node:crypto';
import { ApiError, bad } from './errors.js';
import { configProblems, configuredProviderIds, PROVIDER_ID_PATTERN } from './config.js';
import { validateChatRequest, validateMemoryContext, validateAttachments, validateRouting } from './validate.js';
import { createRateLimiter } from './rateLimit.js';
import { createRedactor, secretsOf } from './redact.js';
import { createProviderRegistry } from './ai/registry.js';
import { createHealthTracker } from './ai/health.js';
import { createOrchestrator, OrchestratorError } from './ai/orchestrator.js';
import { abortableSleep } from './ai/backoff.js';
import { createLuxandClient, decodePhoto, isValidFaceUuid } from './luxand.js';

export const SERVICE_VERSION = '0.4.0';

function sendJson(res, status, payload, extraHeaders = {}) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    ...extraHeaders,
  });
  res.end(body);
}

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const declared = Number.parseInt(req.headers['content-length'] ?? '', 10);
    if (Number.isFinite(declared) && declared > limit) {
      reject(new ApiError(413, 'payload_too_large', `Request body is larger than ${limit} bytes.`));
      return;
    }
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > limit) {
        chunks.length = 0;
        reject(new ApiError(413, 'payload_too_large', `Request body is larger than ${limit} bytes.`));
        req.pause();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', () => reject(bad('The request body could not be read.')));
  });
}

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest();
}

function tokenMatches(provided, expected) {
  return crypto.timingSafeEqual(sha256(provided), sha256(expected));
}

/**
 * Builds the request handler. Dependencies are injectable so tests never touch the network:
 * `fetchImpl` (all providers), `providers` (extra adapter objects, e.g. mocks), `sleep` and `random` (backoff).
 */
export function createApp({
  config,
  fetchImpl = globalThis.fetch,
  logger: rawLogger = () => {},
  now = () => Date.now(),
  providers: extraProviders = [],
  sleep = abortableSleep,
  random = Math.random,
}) {
  // Every log line passes through the redactor, so a secret can never reach the logs even by accident.
  const redact = createRedactor(secretsOf(config));
  const logger = (line) => rawLogger(redact(String(line)));
  const registry = createProviderRegistry({ config, fetchImpl, extraProviders, now });
  const health = createHealthTracker({
    now,
    threshold: config.breakerThreshold,
    breakerBaseMs: config.breakerBaseMs,
    breakerMaxMs: config.breakerMaxMs,
    quotaCooldownMs: config.quotaCooldownMs,
  });
  const orchestrator = createOrchestrator({ registry, health, config, now, sleep, random, logger });
  const limiter = createRateLimiter({
    perMinute: config.rateLimitPerMinute,
    dailyLimit: config.dailyRequestLimit,
    now,
  });
  // Health checks and model lists call the upstream providers, so they get a much tighter per-client limit.
  const checkLimiter = createRateLimiter({ perMinute: config.checkRateLimitPerMinute, dailyLimit: 1_000_000, now });

  // Phase 6b: cloud face verification. Its own, stricter limits because every call is a paid third-party request.
  const luxand = createLuxandClient({ config, fetchImpl });
  const faceLimiter = createRateLimiter({ perMinute: config.face.perMinute, dailyLimit: config.face.dailyLimit, now });

  function clientKey(req) {
    if (config.trustProxy) {
      const forwarded = String(req.headers['x-forwarded-for'] ?? '').split(',').map((s) => s.trim()).filter(Boolean);
      // The proxy appends the real client address last; earlier entries can be forged.
      if (forwarded.length > 0) return forwarded[forwarded.length - 1];
    }
    return req.socket.remoteAddress ?? 'unknown';
  }

  /** Rate limit, configuration and access-token checks shared by all /v1 routes. */
  function guard(req) {
    const rate = limiter.checkClient(clientKey(req));
    if (!rate.ok) {
      throw new ApiError(429, 'rate_limited', 'Too many requests. Please slow down.', { retryAfterSeconds: rate.retryAfterSeconds });
    }
    const problems = configProblems(config);
    if (problems.length > 0) {
      throw new ApiError(503, 'server_not_configured', `The backend is not configured yet: ${problems.join(' ')}`);
    }
    if (config.accessToken) {
      const header = String(req.headers.authorization ?? '');
      const match = /^Bearer\s+(.+)$/i.exec(header);
      if (!match || !tokenMatches(match[1].trim(), config.accessToken)) {
        throw new ApiError(401, 'unauthorized', 'Missing or invalid access token.');
      }
    }
  }

  /** Reads and parses an optional JSON body (empty body = {}). */
  async function readJsonBody(req, { optional = false, limit = config.maxBodyBytes } = {}) {
    const contentType = String(req.headers['content-type'] ?? '').toLowerCase();
    const declared = Number.parseInt(req.headers['content-length'] ?? '0', 10);
    if (optional && (!Number.isFinite(declared) || declared === 0) && !req.headers['transfer-encoding']) return {};
    if (!contentType.startsWith('application/json')) {
      throw new ApiError(415, 'unsupported_media_type', 'Content-Type must be application/json.');
    }
    const raw = await readBody(req, limit);
    if (optional && raw.length === 0) return {};
    try {
      return JSON.parse(raw.toString('utf8'));
    } catch {
      throw bad('Request body is not valid JSON.', 'invalid_json');
    }
  }

  async function handleChat(req, signal) {
    guard(req);
    const body = await readJsonBody(req);
    const messages = validateChatRequest(body, config);
    const memoryContext = validateMemoryContext(body, config);
    const attachments = validateAttachments(body, config);
    const routing = validateRouting(body, registry.ids());

    const daily = limiter.takeDaily();
    if (!daily.ok) {
      throw new ApiError(429, 'daily_limit_reached', 'The backend\'s daily request limit was reached. Try again tomorrow or raise DAILY_REQUEST_LIMIT.', {
        retryAfterSeconds: daily.retryAfterSeconds,
      });
    }
    const result = await orchestrator.generate({ messages, memoryContext, attachments }, { routing, signal });
    return {
      reply: result.reply,
      model: result.model,
      finishReason: result.finishReason,
      usage: result.usage,
      attachmentsUsed: result.attachmentsUsed,
      // Phase 4: which provider really answered, so the app never has to guess or imply.
      provider: result.provider,
      providerName: result.providerName,
      processing: 'remote',
      route: result.route,
    };
  }


  /** Face routes ALWAYS require the app access token, even if ALLOW_UNAUTHENTICATED is on: this is a security feature. */
  function faceGuard(req) {
    const rate = faceLimiter.checkClient(clientKey(req));
    if (!rate.ok) {
      throw new ApiError(429, 'rate_limited', 'Too many face requests. Please slow down.', { retryAfterSeconds: rate.retryAfterSeconds });
    }
    if (!config.accessToken) {
      throw new ApiError(503, 'face_requires_access_token', 'Face routes need APP_ACCESS_TOKEN to be set on the backend.');
    }
    const match = /^Bearer\s+(.+)$/i.exec(String(req.headers.authorization ?? ''));
    if (!match || !tokenMatches(match[1].trim(), config.accessToken)) {
      throw new ApiError(401, 'unauthorized', 'Missing or invalid access token.');
    }
  }

  function takeFaceDaily() {
    const daily = faceLimiter.takeDaily();
    if (!daily.ok) {
      throw new ApiError(429, 'daily_limit_reached', 'The daily limit for face requests was reached.', { retryAfterSeconds: daily.retryAfterSeconds });
    }
  }

  async function readFacePhoto(req) {
    const body = await readJsonBody(req, { limit: config.face.maxBodyBytes });
    if (body === null || typeof body !== 'object' || Array.isArray(body)) throw bad('Request body must be a JSON object.');
    return decodePhoto(body.photo, config.face.maxPhotoBytes);
  }

  function faceUuid(raw) {
    if (!isValidFaceUuid(raw)) throw bad('Invalid person id.', 'invalid_person');
    return raw;
  }

  async function handleFace(req, path, method, signal) {
    faceGuard(req);
    if (path === '/v1/face/status') {
      if (method !== 'GET') throw new ApiError(405, 'method_not_allowed', 'Use GET.');
      return luxand.status();
    }
    if (path === '/v1/face/person') {
      if (method !== 'POST') throw new ApiError(405, 'method_not_allowed', 'Use POST.');
      const photo = await readFacePhoto(req);
      takeFaceDaily();
      return luxand.enroll(photo, signal);
    }
    const m = /^\/v1\/face\/person\/([^/]+)(?:\/(photos|verify))?$/.exec(path);
    if (!m) throw new ApiError(404, 'not_found', 'Unknown face endpoint.');
    const uuid = faceUuid(decodeURIComponent(m[1]));
    const action = m[2];
    if (!action) {
      if (method !== 'DELETE') throw new ApiError(405, 'method_not_allowed', 'Use DELETE.');
      takeFaceDaily();
      return luxand.remove(uuid, signal);
    }
    if (method !== 'POST') throw new ApiError(405, 'method_not_allowed', 'Use POST.');
    const photo = await readFacePhoto(req);
    takeFaceDaily();
    return action === 'photos' ? luxand.addPhoto(uuid, photo, signal) : luxand.verify(uuid, photo, signal);
  }

  async function handleModels(req, signal) {
    guard(req);
    const gemini = registry.get('gemini');
    if (!gemini?.configured) {
      throw new ApiError(404, 'provider_not_configured', 'Gemini is not configured on this backend. See GET /v1/providers.');
    }
    const models = await gemini.fetchModels({ signal }).catch(() => {
      throw new ApiError(502, 'upstream_error', 'Gemini returned an error while listing models.');
    });
    return { configuredModel: config.geminiModel, fallbackModel: config.geminiFallbackModel || null, models: models.map((m) => m.id).sort() };
  }

  /** Cheap and side-effect free: reports what is known. Nothing here calls a provider, so nothing is "verified" by it. */
  function handleProviders(req) {
    guard(req);
    const configured = configuredProviderIds(config);
    const primaryDefault = configured.includes(config.primaryProvider) ? config.primaryProvider : configured[0] ?? null;
    return {
      primaryDefault,
      fallbackOrder: config.fallbackOrder.length > 0 ? config.fallbackOrder : configured.filter((id) => id !== primaryDefault),
      allowPaidFallback: config.allowPaidFallback,
      providers: registry.ids().map((id) => orchestrator.statusFor(id)),
    };
  }

  /** Real health checks (they call the providers). Optional body: {"provider": "<id>"}; no body checks every configured provider. */
  async function handleProviderCheck(req, signal) {
    guard(req);
    const rate = checkLimiter.checkClient(clientKey(req));
    if (!rate.ok) {
      throw new ApiError(429, 'rate_limited', 'Too many connection checks. Please wait a moment.', { retryAfterSeconds: rate.retryAfterSeconds });
    }
    const body = await readJsonBody(req, { optional: true });
    if (body === null || typeof body !== 'object' || Array.isArray(body)) throw bad('Request body must be a JSON object.');
    const requested = body.provider;
    if (requested !== undefined && (typeof requested !== 'string' || !PROVIDER_ID_PATTERN.test(requested) || !registry.get(requested))) {
      throw new ApiError(400, 'unknown_provider', 'Unknown provider.');
    }
    const ids = requested ? [requested] : registry.configuredIds();
    const checked = [];
    for (const id of ids) checked.push(await orchestrator.checkProvider(id, { signal }));
    return { providers: checked };
  }

  async function handleProviderModels(req, id, signal) {
    guard(req);
    const rate = checkLimiter.checkClient(clientKey(req));
    if (!rate.ok) {
      throw new ApiError(429, 'rate_limited', 'Too many requests. Please wait a moment.', { retryAfterSeconds: rate.retryAfterSeconds });
    }
    if (!PROVIDER_ID_PATTERN.test(id) || !registry.get(id)) throw new ApiError(404, 'unknown_provider', 'Unknown provider.');
    let models;
    try {
      models = await orchestrator.modelsFor(id, { signal });
    } catch (err) {
      if (err?.name === 'ProviderError') {
        throw new ApiError(502, 'upstream_error', 'The provider could not list its models right now.');
      }
      throw err;
    }
    if (models === null) throw new ApiError(404, 'provider_not_configured', 'That provider is not configured on this backend.');
    return { provider: id, models };
  }

  function handleHealth() {
    return {
      status: 'ok',
      service: 'almus-backend',
      version: SERVICE_VERSION,
      model: config.geminiModel,
      geminiConfigured: Boolean(config.geminiApiKey),
      // Phase 4: true when at least one provider has credentials. It does NOT mean the provider works; see /v1/providers.
      aiConfigured: configuredProviderIds(config).length > 0,
      authRequired: Boolean(config.accessToken),
    };
  }

  return async function handler(req, res) {
    const started = now();
    let errorCode = '';
    // Cancellation: when the client goes away before we answered, stop upstream work and any pending retries.
    const abort = new AbortController();
    res.on('close', () => {
      if (!res.writableEnded) abort.abort();
    });
    res.on('finish', () => {
      logger(`${req.method} ${(req.url ?? '').split('?')[0]} ${res.statusCode} ${now() - started}ms${errorCode ? ` ${errorCode}` : ''}`);
    });

    try {
      const path = new URL(req.url ?? '/', 'http://localhost').pathname;
      const method = req.method ?? 'GET';

      if (path === '/health') {
        if (method !== 'GET') throw new ApiError(405, 'method_not_allowed', 'Use GET.');
        sendJson(res, 200, handleHealth());
      } else if (path === '/v1/chat') {
        if (method !== 'POST') throw new ApiError(405, 'method_not_allowed', 'Use POST.');
        sendJson(res, 200, await handleChat(req, abort.signal));
      } else if (path === '/v1/models') {
        if (method !== 'GET') throw new ApiError(405, 'method_not_allowed', 'Use GET.');
        sendJson(res, 200, await handleModels(req, abort.signal));
      } else if (path === '/v1/providers') {
        if (method !== 'GET') throw new ApiError(405, 'method_not_allowed', 'Use GET.');
        sendJson(res, 200, handleProviders(req));
      } else if (path === '/v1/providers/check') {
        if (method !== 'POST') throw new ApiError(405, 'method_not_allowed', 'Use POST.');
        sendJson(res, 200, await handleProviderCheck(req, abort.signal));
      } else if (path === '/v1/face/status' || path === '/v1/face/person' || path.startsWith('/v1/face/person/')) {
        sendJson(res, 200, await handleFace(req, path, method, abort.signal));
      } else if (/^\/v1\/providers\/[^/]+\/models$/.test(path)) {
        if (method !== 'GET') throw new ApiError(405, 'method_not_allowed', 'Use GET.');
        sendJson(res, 200, await handleProviderModels(req, decodeURIComponent(path.split('/')[3]), abort.signal));
      } else {
        throw new ApiError(404, 'not_found', 'Unknown endpoint. See README for /health, /v1/chat, /v1/providers and /v1/models.');
      }
    } catch (err) {
      // Anything that is not one of our own safe error types becomes a generic 500: internal exceptions and their
      // messages (which could contain keys or user text) are never sent to the client.
      const apiError =
        err instanceof ApiError
          ? err
          : err instanceof OrchestratorError
            ? new ApiError(err.status, err.code, err.message, { retryAfterSeconds: err.retryAfterSeconds, details: err.details })
            : new ApiError(500, 'internal_error', 'Unexpected server error.');
      errorCode = apiError.code;
      const headers = {};
      if (apiError.retryAfterSeconds) headers['retry-after'] = String(apiError.retryAfterSeconds);
      if (apiError.status === 413) headers.connection = 'close';
      const payload = { error: { code: apiError.code, message: apiError.message } };
      if (apiError.retryAfterSeconds) payload.error.retryAfterSeconds = apiError.retryAfterSeconds;
      if (apiError.details) payload.error.details = apiError.details;
      sendJson(res, apiError.status, payload, headers);
      if (apiError.status === 413) req.destroy();
    }
  };
}

export function createServer(options) {
  const server = http.createServer(createApp(options));
  server.requestTimeout = 60_000;
  server.headersTimeout = 20_000;
  server.keepAliveTimeout = 65_000;
  return server;
}
