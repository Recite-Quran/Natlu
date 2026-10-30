import { DurableObject } from "cloudflare:workers";

/**
 * Natlu Maglis Private Signaling Relay
 * Ultra-fast sub-15ms edge signaling, 100% Free, zero idle compute cost.
 */
export class MaglisRelay extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
  }

  async fetch(request) {
    const webSocketPair = new WebSocketPair();
    const [client, server] = Object.values(webSocketPair);

    // Accept using Hibernation API (zero cost/compute while connected)
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ subs: {} });

    return new Response(null, {
      status: 101,
      webSocket: client,
    });
  }

  async webSocketMessage(ws, message) {
    try {
      const data = JSON.parse(message);
      if (!Array.isArray(data) || data.length < 2) return;

      const type = data[0];
      const attachment = ws.deserializeAttachment() || { subs: {} };

      if (type === "REQ") {
        const subId = data[1];
        const filter = data[2] || {};
        const tags = filter["#t"] || [];
        attachment.subs[subId] = Array.isArray(tags) ? tags : [tags];
        ws.serializeAttachment(attachment);
      } else if (type === "CLOSE") {
        const subId = data[1];
        delete attachment.subs[subId];
        ws.serializeAttachment(attachment);
      } else if (type === "EVENT") {
        const event = data[1];
        if (!event || !Array.isArray(event.tags)) return;

        // Extract #t tags
        const eventTags = new Set(
          event.tags.filter(t => Array.isArray(t) && t[0] === "t").map(t => t[1])
        );
        if (eventTags.size === 0) return;

        // Relay immediately to all matching peers in the room
        for (const peer of this.ctx.getWebSockets()) {
          if (peer === ws || peer.readyState !== WebSocket.READY_STATE_OPEN) continue;
          const peerAttachment = peer.deserializeAttachment();
          if (!peerAttachment || !peerAttachment.subs) continue;

          for (const [subId, subscribedTags] of Object.entries(peerAttachment.subs)) {
            const hasMatch = subscribedTags.some(t => eventTags.has(t));
            if (hasMatch) {
              try {
                peer.send(JSON.stringify(["EVENT", subId, event]));
              } catch (_) {}
              break;
            }
          }
        }
      }
    } catch (_) {}
  }

  async webSocketClose(ws, code, reason, wasClean) {}
  async webSocketError(ws, error) {
    try { ws.close(1011, "WebSocket error"); } catch (_) {}
  }
}

export default {
  async fetch(request, env) {
    if (request.headers.get("Upgrade") === "websocket") {
      const id = env.RELAY.idFromName("maglis-global");
      const stub = env.RELAY.get(id);
      return stub.fetch(request);
    }

    return new Response(
      JSON.stringify({
        status: "online",
        relay: "Quran Maglis Private Edge Relay",
        version: "2.0.0",
        timestamp: Date.now(),
      }),
      {
        headers: {
          "Content-Type": "application/json",
          "Access-Control-Allow-Origin": "*",
        },
      }
    );
  },
};
