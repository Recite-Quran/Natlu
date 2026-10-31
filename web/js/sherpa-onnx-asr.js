// Sherpa-ONNX WebAssembly Online Recognizer JS Binding (Optimized for Recite Quran)
// Retains only OnlineRecognizer / OnlineStream for streaming Zipformer ASR.

function freeConfig(config, Module) {
  if (!config) return;
  if ('buffer' in config && config.buffer) Module._free(config.buffer);
  for (const key of ['transducer', 'paraformer', 'zipformer2Ctc', 'nemoCtc', 'toneCtc', 'feat', 'model', 'ctcFstDecoder', 'hr']) {
    if (key in config && config[key]) freeConfig(config[key], Module);
  }
  if ('ptr' in config && config.ptr) Module._free(config.ptr);
}

function initSherpaOnnxOnlineTransducerModelConfig(config, Module) {
  const enc = config.encoder || '', dec = config.decoder || '', jn = config.joiner || '';
  const eLen = Module.lengthBytesUTF8(enc) + 1;
  const dLen = Module.lengthBytesUTF8(dec) + 1;
  const jLen = Module.lengthBytesUTF8(jn) + 1;
  const buffer = Module._malloc(eLen + dLen + jLen);
  const ptr = Module._malloc(12);

  Module.stringToUTF8(enc, buffer, eLen);
  Module.stringToUTF8(dec, buffer + eLen, dLen);
  Module.stringToUTF8(jn, buffer + eLen + dLen, jLen);

  Module.setValue(ptr, buffer, 'i8*');
  Module.setValue(ptr + 4, buffer + eLen, 'i8*');
  Module.setValue(ptr + 8, buffer + eLen + dLen, 'i8*');

  return { buffer, ptr, len: 12 };
}

function initSherpaOnnxOnlineParaformerModelConfig(config, Module) {
  const enc = config.encoder || '', dec = config.decoder || '';
  const eLen = Module.lengthBytesUTF8(enc) + 1;
  const dLen = Module.lengthBytesUTF8(dec) + 1;
  const buffer = Module._malloc(eLen + dLen);
  const ptr = Module._malloc(8);

  Module.stringToUTF8(enc, buffer, eLen);
  Module.stringToUTF8(dec, buffer + eLen, dLen);

  Module.setValue(ptr, buffer, 'i8*');
  Module.setValue(ptr + 4, buffer + eLen, 'i8*');

  return { buffer, ptr, len: 8 };
}

function initSherpaOnnxOnlineZipformer2CtcModelConfig(config, Module) {
  const model = config.model || '';
  const n = Module.lengthBytesUTF8(model) + 1;
  const buffer = Module._malloc(n);
  const ptr = Module._malloc(4);

  Module.stringToUTF8(model, buffer, n);
  Module.setValue(ptr, buffer, 'i8*');

  return { buffer, ptr, len: 4 };
}

function initSherpaOnnxOnlineNemoCtcModelConfig(config, Module) {
  const model = config.model || '';
  const n = Module.lengthBytesUTF8(model) + 1;
  const buffer = Module._malloc(n);
  const ptr = Module._malloc(4);

  Module.stringToUTF8(model, buffer, n);
  Module.setValue(ptr, buffer, 'i8*');

  return { buffer, ptr, len: 4 };
}

function initSherpaOnnxOnlineToneCtcModelConfig(config, Module) {
  const model = config.model || '';
  const n = Module.lengthBytesUTF8(model) + 1;
  const buffer = Module._malloc(n);
  const ptr = Module._malloc(4);

  Module.stringToUTF8(model, buffer, n);
  Module.setValue(ptr, buffer, 'i8*');

  return { buffer, ptr, len: 4 };
}

