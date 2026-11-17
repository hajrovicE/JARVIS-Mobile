// JARVIS web core: pure, DOM-free logic so it can be unit tested in Node.
// Model output is display data only. Nothing in this file turns model text
// into a command; commands come exclusively from what the owner typed.

export const STATE_KEY = 'jarvis.web.state.v1';
export const SETTINGS_KEY = 'jarvis.web.settings.v1';

export const DEFAULT_SETTINGS = Object.freeze({
  ownerInstructions: '',
  maxTokens: 512,
  contextTokens: 2048,
  temperature: 0.7,
  topP: 0.9,
  thinking: false,
  showReasoning: false,
  useGPU: false,
  speak: false,
});

const lower = (text) => text.trim().toLocaleLowerCase('tr-TR');

export function emptyState() {
  return { version: 1, personal: [], learning: [], history: [] };
}

export function newId() {
  // Short ids are easy to type on a phone ("unut k3x9q2").
  const bytes = new Uint8Array(4);
  globalThis.crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => (b % 36).toString(36)).join('') +
    Date.now().toString(36).slice(-2);
}

export function parseState(raw) {
  if (!raw) return emptyState();
  const value = JSON.parse(raw);
  if (!value || value.version !== 1) throw new Error('unsupported_state');
  const state = emptyState();
  for (const key of ['personal', 'learning', 'history']) {
    if (Array.isArray(value[key])) state[key] = value[key];
  }
  return state;
}

export function parseSettings(raw) {
  const settings = { ...DEFAULT_SETTINGS };
  if (!raw) return settings;
  try {
    const value = JSON.parse(raw);
    for (const key of Object.keys(DEFAULT_SETTINGS)) {
      if (typeof value?.[key] === typeof DEFAULT_SETTINGS[key]) settings[key] = value[key];
    }
  } catch {
    // Corrupt settings fall back to defaults; memory is stored separately.
  }
  return settings;
}

/// Numbers the owner typed are used as given; only values the runtime
/// cannot represent are replaced.
export function normalizeSettings(settings) {
  const s = { ...settings };
  const int = (v, min, fallback) =>
    Number.isFinite(v) ? Math.max(min, Math.round(v)) : fallback;
  s.maxTokens = int(s.maxTokens, 1, DEFAULT_SETTINGS.maxTokens);
  s.contextTokens = int(s.contextTokens, 256, DEFAULT_SETTINGS.contextTokens);
  s.temperature = Number.isFinite(s.temperature) ? Math.max(0, s.temperature) : DEFAULT_SETTINGS.temperature;
  s.topP = Number.isFinite(s.topP) ? Math.min(1, Math.max(0.01, s.topP)) : DEFAULT_SETTINGS.topP;
  return s;
}

const REMEMBER_PREFIXES = ['hatırla ki ', 'bunu hatırla ', 'hatırla: ', 'not al: ', 'kaydet: ', 'aklında tut: '];
const DELETE_ALL = ['tüm hafızayı sil', 'bütün hafızayı sil', 'tüm verilerimi sil', 'bütün verilerimi sil', 'her şeyi unut'];
const EXPORT = ['hafızayı dışa aktar', 'verilerimi dışa aktar', 'verilerimi yedekle', 'hafızamı dışa aktar'];

