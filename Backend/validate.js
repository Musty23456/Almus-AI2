import { ApiError, bad } from './errors.js';

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
