export async function onRequest(context) {
  const { params } = context;
  const rawCode = (params.code || '').trim();
  const code = rawCode.replace(/\D/g, '').slice(0, 5);

  if (code.length === 5) {
    return Response.redirect(`https://natlu.pages.dev/${code}`, 302);
  }
  return Response.redirect('https://natlu.pages.dev/', 302);
}