function initSherpaOnnxOnlineModelConfig(config, Module) {
  const transducer = initSherpaOnnxOnlineTransducerModelConfig(config.transducer || {}, Module);
  const paraformer = initSherpaOnnxOnlineParaformerModelConfig(config.paraformer || {}, Module);
  const zipformer2Ctc = initSherpaOnnxOnlineZipformer2CtcModelConfig(config.zipformer2Ctc || {}, Module);
  const nemoCtc = initSherpaOnnxOnlineNemoCtcModelConfig(config.nemoCtc || {}, Module);
  const toneCtc = initSherpaOnnxOnlineToneCtcModelConfig(config.toneCtc || {}, Module);

  const tokens = config.tokens || '';
  const provider = config.provider || 'cpu';
  const modelType = config.modelType || '';
  const modelingUnit = config.modelingUnit || '';
  const bpeVocab = config.bpeVocab || '';
  const tokensBuf = config.tokensBuf || '';

  const tLen = Module.lengthBytesUTF8(tokens) + 1;
  const pLen = Module.lengthBytesUTF8(provider) + 1;
  const mtLen = Module.lengthBytesUTF8(modelType) + 1;
  const muLen = Module.lengthBytesUTF8(modelingUnit) + 1;
  const bpeLen = Module.lengthBytesUTF8(bpeVocab) + 1;
  const tbLen = Module.lengthBytesUTF8(tokensBuf) + 1;

  const buffer = Module._malloc(tLen + pLen + mtLen + muLen + bpeLen + tbLen);
  let o = 0;
  Module.stringToUTF8(tokens, buffer + o, tLen); o += tLen;
  Module.stringToUTF8(provider, buffer + o, pLen); o += pLen;
  Module.stringToUTF8(modelType, buffer + o, mtLen); o += mtLen;
  Module.stringToUTF8(modelingUnit, buffer + o, muLen); o += muLen;
  Module.stringToUTF8(bpeVocab, buffer + o, bpeLen); o += bpeLen;
  Module.stringToUTF8(tokensBuf, buffer + o, tbLen);

  const len = transducer.len + paraformer.len + zipformer2Ctc.len + 36 + nemoCtc.len + toneCtc.len;
  const ptr = Module._malloc(len);

  let offset = 0;
  Module._CopyHeap(transducer.ptr, transducer.len, ptr + offset); offset += transducer.len;
  Module._CopyHeap(paraformer.ptr, paraformer.len, ptr + offset); offset += paraformer.len;
  Module._CopyHeap(zipformer2Ctc.ptr, zipformer2Ctc.len, ptr + offset); offset += zipformer2Ctc.len;

  Module.setValue(ptr + offset, buffer, 'i8*'); offset += 4;
  Module.setValue(ptr + offset, config.numThreads || 1, 'i32'); offset += 4;
  Module.setValue(ptr + offset, buffer + tLen, 'i8*'); offset += 4;
  Module.setValue(ptr + offset, config.debug ?? 0, 'i32'); offset += 4;
  Module.setValue(ptr + offset, buffer + tLen + pLen, 'i8*'); offset += 4;
  Module.setValue(ptr + offset, buffer + tLen + pLen + mtLen, 'i8*'); offset += 4;
  Module.setValue(ptr + offset, buffer + tLen + pLen + mtLen + muLen, 'i8*'); offset += 4;
  Module.setValue(ptr + offset, buffer + tLen + pLen + mtLen + muLen + bpeLen, 'i8*'); offset += 4;
  Module.setValue(ptr + offset, config.tokensBufSize || 0, 'i32'); offset += 4;

  Module._CopyHeap(nemoCtc.ptr, nemoCtc.len, ptr + offset); offset += nemoCtc.len;
  Module._CopyHeap(toneCtc.ptr, toneCtc.len, ptr + offset);

  return { buffer, ptr, len, transducer, paraformer, zipformer2Ctc, nemoCtc, toneCtc };
}

function initSherpaOnnxFeatureConfig(config, Module) {
  const ptr = Module._malloc(8);
  Module.setValue(ptr, config.sampleRate || 16000, 'i32');
  Module.setValue(ptr + 4, config.featureDim || 80, 'i32');
  return { ptr, len: 8 };
}

function initSherpaOnnxHomophoneReplacerConfig(config, Module) {
  const dictDir = '', lexicon = (config && config.lexicon) || '', ruleFsts = (config && config.ruleFsts) || '';
  const dLen = Module.lengthBytesUTF8(dictDir) + 1;
  const lLen = Module.lengthBytesUTF8(lexicon) + 1;
  const rLen = Module.lengthBytesUTF8(ruleFsts) + 1;
  const buffer = Module._malloc(dLen + lLen + rLen);

  Module.stringToUTF8(dictDir, buffer, dLen);
  Module.stringToUTF8(lexicon, buffer + dLen, lLen);
  Module.stringToUTF8(ruleFsts, buffer + dLen + lLen, rLen);

  const ptr = Module._malloc(12);
  Module.setValue(ptr, buffer, 'i8*');
  Module.setValue(ptr + 4, buffer + dLen, 'i8*');
  Module.setValue(ptr + 8, buffer + dLen + lLen, 'i8*');

  return { ptr, len: 12, buffer };
}

