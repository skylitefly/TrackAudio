# AGENTS.md — TrackAudio

Cross-platform **Audio-For-VATSIM (AFV) ATC voice client** (macOS, Linux,
Windows). A 3-layer Electron app with a C++ native (Node-API v7) backend. This
repo is a **Skylite fork** (`appId: com.skylitefly.trackaudio`, published to
`skylitefly/TrackAudio`, electron mirror `npmmirror.com`); upstream is
`pierr3/TrackAudio`.

**`CLAUDE.md` is the companion agent-guidance file with the same role as this
one. Keep the two consistent** — do not let them disagree on build order, store
names, or architecture.

```bash
# pnpm is enforced (npm/yarn fail via preinstall: npx only-allow pnpm)
git submodule update --init --recursive backend/vcpkg
git submodule update --init --recursive backend/extern/afv-native
git submodule update --init --recursive backend/extern/libuiohook
pnpm run build:backend   # C++ native module - MUST come before install
pnpm install
pnpm run dev
pnpm run lint; pnpm run format; pnpm run typecheck
```

Node `>=22.0.0 <=23.0.0`, Electron `>=41.0.0` (CI pins Node 22.x, pnpm v10).

## Build order (the single most important rule)

1. **Init the three submodules individually** under `backend/` — do **not** run
   a blanket `git submodule update --init --recursive` from the repo root. CI
   force-checks the branches: `afv-native` → `develop-trackaudio`,
   `libuiohook` → `unregister-hook-when-debugging`.
2. **`pnpm run build:backend` BEFORE `pnpm install`.** The renderer depends on
   `file:backend/trackaudio-afv-1.0.0.tgz`, which only exists after the backend
   is built and `npm pack`-ed. Reversing → unresolved native dependency.
3. Any C++ change requires re-running `build:backend` then `pnpm install`
   before `pnpm run dev`. Frontend-only changes need only `pnpm run dev`.

Variants: `build:backend-fast` (8-way parallel, `--fast`),
`build:backend-debug`. `backend/scripts/build-napi.js` deletes
`backend/build/`, then runs `cmake-js` (Ninja on Windows).

## Architecture (3 layers)

```
React UI (src/renderer/src/)  ↔ IPC via context bridge
Electron Main (src/main/)     ↔ direct N-API calls + callback registration
C++ Native Module (backend/)  ↔ afv-native SDK → VATSIM Voice Network
```

- **Main** (`src/main/index.ts` ~975 lines): window management (frameless
  `titleBarStyle: 'hidden'`, mini/maxi modes, always-on-top), all
  `ipcMain.handle`/`on` handlers, `electron-updater`, native-callback event
  router `handleEvent`. `config.ts` (`ConfigManager`, electron-store,
  `currentSettingsVersion = 4` + migration chain; defaults
  `defaultAfvApiUrl='https://voice1.vatsim.net'`,
  `defaultSlurperBaseUrl='https://slurper.vatsim.net'`).
- **Renderer** (`src/renderer/src/`): React 18 + TypeScript + Vite. Entry
  `app.tsx`. Path alias `@renderer/*`. Styling **Bootstrap 5 + SCSS +
  clsx + lucide-react**. No router — single-window desktop app.
- **C++ backend** (`backend/`): Node-API v7 addon built with **cmake-js**
  (not node-gyp; `runtime: electron`). Output `trackaudio-afv.node`, packed as
  `backend/trackaudio-afv-1.0.0.tgz`, consumed via
  `"trackaudio-afv": "file:backend/trackaudio-afv-1.0.0.tgz"`.

`backend/vcpkg.json` declares the C++ deps (cpp-httplib, poco+netssl+jwt,
node-addon-api, abseil, neargye-semver, openssl, restinio, nlohmann-json, plog,
platform-folders, sfml 2.6.1, simpleini, opus, speexdsp, cpp-jwt, msgpack,
curl). Pinned `builtin-baseline` + three `overrides`.

## pnpm / workspace rules

- `preinstall: npx only-allow pnpm` — npm/yarn are **blocked**.
- `pnpm-workspace.yaml`: `packages: ['!backend/']` — the backend is its **own**
  npm project (`backend/package.json`). Add C++-side JS deps in
  `backend/package.json`, never the root.
- `.npmrc`: `node-linker=hoisted` + an `allowBuilds` allowlist.
- The addon targets `napi_versions: [7]`, `cmake-js` runtime `electron` —
  rebuild against the Electron ABI, not Node's.

