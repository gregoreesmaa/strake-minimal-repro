#!/bin/sh
# strake-demo headless boot — Tier-1 trivial (electron/minimal-repro).
#
# Boots the app's main.js to "ready" headlessly and verifies the full
# single-window lifecycle. No `npm install`, no Electron download, no
# display server: `require('electron')` is satisfied by a stub whose
# semantics mirror strake-electron-compat 1:1 (App state machine +
# WindowManager + WebContents::load_file). The stub is the executable
# form of strake-demo/COMPAT.md's Shimmed rows.
#
# Usage:
#   sh strake-demo/RUN.sh                  # phase 1 only (node >= 18)
#   STRAKE_CHECKOUT=/path/to/strake sh strake-demo/RUN.sh   # + phase 2
#
# Exit 0 when main.js boots to ready and the lifecycle assertions hold.
# Phase 2 (live strake primitives) is best-effort and advisory only.
set -eu

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="${TMPDIR:-/tmp}/strake-tier1-boot-$$"
mkdir -p "$TMPDIR/node_modules/electron"
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

command -v node >/dev/null 2>&1 || {
  echo "FAIL: node is required (https://nodejs.org), not found on PATH" >&2
  exit 1
}

# --- Phase 1a: static surface check (which Electron APIs does main.js use?) ---
echo "== phase 1a: static surface =="
node -e '
const fs = require("node:fs");
const src = fs.readFileSync(process.argv[1], "utf8");
const uses = {
  "app.whenReady": /app\.whenReady\(\)/,
  "new BrowserWindow": /new BrowserWindow\(/,
  "webPreferences.preload": /webPreferences/,
  "win.loadFile": /\.loadFile\(/,
  "BrowserWindow.getAllWindows": /getAllWindows\(\)/,
  "app.on(activate)": /on\(.activate./,
  "app.on(window-all-closed)": /on\(.window-all-closed./,
  "app.quit": /app\.quit\(\)/,
  "ipcMain/ipcRenderer": /ipcMain|ipcRenderer/,
};
let failed = false;
for (const [name, re] of Object.entries(uses)) {
  const hit = re.test(src);
  const want = name !== "ipcMain/ipcRenderer"; // trivial tier: must have zero IPC
  const ok = name === "ipcMain/ipcRenderer" ? !hit : hit;
  console.log(`  ${ok ? "ok  " : "FAIL"} ${name}: ${hit ? "used" : "absent"}`);
  if (!ok) failed = true;
}
if (failed) { console.error("FAIL: unexpected API surface"); process.exit(1); }
' "$APP_ROOT/main.js"

# --- Phase 1b: headless boot of main.js against the strake-semantics stub ---
echo "== phase 1b: headless boot to ready =="

# Minimal `electron` stub. Semantics mirror strake-electron-compat:
# App::mark_ready/on(Ready), App::quit, WindowManager::create/window_count,
# WebContents::load_file. Anything main.js calls outside this surface throws,
# so new API usage fails loudly instead of passing silently.
cat > "$TMPDIR/node_modules/electron/package.json" <<'EOF'
{"name":"electron","version":"0.0.0-strake-stub","main":"index.js"}
EOF
cat > "$TMPDIR/node_modules/electron/index.js" <<'EOF'
"use strict";
// Headless `electron` stub with strake-electron-compat semantics.
const listeners = new Map(); // event -> [fn]  (App::on)
let ready = false;           // App::mark_ready
let quitCalled = false;      // App::quit
const windows = [];          // WindowManager

const app = {
  whenReady() { // App::mark_ready/on(Ready)
    return new Promise((resolve) => {
      queueMicrotask(() => {
        ready = true;
        for (const fn of listeners.get("ready") ?? []) fn();
        resolve();
      });
    });
  },
  on(event, fn) {
    if (!listeners.has(event)) listeners.set(event, []);
    listeners.get(event).push(fn);
    return app;
  },
  quit() { quitCalled = true; }, // App::quit
  __emit(event, ...args) { for (const fn of listeners.get(event) ?? []) fn(...args); },
  __isReady: () => ready,
  __quitCalled: () => quitCalled,
  __windowCount: () => windows.length,
};

class BrowserWindow { // WindowManager::create + BrowserWindowOptions
  constructor(opts = {}) {
    this.__opts = { width: 800, height: 600, show: true, ...opts }; // Electron defaults
    this.__loadFileTarget = null;   // WebContents::load_file pending_url
    this.__destroyed = false;
    windows.push(this);
  }
  loadFile(path) { this.__loadFileTarget = path; } // WebContents::load_file
  static getAllWindows() { return windows.filter((w) => !w.__destroyed); }
  __close() { // WindowManager::close -> App::note_window_closed
    this.__destroyed = true;
    const remaining = windows.filter((w) => !w.__destroyed).length;
    if (remaining === 0) app.__emit("window-all-closed");
  }
}

module.exports = { app, BrowserWindow, __windows: windows };
EOF

NODE_PATH="$TMPDIR/node_modules" node -e '
const path = require("node:path");
const assert = require("node:assert/strict");
const { app, BrowserWindow } = require("electron");

(async () => {
  require(process.argv[1]);              // load the app under test: main.js
  await app.whenReady().then(() => {});  // ensure ready settled (App::mark_ready)
  await new Promise((r) => setImmediate(r));

  // 1. ready reached exactly once, one window created.
  assert.equal(app.__isReady(), true, "app must reach ready");
  let wins = BrowserWindow.getAllWindows();
  assert.equal(wins.length, 1, "exactly one window after ready");

  // 2. window options: 800x600 + preload (mirrors BrowserWindowOptions).
  const opts = wins[0].__opts;
  assert.equal(opts.width, 800, "width 800");
  assert.equal(opts.height, 600, "height 600");
  assert.match(opts.webPreferences.preload, /preload\.js$/, "preload target");

  // 3. content target: loadFile("index.html") (WebContents::load_file).
  assert.equal(wins[0].__loadFileTarget, "index.html", "loads index.html");

  // 4. activate with zero windows re-creates one (macOS dock-click path).
  for (const w of [...wins]) w.__close();
  assert.equal(BrowserWindow.getAllWindows().length, 0, "all windows closed");
  app.__emit("activate");
  await new Promise((r) => setImmediate(r));
  assert.equal(BrowserWindow.getAllWindows().length, 1, "activate re-creates window");

  // 5. window-all-closed -> quit on non-darwin, stay alive on darwin
  //    (main.js branches on process.platform; App::quit semantics).
  for (const w of [...BrowserWindow.getAllWindows()]) w.__close();
  if (process.platform !== "darwin") {
    assert.equal(app.__quitCalled(), true, "must quit on window-all-closed (non-darwin)");
    console.log("  ok   lifecycle: ready -> 1 window -> activate -> quit (platform: " + process.platform + ")");
  } else {
    assert.equal(app.__quitCalled(), false, "must stay alive on darwin");
    console.log("  ok   lifecycle: ready -> 1 window -> activate -> alive (platform: darwin)");
  }
  console.log("PASS: main.js boots to ready headless (stub electron, strake semantics)");
})().catch((err) => { console.error("FAIL:", err.message); process.exit(1); });
' "$APP_ROOT/main.js"

# --- Phase 2 (optional): live strake primitives, read-only on the checkout ---
if [ "${STRAKE_CHECKOUT:-}" != "" ]; then
  echo "== phase 2: strake-electron-compat suite (read-only, advisory) =="
  if [ ! -f "$STRAKE_CHECKOUT/packages/strake-electron-compat/Cargo.toml" ]; then
    echo "WARN: \$STRAKE_CHECKOUT does not look like a strake tree; skipping" >&2
  elif ! command -v cargo >/dev/null 2>&1; then
    echo "WARN: cargo not on PATH; skipping live-primitive check" >&2
  else
    echo "  running: cargo test -p strake-electron-compat (in \$STRAKE_CHECKOUT)"
    (cd "$STRAKE_CHECKOUT" && cargo test -p strake-electron-compat --offline 2>&1 | tail -n 8) \
      || echo "WARN: strake-electron-compat suite did not pass; see COMPAT.md gaps" >&2
  fi
else
  echo "== phase 2: skipped (set STRAKE_CHECKOUT=/path/to/strake to run live-primitive check) =="
fi
