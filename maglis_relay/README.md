# Quran Maglis — Edge Signaling Relay & Dynamic Fleet Config

This directory contains the private Cloudflare Worker signaling relay and dynamic fleet configuration for **Natlu Maglis P2P Quran Recitation Sessions**.

---

## Architecture Overview

```text
┌───────────────────────────────────────┐         WebSocket (wss://)         ┌───────────────────────────────────────┐
│           Natlu Mobile App            │ ◄────────────────────────────────► │     Cloudflare Edge Worker (DO)       │
│        (WebRTC Audio & Data)          │                                    │  (quran-maglis.recitequrankarem...)   │
└──────────────────┬────────────────────┘                                    └───────────────────┬───────────────────┘
                   │                                                                             │
                   │ 1. HTTP GET /config (Sub-30ms Edge)                                        │
                   ├─────────────────────────────────────────────────────────────────────────────┘
                   │
                   │ 2. Fallback CDN / GitHub Raw (if Edge offline)
                   ▼
┌───────────────────────────────────────┐
│          maglis_config.json           │
│  (Dynamic Nostr Relays & STUN/TURN)   │
└───────────────────────────────────────┘
```

1. **Sub-15ms Edge WebSockets**: Powered by Cloudflare Workers with modern SQLite-backed **Durable Objects** and WebSocket Hibernation (zero idle compute cost).
2. **Dynamic Fleet Configuration (`/config`)**: Allows app maintainers to update Nostr relays and WebRTC ICE servers dynamically in the cloud without pushing new releases to Google Play.
3. **Multi-Tier Client Sync**:
   * **Tier 1 (Fastest)**: Cloudflare Worker endpoint `https://quran-maglis.recitequrankarem.workers.dev/config`.
   * **Tier 2 (Global CDN)**: jsDelivr CDN mirroring `maglis_config.json`.
   * **Tier 3 (Repository)**: Raw GitHub link to `maglis_config.json`.
   * **Tier 4 (Offline)**: Built-in hardcoded STUN servers (Google, Cloudflare, Twilio).

---

## Directory Structure

```text
maglis_relay/
├── src/
│   └── index.js            # Cloudflare Worker code (WebSocket relay + /config HTTP endpoint)
├── maglis_config.json      # Dynamic fleet config file (GitHub/CDN mirror)
├── package.json            # Worker dependencies (Wrangler)
├── wrangler.jsonc          # Cloudflare deployment & Durable Object binding
└── README.md               # This deployment and update guide
```

---

## How to Update the Configuration on Cloudflare

When you want to add/change Nostr WebSocket relays or add WebRTC STUN/TURN servers:

### Step 1: Edit the Configuration

There are two files to keep in sync:

1. **In `src/index.js`**:
   Open `src/index.js` and locate the `FLEET_CONFIG` object (around line 126):
   ```javascript
   const FLEET_CONFIG = {
     version: 3,
     updated_at: "2026-11-01",
     relays: [
       "wss://quran-maglis.recitequrankarem.workers.dev",
       "wss://relay.primal.net",
       "wss://nostr.mom",
       "wss://nos.lol",
       "wss://relay.damus.io",
       "wss://relay.snort.social",
       "wss://offchain.pub",
       "wss://nostr.bitcoiner.social"
     ],
     iceServers: [
       { urls: "stun:stun.l.google.com:19302" },
       { urls: "stun:stun1.l.google.com:19302" },
       { urls: "stun:stun2.l.google.com:19302" },
       { urls: "stun:stun3.l.google.com:19302" },
       { urls: "stun:stun4.l.google.com:19302" },
       { urls: "stun:stun.cloudflare.com:3478" },
       { urls: "stun:global.stun.twilio.com:3478" }
     ]
   };
   ```

2. **In `maglis_config.json`**:
   Keep `maglis_config.json` identical to `FLEET_CONFIG` so the CDN/GitHub fallbacks serve the exact same servers.

---

### Step 2: Adding TURN Servers in the Future (When You Have Credentials)

If you obtain dedicated TURN credentials (from Metered.ca, Cloudflare Calls, Twilio, Xirsys, or your own Coturn server), add them directly inside the `iceServers` array:

```javascript
iceServers: [
  // Fast public STUN servers for direct P2P connections:
  { urls: "stun:stun.l.google.com:19302" },
  { urls: "stun:stun.cloudflare.com:3478" },

  // Your TURN relay servers for strict cellular (4G/5G) symmetric NAT traversal:
  {
    urls: "turn:your-turn-domain.com:80?transport=udp",
    username: "YOUR_USERNAME",
    credential: "YOUR_PASSWORD"
  },
  {
    urls: "turn:your-turn-domain.com:443?transport=tcp",
    username: "YOUR_USERNAME",
    credential: "YOUR_PASSWORD"
  },
  {
    urls: "turns:your-turn-domain.com:443",
    username: "YOUR_USERNAME",
    credential: "YOUR_PASSWORD"
  }
]
```

> [!TIP]
> Always include both UDP and TCP (`?transport=tcp`) TURN endpoints. Mobile carriers that block or throttle UDP traffic will seamlessly fall back to TCP over port 443.

---

### Step 3: Deploy the Updated Config to Cloudflare

1. Open a terminal in the `maglis_relay` directory:
   ```bash
   cd maglis_relay
   ```

2. Install dependencies (if not already installed):
   ```bash
   npm install
   ```

3. Log in to Cloudflare (first time only):
   ```bash
   npx wrangler login
   ```

4. Deploy the Worker:
   ```bash
   npx wrangler deploy
   ```

   Wrangler will compile and deploy `src/index.js` and update your live worker in seconds:
   ```text
   Uploaded quran-maglis (0.50 sec)
   Deployed quran-maglis triggers (0.25 sec)
     https://quran-maglis.recitequrankarem.workers.dev
   Current Version ID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   ```

---

### Step 4: Verify the Live Deployment

Check that Cloudflare is serving your new configuration:

```bash
curl https://quran-maglis.recitequrankarem.workers.dev/config
```

Or open `https://quran-maglis.recitequrankarem.workers.dev/config` in any web browser. You should immediately see the JSON containing your updated `relays` and `iceServers`.

---

### Step 5: Commit to Git (Updates CDN & GitHub Fallback)

Commit and push `maglis_config.json` and `src/index.js` to GitHub:
```bash
git add maglis_relay/
git commit -m "Update Maglis fleet configuration"
git push
```

---

## How Natlu Client Apps Consume This

1. **Automatic Startup Sync**: Every time Natlu starts or enters a Maglis session, `syncRemoteConfig()` queries `https://quran-maglis.recitequrankarem.workers.dev/config` in a non-blocking background task.
2. **Local Caching**: The fetched relays and ICE configuration are saved to `SharedPreferences` (`maglis_cached_relays`, `maglis_cached_rtc`).
3. **Instant Zero-Update Fleet Migrations**: If a Nostr relay goes down or you change TURN providers, updating Cloudflare immediately updates all mobile devices worldwide on their next app open.
