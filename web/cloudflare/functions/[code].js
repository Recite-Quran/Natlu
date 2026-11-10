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
  <link href="https://fonts.googleapis.com/css2?family=Cairo:wght@600;700;800;900&family=Plus+Jakarta+Sans:wght@700;800&display=swap" rel="stylesheet">

  <style>
    /* PURE LIGHT THEME — High-Contrast, Pristine, Balanced */
    :root {
      --bg: #F8FAF9;
      --card-bg: #FFFFFF;
      --card-border: #E8ECE8;
      --card-shadow: 0 4px 6px -1px rgba(15, 30, 20, 0.03), 0 24px 48px -12px rgba(15, 30, 20, 0.07);
      
      --text-hero: #0F172A;
      --text-sub: #475569;
      --text-muted: #64748B;
      
      --ayah-color: #64748B;
      
      --code-bg: #F4F6F4;
      --code-border: #E2E8E4;
      --digit-bg: #FFFFFF;
      --digit-border: #CBD8D0;
      --digit-color: #047857;
      
      --primary: #047857;
      --primary-hover: #065F46;
      --primary-active: #034D37;
      --primary-shadow: 0 8px 20px -4px rgba(4, 120, 87, 0.30);
      
      --btn-web-bg: #FFFFFF;
      --btn-web-border: #CBD5E1;
      --btn-web-text: #1E293B;
      --btn-web-hover: #F8FAFC;
    }

    * {
      box-sizing: border-box;
      margin: 0;
      padding: 0;
      -webkit-tap-highlight-color: transparent;
    }

    body {
      background-color: var(--bg);
      background-image: 
        radial-gradient(50% 40% at 50% 0%, rgba(4, 120, 87, 0.07) 0%, transparent 100%),
        radial-gradient(40% 30% at 50% 100%, rgba(13, 148, 136, 0.04) 0%, transparent 100%);
      color: var(--text-hero);
      min-height: 100vh;
      min-height: 100dvh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      padding: 24px 16px;
      font-family: "Cairo", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      text-align: center;
    }

    /* Floating Join Card */
    .meet-card {
      background: var(--card-bg);
      border: 1px solid var(--card-border);
      border-radius: 28px;
      padding: 30px 24px 26px;
      max-width: 380px;
      width: 100%;
      box-shadow: var(--card-shadow);
      display: flex;
      flex-direction: column;
      align-items: center;
      position: relative;
    }

    /* 1. Top Ayah (NO BRACKETS — Clean, Serene, Centered) */
    .ayah-text {
      font-size: 13px;
      font-weight: 600;
      color: var(--ayah-color);
      line-height: 1.5;
      margin-bottom: 20px;
      letter-spacing: 0.1px;
    }

    /* 2. Logo & App Identity (Centered Brand Block) */
    .app-brand {
      display: flex;
      flex-direction: column;
      align-items: center;
      margin-bottom: 16px;
    }

    .app-icon {
      width: 58px;
      height: 58px;
      border-radius: 16px;
      background: #FFFFFF;
      border: 1.5px solid var(--card-border);
      object-fit: cover;
      box-shadow: 0 4px 14px rgba(0, 0, 0, 0.06);
      margin-bottom: 8px;
    }

    .app-name-ar {
      font-size: 17px;
      font-weight: 900;
      color: var(--text-hero);
      line-height: 1.2;
    }

    .app-name-en {
      font-size: 12px;
      font-weight: 700;
      color: var(--text-muted);
      letter-spacing: 0.3px;
      margin-top: 2px;
    }

    /* 3. Room Title */
    .room-title {
      font-size: 21px;
      font-weight: 900;
      color: var(--text-hero);
      margin-bottom: 18px;
      letter-spacing: -0.2px;
      line-height: 1.3;
    }

    /* 4. Segmented 5-Digit Room Code */
    .code-container {
      width: 100%;
      display: flex;
      flex-direction: column;
      align-items: center;
      margin-bottom: 22px;
    }

    .code-pill {
      background: var(--code-bg);
      border: 1px solid var(--code-border);
      border-radius: 16px;
      padding: 6px 10px;
      display: inline-flex;
      align-items: center;
      gap: 7px;
      direction: ltr;
      cursor: pointer;
      transition: all 0.15s ease;
    }

    .code-pill:hover {
      background: #EAF0EC;
      border-color: #B8CDC0;
      transform: translateY(-1px);
    }

    .code-pill:active {
      transform: scale(0.98);
    }

    .digit {
      width: 44px;
      height: 50px;
      display: flex;
      align-items: center;
      justify-content: center;
      background: var(--digit-bg);
      border: 1.5px solid var(--digit-border);
      border-radius: 11px;
      font-family: "Plus Jakarta Sans", monospace;
      font-size: 25px;
      font-weight: 800;
      color: var(--digit-color);
      box-shadow: 0 1px 3px rgba(4, 120, 87, 0.05);
      user-select: all;
    }

    .code-label {
      margin-top: 6px;
      font-size: 11.5px;
      font-weight: 600;
      color: var(--text-muted);
      display: inline-flex;
      align-items: center;
      gap: 4px;
      cursor: pointer;
    }

    .code-label svg {
      width: 12px;
      height: 12px;
      fill: currentColor;
    }

    /* 5. Modern Action Buttons */
    .actions-box {
      width: 100%;
      display: flex;
      flex-direction: column;
      gap: 10px;
      margin-bottom: 20px;
    }

    /* Primary: Open in App */
    .btn-primary {
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 8px;
      width: 100%;
      height: 52px;
      background: linear-gradient(180deg, #058560 0%, #047857 100%);
      color: #FFFFFF;
      font-size: 16px;
      font-weight: 800;
      text-decoration: none;
      border-radius: 15px;
      border: none;
      box-shadow: var(--primary-shadow);
      cursor: pointer;
      transition: all 0.15s ease;
    }

    .btn-primary:hover {
      background: linear-gradient(180deg, #059669 0%, #058560 100%);
      transform: translateY(-1px);
    }

    .btn-primary:active {
      transform: scale(0.985);
      background: var(--primary-active);
    }

    .btn-primary svg {
      width: 19px;
      height: 19px;
      fill: currentColor;
    }

    /* Secondary: Continue on Web */
    .btn-secondary {
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 8px;
      width: 100%;
      height: 52px;
      background: var(--btn-web-bg);
      color: var(--btn-web-text);
      font-size: 15px;
      font-weight: 700;
      text-decoration: none;
      border-radius: 15px;
      border: 1.5px solid var(--btn-web-border);
      cursor: pointer;
      transition: all 0.15s ease;
    }

    .btn-secondary:hover {
      background: var(--btn-web-hover);
      border-color: #94A3B8;
      transform: translateY(-1px);
    }

    .btn-secondary:active {
      transform: scale(0.985);
      background: #F1F5F9;
    }

    .btn-secondary svg {
      width: 18px;
      height: 18px;
      fill: #047857;
    }

    /* 6. Store Badges (Google Play LEFT, App Store RIGHT) */
    .store-badges {
      width: 100%;
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 12px;
      direction: ltr; /* Keeps Google Play strictly on LEFT, App Store strictly on RIGHT */
    }

    .badge-link {
      flex: 1;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      text-decoration: none;
      transition: transform 0.12s ease, opacity 0.15s ease;
    }

    .badge-link:hover {
      opacity: 0.92;
      transform: translateY(-1px);
    }

    .badge-link:active {
      transform: scale(0.97);
    }

    .badge-link img {
      height: 40px;
      width: 100%;
      max-width: 148px;
      object-fit: contain;
      display: block;
      filter: drop-shadow(0 2px 4px rgba(0, 0, 0, 0.08));
    }

    /* Toast Notification for Copy */
    .toast {
      position: fixed;
      bottom: 24px;
      background: #0F172A;
      color: #FFFFFF;
      padding: 10px 20px;
      border-radius: 20px;
      font-size: 13.5px;
      font-weight: 700;
      box-shadow: 0 8px 24px rgba(0, 0, 0, 0.18);
      opacity: 0;
      pointer-events: none;
      transform: translateY(12px);
      transition: opacity 0.2s ease, transform 0.2s ease;
      z-index: 99;
    }

    .toast.show {
      opacity: 1;
      transform: translateY(0);
    }
  </style>

  <script>
    const isAndroid = /android/i.test(navigator.userAgent);
    const targetUrl = isAndroid ? "${androidIntentUrl}" : "${appSchemeUrl}";

    function openApp() {
      window.location.href = targetUrl;
    }

    function copyCode() {
      if (navigator.clipboard) {
        navigator.clipboard.writeText("${code}");
      }
      const toast = document.getElementById('toast');
      if (toast) {
        toast.classList.add('show');
        setTimeout(() => toast.classList.remove('show'), 2000);
      }
    }

    // Immediate app launch attempt on load
    try {
      window.location.href = targetUrl;
    } catch (_) {}
  </script>
</head>
<body>

  <div class="meet-card">
    <!-- 1. Top Ayah (NO BRACKETS) -->
    <div class="ayah-text">و ما اسالكم عليه من اجر ان اجري الا على رب العالمين</div>

    <!-- 2. Logo & App Branding (Clean Stacked) -->
    <div class="app-brand">
      <img src="/icons/app_icon.png" alt="Recite Quran" class="app-icon">
      <div class="app-name-ar">اتلو القران</div>
      <div class="app-name-en">Recite Quran</div>
    </div>

    <!-- 3. Room Title -->
    <div class="room-title">مجلس تلاوة القران العظيم</div>

    <!-- 4. Segmented 5-Digit Room Code -->
    <div class="code-container">
      <div class="code-pill" onclick="copyCode()" title="انقر لنسخ الرمز">
        <span class="digit">${code[0]}</span>
        <span class="digit">${code[1]}</span>
        <span class="digit">${code[2]}</span>
        <span class="digit">${code[3]}</span>
        <span class="digit">${code[4]}</span>
      </div>
      <div class="code-label" onclick="copyCode()">
        <svg viewBox="0 0 24 24"><path d="M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z"/></svg>
        <span>رمز المجلس • انقر للنسخ</span>
      </div>
    </div>

    <!-- 5. Modern Action Buttons -->
    <div class="actions-box">
      <!-- Primary: Open in App -->
      <a href="#" onclick="openApp(); return false;" class="btn-primary">
        <svg viewBox="0 0 24 24">
          <path d="M17 1.01L7 1c-1.1 0-2 .9-2 2v18c0 1.1.9 2 2 2h10c1.1 0 2-.9 2-2V3c0-1.1-.9-1.99-2-1.99zM17 19H7V5h10v14z"/>
        </svg>
        <span>فتح في التطبيق</span>
      </a>

      <!-- Secondary: Continue on Web (Matching form factor) -->
      <a href="${webAppUrl}" class="btn-secondary">
        <svg viewBox="0 0 24 24">
          <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/>
        </svg>
        <span>المتابعة عبر الويب</span>
      </a>
    </div>

    <!-- 6. Store Badges: Google Play on LEFT, App Store on RIGHT -->
    <div class="store-badges">
      <a href="${playStoreUrl}" target="_blank" class="badge-link">
        <img src="/badges/google_play.svg" alt="Google Play">
      </a>
      <a href="${appStoreUrl}" target="_blank" class="badge-link">
        <img src="/badges/app_store.svg" alt="App Store">
      </a>
    </div>
  </div>

  <div id="toast" class="toast">تم نسخ الرمز ${code}</div>

</body>
</html>`;

  return new Response(html, {
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'public, max-age=60',
    },
  });
}
