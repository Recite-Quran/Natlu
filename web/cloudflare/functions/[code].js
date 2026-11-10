export async function onRequest(context) {
  const { params, next } = context;
  const rawCode = (params.code || '').trim();

  // Strictly match 5-digit room codes.
  // Any other path (e.g. sw.js, manifest.json, favicon.png, badges/*) passes through to static assets.
  if (!/^\d{5}$/.test(rawCode)) {
    return next();
  }

  const code = rawCode;
  const title = `مجلس تلاوة القرآن العظيم • رمز ${code}`;
  const desc = 'مجلس تلاوة القرآن العظيم وتدارسه عبر تطبيق اتلو القران - Recite Quran.';
  const appSchemeUrl = `natlu://maglis/${code}`;
  const playStoreUrl = 'https://play.google.com/store/apps/details?id=com.recitequran.app';
  const appStoreUrl = 'https://apps.apple.com/app/id6806614841';
  const webAppUrl = `https://natlu.pages.dev/#/${code}`;

  // Telegram-style Android Intent URI: forces native app launch or falls back to Play Store
  const androidIntentUrl = `intent://maglis/${code}#Intent;scheme=natlu;package=com.recitequran.app;S.browser_fallback_url=https%3A%2F%2Fplay.google.com%2Fstore%2Fapps%2Fdetails%3Fid%3Dcom.recitequran.app;end`;

  const html = `<!DOCTYPE html>
<html lang="ar" dir="rtl">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>${title}</title>
  
  <!-- Open Graph / WhatsApp / Telegram Preview Cards (1200x630) -->
  <meta property="og:type" content="website">
  <meta property="og:site_name" content="اتلو القران — Recite Quran">
  <meta property="og:title" content="${title}">
  <meta property="og:description" content="${desc}">
  <meta property="og:image" content="https://natlu.pages.dev/maglis-preview.png">
  <meta property="og:image:secure_url" content="https://natlu.pages.dev/maglis-preview.png">
  <meta property="og:image:type" content="image/png">
  <meta property="og:image:width" content="1200">
  <meta property="og:image:height" content="630">
  <meta property="og:url" content="https://natlu.pages.dev/${code}">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="${title}">
  <meta name="twitter:description" content="${desc}">
  <meta name="twitter:image" content="https://natlu.pages.dev/maglis-preview.png">
  <link rel="image_src" href="https://natlu.pages.dev/maglis-preview.png">

  <!-- Favicons -->
  <link rel="icon" type="image/png" href="/icons/favicon.png?v=quran">
  <link rel="apple-touch-icon" href="/icons/apple-touch-icon.png">

  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Cairo:wght@500;600;700;800&family=Plus+Jakarta+Sans:wght@700;800&display=swap" rel="stylesheet">

  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    
    body {
      background: #05070B;
      color: #E2E8F0;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      padding: 24px 16px;
      text-align: center;
      font-family: "Cairo", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      overflow-x: hidden;
      position: relative;
    }

    /* Ambient background lighting */
    body::before {
      content: '';
      position: fixed;
      top: 15%;
      left: 50%;
      transform: translateX(-50%);
      width: 500px;
      height: 400px;
      background: radial-gradient(circle, rgba(16, 185, 129, 0.15) 0%, rgba(6, 182, 212, 0.05) 45%, transparent 70%);
      filter: blur(60px);
      z-index: 0;
      pointer-events: none;
    }

    /* Ultra-premium glassmorphism card */
    .card {
      position: relative;
      z-index: 1;
      background: rgba(13, 17, 24, 0.85);
      border: 1px solid rgba(255, 255, 255, 0.10);
      border-radius: 28px;
      padding: 30px 24px 28px;
      max-width: 390px;
      width: 100%;
      box-shadow: 
        0 30px 70px -10px rgba(0, 0, 0, 0.9),
        0 0 1px 1px rgba(255, 255, 255, 0.08),
        inset 0 1px 0 rgba(255, 255, 255, 0.15);
      backdrop-filter: blur(28px);
      -webkit-backdrop-filter: blur(28px);
      display: flex;
      flex-direction: column;
      align-items: center;
    }

    /* Ayah Header */
    .ayah {
      font-size: 12px;
      color: #94A3B8;
      margin-bottom: 22px;
      line-height: 1.5;
      font-weight: 500;
      letter-spacing: 0.1px;
    }

    /* App Logo */
    .logo-container {
      position: relative;
      margin-bottom: 14px;
    }
    .logo-container::after {
      content: '';
      position: absolute;
      inset: -4px;
      border-radius: 22px;
      background: radial-gradient(circle, rgba(16, 185, 129, 0.35) 0%, transparent 70%);
      z-index: -1;
      filter: blur(8px);
    }
    .logo {
      width: 72px;
      height: 72px;
      border-radius: 20px;
      background: #FFFFFF;
      border: 1px solid rgba(255, 255, 255, 0.25);
      object-fit: cover;
      display: block;
      box-shadow: 0 8px 24px rgba(0, 0, 0, 0.5);
    }

    /* App Name */
    .app-name {
      font-size: 21px;
      font-weight: 800;
      color: #FFFFFF;
      letter-spacing: -0.3px;
      margin-bottom: 6px;
    }

    /* Maglis Live Session Badge */
    .live-badge {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      background: rgba(16, 185, 129, 0.12);
      border: 1px solid rgba(16, 185, 129, 0.30);
      color: #34D399;
      font-size: 13px;
      font-weight: 700;
      padding: 4px 14px;
      border-radius: 20px;
      margin-bottom: 22px;
    }
    .live-dot {
      width: 7px;
      height: 7px;
      background: #10B981;
      border-radius: 50%;
      box-shadow: 0 0 8px #10B981;
      animation: pulse 2s infinite;
    }
    @keyframes pulse {
      0%, 100% { opacity: 1; transform: scale(1); }
      50% { opacity: 0.4; transform: scale(0.85); }
    }

    /* 5-Digit Segmented Code Card */
    .code-card {
      background: rgba(0, 0, 0, 0.45);
      border: 1px solid rgba(16, 185, 129, 0.25);
      border-radius: 18px;
      padding: 12px 18px;
      display: flex;
      gap: 8px;
      direction: ltr;
      margin-bottom: 24px;
      box-shadow: inset 0 2px 6px rgba(0, 0, 0, 0.6);
    }
    .code-digit {
      width: 44px;
      height: 52px;
      display: flex;
      align-items: center;
      justify-content: center;
      background: linear-gradient(180deg, rgba(255, 255, 255, 0.08) 0%, rgba(16, 185, 129, 0.06) 100%);
      border: 1px solid rgba(16, 185, 129, 0.45);
      border-radius: 12px;
      font-family: "Plus Jakarta Sans", "Cairo", monospace;
      font-size: 27px;
      font-weight: 800;
      color: #34D399;
      box-shadow: 
        inset 0 1px 0 rgba(255, 255, 255, 0.20),
        0 2px 6px rgba(0, 0, 0, 0.3);
      user-select: all;
    }

    /* Actions Box */
    .actions {
      width: 100%;
      display: flex;
      flex-direction: column;
      gap: 11px;
    }

    /* 1. Primary Action Button: Open in App */
    .btn-app {
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 9px;
      width: 100%;
      height: 50px;
      background: linear-gradient(180deg, #10B981 0%, #059669 100%);
      color: #FFFFFF;
      font-size: 15.5px;
      font-weight: 800;
      text-decoration: none;
      border-radius: 14px;
      border: none;
      cursor: pointer;
      box-shadow: 
        inset 0 1px 0 rgba(255, 255, 255, 0.32),
        0 8px 24px -4px rgba(16, 185, 129, 0.45);
      transition: all 0.15s cubic-bezier(0.4, 0, 0.2, 1);
    }
    .btn-app:hover {
      box-shadow: 
        inset 0 1px 0 rgba(255, 255, 255, 0.40),
        0 10px 28px -2px rgba(16, 185, 129, 0.60);
      transform: translateY(-1px);
    }
    .btn-app:active {
      transform: scale(0.98);
      box-shadow: 0 4px 12px rgba(16, 185, 129, 0.3);
    }
    .btn-app svg {
      width: 20px;
      height: 20px;
      fill: currentColor;
    }

    /* 2. Secondary Action Button: Use on Web */
    .btn-web {
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 9px;
      width: 100%;
      height: 50px;
      background: linear-gradient(180deg, rgba(255, 255, 255, 0.08) 0%, rgba(255, 255, 255, 0.03) 100%);
      color: #F1F5F9;
      font-size: 15px;
      font-weight: 700;
      text-decoration: none;
      border-radius: 14px;
      border: 1px solid rgba(255, 255, 255, 0.14);
      cursor: pointer;
      box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.10);
      transition: all 0.15s cubic-bezier(0.4, 0, 0.2, 1);
    }
    .btn-web:hover {
      background: linear-gradient(180deg, rgba(255, 255, 255, 0.12) 0%, rgba(255, 255, 255, 0.05) 100%);
      border-color: rgba(255, 255, 255, 0.22);
      transform: translateY(-1px);
    }
    .btn-web:active {
      transform: scale(0.98);
      background: rgba(255, 255, 255, 0.06);
    }
    .btn-web svg {
      width: 20px;
      height: 20px;
      fill: #34D399;
    }

    /* 3. Official Store Badges: Google Play on LEFT, App Store on RIGHT */
    .stores-row {
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 12px;
      width: 100%;
      margin-top: 6px;
      direction: ltr; /* LTR order ensures 1st item is on LEFT, 2nd item is on RIGHT */
    }
    .store-badge {
      flex: 1;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      text-decoration: none;
      transition: transform 0.12s ease, opacity 0.12s ease;
    }
    .store-badge:hover {
      opacity: 0.95;
      transform: translateY(-1px);
    }
    .store-badge:active {
      transform: scale(0.97);
    }
    .store-badge img {
      height: 38px;
      width: 100%;
      max-width: 145px;
      object-fit: contain;
      display: block;
      filter: drop-shadow(0 2px 8px rgba(0, 0, 0, 0.4));
    }
  </style>

  <script>
    const isAndroid = /android/i.test(navigator.userAgent);
    const targetUrl = isAndroid ? "${androidIntentUrl}" : "${appSchemeUrl}";

    function openApp() {
      window.location.href = targetUrl;
    }

    // Immediate app launch attempt on load
    try {
      window.location.href = targetUrl;
    } catch (_) {}
  </script>
</head>
<body>
  <div class="card">
    <!-- Ayah Dedication -->
    <div class="ayah">و ما اسالكم عليه من اجر ان اجري الا على رب العالمين</div>

    <!-- App Logo -->
    <div class="logo-container">
      <img src="/icons/app_icon.png" alt="اتلو القران" class="logo">
    </div>

    <!-- App Name -->
    <div class="app-name">اتلو القران - Recite Quran</div>

    <!-- Live Maglis Room Badge -->
    <div class="live-badge">
      <span class="live-dot"></span>
      <span>مجلس تلاوة القران العظيم</span>
    </div>

    <!-- 5-Digit Segmented Code Display -->
    <div class="code-card">
      <span class="code-digit">${code[0]}</span>
      <span class="code-digit">${code[1]}</span>
      <span class="code-digit">${code[2]}</span>
      <span class="code-digit">${code[3]}</span>
      <span class="code-digit">${code[4]}</span>
    </div>

    <div class="actions">
      <!-- 1. Open in App Primary Hero Button -->
      <a href="#" onclick="openApp(); return false;" class="btn-app">
        <svg viewBox="0 0 24 24">
          <path d="M19 19H5V5h7V3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7h-2v7zM14 3v2h3.59l-9.83 9.83 1.41 1.41L19 6.41V10h2V3h-7z"/>
        </svg>
        <span>فتح في التطبيق</span>
      </a>

      <!-- 2. Continue on Web Secondary Button -->
      <a href="${webAppUrl}" class="btn-web">
        <svg viewBox="0 0 24 24">
          <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/>
        </svg>
        <span>المتابعة عبر الويب</span>
      </a>

      <!-- 3. Store Badges: Google Play on LEFT, App Store on RIGHT -->
      <div class="stores-row">
        <!-- 1st element in LTR is on the LEFT: Google Play -->
        <a href="${playStoreUrl}" target="_blank" class="store-badge">
          <img src="/badges/google_play.svg" alt="Get it on Google Play">
        </a>
        <!-- 2nd element in LTR is on the RIGHT: App Store -->
        <a href="${appStoreUrl}" target="_blank" class="store-badge">
          <img src="/badges/app_store.svg" alt="Download on the App Store">
        </a>
      </div>
    </div>
  </div>
</body>
</html>`;

  return new Response(html, {
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'public, max-age=60',
    },
  });
}
