import { Wllama } from './vendor/wllama/index.js';
import {
  STATE_KEY, SETTINGS_KEY, MODEL_CHOICES, routeCommand, executeCommand, parseState,
  parseSettings, normalizeSettings, buildMessages, stripReasoning, isGGUF, newId,
} from './core.js';

const WASM = { default: new URL('./vendor/wllama/wllama.wasm', import.meta.url).href };
// Safari has no JSPI / Memory64, so it needs the compatibility build (served locally).
const COMPAT = {
  wasm: new URL('./vendor/wllama-compat/wllama.wasm', import.meta.url).href,
  worker: new URL('./vendor/wllama-compat/wllama.js', import.meta.url).href,
};

const $ = (id) => document.getElementById(id);

// ---------- persistence (owner data stays until the owner deletes it) ----------
const safeGet = (key) => { try { return localStorage.getItem(key); } catch { return null; } };
const safeSet = (key, value) => {
  try { localStorage.setItem(key, value); return true; } catch { return false; }
};

let state;
try { state = parseState(safeGet(STATE_KEY)); }
catch {
  state = parseState(null);
  queueMicrotask(() => showError('Kayıtlı veriler okunamadı; boş hafızayla başlandı. Eski kayıt silinmedi.'));
}
let settings = normalizeSettings(parseSettings(safeGet(SETTINGS_KEY)));

function commitState(next) {
  const serialized = JSON.stringify(next);
  if (!safeSet(STATE_KEY, serialized)) {
    throw new Error('Veriler kaydedilemedi (depolama dolu veya kapalı). İşlem uygulanmadı.');
  }
  state = next;
}
const saveSettings = () => safeSet(SETTINGS_KEY, JSON.stringify(settings));

// ---------- model file storage (IndexedDB holds the GGUF blob) ----------
function openDB() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open('jarvis-models', 1);
    request.onupgradeneeded = () => request.result.createObjectStore('files');
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}
async function dbOp(mode, fn) {
  const db = await openDB();
  try {
    return await new Promise((resolve, reject) => {
      const tx = db.transaction('files', mode);
      const result = fn(tx.objectStore('files'));
      tx.oncomplete = () => resolve(result?.result);
      tx.onerror = () => reject(tx.error);
      tx.onabort = () => reject(tx.error || new Error('aborted'));
    });
  } finally { db.close(); }
}
const getStoredModel = () => dbOp('readonly', (s) => s.get('active'));
const putStoredModel = (record) => dbOp('readwrite', (s) => s.put(record, 'active'));
const deleteStoredModel = () => dbOp('readwrite', (s) => s.delete('active'));

// ---------- engine ----------
let wllama = null;
let loadedSignature = '';
let busy = false;
let abort = null;

const gb = (bytes) => (bytes / 1e9).toLocaleString('tr-TR', { maximumFractionDigits: 2 }) + ' GB';
const mb = (bytes) => Math.round(bytes / 1e6).toLocaleString('tr-TR') + ' MB';

async function unloadModel() {
  const current = wllama;
  wllama = null;
  loadedSignature = '';
  if (current) { try { await current.exit(); } catch { /* already gone */ } }
  $('engine-badge').textContent = 'Model yüklü değil';
}

// Load-time diagnostics only: engine messages while the model loads, before any
// prompt exists, so the log never contains the owner's questions or memory.
const loadLog = [];
let capturingLoadLog = false;
const pushLog = (level, args) => {
  if (!capturingLoadLog) return;
  const line = args.map((a) => (a instanceof Error ? a.message : String(a))).join(' ').trim();
  if (!line) return;
  loadLog.push(`${new Date().toLocaleTimeString('tr-TR')} ${level}: ${line}`.slice(0, 300));
  if (loadLog.length > 80) loadLog.shift();
  renderLoadLog();
};
const engineLogger = {
  debug: () => {},
  log: (...a) => pushLog('bilgi', a),
  warn: (...a) => pushLog('uyarı', a),
  error: (...a) => { pushLog('hata', a); console.error('[wllama]', ...a); },
};
function renderLoadLog() {
  const box = $('load-log');
  if (box) box.textContent = loadLog.length ? loadLog.join('\n') : 'Henüz kayıt yok.';
}

