# Online multiplayer in the browser build

Status: plan. Companion to [web-port.md](web-port.md). Today the browser
build says "Online play needs the desktop or mobile app"
(`src/import/online/Home.lua`, `OnlinePanel.connect` refuses on Web).

## Goal

Browser players use the same lobby, rooms, battles, trades, spectating and
tournaments as desktop players, on the same relay, at the same protocol
version. Desktop and mobile clients must not need to change.

## How online play works today

- **Layers.** UI (`src/import/OnlinePanel.lua`, `src/import/online/*`) calls
  `src/online/Connect.lua` (name, optional ticket, connect). That drives
  `src/online/Client.lua`, the one process-wide connection (lobby, rooms,
  tournaments, invites, plaza, groups, resume). Messages go through
  `src/link/Session.lua` to a transport. The only transport today is
  `src/link/Net.lua`, using luasocket TCP.
- **Polled, single-threaded.** `main.lua` calls `Connect.update` and
  `Client.update` every frame. There are no threads or coroutines, which suits
  the browser.
- **One connection carries everything.** Gen 1/2 link battles
  (`LinkBattle.lua`), trades (`src/online/Trade.lua`) and Gen 3
  (`src/core/game3/link/relay_transport.lua`, union room, minigames) all run
  over `Client.roomSession()`.
- **The transport is already injectable.** `Client.configure{ connect = fn }`
  (`Client.lua:1171`) takes `fn(relayAddress)` returning a transport, or
  `nil, err`. Session requires four methods (`Session.lua:8`):
  - `update()`, called once per frame
  - `poll()`, which returns the decoded messages received since the last call
  - `send(tbl)`, which takes a Lua table; the transport does the encoding
  - `close()`

  It also reads `.closed` and `.error`. Tests already inject fake transports
  (`tests/online_client.lua`, `tests/g3link_fake_relay.lua`). Nothing in
  `src/` uses the hook yet.
- **Wire protocol.** Newline-delimited JSON over plain TCP to
  `relay.gen1re.com:7778` (`Net.lua:38`):
  - **Size caps:** 256 KB per line, 512 KB read per frame.
  - **Handshake:** `lobby_hello` → `lobby_welcome` (`Protocol2.lua`,
    `PROTOCOL=3`).
  - **Resume:** `resume {session, ack}` with a two-minute seat hold and a
    replay log.
  - **Heartbeat:** owned by the transport (`Net.lua:284-335`). It answers
    `ping` with `pong` and sends its own `ping` every 10 s, dropping the
    connection after 3 misses. The relay drops idle connections after 60 s.
- **Identity.** Optional. `POST /lobby/ticket` on the sync server
  (`SyncClient.lua`) returns a single-use, 60-second ticket, authenticated
  with `x-sync-account` / `x-sync-token` headers. There is no request
  signing. Without a ticket a player joins as a guest (`verified:false`).
- **TLS.** The relay is plaintext TCP (`docs/link-security.md`).
  `src/net/Gen1Tls.lua` (LuaJIT FFI) is used by the mod sandbox, not by
  `Client`.
- **Server.** The relay is Node, in a separate repository (`pokeserver`), with
  the sync/ticket HTTP server in the same process. It has no WebSocket
  endpoint today. That repository is not available to this session.

### Latency tolerance

Link battles are message-level lockstep, not byte-level cable emulation. Each
side simulates the battle from a seed the host deals, and they exchange
per-turn actions and state hashes (`LinkBattle.lua:1-15`). That tolerates
WebSocket latency well.

The sensitive parts are:
- the tournament shot clock
- relay deadlines
- Gen 3's real-time minigames (Berry Crush, Dodrio Berry Picking, Pokémon
  Jump)

## What blocks the browser

| Blocker | Why | Fix |
| --- | --- | --- |
| No raw TCP in a page | `Net.lua` needs luasocket TCP | A WebSocket transport (below) |
| An https page can't open `ws://` | Mixed-content rules | The relay must be reachable over `wss://` |
| Relay speaks TCP only | No WS listener in pokeserver | Add a WS endpoint (below) |
| Ticket/sync over `fetch()` needs CORS | `POST` with `x-sync-*` headers triggers a preflight | CORS on the sync server for the site's origin |
| Background tabs throttle timers | The relay drops idle connections after 60 s | Heartbeat from the page and resume on return (below) |
| LAN link (ENet/UDP), Discord, Gen1Tls | Native only | Hide them on Web; online play doesn't need them |

The fetch side already works in the browser. `src/net/Fetch.lua` has a web
transport, so tickets and save sync need only CORS.

## Architecture decision: a WebSocket JSON transport

**Recommended: one JSON message per WebSocket text frame, through a small
bridge.**

- The page gains `wsOpen` / `wsSend` / `wsPoll` / `wsState` / `wsClose` in
  `ports/web/native/lovejs_bridge.cpp`, with a per-connection inbox, polled
  every frame the way `fetchPoll` is.
- `src/net/WsTransport.lua` implements Session's four methods on top of
  that bridge:
  - JSON-encodes on `send` and decodes in `poll`.
  - Answers `ping` and sends its own heartbeat, mirroring `Net`.
  - Queues an outbox before the socket opens.
  - Latches `.closed` / `.error`.
