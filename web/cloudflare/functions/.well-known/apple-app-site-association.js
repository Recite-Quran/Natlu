export async function onRequest() {
  const aasa = {
    "applinks": {
      "apps": [],
      "details": [
        {
          "appID": "ZKQ5264RUS.com.recitequran.app",
          "paths": ["/m/*", "/[0-9][0-9][0-9][0-9][0-9]"],
          "components": [
            {
              "/": "/m/*",
              "comment": "Natlu Maglis Room Code Deep Link (Prefixed)"
            },
            {
              "/": "/[0-9][0-9][0-9][0-9][0-9]",
              "comment": "Natlu Maglis Room Code Deep Link (Direct 5-digit)"
            }
          ]
        }
      ]
    }
  };

  return new Response(JSON.stringify(aasa), {
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
      "Cache-Control": "public, max-age=86400"
    }
  });
}

