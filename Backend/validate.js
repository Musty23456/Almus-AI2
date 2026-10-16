import { ApiError, bad } from './errors.js';
import { GATEWAY_MODEL_PATTERN, PROVIDER_ID_PATTERN } from './config.js';

const ROLES = new Set(['user', 'assistant']);

/**
 * Validates the JSON body of POST /v1/chat and returns a clean message list.
 * Throws ApiError(400) with a helpful message on any problem.
 */
export function validateChatRequest(body, config) {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) {
    throw bad('Request body must be a JSON object like {"messages":[{"role":"user","content":"Hello"}]}.');
  }
  const { messages } = body;
  if (!Array.isArray(messages) || messages.length === 0) {
    throw bad('"messages" must be a non-empty array.');
  }
  if (messages.length > config.maxMessages) {
    throw bad(`"messages" may contain at most ${config.maxMessages} items.`);
  }

  const clean = [];
  messages.forEach((m, i) => {
    if (m === null || typeof m !== 'object' || Array.isArray(m)) {
      throw bad(`messages[${i}] must be an object.`);
    }
    if (!ROLES.has(m.role)) throw bad(`messages[${i}].role must be "user" or "assistant".`);
    if (typeof m.content !== 'string') throw bad(`messages[${i}].content must be a string.`);
    let content = m.content.trim();
    if (!content) throw bad(`messages[${i}].content must not be empty.`);
    if (content.length > config.maxMessageChars) {
      if (m.role === 'assistant') {
        // Old assistant replies are only context, so shorten instead of failing the whole request.
        content = content.slice(0, config.maxMessageChars);
      } else {
        throw new ApiError(400, 'message_too_long', `messages[${i}].content exceeds ${config.maxMessageChars} characters.`);
      }
    }
    clean.push({ role: m.role, content });
  });

  if (clean[clean.length - 1].role !== 'user') {
    throw bad('The last message must have role "user".');
  }
  return clean;
}

/**
 * Validates the optional "memoryContext" field (Phase 4): a short block of
 * personal memory notes picked on the user's phone. Returns the cleaned text,
 * or null when absent or blank. Throws ApiError(400) when it is not a string
 * or is longer than config.maxMemoryChars.
 */
export function validateMemoryContext(body, config) {
  const value = body?.memoryContext;
  if (value === undefined || value === null) return null;
  if (typeof value !== 'string') throw bad('"memoryContext" must be a string.');
  // Drop control characters except newlines and tabs.
  const cleaned = value.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, '').trim();
  if (!cleaned) return null;
  if (cleaned.length > config.maxMemoryChars) {
    throw new ApiError(400, 'memory_too_long', `"memoryContext" exceeds ${config.maxMemoryChars} characters.`);
  }
  return cleaned;
}

/**
 * Turns validated messages into Gemini "contents", keeping only the newest messages that fit
 * inside the character budget (a rough stand-in for a token limit).
 */
export function buildContents(messages, maxContextChars) {
  const kept = [];
  let total = 0;
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const len = messages[i].content.length;
    if (kept.length > 0 && total + len > maxContextChars) break;
    kept.push(messages[i]);
    total += len;
  }
  kept.reverse();

  // A conversation must start with the user.
  while (kept.length > 1 && kept[0].role !== 'user') kept.shift();

  // Merge consecutive messages from the same role (can happen when error bubbles were skipped).
  const contents = [];
  for (const m of kept) {
    const role = m.role === 'assistant' ? 'model' : 'user';
    const last = contents[contents.length - 1];
    if (last && last.role === role) {
      last.parts[0].text += `\n\n${m.content}`;
    } else {
      contents.push({ role, parts: [{ text: m.content }] });
    }
  }
  return contents;
}

/** Kinds of attachment the backend accepts. Every one arrives as text the app extracted on the phone. */
export const ATTACHMENT_KINDS = new Set(['text', 'markdown', 'csv', 'pdf', 'docx', 'xlsx']);
const ATTACHMENT_FIELDS = new Set(['name', 'kind', 'text', 'truncated']);

/**
 * Validates the optional "attachments" field (Phase 3). The app sends only the text it extracted from
 * a file the user attached, plus a display name. Files, images, device paths and URIs are refused.
 * Returns a clean list ([] when absent). Throws ApiError(400) on any problem.
 */
export function validateAttachments(body, config) {
  const value = body?.attachments;
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) throw bad('"attachments" must be an array.', 'invalid_attachment');
  if (value.length > config.maxAttachments) {
    throw new ApiError(400, 'too_many_attachments', `"attachments" may contain at most ${config.maxAttachments} items.`);
  }
  let total = 0;
  const clean = value.map((a, i) => {
    if (a === null || typeof a !== 'object' || Array.isArray(a)) throw bad(`attachments[${i}] must be an object.`, 'invalid_attachment');
    for (const key of Object.keys(a)) {
      if (!ATTACHMENT_FIELDS.has(key)) {
        throw bad(`attachments[${i}] has an unsupported field "${key.slice(0, 30)}". Only extracted text is accepted, never files or device paths.`, 'invalid_attachment');
      }
    }
    if (!ATTACHMENT_KINDS.has(a.kind)) {
      throw bad(`attachments[${i}].kind is not supported. Images and unknown files cannot be analyzed.`, 'unsupported_attachment');
    }
    if (typeof a.text !== 'string') throw bad(`attachments[${i}].text must be a string.`, 'invalid_attachment');
    const text = a.text.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, '').trim();
    if (!text) throw bad(`attachments[${i}].text must not be empty.`, 'invalid_attachment');
    if (text.length > config.maxAttachmentChars) {
      throw new ApiError(400, 'attachment_too_long', `attachments[${i}].text exceeds ${config.maxAttachmentChars} characters.`);
    }
    total += text.length;
    const rawName = typeof a.name === 'string' ? a.name : '';
    const name = rawName.replace(/[\u0000-\u001F\u007F"\\/]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 100) || `file ${i + 1}`;
    if (a.truncated !== undefined && typeof a.truncated !== 'boolean') throw bad(`attachments[${i}].truncated must be true or false.`, 'invalid_attachment');
    return { name, kind: a.kind, text, truncated: a.truncated === true };
  });
  if (total > config.maxAttachmentTotalChars) {
    throw new ApiError(400, 'attachments_too_long', `The attachments together exceed ${config.maxAttachmentTotalChars} characters.`);
  }
  return clean;
}

