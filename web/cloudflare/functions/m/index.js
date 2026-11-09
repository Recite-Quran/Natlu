export async function onRequest(context) {
  const { request } = context;
  const url = new URL(request.url);
  const code = (url.searchParams.get('m') || url.searchParams.get('code') || '').trim().replace(/\D/g, '').slice(0, 5);

  if (code) {
    return Response.redirect(`https://natlu.pages.dev/m/${code}`, 302);
  }

  return Response.redirect('https://natlu.pages.dev/', 302);
}

