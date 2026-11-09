export async function onRequest() {
  const aasa = {
    "applinks": {
      "apps": [],
      "details": [
        {
          "appID": "ZKQ5264RUS.com.recitequran.app",
          "paths": ["/m/*"],
          "components": [
            {
              "/": "/m/*",
              "comment": "Natlu Maglis Room Code Deep Link"
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

