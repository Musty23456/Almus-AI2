import crypto from 'node:crypto';
import { ApiError, bad } from './errors.js';
import { isLocalHttpUrl } from './config.js';

/**
 * Luxand.cloud 1:1 face verification (Phase 6b).
 *
 * The Luxand API token lives ONLY in this server's environment (LUXAND_API_TOKEN). The app never sees it.
 * The app talks to our own /v1/face/* routes with the usual APP_ACCESS_TOKEN.
 *
 * Fail-closed rules: no token, no calibrated threshold, or an unexpected Luxand answer => never "verified".
 * Nothing here logs photos, uuids, scores or Luxand response bodies.
 */

const UUID_PATTERN = /^[0-9a-fA-F-]{36}$/;

export function isValidFaceUuid(value) {
  return typeof value === 'string' && UUID_PATTERN.test(value);
}

/** Decodes a base64 JPEG sent by the app. Throws a safe 400 for anything else. */
export function decodePhoto(value, maxBytes) {
  if (typeof value !== 'string' || value.length === 0) throw bad('"photo" must be a base64 JPEG string.', 'invalid_photo');
  if (value.length > Math.ceil((maxBytes * 4) / 3) + 8) throw bad('The photo is too large.', 'invalid_photo');
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(value)) throw bad('"photo" is not valid base64.', 'invalid_photo');
  const bytes = Buffer.from(value, 'base64');
  if (bytes.length === 0 || bytes.length > maxBytes) throw bad('The photo is empty or too large.', 'invalid_photo');
  if (!(bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff)) throw bad('The photo must be a JPEG.', 'invalid_photo');
  return bytes;
}

export function createLuxandClient({ config, fetchImpl = globalThis.fetch }) {
  const cfg = config.face;

  function baseUrlProblem() {
    try {
      const u = new URL(cfg.baseUrl);
      if (u.username || u.password || u.search || u.hash) return 'LUXAND_BASE_URL must be a plain address.';
      if (u.protocol !== 'https:' && !isLocalHttpUrl(cfg.baseUrl)) return 'LUXAND_BASE_URL must use https://.';
      return null;
    } catch {
      return 'LUXAND_BASE_URL is not a valid URL.';
    }
  }

  const status = () => ({
    available: Boolean(cfg.token) && baseUrlProblem() === null,
    // Matching is disabled until the operator has measured and set a threshold.
    calibrated: cfg.minSimilarity !== null,
  });

  function requireAvailable() {
    if (!cfg.token) throw new ApiError(503, 'face_not_configured', 'Cloud face verification is not configured on this backend.');
    if (baseUrlProblem()) throw new ApiError(503, 'face_not_configured', 'Cloud face verification is misconfigured on this backend.');
  }

  async function call(method, path, form, signal) {
    requireAvailable();
    const timeout = AbortSignal.timeout(cfg.timeoutMs);
    const combined = signal && typeof AbortSignal.any === 'function' ? AbortSignal.any([signal, timeout]) : timeout;
    let res;
    try {
      res = await fetchImpl(`${cfg.baseUrl}${path}`, { method, headers: { token: cfg.token }, body: form, signal: combined });
    } catch {
      throw new ApiError(502, 'face_upstream_error', 'The face service could not be reached.');
    }
    let json = null;
    try {
      json = await res.json();
    } catch {
      json = null;
    }
    return { status: res.status, json };
  }

  function failFor(statusCode) {
    if (statusCode === 400 || statusCode === 422) {
      return new ApiError(422, 'face_not_usable', 'The face service could not use that photo (for example no single clear face was found).');
    }
    if (statusCode === 429) return new ApiError(503, 'face_upstream_busy', 'The face service is busy or its quota is used up.', { retryAfterSeconds: 30 });
    // 401/403 here means OUR Luxand token is wrong. The app must not think its own token is wrong.
    return new ApiError(502, 'face_upstream_error', 'The face service returned an error.');
  }

  function photoForm(bytes, field, extra = {}) {
    const form = new FormData();
    for (const [k, v] of Object.entries(extra)) form.append(k, v);
    form.append(field, new Blob([bytes], { type: 'image/jpeg' }), 'face.jpg');
    return form;
  }

  return {
    status,

    /** Creates a person. The label sent to Luxand is random: no real name leaves the phone. */
    async enroll(photoBytes, signal) {
      const label = `almus-${crypto.randomBytes(6).toString('hex')}`;
      const { status: code, json } = await call('POST', '/v2/person', photoForm(photoBytes, 'photos', { name: label, store: '1' }), signal);
      if (code < 200 || code >= 300) throw failFor(code);
      if (!json || !isValidFaceUuid(json.uuid)) throw new ApiError(502, 'face_unexpected_response', 'The face service answered in an unexpected way.');
      return { uuid: json.uuid };
    },

    async addPhoto(uuid, photoBytes, signal) {
      const { status: code } = await call('POST', `/v2/person/${uuid}`, photoForm(photoBytes, 'photo', { store: '1' }), signal);
      if (code < 200 || code >= 300) throw failFor(code);
      return { added: true };
    },

    /** 1:1 check of a photo against ONE enrolled person. Returns verified=false on anything unclear. */
    async verify(uuid, photoBytes, signal) {
      if (cfg.minSimilarity === null) {
        throw new ApiError(503, 'face_not_calibrated', 'No similarity threshold is set (LUXAND_MIN_SIMILARITY), so matching is disabled.');
      }
      const { status: code, json } = await call('POST', `/photo/verify/${uuid}`, photoForm(photoBytes, 'photo'), signal);
      if (code < 200 || code >= 300) throw failFor(code);
      const score = json && typeof json === 'object' ? json.similarity : undefined;
      if (typeof score !== 'number' || !Number.isFinite(score) || score < 0 || score > 1) {
        // Fail closed: an answer we do not understand is never a match.
        throw new ApiError(502, 'face_unexpected_response', 'The face service answered in an unexpected way.');
      }
      const result = { verified: score >= cfg.minSimilarity };
      if (cfg.returnScore) result.similarity = Math.round(score * 1000) / 1000;
      return result;
    },

    /** Deletes the person at Luxand. A person that is already gone counts as deleted; any other failure is reported. */
    async remove(uuid, signal) {
      const { status: code } = await call('DELETE', `/person/${uuid}`, undefined, signal);
      if ((code >= 200 && code < 300) || code === 404) return { deleted: true };
      throw failFor(code);
    },
  };
}
