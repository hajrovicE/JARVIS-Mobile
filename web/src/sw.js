// Offline support: the app shell and the inference engine are cached on first
// visit, so JARVIS opens without internet. The model itself lives in IndexedDB.
const CACHE = 'jarvis-__BUILD_ID__';
const SHELL = __SHELL_FILES__;

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k.startsWith('jarvis-') && k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()));
});
self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== 'GET' || url.origin !== self.location.origin) return;
  event.respondWith(
    caches.match(event.request, { ignoreSearch: true }).then((hit) => hit || fetch(event.request)));
});
