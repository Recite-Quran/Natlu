#!/bin/bash
set -e

# Always run from repository root
cd "$(dirname "$0")/../.."

echo "=== [1/3] Preparing Asset Placeholders for Web ==="
mkdir -p assets/model
touch assets/model/zipformer_p_arabic_v3.int8.onnx

echo "=== [2/3] Building Flutter Web App ==="
if ! command -v flutter &> /dev/null; then
    echo "Installing Flutter SDK (Stable)..."
    git config --global --add safe.directory "*" || true
    git clone https://github.com/flutter/flutter.git -b stable --depth 1 "$HOME/flutter"
    export PATH="$HOME/flutter/bin:$PATH"
    git config --global --add safe.directory "$HOME/flutter" || true
    flutter config --no-analytics
fi

flutter pub get
flutter build web --release --base-href "/" --no-web-resources-cdn --dart-define=RECITATION_MODEL_URL="/download-model?model=zipformer_p_arabic_v3.int8.onnx"

echo "=== [3/3] Setting Up Cloudflare Pages Artifacts ==="
cp web/cloudflare/_headers build/web/_headers 2>/dev/null || true
cp web/cloudflare/_redirects build/web/_redirects 2>/dev/null || true

# Provide Cloudflare Pages Functions to both root and output dir
mkdir -p functions build/web/functions
cp web/cloudflare/functions/download-model.js functions/download-model.js 2>/dev/null || true
cp web/cloudflare/functions/download-model.js build/web/functions/download-model.js 2>/dev/null || true
cp web/cloudflare/wrangler.toml build/web/wrangler.toml 2>/dev/null || true

echo "=== Build Complete! Deploy directory: build/web ==="