let loadingInstance = null;
let loadCancelled = false;

async function ensureModel() {
  const record = await getStoredModel();
  if (!record?.blob) throw new UserError('Henüz model yok. AI sekmesinden bir model indirin veya dosya seçin.');
  const signature = [record.savedAt, settings.contextTokens, settings.useGPU].join('|');
  if (wllama && loadedSignature === signature) return wllama;
  await unloadModel();
  loadLog.length = 0;
  capturingLoadLog = true;
  loadCancelled = false;
  const started = Date.now();
  const sizeText = record.blob.size >= 1e9 ? gb(record.blob.size) : mb(record.blob.size);
  const tick = () => {
    const seconds = Math.round((Date.now() - started) / 1000);
    let text = `Model belleğe yükleniyor (${sizeText})… ${seconds} sn`;
    if (seconds >= 180) {
      text += ' — Uzun sürüyor. İptal edip AI sekmesinden bağlam penceresini küçültün veya daha küçük modeli deneyin; ayrıntı için AI → Tanılama kaydı.';
    }
    setProgress(text);
  };
  tick();
  const timer = setInterval(tick, 1000);
  pushLog('bilgi', [`Yükleme başladı: ${record.name}, ${sizeText}, bağlam ${settings.contextTokens}, ` +
    `GPU ${settings.useGPU ? 'açık' : 'kapalı'}, WebGPU ${'gpu' in navigator ? 'var' : 'yok'}, ` +
    `iş parçacığı ${globalThis.crossOriginIsolated ? 'çoklu' : 'tek'}`]);
  const attempt = async (gpu) => {
    const instance = new Wllama(WASM, { suppressNativeLog: false, logger: engineLogger });
    instance.setCompat(COMPAT);
    loadingInstance = instance;
    try {
      await instance.loadModel([record.blob], {
        n_ctx: settings.contextTokens,
        n_threads: globalThis.crossOriginIsolated ? Math.min(4, navigator.hardwareConcurrency || 2) : 1,
        n_gpu_layers: gpu ? 999 : 0,
        jinja: true,
      });
      if (loadCancelled) throw new DOMException('cancelled', 'AbortError');
      return instance;
    } catch (error) {
      try { await instance.exit(); } catch { /* ignore */ }
      if (loadCancelled) throw new DOMException('cancelled', 'AbortError');
      throw error;
    } finally {
      loadingInstance = null;
    }
  };
  let instance;
  let usedGPU = settings.useGPU;
  try {
    try { instance = await attempt(settings.useGPU); }
    catch (error) {
      if (!settings.useGPU || loadCancelled) throw error;
      pushLog('uyarı', ['GPU ile yüklenemedi, CPU ile yeniden deneniyor: ' + (error?.message || error)]);
      usedGPU = false;
      instance = await attempt(false);
    }
  } catch (error) {
    pushLog('hata', ['Yükleme başarısız: ' + (error?.message || error)]);
    throw error;
  } finally {
    clearInterval(timer);
    capturingLoadLog = false;
  }
  const seconds = Math.round((Date.now() - started) / 1000);
  loadLog.push(`Model ${seconds} sn içinde yüklendi.`);
  renderLoadLog();
  wllama = instance;
  loadedSignature = signature;
  $('engine-badge').textContent = 'Model hazır';
  $('runtime-info').textContent = 'Çalışma modu: ' + (usedGPU ? 'GPU (WebGPU)' : 'CPU') +
    ', ' + (instance.isMultithread?.() ? 'çok iş parçacıklı' : 'tek iş parçacıklı') +
    ', bağlam ' + settings.contextTokens + ` token, yükleme ${seconds} sn.`;
  return instance;
}

/// Stops an in-progress model load by shutting down its worker.
function cancelLoading() {
  if (!loadingInstance) return;
  loadCancelled = true;
  const instance = loadingInstance;
  instance.exit().catch(() => {});
}

class UserError extends Error {}

