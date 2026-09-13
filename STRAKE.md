# Running this app under Strake (issue gregoreesmaa/strake#84)

This fork is **pristine upstream** [`electron/minimal-repro`](https://github.com/electron/minimal-repro)
plus this file — no app source was changed. It boots under
[Strake](https://github.com/gregoreesmaa/strake), the native Electron
alternative, via the drop-in `require('electron')` shim (slices #81–#83).

## Run it

```sh
# In a Strake checkout:
cargo run -rp strake-run -- --prove-ipc /path/to/strake-minimal-repro
```

Observed output (Strake `feat/84` branch, macOS/arm64, headless):

```text
app: minimal-repro (main: main.js)
main: ok, no JS errors
windows: 1
  #0 800x600 entry=/path/to/strake-minimal-repro/index.html
    title: Hello World!
    preload: /path/to/strake-minimal-repro/preload.js (ok)
ipc: round-trip reply "strake:pong" (pumped 1)
```

Exit status is 0 only when the boot, the main script, the preload, and the
IPC round-trip all succeed.

## What this proves

- `main.js` runs unmodified: `require('electron')` → `app`/`BrowserWindow`,
  `require('node:path')` (`path.join(__dirname, ...)`), `process.platform`
  guard, `app.whenReady()`, `BrowserWindow.getAllWindows()`.
- One 800x600 window is created; `index.html` first-paints through the DOM
  pipeline (`<title>Hello World!</title>` observed); `preload.js` executes
  cleanly in renderer scope (versions stamped into the page).
- One IPC round-trip settles: a harness-registered probe `ipcMain.handle`
  is invoked from the booted window's renderer via `ipcRenderer.invoke`
  (`strake:pong`, pumped 1). The app itself ships no IPC flow, so both probe
  endpoints are harness-driven — the handler, transport, and promise
  settlement are the app's own booted processes.

## Known gaps (follow-ups in gregoreesmaa/strake)

- **Headed open**: the boot is headless by design. Handing window #0 to a
  real OS surface (`ShellWindow::attach` on a live winit loop) still needs a
  display + eyeballs — tracked in
  [strake#131](https://github.com/gregoreesmaa/strake/issues/131).
  The exact winit attributes the handoff consumes are pinned by Slice 2
  tests, so this is verification, not new wiring.
- **DevTools**: `openDevTools()` stays commented out, as upstream.
- **Packaging**: `electron .` / installers are the packager epic
  ([strake#14](https://github.com/gregoreesmaa/strake/issues/14));
  `strake-run` is the `npm start` equivalent only.