/**
 * Adds the attachments to the newest user turn, clearly delimited so the model can tell the user's own
 * words from file content. Marker lines inside the file text are defused.
 */
export function appendAttachments(contents, attachments) {
  if (!attachments.length || contents.length === 0) return contents;
  const last = contents[contents.length - 1];
  const blocks = attachments.map((a, i) => {
    const safe = a.text.replace(/^(\s*)-----(\s*(?:BEGIN|END) ATTACHED FILE)/gim, '$1- ----$2');
    const note = a.truncated ? ' (text was shortened on the phone)' : '';
    return `----- BEGIN ATTACHED FILE ${i + 1}: "${a.name}" (${a.kind})${note} -----\n${safe}\n----- END ATTACHED FILE ${i + 1} -----`;
  });
  last.parts[0].text += `\n\n${blocks.join('\n\n')}`;
  return contents;
}

const ROUTING_KEYS = new Set(['provider', 'models', 'fallback']);
const FALLBACK_KEYS = new Set(['enabled', 'providers', 'shareMemory', 'shareAttachments']);

/** Routing preferences used when the app sends none (older app versions): primary provider only, no fallback. */
export function defaultRouting() {
  return { provider: null, models: {}, fallback: { enabled: false, providers: [], shareMemory: false, shareAttachments: false } };
}

function providerId(value, known, where) {
  if (typeof value !== 'string' || !PROVIDER_ID_PATTERN.test(value)) throw bad(`${where} must be a provider id.`, 'invalid_routing');
  if (!known.includes(value)) throw new ApiError(400, 'unknown_provider', `${where} names a provider this backend does not know.`);
  return value;
}

/**
 * Validates the optional "routing" field (Phase 4): which provider the user prefers, per-provider model choices and
 * the user's fallback consent. Strict on purpose: unknown keys are refused, and fallback is OFF unless the user
 * switched it on and named the providers that may receive their messages.
 *
 *   "routing": { "provider": "groq", "models": { "groq": "<model id>" },
 *                "fallback": { "enabled": true, "providers": ["gemini"], "shareMemory": false, "shareAttachments": false } }
 */
export function validateRouting(body, knownProviderIds) {
  const value = body?.routing;
  if (value === undefined || value === null) return defaultRouting();
  if (typeof value !== 'object' || Array.isArray(value)) throw bad('"routing" must be an object.', 'invalid_routing');
  for (const key of Object.keys(value)) {
    if (!ROUTING_KEYS.has(key)) throw bad(`"routing" has an unsupported field "${key.slice(0, 30)}".`, 'invalid_routing');
  }
  const out = defaultRouting();
  if (value.provider !== undefined && value.provider !== null) out.provider = providerId(value.provider, knownProviderIds, 'routing.provider');
  if (value.models !== undefined && value.models !== null) {
    if (typeof value.models !== 'object' || Array.isArray(value.models)) throw bad('"routing.models" must be an object.', 'invalid_routing');
    const entries = Object.entries(value.models);
    if (entries.length > 8) throw bad('"routing.models" may contain at most 8 entries.', 'invalid_routing');
    for (const [id, model] of entries) {
      providerId(id, knownProviderIds, 'routing.models key');
      if (typeof model !== 'string' || !GATEWAY_MODEL_PATTERN.test(model)) throw bad('A model id in "routing.models" is not valid.', 'invalid_routing');
      out.models[id] = model;
    }
  }
  if (value.fallback !== undefined && value.fallback !== null) {
    const f = value.fallback;
    if (typeof f !== 'object' || Array.isArray(f)) throw bad('"routing.fallback" must be an object.', 'invalid_routing');
    for (const key of Object.keys(f)) {
      if (!FALLBACK_KEYS.has(key)) throw bad(`"routing.fallback" has an unsupported field "${key.slice(0, 30)}".`, 'invalid_routing');
    }
    for (const flag of ['enabled', 'shareMemory', 'shareAttachments']) {
      if (f[flag] !== undefined && typeof f[flag] !== 'boolean') throw bad(`"routing.fallback.${flag}" must be true or false.`, 'invalid_routing');
    }
    if (f.providers !== undefined) {
      if (!Array.isArray(f.providers) || f.providers.length > 8) throw bad('"routing.fallback.providers" must be an array of at most 8 provider ids.', 'invalid_routing');
      out.fallback.providers = [...new Set(f.providers.map((id) => providerId(id, knownProviderIds, 'routing.fallback.providers item')))];
    }
    out.fallback.enabled = f.enabled === true;
    out.fallback.shareMemory = f.shareMemory === true;
    out.fallback.shareAttachments = f.shareAttachments === true;
  }
  return out;
}