// ---------- chat ----------
function addMessage(kind, text) {
  const div = document.createElement('div');
  div.className = 'msg ' + kind;
  div.textContent = text;
  $('messages').append(div);
  div.scrollIntoView({ block: 'end' });
  return div;
}
function showError(text) { addMessage('error', text); }
function setProgress(text) {
  $('progress').hidden = !text;
  if (text) $('progress-text').textContent = text;
}
function setBusy(value) {
  busy = value;
  $('send').disabled = value;
  $('cancel').hidden = !value;
  if (!value) setProgress('');
}

function renderAnswer(div, content, reasoning) {
  div.textContent = '';
  if (settings.showReasoning && reasoning.trim()) {
    const r = document.createElement('span');
    r.className = 'reasoning';
    r.textContent = reasoning.trim();
    div.append(r);
  }
  div.append(document.createTextNode(
    settings.showReasoning ? content : stripReasoning(content)));
}

async function ask(prompt) {
  addMessage('user', prompt);
  const bubble = addMessage('bot', '…');
  setBusy(true);
  abort = new AbortController();
  let content = '';
  let reasoning = '';
  try {
    const engine = await ensureModel();
    const answerStarted = Date.now();
    let firstToken = 0;
    setProgress('JARVIS yanıtlıyor… (ilk kelime gelene kadar istem işleniyor)');
    const messages = buildMessages({
      state, prompt, ownerInstructions: settings.ownerInstructions,
      contextTokens: settings.contextTokens, maxTokens: settings.maxTokens,
    });
    const stream = await engine.createChatCompletion({
      messages,
      stream: true,
      max_tokens: settings.maxTokens,
      temperature: settings.temperature,
      top_p: settings.topP,
      chat_template_kwargs: { enable_thinking: settings.thinking },
      abortSignal: abort.signal,
    });
    for await (const chunk of stream) {
      const delta = chunk?.choices?.[0]?.delta ?? {};
      if ((delta.content || delta.reasoning_content) && !firstToken) {
        firstToken = Date.now();
        setProgress('JARVIS yazıyor…');
      }
      if (delta.content) content += delta.content;
      if (delta.reasoning_content) reasoning += delta.reasoning_content;
      renderAnswer(bubble, content, reasoning);
      bubble.scrollIntoView({ block: 'end' });
    }
    const answer = stripReasoning(content).trim();
    if (firstToken) {
      $('runtime-info').dataset.last = `Son yanıt: ilk kelime ${((firstToken - answerStarted) / 1000).toFixed(1)} sn, toplam ${((Date.now() - answerStarted) / 1000).toFixed(1)} sn.`;
      setProgress('');
      $('last-answer-timing').textContent = $('runtime-info').dataset.last;
    }
    if (!answer) throw new UserError('Model boş yanıt üretti. Yeniden deneyin.');
    const next = structuredClone(state);
    const now = Date.now();
    next.history.push({ id: newId(), role: 'user', text: prompt, at: now });
    next.history.push({ id: newId(), role: 'assistant', text: answer, at: now });
    try { commitState(next); }
    catch (e) { showError('Yanıt üretildi ancak geçmişe kaydedilemedi: ' + e.message); }
    renderHistory();
    if (settings.speak) speak(answer);
  } catch (error) {
    if (abort?.signal.aborted || error?.name === 'AbortError' || error?.name === 'WllamaAbortError') {
      if (content.trim()) renderAnswer(bubble, content + '\n[iptal edildi]', reasoning);
      else bubble.remove();
      addMessage('system', 'İstek iptal edildi; bu yanıt geçmişe kaydedilmedi.');
    } else {
      bubble.remove();
      showError(describeError(error));
    }
  } finally {
    abort = null;
    setBusy(false);
  }
}

