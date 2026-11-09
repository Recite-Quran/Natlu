export async function onRequest(context) {
  const { params } = context;
  const rawCode = (params.code || '').trim();
  const code = rawCode.replace(/\D/g, '').slice(0, 5);

  const title = code ? `مجلس تلاوة القرآن الكريم • رمز ${code}` : 'مجلس تلاوة القرآن الكريم - تطبيق اتلو القران';
  const desc = 'انضم الآن لتدارس القرآن الكريم والتلاوة الجماعية الحية عبر تطبيق اتلو القران.';
  const appSchemeUrl = code ? `natlu://maglis/${code}` : 'natlu://maglis';
  const playStoreUrl = 'https://play.google.com/store/apps/details?id=com.recitequran.app';
  const appStoreUrl = 'https://apps.apple.com/app/id6806614841';
  const webAppUrl = code ? `https://natlu.pages.dev/#/m/${code}` : 'https://natlu.pages.dev/';
  
  // Telegram-style Android Intent URI: forces native app launch or falls back to Play Store
  const androidIntentUrl = code
    ? `intent://maglis/${code}#Intent;scheme=natlu;package=com.recitequran.app;S.browser_fallback_url=https%3A%2F%2Fplay.google.com%2Fstore%2Fapps%2Fdetails%3Fid%3Dcom.recitequran.app;end`
    : 'natlu://maglis';

  const html = `<!DOCTYPE html>
<html lang="ar" dir="rtl">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${title}</title>
  
  <!-- Open Graph / WhatsApp / Telegram Preview Cards -->
  <meta property="og:type" content="website">
  <meta property="og:title" content="${title}">
  <meta property="og:description" content="${desc}">
  <meta property="og:image" content="https://natlu.pages.dev/ReciteQuran.png">
  <meta property="og:url" content="https://natlu.pages.dev/m/${code}">
  <meta name="twitter:card" content="summary_large_image">

  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Cairo", "Segoe UI", Roboto, sans-serif; }
    body { background: #0B0F19; color: #F8FAFC; display: flex; align-items: center; justify-content: center; min-height: 100vh; padding: 20px; text-align: center; }
    .card { background: #131B2E; border: 1px solid rgba(16, 185, 129, 0.25); border-radius: 24px; padding: 32px 24px; max-width: 420px; width: 100%; box-shadow: 0 20px 40px rgba(0,0,0,0.4); }
    .logo { width: 84px; height: 84px; border-radius: 20px; margin-bottom: 18px; box-shadow: 0 8px 20px rgba(16,185,129,0.2); }
    h1 { font-size: 20px; font-weight: 700; margin-bottom: 8px; color: #F8FAFC; }
    .badge { display: inline-block; background: rgba(16, 185, 129, 0.15); color: #10B981; border: 1px solid rgba(16, 185, 129, 0.3); padding: 6px 16px; border-radius: 12px; font-size: 24px; font-weight: 800; letter-spacing: 3px; margin: 12px 0 18px; }
    p { font-size: 14px; color: #94A3B8; line-height: 1.6; margin-bottom: 24px; }
    .btn { display: block; width: 100%; padding: 14px; border-radius: 14px; font-size: 15px; font-weight: 700; text-decoration: none; margin-bottom: 10px; transition: transform 0.1s ease; }
    .btn:active { transform: scale(0.98); }
    .btn-primary { background: #10B981; color: #FFFFFF; font-size: 16px; box-shadow: 0 4px 14px rgba(16,185,129,0.3); }
    .btn-secondary { background: rgba(255,255,255,0.06); color: #CBD5E1; border: 1px solid rgba(255,255,255,0.12); }
    .footer-note { font-size: 12px; color: #64748B; margin-top: 14px; }
  </style>

  <script>
    const isAndroid = /android/i.test(navigator.userAgent);
    const targetUrl = isAndroid ? "${androidIntentUrl}" : "${appSchemeUrl}";

    function openApp() {
      window.location.href = targetUrl;
    }

    // Telegram-style automatic handoff attempt on load
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
  <div class="card">
    <img src="https://natlu.pages.dev/ReciteQuran.png" alt="اتلو القران" class="logo">
    <h1>مجلس تلاوة القرآن الكريم</h1>
    <div class="badge">${code}</div>
    <p>انضم الآن إلى إخوانك في المجلس لتدارس القرآن الكريم والتلاوة التفاعلية المباشرة.</p>
    
    <!-- Telegram-Style "VIEW IN APP" Primary Action -->
    <a href="#" onclick="openApp(); return false;" class="btn btn-primary">فتح في تطبيق اتلو القران</a>
    
    <!-- Fallback options if app is not installed -->
    <a href="${playStoreUrl}" class="btn btn-secondary">تحميل من Google Play</a>
    <a href="${appStoreUrl}" class="btn btn-secondary">تحميل من App Store</a>
    <a href="${webAppUrl}" class="btn btn-secondary" style="font-size: 13px; color: #94A3B8;">المتابعة عبر الويب مباشرة</a>

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
