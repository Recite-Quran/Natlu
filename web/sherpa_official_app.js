// Bridge between Sherpa-ONNX WebAssembly and Flutter Dart application
// Handles VFS initialization, audio chunk feeding, and IndexedDB model caching.

Module = {};

Module.locateFile = function(path, scriptDirectory = '') {
  return scriptDirectory ? (scriptDirectory + path) : path;
};

let recognizer = null;
let recognizerStream = null;
let isRecognizerReady = false;
let isWasmLoaded = false;
let initializationError = '';
let lastResult = '';
const SAMPLE_RATE = 16000;

Module.printErr = function(text) {
  console.error('[Sherpa WASM Error]', text);
};

Module.onAbort = function(what) {
  console.error('[Sherpa WASM Aborted]', what);
};

Module.onRuntimeInitialized = function() {
  console.log('[Sherpa] WASM runtime initialized.');
  isWasmLoaded = true;
};

window.isWasmModuleLoaded = () => isWasmLoaded;
window.getOfficialSherpaError = () => initializationError;
window.isOfficialSherpaReady = () => isRecognizerReady;

// Write asset bytes directly into Emscripten Virtual File System (VFS)
window.writeSherpaAssetToVFS = function(filename, bytes) {
  try {
    const cleanName = filename.replace(/^(\.\/|\/)/, '');
    const fullPath = '/' + cleanName;

    // 1. Emscripten Module.FS API
    if (Module.FS && Module.FS.writeFile) {
      try {
        if (Module.FS.analyzePath && Module.FS.analyzePath(fullPath).exists) {
          Module.FS.unlink(fullPath);
        }
      } catch (_) {}
      Module.FS.writeFile(fullPath, bytes);
      return true;
    }

    // 2. Emscripten FS_createDataFile / FS_unlink API
    if (Module.FS_createDataFile) {
      if (Module.FS_unlink) {
        try { Module.FS_unlink(fullPath); } catch (_) {}
      }
      Module.FS_createDataFile('/', cleanName, bytes, true, true, true);
      return true;
    }

    console.error('[Sherpa] No VFS API available on Module!');
    return false;
  } catch (e) {
    console.error(`[Sherpa] Failed to write ${filename} to VFS:`, e);
    return false;
  }
};

// Initialize the Sherpa OnlineRecognizer
window.initSherpaRecognizer = function(modelFilename, tokensFilename) {
  const cleanM = (modelFilename || 'zipformer_p_arabic_v3.int8.onnx').replace(/^(\.\/|\/)/, '');
  const cleanT = (tokensFilename || 'quran_tokens.txt').replace(/^(\.\/|\/)/, '');

  const fullM = '/' + cleanM;
  const fullT = '/' + cleanT;

  function cleanupVFS() {
    if (Module.FS && Module.FS.unlink) {
      try {
        if (Module.FS.analyzePath && Module.FS.analyzePath(fullM).exists) Module.FS.unlink(fullM);
      } catch (_) {}
    } else if (Module.FS_unlink) {
      try { Module.FS_unlink(fullM); } catch (_) {}
    }
  }

  try {
    Module.modelPath = fullM;
    Module.tokensPath = fullT;

    recognizer = createOnlineRecognizer(Module);
    if (!recognizer || !recognizer.handle) {
      throw new Error('OnlineRecognizer handle is invalid');
    }
    isRecognizerReady = true;
    console.log('[Sherpa] Recognizer created successfully.');

    // Release 72MB VFS memory immediately after C++ engine loads weights into memory
    cleanupVFS();
    return true;
  } catch (e) {
    console.error('[Sherpa] Failed to create recognizer:', e);
    cleanupVFS();
    return false;
  }
};

function primeRecognizer() {
  if (recognizer && recognizerStream) {
    const priming = new Float32Array(4800); // 300ms silence
    recognizerStream.acceptWaveform(SAMPLE_RATE, priming);
    while (recognizer.isReady(recognizerStream)) {
      recognizer.decode(recognizerStream);
    }
  }
}

// Feed audio samples from Dart AudioProcessor into the Sherpa recognizer
window.feedSherpaAudioChunk = function(chunk, isFinal) {
  if (!chunk) return;
  let samples = chunk;
  if (!(samples instanceof Float32Array)) {
    if (samples && samples.buffer) {
      samples = new Float32Array(samples.buffer, samples.byteOffset || 0, samples.length);
    } else {
      samples = new Float32Array(chunk);
    }
  }
  if (!samples || samples.length === 0) return;

  if (!isRecognizerReady || !recognizer) return;

  if (!recognizerStream) {
    recognizerStream = recognizer.createStream();
    primeRecognizer();
  }

  recognizerStream.acceptWaveform(SAMPLE_RATE, samples);

  if (isFinal) {
    try {
      recognizerStream.inputFinished();
    } catch (_) {}
  }

  while (recognizer.isReady(recognizerStream)) {
    recognizer.decode(recognizerStream);
  }

  const isEndpoint = recognizer.isEndpoint(recognizerStream);
  const fullResult = recognizer.getResult(recognizerStream);
  const resultText = (fullResult && fullResult.text) ? fullResult.text : '';

  if (resultText && resultText !== lastResult) {
    lastResult = resultText;
    if (window.dartSherpaOnResult) {
      window.dartSherpaOnResult(JSON.stringify(fullResult), false);
    }
  }

  if ((isEndpoint || isFinal) && window.dartSherpaOnResult) {
    window.dartSherpaOnResult(JSON.stringify(fullResult), true);
  }
};
globalThis.feedSherpaAudioChunk = window.feedSherpaAudioChunk;

