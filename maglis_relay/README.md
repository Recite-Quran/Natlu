# Quran Maglis — Edge Signaling Relay & Dynamic Fleet Config

This directory contains the private Cloudflare Worker signaling relay and dynamic fleet configuration for **Natlu Maglis P2P Quran Sessions**.

## Architecture Overview

```text
┌────────────────────────┐         WebSocket (wss://)         ┌────────────────────────┐
│   Natlu Mobile App     │ ◄────────────────────────────────► │  Cloudflare Worker     │
│   (WebRTC Peer Mesh)   │                                    │  (Durable Objects Edge)│
└───────────┬────────────┘                                    └────────────────────────┘
            │
            │ HTTP GET (with cached fallback)
            ▼
┌──────────────────────────────────────┐
│  maglis_config.json                  │
│  (Dynamic Nostr Relays & STUN/TURN)  │
└──────────────────────────────────────┘
```

1. **Sub-15ms Edge WebSockets**: Powered by Cloudflare Workers with modern SQLite-backed **Durable Objects** and WebSocket Hibernation (zero idle compute cost).
2. **Dynamic Fleet Configuration (`maglis_config.json`)**: Allows app maintainers to update Nostr relays and WebRTC ICE servers dynamically over GitHub without pushing new releases to Google Play.

---

## Files

- **`src/index.js`**: Cloudflare Worker script implementing the Nostr NIP-01 ephemeral signaling protocol with room isolation and tag-matching.
- **`wrangler.jsonc`**: Cloudflare deployment and SQLite Durable Object binding configuration.
- **`maglis_config.json`**: Dynamic fleet configuration (Relays, STUN/TURN servers) consumed by the mobile app.

---

## How to Deploy Your Own Relay

1. Install dependencies:
   ```bash
   npm install
   ```

2. Deploy directly to Cloudflare:
   ```bash
   npx wrangler deploy
   ```

3. Copy the published URL (e.g., `https://quran-maglis.<subdomain>.workers.dev`) and replace `https://` with `wss://` to use it as your primary WebSocket signaling relay.

---

## Updating Fleet Relays Remotely

To update or replace relays without releasing a new app update:
1. Edit `maglis_config.json` directly in this folder.
2. Commit and push to GitHub.
3. Mobile client apps will automatically fetch and cache the new list in the background on next startup.
