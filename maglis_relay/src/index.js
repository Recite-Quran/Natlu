import { DurableObject } from "cloudflare:workers";

/**
 * Natlu Maglis Production Edge Signaling Relay
 * - Isolated Durable Object per room code (O(1) peer lookup, sub-10ms edge distribution)
 * - WebSocket Hibernation API (zero idle compute cost)
 * - Memory bounds (max 64 KB message size, max 10 subscriptions per peer)
 * - Rate limiting (max 60 msgs/sec per peer)
 */
export class MaglisRelay extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.ctx = ctx;
  }

  async fetch(request) {
    const webSocketPair = new WebSocketPair();
    const [client, server] = Object.values(webSocketPair);

    // Accept server socket using Hibernation API
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({
      subs: {},
      msgCount: 0,
      lastReset: Date.now(),
    });

    return new Response(null, {
      status: 101,
      webSocket: client,
    });
  }

  async webSocketMessage(ws, message) {
    try {
      // 1. Guard payload size against memory/DoS attacks (max 64 KB)
      if (typeof message === "string" && message.length > 65536) {
        try { ws.close(1009, "Payload too large"); } catch (_) {}
        return;
      }

      // 2. Sliding rate limiting (max 60 messages/sec per connection)
      const now = Date.now();
      const attachment = ws.deserializeAttachment() || {
        subs: {},
        msgCount: 0,
        lastReset: now,
      };

      if (now - attachment.lastReset > 1000) {
        attachment.msgCount = 0;
        attachment.lastReset = now;
      }
      attachment.msgCount++;
      if (attachment.msgCount > 60) {
        return; // Drop excess packets silently
      }

      const data = JSON.parse(message);
      if (!Array.isArray(data) || data.length < 2) return;

      const type = data[0];

      if (type === "REQ") {
        const subId = String(data[1]).substring(0, 48);
        const filter = data[2] || {};
        const tags = filter["#t"] || [];

        // Cap active subscriptions per socket to 10
        if (Object.keys(attachment.subs).length < 10) {
          attachment.subs[subId] = Array.isArray(tags)
            ? tags.map((t) => String(t).substring(0, 64))
            : [String(tags).substring(0, 64)];
          ws.serializeAttachment(attachment);
        }
      } else if (type === "CLOSE") {
        const subId = String(data[1]);
        delete attachment.subs[subId];
        ws.serializeAttachment(attachment);
      } else if (type === "EVENT") {
        const event = data[1];
        if (!event || !Array.isArray(event.tags)) return;

        // Extract #t tags
        const eventTags = new Set(
          event.tags
            .filter((t) => Array.isArray(t) && t[0] === "t")
            .map((t) => t[1])
        );
        if (eventTags.size === 0) return;

        // Broadcast ONLY within this room's isolated peer pool (2-4 peers)
        for (const peer of this.ctx.getWebSockets()) {
          if (peer === ws || peer.readyState !== WebSocket.READY_STATE_OPEN) {
            continue;
          }
          const peerAttachment = peer.deserializeAttachment();
          if (!peerAttachment?.subs) continue;

          for (const [subId, subscribedTags] of Object.entries(
            peerAttachment.subs
          )) {
            if (subscribedTags.some((t) => eventTags.has(t))) {
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

  async webSocketClose(ws, code, reason, wasClean) {
    try { ws.close(); } catch (_) {}
  }

  async webSocketError(ws, error) {
    try { ws.close(1011, "WebSocket error"); } catch (_) {}
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.headers.get("Upgrade") === "websocket") {
      // Extract room identifier from query param ?room=12345 or path /room/12345
      let room = url.searchParams.get("room");
      if (!room) {
        const segments = url.pathname.split("/").filter(Boolean);
        if (segments.length >= 2 && segments[0] === "room") {
          room = segments[1];
        }
      }

      const cleanRoom = (room || "default")
        .trim()
        .toLowerCase()
        .substring(0, 48);

      // Route to an isolated Durable Object per room code
      const id = env.RELAY.idFromName(`maglis_room_${cleanRoom}`);
      const stub = env.RELAY.get(id);
      return stub.fetch(request);
    }

    return new Response(
      JSON.stringify({
        status: "online",
        relay: "Quran Maglis Production Edge Relay",
        version: "2.1.0",
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