- On Web, `Connect` calls `Client.configure{ connect = WsTransport.open }`.
  Nothing above Session changes.

**Considered: websockify plus Emscripten SOCKFS.** The love.js build already
contains luasocket and Emscripten's socket emulation. A `tcp:connect` there
becomes `new WebSocket(url, "binary")` carrying a raw byte stream, so
`Net.lua` could run unchanged behind a websockify-style bridge in front of
port 7778. It is attractive for a quick spike, but:
- emulated non-blocking `connect`/`select` under luasocket is unverified
- hostnames resolve to fake addresses
- `Net`'s blocking fallback can't block in a page
- debugging a byte stream inside an emulated socket is harder than reading
  JSON frames

Use it only to prove the relay path end to end before the real transport
lands.

**Server side (pokeserver).**
- Add a WebSocket listener, e.g. `/ws` on the HTTPS host, so the existing TLS
  terminator provides `wss://`. Each text frame is one protocol line, fed to
  the same handler the TCP listener uses, with the same caps.
- Same protocol version. Clients announce `platform = "web"` (the field
  exists and is unset today) so the relay can tell them apart.
- Check `Origin` against an allowlist of the sites hosting the page.

## Plan

### Phase 0: decisions (owner: project)
- Where the page is hosted: GitHub Pages, gen1re.com or elsewhere. This
  decides the `Origin` and CORS allowlists.
- Whether `relay.gen1re.com` already has a TLS terminator (Caddy or nginx in
  front of the sync port) that can also proxy `wss://` to a relay WS
  listener.
- Whether guest-only play on Web is acceptable at first, if sync CORS lands
  later.

### Phase 1: client transport (this repo), medium
- **Bridge.** WebSocket functions in `lovejs_bridge.cpp`: open with a URL,
  send a text frame, poll an inbox (drained per call, with a byte cap),
  report state and close code/reason, close. Rebuild love.js.
- **`src/net/WsTransport.lua`.**
  - Session's interface, using the JSON codec `Net` uses, and the same
    256 KB per-message cap.
  - Ping/pong and a 10 s heartbeat, with `.error` after 3 misses.
  - An outbox flushed on open.
- **Relay URL.** A `wss://` default for Web, overridable by a page query
  parameter (browsers have no environment variables), passed in as
  `Connect.setRelayAddress`.
- **Tests (fake-bridge style, like `tests/engine/fetch_web_transport_test.lua`):**
  - framing and message cap
  - ping/pong and heartbeat timeout
  - open/close/error states
  - outbox before open
  - `Client` driving `WsTransport` through the existing fake relay
- **Gate.** Add the suite to `scripts/ci/lua51_compat.sh`.

### Phase 2: relay endpoint (pokeserver), medium
- A WebSocket listener sharing the line handler, behind `wss://`, with an
  `Origin` allowlist and the same caps, heartbeat and resume.
- A local harness: the relay's own tests plus this repo's
  `tests/drivers/online_*_smoke.lua`, pointed at the WS endpoint.

### Phase 3: unblock the UI (this repo), small
- Remove the Web refusals (`OnlinePanel.connect`/`doConnect`, `Home.lua`
  note) when the transport is available. Keep them when it isn't (e.g. an old
  love.js without the bridge functions).
- Hide LAN link and Discord rows on Web.
- Tickets through `Fetch` once the sync server sends CORS. Until then,
  connect as a guest with a clear "not verified on the web yet" note.

### Phase 4: page lifecycle, small–medium
- **Hidden tab.** On `visibilitychange` to hidden, keep the heartbeat on a JS
  timer: rAF stops, so Lua can't send it. Background timers are throttled to
  about once a minute in some browsers, so expect a resume on return rather
  than relying on staying seated.
- **Return.** On `visible`, run the existing `resume {session, ack}` path.
  Most of it already exists.
- **Unload.** On `beforeunload` / `pagehide`, send a leave.

### Phase 5: verification and performance, medium
- **Cross-platform matches.** Browser against desktop for Gen 1 and Gen 2
  link battles, trades, spectating and a tournament match on the shot
  clock.
- **Gen 3.** Union room and one real-time minigame, to measure added latency
  over WebSocket.
- **PUC Lua cost.** Arena boot and battle fingerprint/hash on PUC Lua
  (`ArenaData`): the same main-thread budget work as web-port Phase 3.
- **CI.** A browser smoke against a local relay, if pokeserver can run in
  CI.

## Risks and open questions

- **Relay and sync hosting.** The relay and sync server share one process and
  host, so the WS listener and its TLS sit there too. That needs
  pokeserver's maintainers.
- **Background-tab disconnects** are unavoidable in some browsers. Resume
  covers short absences; a long one rejoins as a new session.
- **Cheating surface.** Web clients are as trusted as desktop clients: the
  relay already doesn't trust client state beyond lockstep hashes. Giving
  them a distinct `platform` value lets the relay apply limits if needed.
- **Mixed versions.** A WS endpoint at the same protocol version needs no
  client upgrade for desktop. The relay's `upgrade_required` path still
  covers web clients that fall behind (the page is replaced on deploy, so
  this should be rare).