function initSherpaOnnxOnlineCtcFstDecoderConfig(config, Module) {
  const graph = (config && config.graph) || '';
  const gLen = Module.lengthBytesUTF8(graph) + 1;
  const buffer = Module._malloc(gLen);
  Module.stringToUTF8(graph, buffer, gLen);

  const ptr = Module._malloc(8);
  Module.setValue(ptr, buffer, 'i8*');
  Module.setValue(ptr + 4, (config && config.maxActive) || 3000, 'i32');
  return { ptr, len: 8, buffer };
}

function initSherpaOnnxOnlineRecognizerConfig(config, Module) {
  const feat = initSherpaOnnxFeatureConfig(config.featConfig || {}, Module);
  const model = initSherpaOnnxOnlineModelConfig(config.modelConfig || {}, Module);
  const ctcFstDecoder = initSherpaOnnxOnlineCtcFstDecoderConfig(config.ctcFstDecoderConfig || {}, Module);
  const hr = initSherpaOnnxHomophoneReplacerConfig(config.hr || {}, Module);

  const decMethod = config.decodingMethod || 'greedy_search';
  const hwFile = config.hotwordsFile || '';
  const rFsts = config.ruleFsts || '';
  const rFars = config.ruleFars || '';
  const hwBuf = config.hotwordsBuf || '';

  const dmLen = Module.lengthBytesUTF8(decMethod) + 1;
  const hwfLen = Module.lengthBytesUTF8(hwFile) + 1;
  const rfLen = Module.lengthBytesUTF8(rFsts) + 1;
  const rfaLen = Module.lengthBytesUTF8(rFars) + 1;
  const hwbLen = Module.lengthBytesUTF8(hwBuf) + 1;

  const buffer = Module._malloc(dmLen + hwfLen + rfLen + rfaLen + hwbLen);
  let o = 0;
  Module.stringToUTF8(decMethod, buffer + o, dmLen); o += dmLen;
  Module.stringToUTF8(hwFile, buffer + o, hwfLen); o += hwfLen;
  Module.stringToUTF8(rFsts, buffer + o, rfLen); o += rfLen;
  Module.stringToUTF8(rFars, buffer + o, rfaLen); o += rfaLen;
  Module.stringToUTF8(hwBuf, buffer + o, hwbLen);

  const len = feat.len + model.len + 32 + ctcFstDecoder.len + 20 + hr.len;
  const ptr = Module._malloc(len);

  let offset = 0;
  Module._CopyHeap(feat.ptr, feat.len, ptr + offset); offset += feat.len;
  Module._CopyHeap(model.ptr, model.len, ptr + offset); offset += model.len;

  Module.setValue(ptr + offset, buffer, 'i8*'); offset += 4;
  Module.setValue(ptr + offset, config.maxActivePaths || 4, 'i32'); offset += 4;
  Module.setValue(ptr + offset, config.enableEndpoint || 0, 'i32'); offset += 4;
  Module.setValue(ptr + offset, config.rule1MinTrailingSilence || 2.4, 'float'); offset += 4;
  Module.setValue(ptr + offset, config.rule2MinTrailingSilence || 1.2, 'float'); offset += 4;
  Module.setValue(ptr + offset, config.rule3MinUtteranceLength || 20, 'float'); offset += 4;
  Module.setValue(ptr + offset, buffer + dmLen, 'i8*'); offset += 4;
  Module.setValue(ptr + offset, config.hotwordsScore || 1.5, 'float'); offset += 4;

  Module._CopyHeap(ctcFstDecoder.ptr, ctcFstDecoder.len, ptr + offset); offset += ctcFstDecoder.len;

  Module.setValue(ptr + offset, buffer + dmLen + hwfLen, 'i8*'); offset += 4;
  Module.setValue(ptr + offset, buffer + dmLen + hwfLen + rfLen, 'i8*'); offset += 4;
  Module.setValue(ptr + offset, config.blankPenalty || 0, 'float'); offset += 4;
  Module.setValue(ptr + offset, buffer + dmLen + hwfLen + rfLen + rfaLen, 'i8*'); offset += 4;
  Module.setValue(ptr + offset, config.hotwordsBufSize || 0, 'i32'); offset += 4;

  Module._CopyHeap(hr.ptr, hr.len, ptr + offset);

  return { buffer, ptr, len, feat, model, ctcFstDecoder, hr };
}

