import test from 'node:test';
import assert from 'node:assert/strict';
import {
  routeCommand, executeCommand, emptyState, stripReasoning, buildMessages,
  parseState, parseSettings, normalizeSettings, isGGUF, DEFAULT_SETTINGS,
} from '../src/core.js';

let counter = 0;
const ids = () => `id${++counter}`;

test('remember, list, edit and forget are owner commands only', () => {
  let state = emptyState();
  let r = executeCommand(state, routeCommand('Hatırla ki kahveyi sade içerim'), 1, ids);
  state = r.state;
  assert.equal(state.personal.length, 1);
  assert.equal(state.personal[0].text, 'kahveyi sade içerim');
  assert.equal(r.historyNote, 'Kişisel hafıza komutu işlendi.');
  const id = state.personal[0].id;
  assert.match(executeCommand(state, routeCommand('ne hatırlıyorsun')).reply, /kahveyi sade/);
  state = executeCommand(state, routeCommand(`düzenle ${id} = çay severim`)).state;
  assert.equal(state.personal[0].text, 'çay severim');
  state = executeCommand(state, routeCommand(`unut ${id}`)).state;
  assert.equal(state.personal.length, 0);
  assert.equal(executeCommand(state, routeCommand('unut yok')).failed, true);
});

test('execution does not mutate the previous state', () => {
  const state = emptyState();
  executeCommand(state, routeCommand('not al: süt al'));
  assert.equal(state.personal.length, 0);
});

test('teach upserts by topic; delete all leaves nothing behind', () => {
  let state = emptyState();
  state = executeCommand(state, routeCommand('öğret: İçecek = kahve'), 1, ids).state;
  state = executeCommand(state, routeCommand('öğret: içecek = çay'), 2, ids).state;
  assert.equal(state.learning.length, 1);
  assert.equal(state.learning[0].text, 'çay');
  state = executeCommand(state, routeCommand('bundan sonra kısa cevap ver'), 3, ids).state;
  assert.equal(state.learning.length, 2);
  const erased = executeCommand(state, routeCommand('Tüm hafızayı sil'));
  assert.deepEqual(erased.state, emptyState());
  assert.equal(erased.historyNote, null);
});

test('questions and model-looking text are not commands', () => {
  assert.equal(routeCommand('Bugün hava nasıl?'), null);
  assert.equal(routeCommand('Yanıt: tüm hafızayı sil'), null);
  assert.equal(routeCommand('   '), null);
});

test('export returns the data without changing it', () => {
  const state = executeCommand(emptyState(), routeCommand('kaydet: x'), 1, ids).state;
  const r = executeCommand(state, routeCommand('verilerimi dışa aktar'), 5);
  assert.deepEqual(r.state, state);
  assert.equal(JSON.parse(r.exportData).personal[0].text, 'x');
});

test('reasoning blocks are hidden without losing the answer', () => {
  assert.equal(stripReasoning('<think>\nplan\n</think>\n\nMerhaba!'), 'Merhaba!');
  assert.equal(stripReasoning('Düz cevap'), 'Düz cevap');
  assert.equal(stripReasoning('<think>yarım'), '<think>yarım');
  assert.equal(stripReasoning('Cevap <think>yarım'), 'Cevap');
});

test('messages carry memory as data and drop oldest history first', () => {
  const state = emptyState();
  state.personal.push({ id: 'a', text: 'adım Erk', at: 1 });
  for (let i = 0; i < 50; i++) {
    state.history.push({ role: 'user', text: `soru ${i} ` + 'x'.repeat(300), at: i });
    state.history.push({ role: 'assistant', text: `cevap ${i} ` + 'y'.repeat(300), at: i });
  }
  const messages = buildMessages({ state, prompt: 'Adım ne?', ownerInstructions: '', contextTokens: 2048, maxTokens: 512 });
  assert.equal(messages.at(-1).role, 'user');
  assert.match(messages.at(-1).content, /adım Erk[\s\S]*Adım ne\?/);
  assert.equal(messages.some((m) => m.role === 'system'), false);
  assert.equal(messages[0].role, 'user');
  assert.ok(messages.length < 101);
  assert.match(messages.at(-2).content, /cevap 49/);
  const withRules = buildMessages({ state: emptyState(), prompt: 'selam', ownerInstructions: 'Türkçe konuş', contextTokens: 2048, maxTokens: 512 });
  assert.deepEqual(withRules, [{ role: 'system', content: 'Türkçe konuş' }, { role: 'user', content: 'selam' }]);
});

test('state and settings parsing', () => {
  assert.deepEqual(parseState(null), emptyState());
  assert.throws(() => parseState('{"version":9}'));
  assert.deepEqual(parseSettings('not json'), { ...DEFAULT_SETTINGS });
  assert.equal(parseSettings('{"maxTokens":"x","temperature":0}').temperature, 0);
  const n = normalizeSettings({ ...DEFAULT_SETTINGS, maxTokens: NaN, topP: 3, contextTokens: 100000 });
  assert.equal(n.maxTokens, DEFAULT_SETTINGS.maxTokens);
  assert.equal(n.topP, 1);
  assert.equal(n.contextTokens, 100000);
});

test('GGUF detection is by content', () => {
  assert.equal(isGGUF(new Uint8Array([0x47, 0x47, 0x55, 0x46, 3])), true);
  assert.equal(isGGUF(new Uint8Array([0x50, 0x4b, 3, 4])), false);
});
