import test from 'node:test';
import assert from 'node:assert/strict';
import { loadConfig } from './config.js';
import { validateChatRequest, validateMemoryContext, buildContents } from './validate.js';

const config = loadConfig({});
const user = (content) => ({ role: 'user', content });
const bot = (content) => ({ role: 'assistant', content });

test('accepts a valid conversation and trims whitespace', () => {
  const out = validateChatRequest({ messages: [user(' hi '), bot('hello'), user('how are you?')] }, config);
  assert.equal(out.length, 3);
  assert.equal(out[0].content, 'hi');
});

test('rejects non-object bodies', () => {
  for (const body of [null, 'x', 5, [], undefined]) {
    assert.throws(() => validateChatRequest(body, config), (e) => e.status === 400 && e.code === 'invalid_request');
  }
});

test('rejects missing or empty messages', () => {
  assert.throws(() => validateChatRequest({}, config), /non-empty array/);
  assert.throws(() => validateChatRequest({ messages: [] }, config), /non-empty array/);
});

test('rejects too many messages', () => {
  const messages = Array.from({ length: config.maxMessages + 1 }, () => user('x'));
  assert.throws(() => validateChatRequest({ messages }, config), /at most/);
});

test('rejects bad roles, non-string and empty content', () => {
  assert.throws(() => validateChatRequest({ messages: [{ role: 'system', content: 'x' }] }, config), /role/);
  assert.throws(() => validateChatRequest({ messages: [{ role: 'user', content: 5 }] }, config), /string/);
  assert.throws(() => validateChatRequest({ messages: [user('   ')] }, config), /empty/);
  assert.throws(() => validateChatRequest({ messages: ['text'] }, config), /object/);
});

test('last message must come from the user', () => {
  assert.throws(() => validateChatRequest({ messages: [user('a'), bot('b')] }, config), /last message/);
});

test('long user messages are rejected, long assistant messages are shortened', () => {
  const long = 'a'.repeat(config.maxMessageChars + 1);
  assert.throws(() => validateChatRequest({ messages: [user(long)] }, config), (e) => e.code === 'message_too_long');
  const out = validateChatRequest({ messages: [bot(long), user('ok')] }, config);
  assert.equal(out[0].content.length, config.maxMessageChars);
});

test('buildContents keeps the newest messages within the character budget', () => {
  const msgs = [user('a'.repeat(50)), bot('b'.repeat(50)), user('c'.repeat(50)), bot('d'.repeat(50)), user('e'.repeat(10))];
  const contents = buildContents(msgs, 80);
  const text = contents.map((c) => c.parts[0].text).join('|');
  assert.ok(text.endsWith('e'.repeat(10)));
  assert.ok(!text.includes('a'));
  assert.equal(contents[0].role, 'user');
});

test('buildContents always keeps the last message even if it is over budget', () => {
  const contents = buildContents([user('z'.repeat(500))], 10);
  assert.equal(contents.length, 1);
});

test('buildContents merges consecutive same-role messages and maps assistant to model', () => {
  const contents = buildContents([user('one'), user('two'), bot('three'), user('four')], 1000);
  assert.deepEqual(contents.map((c) => c.role), ['user', 'model', 'user']);
  assert.equal(contents[0].parts[0].text, 'one\n\ntwo');
});

test('memoryContext is optional, trimmed and cleaned', () => {
  assert.equal(validateMemoryContext({}, config), null);
  assert.equal(validateMemoryContext({ memoryContext: null }, config), null);
  assert.equal(validateMemoryContext({ memoryContext: '   ' }, config), null);
  assert.equal(validateMemoryContext({ memoryContext: '  - [fact] likes tea\u0000\n' }, config), '- [fact] likes tea');
});

test('memoryContext must be a string within the size limit', () => {
  assert.throws(() => validateMemoryContext({ memoryContext: 5 }, config), (e) => e.status === 400);
  assert.throws(
    () => validateMemoryContext({ memoryContext: 'a'.repeat(config.maxMemoryChars + 1) }, config),
    (e) => e.status === 400 && e.code === 'memory_too_long',
  );
});