/// Maps text the owner typed to a local command, or null when it is a
/// question for the model.
export function routeCommand(input) {
  const text = input.trim();
  const n = lower(text);
  if (!n) return null;
  if (DELETE_ALL.includes(n)) return { type: 'deleteAll' };
  if (EXPORT.includes(n)) return { type: 'export' };
  if (n === 'ne hatırlıyorsun') return { type: 'listMemory' };
  if (n === 'öğrendiklerin') return { type: 'listLearning' };
  if (n === 'geçmiş') return { type: 'listHistory' };
  const prefix = REMEMBER_PREFIXES.find((p) => n.startsWith(p));
  if (prefix) return { type: 'remember', text: text.slice(prefix.length).trim() };
  if (n === 'hatırla ki' || n === 'bunu hatırla') return { type: 'remember', text: '' };
  if (n.startsWith('düzenle ') && text.includes('=')) {
    const [left, ...rest] = text.slice('düzenle '.length).split('=');
    return { type: 'edit', id: left.trim(), text: rest.join('=').trim() };
  }
  if (n.startsWith('öğrenmeyi sil ')) return { type: 'deleteLearning', id: text.slice('öğrenmeyi sil '.length).trim() };
  if (n.startsWith('unut ')) return { type: 'forget', id: text.slice('unut '.length).trim() };
  if (n === 'unut') return { type: 'forget', id: '' };
  if (n.startsWith('öğret: ')) {
    const body = text.slice('öğret: '.length);
    const at = body.indexOf('=');
    if (at < 0) return { type: 'teach', topic: '', text: '' };
    return { type: 'teach', topic: lower(body.slice(0, at)), text: body.slice(at + 1).trim() };
  }
  if (n.startsWith('bundan sonra ')) return { type: 'rule', text: text.slice('bundan sonra '.length).trim() };
  return null;
}

/// Executes a command the owner typed. Returns the new state (never mutates
/// the input), the reply to show, and what should be appended to history.
export function executeCommand(state, command, now = Date.now(), makeId = newId) {
  const next = structuredClone(state);
  const done = (reply, historyNote = null, extra = {}) => ({ state: next, reply, historyNote, ...extra });
  switch (command.type) {
    case 'remember': {
      if (!command.text) return done('Neyi hatırlamamı istediğinizi yazın: "hatırla ki …"');
      const item = { id: makeId(), text: command.text, at: now };
      next.personal.push(item);
      return done(`Kişisel hafızaya kaydedildi (${item.id}).`, 'Kişisel hafıza komutu işlendi.');
    }
    case 'listMemory':
      return done(next.personal.length
        ? next.personal.map((m) => `${m.id}: ${m.text}`).join('\n')
        : 'Kişisel hafıza boş.');
    case 'listLearning':
      return done(next.learning.length
        ? next.learning.map((l) => `${l.id} · ${l.topic}: ${l.text}`).join('\n')
        : 'Onaylanmış öğrenme kaydı yok.');
    case 'listHistory':
      return done(next.history.length
        ? next.history.map((h) => `${h.role === 'user' ? 'Siz' : 'JARVIS'}: ${h.text}`).join('\n')
        : 'Konuşma geçmişi boş.');
    case 'forget': {
      const index = next.personal.findIndex((m) => m.id === command.id);
      if (index < 0) return done('Bu kimlikte bir hafıza kaydı yok. "ne hatırlıyorsun" ile kimlikleri görebilirsiniz.', null, { failed: true });
      next.personal.splice(index, 1);
      return done('Hafıza kaydı silindi.', 'Kişisel hafıza komutu işlendi.');
    }
    case 'edit': {
      const item = next.personal.find((m) => m.id === command.id);
      if (!item || !command.text) return done('Kullanım: düzenle <kimlik> = yeni metin', null, { failed: true });
      item.text = command.text;
      return done('Hafıza kaydı güncellendi.', 'Kişisel hafıza komutu işlendi.');
    }
    case 'teach': {
      if (!command.topic || !command.text) return done('Kullanım: öğret: konu = öğrenilecek bilgi');
      const prior = next.learning.find((l) => l.topic === command.topic);
      if (prior) { prior.text = command.text; prior.at = now; }
      else next.learning.push({ id: makeId(), topic: command.topic, text: command.text, at: now });
      return done('Öğrettiğiniz bilgi kaydedildi.', 'Kişisel hafıza komutu işlendi.');
    }
    case 'rule': {
      if (!command.text) return done('Hangi kuralı uygulamamı istediğinizi yazın.');
      next.learning.push({ id: makeId(), topic: 'sahibin talimatı', text: command.text, at: now });
      return done('Talimatınız kaydedildi.', 'Kişisel hafıza komutu işlendi.');
    }
    case 'deleteLearning': {
      const index = next.learning.findIndex((l) => l.id === command.id);
      if (index < 0) return done('Bu kimlikte bir öğrenme kaydı yok.', null, { failed: true });
      next.learning.splice(index, 1);
      return done('Öğrenme kaydı silindi.', 'Kişisel hafıza komutu işlendi.');
    }
    case 'deleteAll':
      // A full erase must stay erased: no history note is written afterwards.
      return { state: emptyState(), reply: 'Tüm kayıtlar silindi.', historyNote: null };
    case 'export':
      return done('Dışa aktarma dosyası hazırlandı.', null, { exportData: exportJSON(next, now) });
    default:
      return done('Bu komut desteklenmiyor.', null, { failed: true });
  }
}