window.resetOfficialSherpaBuffer = function() {
  if (recognizer && recognizerStream) {
    recognizer.reset(recognizerStream);
    primeRecognizer();
  }
  lastResult = '';
};

// --- IndexedDB Caching ---
const DB_NAME = 'SherpaModelDB';
const STORE_NAME = 'models';

function openDB() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = (e) => {
      const db = e.target.result;
      if (!db.objectStoreNames.contains(STORE_NAME)) db.createObjectStore(STORE_NAME);
    };
    req.onsuccess = (e) => resolve(e.target.result);
    req.onerror = (e) => reject(e.target.error);
  });
}

async function getCachedModel(url) {
  try {
    const db = await openDB();
    return new Promise((resolve) => {
      const tx = db.transaction(STORE_NAME, 'readonly');
      const req = tx.objectStore(STORE_NAME).get(url);
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => resolve(null);
    });
  } catch (_) {
    return null;
  }
}

async function cacheModel(url, buffer) {
  try {
    const db = await openDB();
    const tx = db.transaction(STORE_NAME, 'readwrite');
    tx.objectStore(STORE_NAME).put(buffer, url);
    if (navigator.storage && navigator.storage.persist) {
      navigator.storage.persist().catch(() => {});
    }
  } catch (_) {}
}

// Check if model already exists locally in IndexedDB (> 50MB)
window.isSherpaModelCached = async function(modelFilename) {
  try {
    const filename = modelFilename || 'zipformer_p_arabic_v3.int8.onnx';
    const targetUrl = '/download-model?model=' + filename;
    const cached = await getCachedModel(targetUrl);
    return Boolean(cached && cached.byteLength > 50000000);
  } catch (_) {
    return false;
  }
};

// --- Multi-Chunk Downloader ---
let activeModelDownloadPromise = null;

window.fetchSherpaModel = async function(url) {
  if (activeModelDownloadPromise) return activeModelDownloadPromise;

  activeModelDownloadPromise = (async () => {
    try {
      const targetUrl = (url && !url.includes('pythonanywhere') && !url.includes('tathbeet'))
        ? url
        : '/download-model?model=zipformer_p_arabic_v3.int8.onnx';

      const cached = await getCachedModel(targetUrl);
      if (cached && cached.byteLength > 50000000) {
        return new Uint8Array(cached);
      }

      // Probe size and range support
      let totalSize = 72705392;
      let supportsRanges = false;
      try {
        const headRes = await fetch(targetUrl, { method: 'HEAD' });
        const len = headRes.headers.get('content-length');
        if (len) totalSize = parseInt(len, 10);
        supportsRanges = headRes.headers.get('accept-ranges') === 'bytes';
      } catch (_) {}

      let arrayBuffer;
      if (supportsRanges && totalSize > 10000000) {
        // 4-way parallel chunk download
        const numChunks = 4;
        const chunkSize = Math.ceil(totalSize / numChunks);

        const chunkPromises = Array.from({ length: numChunks }, (_, i) => {
          const start = i * chunkSize;
          const end = Math.min(start + chunkSize - 1, totalSize - 1);

          return new Promise((resolve, reject) => {
            const xhr = new XMLHttpRequest();
            xhr.open('GET', targetUrl, true);
            xhr.responseType = 'arraybuffer';
            xhr.setRequestHeader('Range', `bytes=${start}-${end}`);
            xhr.onload = () => {
              if (xhr.status === 206) {
                resolve({ index: i, buffer: xhr.response });
              } else {
                reject(new Error(`Chunk ${i} HTTP ${xhr.status}`));
              }
            };
            xhr.onerror = () => reject(new Error(`Chunk ${i} failed`));
            xhr.send();
          });
        });

        const results = await Promise.all(chunkPromises);
        results.sort((a, b) => a.index - b.index);

        const assembled = new Uint8Array(totalSize);
        let offset = 0;
        for (const r of results) {
          assembled.set(new Uint8Array(r.buffer), offset);
          offset += r.buffer.byteLength;
        }
        arrayBuffer = assembled.buffer;
      } else {
        // Single-stream fallback
        arrayBuffer = await new Promise((resolve, reject) => {
          const xhr = new XMLHttpRequest();
          xhr.open('GET', targetUrl, true);
          xhr.responseType = 'arraybuffer';
          xhr.onload = () => (xhr.status >= 200 && xhr.status < 300) ? resolve(xhr.response) : reject(new Error(`HTTP ${xhr.status}`));
          xhr.onerror = () => reject(new Error('Network error'));
          xhr.send();
        });
      }

      cacheModel(targetUrl, arrayBuffer);
      return new Uint8Array(arrayBuffer);
    } catch (err) {
      console.error('[Sherpa] Model download failed:', err);
      activeModelDownloadPromise = null;
      return null;
    }
  })();

  return activeModelDownloadPromise;
};