## Connection to afv-server-rs / slurper (runtime, not build)

Integration is **protocol-level**, not a source dependency:

- **AFV API server** (`voice1.vatsim.net` default) reached in C++ via the
  `afv-native` submodule (`afv_native::api::atcClient`); URL passed from main
  and user-configurable (Settings > Network).
- **Slurper** (`slurper.vatsim.net` default) polled by `RemoteData` on a Poco
  timer (`TIMER_CALLBACK_INTERVAL_SEC = 15`). `getSlurperData()` does
  `GET {slurperBaseUrl}/users/info/?cid=<cid>` (`SLURPER_DATA_ENDPOINT =
  "/users/info/"`). Response is the slurper CSV parsed by `parseSlurper()`.
  Both URLs configurable; slurper URL split into `slurperBaseUrl` +
  `slurperPathPrefix` so path-prefixed deployments work.
- **Slurper outage grace period**: first failure sets
  `enteredSlurperGracePeriod` and retries once; second marks
  `isSlurperAvailable=false` and notifies once. **Never feed empty slurper data
  into `parseSlurper`** — it returns false and causes a voice disconnect.

## Local SDK server

`backend/src/sdk.cpp` + `include/sdk.hpp` — RestinO HTTP + WebSocket server on
`0.0.0.0:49080` (`API_SERVER_PORT`). Routes `/transmitting`, `/rx`, `/tx`,
`/ws`. This is what the Elgato Stream Deck plugin and the EuroScope RDF plugin
talk to. Docs live in the GitHub wiki.

## State management — Zustand (4 stores in `src/renderer/src/store/`)

`radioStore.ts` (radios, selected-for-bulk-delete, PTT, unicom bar; reads via
`useRadioState.getState()` outside React), `sessionStore.ts` (connection,
callsign, network, version; default `frequency=199998000` = OBS),
`utilStore.ts` (VU meter, platform, PTT key names, edit mode, update channel
`'stable'|'beta'`), `errorStore.ts` (timestamped queue). **No Redux, no
Context for app state.**

The bridge between native events and stores is `interfaces/IPCInterface.ts`
(instantiated as a singleton, `init()` from `app.tsx`). It subscribes to every
`window.api.on(...)` channel and dispatches into stores; `destroy()` removes
every listener. **Always mirror new `on` registrations with a matching
`removeAllListeners` in `destroy()`.**

## TypeScript / React code style

- **Prettier** (`.prettierrc.yaml`): `singleQuote: true`, `printWidth: 100`,
  `trailingComma: none`. **EditorConfig**: 2-space, UTF-8, LF.
- **ESLint** (`eslint.config.mjs`): flat, `recommendedTypeChecked` +
  `stylisticTypeChecked` + `strictTypeChecked` from typescript-eslint, plus
  `eslint-plugin-react/recommended` (`react/react-in-jsx-scope: off`,
  `react.version: detect`). Type-aware lint uses both `tsconfig.web.json` and
  `tsconfig.node.json`. Lints `src/**/*.{tsx,ts,js,jsx}` only.
- Functional components typed `React.FC<Props>`, an `export interface Props`
  above the component, `clsx` for conditional classes, Bootstrap utility
  classes (`btn`, `btn-primary`, `d-flex`, `form-control`) over bespoke CSS,
  `useCallback`/`memo` for hot radio-row components, lucide-react icons
  `size={n}`.
- **IPC from renderer goes exclusively through `window.api.*`** (typed via
  `src/preload/index.d.ts` declaring `Window.api: API`). **Never import
  `electron` directly in renderer code.**
- tsconfig: project references — `tsconfig.json` references `tsconfig.node.json`
  (main+preload+shared) and `tsconfig.web.json` (renderer+shared). `strict`,
  `sourceMap`, `composite`. Web enables `jsx: react-jsx`, path alias
  `@renderer/*`.
- Comments cite specific GitHub issues (`// Issue 207`) explaining non-obvious
  platform workarounds — **preserve them**.

## Copywriting — **English throughout** (no Chinese)

Concise, user-facing, slightly informal in docs, clipped in UI:

- README: emoji bullets, warm tone, VATSIM domain jargon fluent.
- UI labels short and capitalized: `"Add a Station"`, `"Add"`, placeholder
  `"XXXX_XAXXX"`, radio controls `"RX"`,`"TX"`,`"XC"`,`"XCA"`,`"SPK"`,
  `"MANUAL"`/`"VOLUME"`.
