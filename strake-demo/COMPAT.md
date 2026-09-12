# COMPAT.md — electron/minimal-repro (ex electron-quick-start) on strake

Tier-1 trivial demo: official Electron sample, single window, **zero IPC**.
Fork: `gregoreesmaa/minimal-repro`, branch `strake-demo`.
Run: `sh strake-demo/RUN.sh` (phase 1: node only, no `npm install`).

Strake rev referenced: `68d22d7b` (worktree, read-only; checkout not modified).
Coverage source: `packages/strake-electron-compat/src/coverage.rs` TOP50 freeze
plus direct reads of `app.rs` / `window.rs` / `ipc.rs`,
`packages/strake-vibey-script/src/{runtime,document,dom/*}.rs`.

## Result

`main.js` boots to ready headless: `app.whenReady` resolves, exactly one
800x600 window is created, `loadFile('index.html')` is recorded, `activate`
re-creates a window from zero, and `window-all-closed` quits (non-darwin) —
verified by `RUN.sh` phase 1b against a stub whose semantics mirror
`strake-electron-compat` 1:1. No headless boot blockers in `main.js`;
remaining gaps are all outside the main-process boot path (preload sandbox,
real pixels, `process` global, `innerText`).

## API-by-API

Statuses: **native** = maps onto an existing strake primitive;
**shim** = implemented by `strake-electron-compat`;
**deferred** = out of MVP scope, blocker named.

### main.js (main process)

| Electron API | Status | Strake counterpart / blocker |
|---|---|---|
| `require('electron')` (CJS) | deferred | vibey-script evaluates classic + ES-module scripts only; no CommonJS loader. Main-process bootstrap binds via the planned TS shim onto the compat core (`strake-electron-compat/src/lib.rs`) |
| `app.whenReady()` | shim | `App::mark_ready` / `on(Ready)` |
| `app.on('activate'/'window-all-closed')` | shim | `App::on(Activate/WindowAllClosed)` |
| `app.quit()` | shim | `App::quit` (`before-quit` then `will-quit`; quits on last-window-close unless macOS-style opt-out, matching `main.js`) |
| `new BrowserWindow({width:800,height:600})` | shim | `WindowManager::create` + `BrowserWindowOptions` (800x600 are the Electron defaults, preserved) |
| `webPreferences.preload` | deferred | needs #18 N-API preload sandbox (TOP50 entry verbatim) |
| `win.loadFile('index.html')` | shim | `WebContents::load_file` (relative-path → `file://` URL, percent-encoded) |
| `BrowserWindow.getAllWindows().length` | shim (shape note) | `WindowManager::window_count` (count only; no window list yet) |
| `webContents.openDevTools` (commented out in source) | deferred | devtools UI (TOP50 entry verbatim) |
| real OS window / pixels | deferred | compat core is deliberately headless; `strake-shell`/`winit` binding is a follow-up (`lib.rs` docs) |
| `ipcMain` / `ipcRenderer` | n/a (app uses none) | `IpcBus::{handle,invoke,on,send}` shim available if IPC is added later |
| `require('node:path')` | native | host Node in this harness; strake packs app files via its own base-URL/file resolution (`ScriptDocument` base_url) |

### preload.js (preload)

| API | Status | Note |
|---|---|---|
| preload sandbox / `contextBridge` | deferred | needs #18 N-API preload sandbox |
| `window` global | renderer-native | vibey-script registers `window` as the global object (`runtime.rs`) |
| `window.addEventListener('DOMContentLoaded')` | partial | `ScriptDocument::execute_scripts` dispatches `DOMContentLoaded` to the document (`document.rs`); window-targeted delivery of that dispatch is unverified |
| `document.getElementById` | renderer-native | implemented (`dom/document.rs`) |
| `element.innerText` | deferred (gap) | vibey-script implements `textContent` only (`dom/node.rs`); no `innerText` found in `strake-vibey-script/src` |
| `process.versions.{chrome,node,electron}` | deferred (gap) | no `process` global in vibey-script renderer globals; version strings would come from the embedder |

### renderer.js / index.html

`renderer.js` is an empty comment block: trivially compatible. `index.html`
is static markup + one `<script src>`; loadable via
`ScriptDocument::from_html` + `execute_scripts()` (the `preact_script`
example pattern). Not executed in `RUN.sh` phase 1 because the boot target
is `main.js`; renderer execution is covered by the vibey-script conformance
suite (`tests/event_loop.rs`, `dom.rs`).

## Key gaps (ordered by what blocks a real strake boot)

1. **Preload sandbox (#18)** — `webPreferences.preload` + `contextBridge`
   isolation have no strake binding; preload currently cannot run.
2. **Main-process JS bootstrap** — no CommonJS `require('electron')`
   loader; needs the TS shim binding onto `App`/`WindowManager`/`IpcBus`.
3. **`process` global + `innerText`** — two small renderer gaps that keep
   `preload.js` from running even inside an un-sandboxed `ScriptDocument`.
4. **Real window (`strake-shell`)** — headless lifecycle is fully modeled;
   pixels are a follow-up, not a boot blocker.