function describeError(error) {
  if (error instanceof UserError) return error.message;
  const text = String(error?.message || error);
  if (/kv_cache_full|context/i.test(text) || error?.type === 'kv_cache_full') {
    return 'Bağlam penceresi doldu. AI sekmesinden bağlam penceresini büyütün veya yanıt bütçesini küçültün.';
  }
  if (/memory|alloc|OOM|RangeError/i.test(text)) {
    return 'Telefonun belleği bu model/bağlam için yetmedi. Bağlam penceresini küçültün veya daha küçük modeli seçin.';
  }
  if (/load_error|failed to load|gguf/i.test(text)) {
    return 'Model dosyası açılamadı. Geçerli bir GGUF dosyası seçin. (' + text + ')';
  }
  return 'Model çalıştırılamadı: ' + text;
}

function runCommand(command, typed) {
  const result = executeCommand(state, command);
  if (typed) addMessage('user', typed);
  if (result.failed) { addMessage('bot', result.reply); return; }
  let next = result.state;
  if (result.historyNote) {
    next = structuredClone(next);
    next.history.push({ id: newId(), role: 'note', text: result.historyNote, at: Date.now() });
  }
  try { commitState(next); }
  catch (e) { showError(e.message); return; }
  if (result.exportData) downloadExport(result.exportData);
  addMessage('bot', result.reply);
  renderAll();
}

function downloadExport(json) {
  const blob = new Blob([json], { type: 'application/json' });
  const file = new File([blob], 'jarvis-verilerim.json', { type: 'application/json' });
  if (navigator.canShare?.({ files: [file] })) {
    navigator.share({ files: [file], title: 'JARVIS verilerim' }).catch(() => {});
    return;
  }
  const url = URL.createObjectURL(blob);
  const a = Object.assign(document.createElement('a'), { href: url, download: file.name });
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
}

function speak(text) {
  if (!('speechSynthesis' in window)) return;
  speechSynthesis.cancel();
  const utterance = new SpeechSynthesisUtterance(text);
  utterance.lang = 'tr-TR';
  const voice = speechSynthesis.getVoices().find((v) => v.lang?.toLowerCase().startsWith('tr'));
  if (voice) utterance.voice = voice;
  speechSynthesis.speak(utterance);
}

// ---------- rendering ----------
function emptyItem(text) {
  const li = document.createElement('li');
  li.className = 'empty';
  li.textContent = text;
  return li;
}
function button(label, onClick, cls = '') {
  const b = document.createElement('button');
  b.type = 'button';
  b.textContent = label;
  if (cls) b.className = cls;
  b.addEventListener('click', onClick);
  return b;
}
const dateText = (at) => new Date(at).toLocaleString('tr-TR', { dateStyle: 'short', timeStyle: 'short' });

function renderMemory() {
  const list = $('memory-list');
  list.replaceChildren();
  if (!state.personal.length) list.append(emptyItem('Kişisel hafıza boş.'));
  for (const item of state.personal) {
    const li = document.createElement('li');
    const editor = document.createElement('textarea');
    editor.rows = 2;
    editor.value = item.text;
    const meta = document.createElement('div');
    meta.className = 'meta';
    meta.textContent = `${item.id} · ${dateText(item.at)}`;
    const actions = document.createElement('div');
    actions.className = 'actions';
    actions.append(
      button('Kaydet', () => {
        const text = editor.value.trim();
        if (text) runCommand({ type: 'edit', id: item.id, text });
      }),
      button('Sil', () => runCommand({ type: 'forget', id: item.id }), 'danger'),
    );
    li.append(editor, meta, actions);
    list.append(li);
  }
  const learning = $('learning-list');
  learning.replaceChildren();
  if (!state.learning.length) learning.append(emptyItem('Henüz öğrettiğiniz bir şey yok. Sohbette "öğret: konu = bilgi" yazın.'));
  for (const item of state.learning) {
    const li = document.createElement('li');
    const text = document.createElement('div');
    text.textContent = `${item.topic}: ${item.text}`;
    const meta = document.createElement('div');
    meta.className = 'meta';
    meta.textContent = `${item.id} · ${dateText(item.at)}`;
    const actions = document.createElement('div');
    actions.className = 'actions';
    actions.append(button('Sil', () => runCommand({ type: 'deleteLearning', id: item.id }), 'danger'));
    li.append(text, meta, actions);
    learning.append(li);
  }
}

