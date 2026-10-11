import http from 'node:http';
import crypto from 'node:crypto';
import { ApiError, bad } from './errors.js';
import { configProblems } from './config.js';
import { validateChatRequest, buildContents } from './validate.js';
import { createGeminiClient } from './gemini.js';
import { createRateLimiter } from './rateLimit.js';

export const SERVICE_VERSION = '0.1.0';

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

/** Builds the request handler. Dependencies are injectable so tests never touch the network. */
export function createApp({ config, fetchImpl = globalThis.fetch, logger = () => {}, now = () => Date.now() }) {
  const gemini = createGeminiClient({ config, fetchImpl });
  const limiter = createRateLimiter({
    perMinute: config.rateLimitPerMinute,
    dailyLimit: config.dailyRequestLimit,
    now,
  });

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

  async function handleChat(req) {
    guard(req);
    const contentType = String(req.headers['content-type'] ?? '').toLowerCase();
    if (!contentType.startsWith('application/json')) {
      throw new ApiError(415, 'unsupported_media_type', 'Content-Type must be application/json.');
    }
    const raw = await readBody(req, config.maxBodyBytes);
    let body;
    try {
      body = JSON.parse(raw.toString('utf8'));
    } catch {
      throw bad('Request body is not valid JSON.', 'invalid_json');
    }
    const messages = validateChatRequest(body, config);
    const contents = buildContents(messages, config.maxContextChars);

    const daily = limiter.takeDaily();
    if (!daily.ok) {
      throw new ApiError(429, 'daily_limit_reached', 'The backend\'s daily request limit was reached. Try again tomorrow or raise DAILY_REQUEST_LIMIT.', {
        retryAfterSeconds: daily.retryAfterSeconds,
      });
    }
    const result = await gemini.generate(contents);
    return { reply: result.reply, model: result.model, finishReason: result.finishReason, usage: result.usage };
  }

  async function handleModels(req) {
    guard(req);
    const models = await gemini.listModels();
    return { configuredModel: config.geminiModel, fallbackModel: config.geminiFallbackModel || null, models };
  }

  function handleHealth() {
    return {
      status: 'ok',
      service: 'almus-backend',
      version: SERVICE_VERSION,
      model: config.geminiModel,
      geminiConfigured: Boolean(config.geminiApiKey),
      authRequired: Boolean(config.accessToken),
    };
  }

  return async function handler(req, res) {
    const started = now();
    let errorCode = '';
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
        sendJson(res, 200, await handleChat(req));
      } else if (path === '/v1/models') {
        if (method !== 'GET') throw new ApiError(405, 'method_not_allowed', 'Use GET.');
        sendJson(res, 200, await handleModels(req));
      } else {
        throw new ApiError(404, 'not_found', 'Unknown endpoint. See README for /health, /v1/chat and /v1/models.');
      }
    } catch (err) {
      const apiError = err instanceof ApiError ? err : new ApiError(500, 'internal_error', 'Unexpected server error.');
      errorCode = apiError.code;
      const headers = {};
      if (apiError.retryAfterSeconds) headers['retry-after'] = String(apiError.retryAfterSeconds);
      if (apiError.status === 413) headers.connection = 'close';
      const payload = { error: { code: apiError.code, message: apiError.message } };
      if (apiError.retryAfterSeconds) payload.error.retryAfterSeconds = apiError.retryAfterSeconds;
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
