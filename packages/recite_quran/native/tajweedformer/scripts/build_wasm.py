import os
import subprocess
import sys

EMSDK_ROOT = r"D:\Installations\emsdk"
EMCC_PY = os.path.join(EMSDK_ROOT, "upstream", "emscripten", "emcc.py")

ROOT_DIR = r"D:\there is no god unless ALLAH\Playstore\Natlu"
NATIVE_DIR = os.path.join(ROOT_DIR, "packages", "recite_quran", "native", "tajweedformer")
WEB_DIR = r"C:\Users\redaa\Downloads\tajweedformer-web"
OUT_DIR = os.path.join(ROOT_DIR, "web", "js")

INCLUDES = [
    os.path.join(NATIVE_DIR, "engine", "include"),
    os.path.join(NATIVE_DIR, "accel", "include"),
    os.path.join(NATIVE_DIR, "tajweed", "include"),
    os.path.join(NATIVE_DIR, "tajweed", "src"),
    os.path.join(NATIVE_DIR, "third_party", "kissfft"),
    os.path.join(WEB_DIR, "third_party", "onnxruntime", "include"),
]

CFLAGS = [
    "-O3",
    "-ffp-contract=off",
    "-DZF_RELEASE=1",
    "-DZF_QUANT_DIVIDE=1",
    "-DZF_NEON_EMU=1",
    "-msimd128",
    "-fPIC",
]

for inc in INCLUDES:
    CFLAGS.append(f"-I{inc}")

SOURCES = [
    # engine
    os.path.join(NATIVE_DIR, "engine", "src", "pool.c"),
    os.path.join(NATIVE_DIR, "engine", "src", "kernels.c"),
    os.path.join(NATIVE_DIR, "engine", "src", "dot.c"),
    os.path.join(NATIVE_DIR, "engine", "src", "conv.c"),
    os.path.join(NATIVE_DIR, "engine", "src", "layout.c"),
    os.path.join(NATIVE_DIR, "engine", "src", "block.c"),
    os.path.join(NATIVE_DIR, "engine", "src", "zfw.c"),
    os.path.join(NATIVE_DIR, "engine", "src", "frontend.c"),
    os.path.join(NATIVE_DIR, "engine", "src", "layer.c"),
    os.path.join(NATIVE_DIR, "engine", "src", "decode.c"),
    os.path.join(NATIVE_DIR, "engine", "src", "zf_libm.c"),
    os.path.join(NATIVE_DIR, "engine", "src", "fbank.c"),
    os.path.join(NATIVE_DIR, "engine", "src", "resample.c"),
    os.path.join(NATIVE_DIR, "engine", "src", "vfs.c"),
    os.path.join(NATIVE_DIR, "engine", "src", "sha256.c"),
    os.path.join(NATIVE_DIR, "engine", "src", "zfs.c"),
    os.path.join(NATIVE_DIR, "engine", "src", "neon_emu_trace.c"),
    # kissfft
    os.path.join(NATIVE_DIR, "third_party", "kissfft", "kiss_fft.c"),
    os.path.join(NATIVE_DIR, "third_party", "kissfft", "kiss_fftr.c"),
    # accel
    os.path.join(NATIVE_DIR, "accel", "src", "ort_ops.c"),
    os.path.join(NATIVE_DIR, "accel", "src", "zf_rt.c"),
    os.path.join(NATIVE_DIR, "accel", "src", "stream.c"),
    # tajweed
    os.path.join(NATIVE_DIR, "tajweed", "src", "model.c"),
    os.path.join(NATIVE_DIR, "tajweed", "src", "decoded.c"),
    os.path.join(NATIVE_DIR, "tajweed", "src", "reference.c"),
    os.path.join(NATIVE_DIR, "tajweed", "src", "engine.c"),
    # zft_api from tajweedformer-web
    os.path.join(WEB_DIR, "src", "zft_api.c"),
]

LDFLAGS = [
    "-sMODULARIZE=1",
    "-sEXPORT_NAME=createTajweedFormer",
    "-sEXPORT_ES6=1",
    "-sFORCE_FILESYSTEM=1",
    "-sALLOW_MEMORY_GROWTH=1",
    "-sINITIAL_MEMORY=256MB",
    "-sMAXIMUM_MEMORY=4GB",
    "-sSTACK_SIZE=2MB",
    "-sEXPORTED_RUNTIME_METHODS=ccall,cwrap,FS,HEAPF32,HEAPF64,HEAP32,HEAPU8,getValue,setValue,UTF8ToString,stringToNewUTF8",
    "-sEXPORTED_FUNCTIONS=_malloc,_free",
    "--no-entry",
]

OUTPUT_JS = os.path.join(OUT_DIR, "tajweedformer.mjs")

os.makedirs(OUT_DIR, exist_ok=True)

# Build command
cmd = [sys.executable, EMCC_PY] + CFLAGS + SOURCES + LDFLAGS + ["-o", OUTPUT_JS]

print("Compiling standalone TajweedFormer to WebAssembly...")
env = os.environ.copy()
env["PATH"] = f"{os.path.join(EMSDK_ROOT, 'upstream', 'emscripten')};{os.path.join(EMSDK_ROOT, 'node', '22.16.0_64bit', 'bin')};{env['PATH']}"
env["EMSDK"] = EMSDK_ROOT
env["EMSDK_NODE"] = os.path.join(EMSDK_ROOT, "node", "22.16.0_64bit", "bin", "node.exe")
env["EMSDK_PYTHON"] = os.path.join(EMSDK_ROOT, "python", "3.13.3_64bit", "python.exe")

res = subprocess.run(cmd, env=env)
if res.returncode == 0:
    wasm_file = os.path.join(OUT_DIR, "tajweedformer.wasm")
    if os.path.exists(wasm_file):
        print(f"SUCCESS! Built WebAssembly binary: {wasm_file} ({os.path.getsize(wasm_file)} bytes)")
    else:
        print("Build finished, checking files in output dir...")
else:
    print(f"Build failed with exit code: {res.returncode}")
    sys.exit(res.returncode)