function renderHistory() {
  const list = $('history-list');
  list.replaceChildren();
  if (!state.history.length) list.append(emptyItem('Konuşma geçmişi boş.'));
  for (const item of [...state.history].reverse()) {
    const li = document.createElement('li');
    const who = item.role === 'user' ? 'Siz' : item.role === 'assistant' ? 'JARVIS' : 'Not';
    const text = document.createElement('div');
    text.textContent = `${who}: ${item.text}`;
    const meta = document.createElement('div');
    meta.className = 'meta';
    meta.textContent = dateText(item.at);
    li.append(text, meta);
    list.append(li);
  }
}

async function renderModelStatus() {
  let record = null;
  try { record = await getStoredModel(); } catch { /* storage unavailable */ }
  $('model-status').textContent = record?.blob
    ? `Kayıtlı model: ${record.name} (${record.blob.size >= 1e9 ? gb(record.blob.size) : mb(record.blob.size)}). Sohbet sekmesinden soru sorabilirsiniz.`
    : 'Henüz model yok. Aşağıdan birini indirin (Wi‑Fi önerilir) veya telefondaki bir GGUF dosyasını seçin.';
  $('model-delete').disabled = !record?.blob;
  if (!wllama) $('engine-badge').textContent = record?.blob ? 'Model kayıtlı' : 'Model yok';
}

function renderSettings() {
  $('owner-instructions').value = settings.ownerInstructions;
  $('max-tokens').value = settings.maxTokens;
  $('context-tokens').value = settings.contextTokens;
  $('temperature').value = settings.temperature;
  $('top-p').value = settings.topP;
  $('thinking').checked = settings.thinking;
  $('show-reasoning').checked = settings.showReasoning;
  $('use-gpu').checked = settings.useGPU;
  $('use-gpu').disabled = !('gpu' in navigator);
  $('speak').checked = settings.speak;
}

function renderAll() { renderMemory(); renderHistory(); }

// ---------- model acquisition ----------
async function storeModel(name, blob) {
  const head = new Uint8Array(await blob.slice(0, 4).arrayBuffer());
  if (!isGGUF(head)) throw new UserError('Bu dosya bir GGUF modeli değil.');
  await unloadModel();
  try {
    await putStoredModel({ name, blob, savedAt: Date.now() });
  } catch {
    throw new UserError('Model telefona kaydedilemedi; depolama alanı yetmiyor olabilir. Yer açıp yeniden deneyin.');
  }
  await renderModelStatus();
}

async function downloadModel(choice) {
  if (busy) return;
  setBusy(true);
  $('cancel').hidden = true;
  const box = $('download-box');
  box.hidden = false;
  const show = (text, ratio) => {
    $('download-text').textContent = text;
    $('download-fill').style.width = `${Math.round((ratio ?? 0) * 100)}%`;
  };
  try {
    let response = null;
    for (const url of choice.urls) {
      show('Bağlanılıyor…', 0);
      try {
        const r = await fetch(url);
        if (r.ok && r.body) { response = r; break; }
      } catch { /* try the next file */ }
    }
    if (!response) throw new UserError('Model indirilemedi. İnternet bağlantısını kontrol edip yeniden deneyin.');
    const total = Number(response.headers.get('content-length')) || 0;
    const reader = response.body.getReader();
    const chunks = [];
    let loaded = 0;
    let lastPaint = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
      loaded += value.length;
      if (performance.now() - lastPaint > 250) {
        lastPaint = performance.now();
        show(total ? `İndiriliyor: ${mb(loaded)} / ${mb(total)}` : `İndiriliyor: ${mb(loaded)}`, total ? loaded / total : 0);
      }
    }
    if (total && loaded !== total) throw new UserError('İndirme yarım kaldı. Yeniden deneyin.');
    show('Telefona kaydediliyor…', 1);
    const name = decodeURIComponent(response.url.split('/').pop().split('?')[0]) || choice.label;
    await storeModel(name, new Blob(chunks));
    show('Model hazır.', 1);
    addMessage('system', 'Model indirildi ve kaydedildi. Artık soru sorabilirsiniz.');
  } catch (error) {
    show('', 0);
    box.hidden = true;
    showError(error instanceof UserError ? error.message : 'İndirme başarısız: ' + (error?.message || error));
    switchTab('chat');
  } finally {
    setBusy(false);
  }
}