- Error/toast messages full English sentences ending in a period, often with a
  remediation hint: `"Audio settings not set, please set all your audio
  devices correctly (Speakers, Microphone, Headset and API)"`,
  `"Invalid Credentials"`, `"Slurper is back online. You can now connect to
  the network."`, `"Callsign changed during an active session, you have been
  disconnected."`.
- Dialog buttons plain: `['OK']`, `['Yes', 'No']`; quit-confirm `"Are you sure
  you want to quit?"`.

## Native lifecycle & platform invariants (do not break)

- **`Exit()` follows a strict ordered shutdown** (`backend/src/main.cpp`): set
  `_requestExit` → stop/join VU meter thread → remove all EventBus handlers →
  reset subsystems in reverse creation order (inputHandler → remoteData →
  apiServer) → disconnect/stop audio → destroy `mClient`. Reorder = use-after-free.
- **`before-quit`** (`src/main/index.ts`) calls `Disconnect()` → `StopMicTest()`
  → `Exit()`, guarded by `isNativeExited` so it never runs twice. **Mic test
  must be stopped AFTER `Disconnect()`** (StopMicTest calls StopAudio;
  Disconnect still needs audio).
- VU meter thread capped at 2400 iterations, `Sleep(50)` on Windows
  (`std::this_thread::sleep_for` is "boinked on windows") — keep the workaround.
- **`headset` (native) vs `onSpeaker` (renderer) are logical opposites.**
  `newState.headset = !info[5]...`, `GetFrequencyState` returns
  `onSpeaker = !GetOnHeadset`. Same for `crossCoupleAcross`. Don't "fix" the
  asymmetry without changing both sides.
- **Frequencies are integers in Hz** (`122800000` = 122.800 MHz). Constants
  `UNICOM_FREQUENCY`, `GUARD_FREQUENCY`, `OBS_FREQUENCY 199998000`.
- **IPC event-queue invariant**: main buffers native events in `eventQueue`
  until the renderer signals `settings-ready` (`ipcMain.handle('settings-ready')`),
  triggered by the navbar `useEffect`. New renderers must not assume events
  arrive before `settings-ready`.
- Config versioning: TS `currentSettingsVersion = 4` but C++ `CONFIG_VERSION 1`
  — two **separate** persistence mechanisms (electron-store JSON for
  renderer/main; SimpleIni for PTT keys). Bumping the `Configuration` schema
  requires a migration step in `migrateConfig`.
- **Auto-updater is Windows-only and currently short-circuited** on non-Windows
  / unpackaged; `checkForUpdatesAndNotify` is commented out. Updater UI still
  ships for all platforms.
- `sandbox: false`; preload uses `contextBridge` only when
  `process.contextIsolated`.
- macOS needs Input Monitoring permission for keyboard PTT; Linux requires X11
  (Wayland unsupported); Windows needs VC++ Redistributable. Mini-mode width
  breakpoint `455` in `index.ts` must match `$mini-mode-width-breakpoint` in
  `style/variables.scss` — keep in sync.

## Tests

**No test suite** (`CLAUDE.md` states it). No `*.test.*`/`*.spec.*` files. CI
runs `pnpm run lint:check` + packaging build. Quality gates for an agent:
`pnpm run typecheck`, `pnpm run lint:check`, `pnpm run build`.

## Do-not edit / do-not list

1. No npm/yarn (pnpm enforced); Node must be `>=22 <=23`.
2. No blanket recursive submodule update — init the three backend submodules
   individually.
3. No reordering `build:backend` / `pnpm install` / `pnpm run dev`.
4. No direct renderer → `electron` imports — go through `window.api`.
5. Don't edit `backend/vcpkg/`, `backend/extern/afv-native/`,
   `backend/extern/libuiohook/` (submodules on tracked branches),
   `backend/trackaudio-afv-1.0.0.tgz` (build artifact), `out/`/`dist/`
   (build output), or `LICENSES_COMPILED.md` (generated, 246KB).
6. Don't reorder the native `Exit()` shutdown sequence.
7. Don't feed empty slurper data into `parseSlurper`.
8. `.cursorignore` excludes `backend/extern/`, `**/vcpkg/`, secrets,
   `node_modules`, build output — stay out of the giant `backend/vcpkg/` and
   `backend/extern/` trees.
