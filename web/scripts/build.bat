@echo off
setlocal
cd /d "%~dp0\..\.."

echo === [1/3] Preparing Asset Placeholders for Web ===
if not exist assets\model mkdir assets\model
type nul > assets\model\zipformer_p_arabic_v3.int8.onnx

echo === [2/3] Building Flutter Web App ===
call flutter pub get
call flutter build web --release --base-href "/" --no-web-resources-cdn --dart-define=RECITATION_MODEL_URL="/download-model?model=zipformer_p_arabic_v3.int8.onnx"

echo === [3/3] Setting Up Cloudflare Pages Artifacts ===
if exist web\cloudflare\_headers copy /Y web\cloudflare\_headers build\web\_headers >nul
if exist web\cloudflare\_redirects copy /Y web\cloudflare\_redirects build\web\_redirects >nul
if not exist functions mkdir functions
if not exist build\web\functions mkdir build\web\functions
if exist web\cloudflare\functions\download-model.js copy /Y web\cloudflare\functions\download-model.js functions\download-model.js >nul
if exist web\cloudflare\functions\download-model.js copy /Y web\cloudflare\functions\download-model.js build\web\functions\download-model.js >nul
if exist web\cloudflare\wrangler.toml copy /Y web\cloudflare\wrangler.toml build\web\wrangler.toml >nul

echo === Build Complete! Output directory: build\web ===