export function exportJSON(state, now = Date.now()) {
  return JSON.stringify({ exportedAt: new Date(now).toISOString(), ...state }, null, 2);
}

/// Hides a <think>…</think> block so only the answer is shown and spoken.
/// If nothing would remain, the original text is returned.
export function stripReasoning(text) {
  let rest = text;
  let stripped = false;
  for (;;) {
    const open = rest.indexOf('<think>');
    if (open < 0) break;
    const close = rest.indexOf('</think>', open);
    rest = close < 0 ? rest.slice(0, open) : rest.slice(0, open) + rest.slice(close + '</think>'.length);
    stripped = true;
  }
  if (!stripped) return text;
  const visible = rest.trim();
  return visible || text;
}

/// Rough size estimate used only to keep the prompt inside the context window.
export const estimateTokens = (text) => Math.ceil(text.length / 3);

/// Builds chat messages for the local model. Saved memory is passed as data
/// inside the user turn; the only system text is what the owner wrote.
/// When history does not fit, the oldest turns are left out (not deleted).
export function buildMessages({ state, prompt, ownerInstructions, contextTokens, maxTokens }) {
  const messages = [];
  if (ownerInstructions.trim()) messages.push({ role: 'system', content: ownerInstructions });
  const facts = [
    ...state.learning.map((l) => `${l.topic}: ${l.text}`),
    ...state.personal.map((m) => m.text),
  ];
  const user = facts.length
    ? 'Hafıza bağlamı (kaydedilmiş veri):\n' + facts.map((f, i) => `Bilgi ${i + 1}: ${f}`).join('\n') +
      '\n\nKullanıcının doğrudan isteği:\n' + prompt
    : prompt;
  const reserve = Math.min(maxTokens, Math.floor(contextTokens / 2));
  let budget = contextTokens - reserve - estimateTokens(user) -
    estimateTokens(ownerInstructions) - 16;
  const turns = [];
  for (let i = state.history.length - 1; i >= 0 && budget > 0; i--) {
    const h = state.history[i];
    if (h.role !== 'user' && h.role !== 'assistant') continue;
    const cost = estimateTokens(h.text) + 8;
    if (cost > budget) break;
    budget -= cost;
    turns.unshift({ role: h.role, content: h.text });
  }
  // A chat template expects turns to start with the user.
  while (turns.length && turns[0].role !== 'user') turns.shift();
  return [...messages, ...turns, { role: 'user', content: user }];
}

export const MODEL_CHOICES = Object.freeze([
  {
    id: 'qwen3-0.6b',
    label: 'Hızlı · Qwen3 0.6B (~400 MB)',
    urls: [
      'https://huggingface.co/ggml-org/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf',
      'https://huggingface.co/ggml-org/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q8_0.gguf',
    ],
  },
  {
    id: 'qwen3-1.7b',
    label: 'Daha akıllı · Qwen3 1.7B (~1,3 GB, yeni iPhone gerekir)',
    urls: [
      'https://huggingface.co/ggml-org/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf',
      'https://huggingface.co/ggml-org/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q8_0.gguf',
    ],
  },
]);

/// GGUF is identified by its content, not by the file name.
export function isGGUF(firstBytes) {
  return firstBytes.length >= 4 && firstBytes[0] === 0x47 && firstBytes[1] === 0x47 &&
    firstBytes[2] === 0x55 && firstBytes[3] === 0x46;
}