// ---------- wiring ----------
function switchTab(name) {
  document.querySelectorAll('.tab').forEach((t) => t.classList.toggle('active', t.id === 'tab-' + name));
  document.querySelectorAll('.tabs button').forEach((b) => b.classList.toggle('active', b.dataset.tab === name));
}
document.querySelectorAll('.tabs button').forEach((b) => b.addEventListener('click', () => switchTab(b.dataset.tab)));

const input = $('input');
input.addEventListener('input', () => {
  input.style.height = 'auto';
  input.style.height = Math.min(140, input.scrollHeight) + 'px';
});
input.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey && !e.isComposing && window.matchMedia('(pointer: fine)').matches) {
    e.preventDefault();
    $('composer').requestSubmit();
  }
});
$('composer').addEventListener('submit', (e) => {
  e.preventDefault();
  const text = input.value.trim();
  if (!text || busy) return;
  input.value = '';
  input.style.height = 'auto';
  // Only text the owner typed is ever routed to a command.
  const command = routeCommand(text);
  if (command) runCommand(command, text);
  else ask(text);
});
$('cancel').addEventListener('click', () => { cancelLoading(); abort?.abort(); });

$('memory-add').addEventListener('submit', (e) => {
  e.preventDefault();
  const text = $('memory-new').value.trim();
  if (!text) return;
  $('memory-new').value = '';
  runCommand({ type: 'remember', text });
});
$('export').addEventListener('click', () => runCommand({ type: 'export' }));
$('delete-all').addEventListener('click', () => runCommand({ type: 'deleteAll' }));

for (const choice of MODEL_CHOICES) {
  $('model-choices').append(button('İndir: ' + choice.label, () => downloadModel(choice), 'primary'));
}
$('model-file').addEventListener('change', async (e) => {
  const file = e.target.files?.[0];
  e.target.value = '';
  if (!file || busy) return;
  setBusy(true);
  $('cancel').hidden = true;
  $('model-status').textContent = 'Dosya kaydediliyor…';
  try {
    await storeModel(file.name, file);
    addMessage('system', `"${file.name}" modeli kaydedildi.`);
  } catch (error) {
    showError(error instanceof UserError ? error.message : 'Dosya kaydedilemedi: ' + (error?.message || error));
    await renderModelStatus();
  } finally { setBusy(false); }
});
$('model-delete').addEventListener('click', async () => {
  if (busy) return;
  await unloadModel();
  try { await deleteStoredModel(); } catch { /* nothing stored */ }
  await renderModelStatus();
});

const bindNumber = (id, key) => $(id).addEventListener('change', (e) => {
  settings = normalizeSettings({ ...settings, [key]: Number(e.target.value) });
  saveSettings();
  renderSettings();
});
bindNumber('max-tokens', 'maxTokens');
bindNumber('context-tokens', 'contextTokens');
bindNumber('temperature', 'temperature');
bindNumber('top-p', 'topP');
const bindCheck = (id, key) => $(id).addEventListener('change', (e) => {
  settings = { ...settings, [key]: e.target.checked };
  saveSettings();
});
bindCheck('thinking', 'thinking');
bindCheck('show-reasoning', 'showReasoning');
bindCheck('use-gpu', 'useGPU');
bindCheck('speak', 'speak');
$('owner-instructions').addEventListener('input', (e) => {
  settings = { ...settings, ownerInstructions: e.target.value };
  saveSettings();
});

renderSettings();
renderAll();
renderModelStatus();
// Ask the browser not to evict saved memory and the model under storage pressure.
navigator.storage?.persist?.().catch(() => {});
if ('serviceWorker' in navigator && location.protocol === 'https:') {
  navigator.serviceWorker.register('sw.js').catch(() => {});
}
window.jarvisReady = true;
