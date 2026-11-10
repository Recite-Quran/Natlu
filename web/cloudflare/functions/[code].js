export async function onRequest(context) {
  const { params, next } = context;
  const rawCode = (params.code || '').trim();

  // Strictly match 5-digit room codes.
  // Any other path (e.g. sw.js, manifest.json, favicon.png, badges/*) passes through to static assets.
  if (!/^\d{5}$/.test(rawCode)) {
    return next();
  }

  const code = rawCode;
  const title = `مجلس تلاوة القرآن الكريم • رمز ${code}`;
  const desc = 'انضم الآن لتدارس القرآن الكريم والتلاوة الجماعية الحية عبر تطبيق اتلو القران.';
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
  <meta property="og:site_name" content="اتلو القران — Natlu">
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

  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: #000000;
      color: #F8FAFC;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      padding: 18px;
      text-align: center;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Cairo", sans-serif;
      background-image: 
        radial-gradient(circle at 50% 20%, rgba(16, 185, 129, 0.14) 0%, transparent 60%),
        radial-gradient(circle at 50% 85%, rgba(6, 182, 212, 0.08) 0%, transparent 60%);
      background-attachment: fixed;
    }

    /* Dialog Window (Aligned with Natlu DialogTokens: radius 28px, surface #0D111A, subtle glass border) */
    .dialog-card {
      background: #0D111A;
      border: 1px solid rgba(255, 255, 255, 0.12);
      border-radius: 28px;
      padding: 24px 22px 26px;
      max-width: 410px;
      width: 100%;
      box-shadow: 0 24px 60px rgba(0, 0, 0, 0.75), 0 0 32px rgba(16, 185, 129, 0.09);
      position: relative;
      display: flex;
      flex-direction: column;
      align-items: center;
      backdrop-filter: blur(16px);
      -webkit-backdrop-filter: blur(16px);
    }

    /* Standardized Dialog Drag Handle (44px x 4px) */
    .drag-handle {
      width: 44px;
      height: 4px;
      background: rgba(255, 255, 255, 0.22);
      border-radius: 2px;
      margin-bottom: 20px;
    }

    /* Ayah Dedication at top */
    .ayah-top {
      font-size: 13px;
      color: #94A3B8;
      line-height: 1.5;
      margin-bottom: 18px;
      padding: 0 10px;
    }

    /* App Logo (76x76 squircle with subtle emerald border and soft glow) */
    .logo-wrap {
      width: 76px;
      height: 76px;
      border-radius: 20px;
      background: #FFFFFF;
      display: flex;
      align-items: center;
      justify-content: center;
      margin-bottom: 14px;
      border: 2px solid rgba(16, 185, 129, 0.50);
      box-shadow: 0 8px 24px rgba(16, 185, 129, 0.25);
      overflow: hidden;
    }
    .logo-wrap img {
      width: 100%;
      height: 100%;
      object-fit: cover;
    }

    /* App Name & Main Title */
    .app-name {
      font-size: 22px;
      font-weight: 800;
      color: #F8FAFC;
      letter-spacing: -0.3px;
      margin-bottom: 4px;
    }
    .maglis-title {
      font-size: 15px;
      font-weight: 700;
      color: #10B981;
      margin-bottom: 14px;
    }

    /* 5-Digit Segmented Code Boxes (Matching _CodeBox in Natlu's MaglisEntryDialog) */
    .code-label {
      font-size: 12px;
      color: #64748B;
      font-weight: 600;
      margin-bottom: 8px;
    }
    .code-container {
      display: flex;
      justify-content: center;
      gap: 8px;
      direction: ltr; /* Keeps digits in natural order 0-9 */
      margin-bottom: 16px;
    }
    .code-digit {
      width: 46px;
      height: 52px;
      display: flex;
      align-items: center;
      justify-content: center;
      background: rgba(16, 185, 129, 0.08);
      border: 1px solid rgba(16, 185, 129, 0.35);
      border-radius: 12px;
      font-size: 28px;
      font-weight: 800;
      color: #10B981;
      box-shadow: inset 0 1px 3px rgba(16, 185, 129, 0.15);
      user-select: all;
    }

    .desc {
      font-size: 13.5px;
      color: #94A3B8;
      line-height: 1.6;
      margin-bottom: 22px;
      padding: 0 6px;
    }

    /* Actions Section - Strict Aligned Order */
    .actions-box {
      width: 100%;
      display: flex;
      flex-direction: column;
      gap: 12px;
    }

    /* 1. Main Action: OPEN IN APP (Dominant Hero Button) */
    .btn-main {
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 10px;
      width: 100%;
      height: 52px;
      background: linear-gradient(135deg, #10B981 0%, #059669 100%);
      color: #FFFFFF;
      font-size: 16px;
      font-weight: 800;
      text-decoration: none;
      border-radius: 14px;
      box-shadow: 0 6px 20px rgba(16, 185, 129, 0.38);
      transition: transform 0.12s ease, box-shadow 0.12s ease;
      border: none;
      cursor: pointer;
    }
    .btn-main:active {
      transform: scale(0.98);
      box-shadow: 0 3px 10px rgba(16, 185, 129, 0.3);
    }
    .btn-main svg {
      width: 22px;
      height: 22px;
      fill: currentColor;
    }

    /* Section divider */
    .divider {
      display: flex;
      align-items: center;
      text-align: center;
      color: #475569;
      font-size: 11px;
      font-weight: 600;
      margin: 4px 0;
    }
    .divider::before, .divider::after {
      content: '';
      flex: 1;
      border-bottom: 1px solid rgba(255, 255, 255, 0.08);
    }
    .divider::before { margin-left: 10px; }
    .divider::after { margin-right: 10px; }

    /* 2. Store Badges Row (Google Play & App Store Aligned Side-by-Side) */
    .store-row {
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 10px;
      width: 100%;
    }
    .store-badge {
      flex: 1;
      height: 48px;
      display: flex;
      align-items: center;
      justify-content: center;
      text-decoration: none;
      transition: transform 0.12s ease, opacity 0.12s ease;
      border-radius: 8px;
    }
    .store-badge img {
      width: 100%;
      height: 100%;
      object-fit: contain;
    }
    .store-badge:active {
      transform: scale(0.97);
      opacity: 0.9;
    }

    /* 3. Web App Button (Centered Below Store Badges) */
    .web-badge-wrap {
      width: 100%;
      display: flex;
      justify-content: center;
    }
    .web-badge {
      width: 180px;
      height: 48px;
      display: flex;
      align-items: center;
      justify-content: center;
      text-decoration: none;
      transition: transform 0.12s ease, opacity 0.12s ease;
      border-radius: 8px;
    }
    .web-badge img {
      width: 100%;
      height: 100%;
      object-fit: contain;
    }
    .web-badge:active {
      transform: scale(0.97);
      opacity: 0.9;
    }

    /* Footer / Helper Note */
    .footer-note {
      font-size: 11.5px;
      color: #475569;
      margin-top: 16px;
      line-height: 1.5;
    }
  </style>

  <script>
    const isAndroid = /android/i.test(navigator.userAgent);
    const targetUrl = isAndroid ? "${androidIntentUrl}" : "${appSchemeUrl}";

    function openApp() {
      window.location.href = targetUrl;
    }

    // Automatic Telegram-style handoff attempt on page load
    window.onload = function() {
      setTimeout(function() {
        try {
          window.location.href = targetUrl;
        } catch (_) {}
      }, 100);
    };
  </script>
</head>
<body>
  <div class="dialog-card">
    <!-- Top Drag Handle -->
    <div class="drag-handle"></div>

    <!-- Ayah Dedication -->
    <div class="ayah-top">و ما اسالكم عليه من اجر ان اجري الا على رب العالمين</div>

    <!-- App Logo -->
    <div class="logo-wrap">
      <img src="/icons/app_icon.png" alt="اتلو القران">
    </div>

    <!-- App Name & Maglis Title -->
    <div class="app-name">اتلو القران</div>
    <div class="maglis-title">مجلس تلاوة القرآن الكريم</div>

    <!-- Segmented 5-Digit Code Display -->
    <div class="code-label">رمز المجلس</div>
    <div class="code-container">
      <span class="code-digit">${code[0]}</span>
      <span class="code-digit">${code[1]}</span>
      <span class="code-digit">${code[2]}</span>
      <span class="code-digit">${code[3]}</span>
      <span class="code-digit">${code[4]}</span>
    </div>

    <p class="desc">انضم الآن إلى إخوانك في المجلس لتدارس القرآن الكريم والتلاوة التفاعلية المباشرة.</p>
    
    <div class="actions-box">
      <!-- 1. MAIN HERO BUTTON: Open in Natlu App -->
      <a href="#" onclick="openApp(); return false;" class="btn-main">
        <svg viewBox="0 0 24 24">
          <path d="M19 19H5V5h7V3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7h-2v7zM14 3v2h3.59l-9.83 9.83 1.41 1.41L19 6.41V10h2V3h-7z"/>
        </svg>
        <span>فتح في تطبيق اتلو القران</span>
      </a>

      <div class="divider">أو حمّل التطبيق مجاناً</div>

      <!-- 2. STORE BADGES (Google Play & App Store Aligned Side-by-Side) -->
      <div class="store-row">
        <a href="${playStoreUrl}" target="_blank" class="store-badge">
          <img src="/badges/google_play.svg" alt="Get it on Google Play">
        </a>
        <a href="${appStoreUrl}" target="_blank" class="store-badge">
          <img src="/badges/app_store.svg" alt="Download on the App Store">
        </a>
      </div>

      <!-- 3. WEB APP BUTTON (Centered directly below store badges) -->
      <div class="web-badge-wrap">
        <a href="${webAppUrl}" class="web-badge">
          <img src="/badges/web_app.svg" alt="Use it on Web">
        </a>
      </div>
    </div>

    <div class="footer-note">إذا كان التطبيق مثبتاً ولم يفتح تلقائياً، اضغط "فتح في تطبيق اتلو القران"</div>
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
