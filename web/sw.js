// Service Worker for Recite Quran (اتلو القران)
// Provides complete offline caching, dynamic caching, and Cross-Origin Isolation (COOP/COEP) for WebAssembly.

const CACHE_NAME = 'recite-quran-pwa-v21-1793465954';

const STATIC_PRECACHE = [
  './',
  'index.html',
  'manifest.json',
  'favicon.png',
  'ReciteQuran.png',
  'icons/apple-touch-icon.png',
  'icons/Icon-192.png',
  'icons/Icon-512.png',
  'icons/Icon-maskable-192.png',
  'icons/Icon-maskable-512.png',
  'pwa_install.js',
  'qvp.js',
  'sherpa-onnx-asr.js',
  'sherpa_official_app.js',
  'sherpa-onnx-wasm-main-asr.js',
  'sherpa-onnx-wasm-main-asr.wasm',
  'flutter_bootstrap.js',
  'flutter.js',
  'main.dart.js',
  'canvaskit/canvaskit.js',
  'canvaskit/canvaskit.wasm',
  'canvaskit/skwasm.js',
  'canvaskit/skwasm.wasm',
  'canvaskit/chromium/canvaskit.js',
  'canvaskit/chromium/canvaskit.wasm',
  'assets/AssetManifest.bin',
  'assets/AssetManifest.bin.json',
  'assets/FontManifest.json',
  'assets/NOTICES',
  'assets/assets/fonts/Cairo-Regular.ttf',
  'assets/assets/fonts/Cairo-Medium.ttf',
  'assets/assets/fonts/Cairo-SemiBold.ttf',
  'assets/assets/fonts/Cairo-Bold.ttf',
  'assets/fonts/MaterialIcons-Regular.otf',
  'assets/assets/icon/app_icon.png',
  'assets/packages/recite_quran/assets/model/tokens.txt',
  'assets/packages/qvp_flutter/assets/wasm/qvp_ffi.wasm',
  'assets/packages/qvp_flutter/assets/js/qvp.js',
  'assets/shaders/ink_sparkle.frag',
  'assets/shaders/stretch_effect.frag'
];

self.addEventListener('install', (event) => {
  self.skipWaiting();
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) =>
      Promise.allSettled(
        STATIC_PRECACHE.map((url) =>
          cache.add(url).catch((err) => console.warn('[SW] Precache skipped:', url, err))
        )
      )
    )
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

function addCoopCoepHeaders(response) {
  if (!response || response.status !== 200 || response.type === 'opaque') {
    return response;
  }
  if (response.headers.get('Cross-Origin-Opener-Policy') === 'same-origin') {
    return response;
  }
  const headers = new Headers(response.headers);
  headers.set('Cross-Origin-Opener-Policy', 'same-origin');
  headers.set('Cross-Origin-Embedder-Policy', 'credentialless');
  headers.set('Cross-Origin-Resource-Policy', 'cross-origin');

  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers
  });
}

self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;

  const url = new URL(event.request.url);

  // Model download endpoint is saved directly to IndexedDB
  if (url.pathname.includes('/download-model')) return;

  // Stream MP3Quran audio directly through browser native HTTP range request pipeline
  if (url.hostname.includes('mp3quran.net')) return;

  // 1. Navigation requests & entry bootstrap scripts: Network First, fallback to cached
  const isBootstrapOrVersion = url.pathname.endsWith('/flutter_bootstrap.js') ||
                               url.pathname.endsWith('/version.json') ||
                               url.pathname.endsWith('/pwa_install.js');

  if (event.request.mode === 'navigate' || isBootstrapOrVersion) {
    event.respondWith(
      fetch(event.request)
        .then((res) => {
          if (res && res.status === 200) {
            const clone = res.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone));
          }
          return addCoopCoepHeaders(res);
        })
        .catch(async () => {
          const cleanPath = url.pathname.replace(/^\//, '');
          const cached = (await caches.match(event.request, { ignoreSearch: true })) ||
                         (await caches.match(cleanPath, { ignoreSearch: true })) ||
                         (await caches.match('index.html')) ||
                         (await caches.match('./'));
          return cached ? addCoopCoepHeaders(cached) : Response.error();
        })
    );
    return;
  }

  // 2. Static assets: Cache First, fallback to Network with dynamic caching
  event.respondWith(
    caches.match(event.request, { ignoreSearch: true }).then((cached) => {
      if (cached) return cached;

      return fetch(event.request).then((res) => {
        if (res && res.status === 200) {
          const clone = res.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone));
        }
        return res;
      }).catch(async () => {
        const cleanPath = url.pathname.replace(/^\//, '');
        const fallback = (await caches.match(cleanPath, { ignoreSearch: true })) ||
                         (await caches.match(url.pathname, { ignoreSearch: true }));
        return fallback || Response.error();
      });
    })
  );
});