class OnlineStream {
  constructor(handle, Module) {
    this.handle = handle;
    this.pointer = null;
    this.n = 0;
    this.Module = Module;
  }

  free() {
    if (this.handle) {
      this.Module._SherpaOnnxDestroyOnlineStream(this.handle);
      this.handle = null;
      if (this.pointer) {
        this.Module._free(this.pointer);
        this.pointer = null;
      }
      this.n = 0;
    }
  }

  acceptWaveform(sampleRate, samples) {
    if (this.n < samples.length) {
      if (this.pointer) this.Module._free(this.pointer);
      this.pointer = this.Module._malloc(samples.length * samples.BYTES_PER_ELEMENT);
      this.n = samples.length;
    }
    this.Module.HEAPF32.set(samples, this.pointer / samples.BYTES_PER_ELEMENT);
    this.Module._SherpaOnnxOnlineStreamAcceptWaveform(this.handle, sampleRate, this.pointer, samples.length);
  }

  inputFinished() {
    this.Module._SherpaOnnxOnlineStreamInputFinished(this.handle);
  }
}

class OnlineRecognizer {
  constructor(configObj, Module) {
    this.config = configObj;
    const config = initSherpaOnnxOnlineRecognizerConfig(configObj, Module);
    this.handle = Module._SherpaOnnxCreateOnlineRecognizer(config.ptr);
    freeConfig(config, Module);
    this.Module = Module;
  }

  free() {
    if (this.handle) {
      this.Module._SherpaOnnxDestroyOnlineRecognizer(this.handle);
      this.handle = 0;
    }
  }

  createStream() {
    const handle = this.Module._SherpaOnnxCreateOnlineStream(this.handle);
    return new OnlineStream(handle, this.Module);
  }

  isReady(stream) {
    return this.Module._SherpaOnnxIsOnlineStreamReady(this.handle, stream.handle) === 1;
  }

  decode(stream) {
    this.Module._SherpaOnnxDecodeOnlineStream(this.handle, stream.handle);
  }

  isEndpoint(stream) {
    return this.Module._SherpaOnnxOnlineStreamIsEndpoint(this.handle, stream.handle) === 1;
  }

  reset(stream) {
    this.Module._SherpaOnnxOnlineStreamReset(this.handle, stream.handle);
  }

  getResult(stream) {
    const r = this.Module._SherpaOnnxGetOnlineStreamResultAsJson(this.handle, stream.handle);
    const jsonStr = this.Module.UTF8ToString(r);
    const ans = JSON.parse(jsonStr);
    this.Module._SherpaOnnxDestroyOnlineStreamResultJson(r);
    return ans;
  }
}

function createOnlineRecognizer(Module, myConfig) {
  const modelPath = (Module && Module.modelPath) ? Module.modelPath : '/zipformer_p_arabic_v3.int8.onnx';
  const tokensPath = (Module && Module.tokensPath) ? Module.tokensPath : '/quran_tokens.txt';

  const recognizerConfig = myConfig || {
    featConfig: { sampleRate: 16000, featureDim: 80 },
    modelConfig: {
      transducer: { encoder: '', decoder: '', joiner: '' },
      paraformer: { encoder: '', decoder: '' },
      zipformer2Ctc: { model: modelPath },
      nemoCtc: { model: '' },
      toneCtc: { model: '' },
      tokens: tokensPath,
      numThreads: 1,
      provider: 'cpu',
      debug: 0,
      modelType: '',
      modelingUnit: 'cjkchar',
      bpeVocab: '',
    },
    decodingMethod: 'greedy_search',
    maxActivePaths: 4,
    enableEndpoint: 1,
    rule1MinTrailingSilence: 50.0,
    rule2MinTrailingSilence: 50.0,
    rule3MinUtteranceLength: 99999.0,
    hotwordsFile: '',
    hotwordsScore: 1.5,
    ctcFstDecoderConfig: { graph: '', maxActive: 3000 },
    ruleFsts: '',
    ruleFars: '',
  };

  return new OnlineRecognizer(recognizerConfig, Module);
}

if (typeof window !== 'undefined') {
  window.createOnlineRecognizer = createOnlineRecognizer;
  window.OnlineRecognizer = OnlineRecognizer;
  window.OnlineStream = OnlineStream;
}
