# ScreenGPT Brain

The "brain" is a headless Python process that handles everything platform-neutral:
login, AI scan requests, LaTeX→Unicode conversion, settings persistence,
and machine-ID derivation. It speaks JSON-over-stdio with the Swift app shell.

This folder contains:

| File | Purpose |
|------|---------|
| `screenai_brain.py` | The brain itself — single Python file, no build step needed to run |
| `build_brain_mac.sh` | Nuitka build script that produces a single-file Mach-O binary |
| `requirements.txt` | Runtime Python dependencies (`requests`, `pillow`) |
| `test_brain.py` | Smoke tests — run on any platform, no Mac/Nuitka needed |
| `README.md` | This file |

The compiled binary ships inside `ScreenGPT.app/Contents/Resources/brain/helper`.

---

## Architecture recap

```
       Swift app                          Python brain
   (ScreenGPT.app)                  (helper, Nuitka-compiled)
   ────────────────                  ──────────────────────────
        │                                       │
        │   stdin  ─────────────────────►       │
        │   {"cmd":"login", ...}                │
        │                                       │
        │   ◄───────────────────── stdout       │
        │   {"evt":"login_ok",   ...}           │
        │   {"evt":"usage",      ...}           │
        │                                       │
        │   ◄───────────────────── stderr       │
        │   [info] free-form logs               │
```

The Swift app is responsible for everything Mac-specific (windows, hotkeys,
screen capture, UI). The brain is responsible for everything else.

---

## JSON IPC protocol

### Commands (Swift → brain)

| Command | Fields | Notes |
|---------|--------|-------|
| `login` | `email`, `password`, `machine_id?` | Returns `login_ok` with JWT or `login_err` |
| `scan` | `image_b64`, `mode?`, `provider?`, `use_context?` | `image_b64` is a base64 PNG or JPEG of the full screen |
| `fetch_usage` | — | Returns `usage_full` |
| `get_setting` | `key` | Returns `setting_value` |
| `get_all_settings` | — | Returns `all_settings` |
| `set_setting` | `key`, `value` | Persists immediately, returns `setting_value` |
| `get_machine_id` | — | Returns `machine_id` |
| `logout` | — | Clears token + context, returns `logged_out` |
| `ping` | — | Liveness check, returns `pong` |
| `shutdown` | — | Graceful exit, returns `shutdown_ok` then exits |

### Events (brain → Swift)

| Event | Fields | Notes |
|-------|--------|-------|
| `ready` | `version` | Emitted at startup |
| `login_ok` | `token` | JWT for subsequent /api/scan calls |
| `login_err` | `code`, `msg` | `code` ∈ {`bad_creds`, `device_limit`, `no_plan`, `network`} |
| `scan_progress` | `stage` | `stage` ∈ {`preparing`, `waiting`, `parsing`} |
| `scan_ok` | `answer`, `provider`, `tokens_used?`, `tokens_remaining?` | LaTeX already converted to Unicode |
| `scan_err` | `msg` | User-facing error string |
| `usage` | `provider`, `tokens_used`, `tokens_limit`, `tokens_remaining` | Emitted automatically on every successful scan |
| `usage_full` | `data` | Full per-provider usage from /api/usage |
| `setting_value` | `key`, `value` | Echoed after get/set |
| `all_settings` | `values` | Full settings snapshot |
| `machine_id` | `value` | 64-char SHA-256 hex |
| `logged_out` | — | After `logout` |
| `pong` | `t` | Server time when ping was handled |
| `shutdown_ok` | — | Last event before process exit |
| `log` | `level`, `msg` | Free-form diagnostic |

All events also appear on stderr in human-readable form for debugging.

---

## Running on macOS

### Option A: from source (development)

```bash
cd screengpt_mac/Brain
python3 -m pip install -r requirements.txt
python3 screenai_brain.py
```

The brain prints `{"evt":"ready","version":"1.0.0"}` immediately. Type a
JSON command on stdin and press Enter to see the response.

### Option B: Nuitka-compiled binary (production)

```bash
cd screengpt_mac/Brain
chmod +x build_brain_mac.sh
./build_brain_mac.sh
# → build/helper
```

The build script:
1. Installs Nuitka and runtime dependencies via pip
2. Compiles `screenai_brain.py` to a single-file universal Mach-O
3. Names the output `helper` (generic, doesn't stand out in `ps`)
4. Runs a smoke test to confirm the binary works

Universal binary by default (Apple Silicon + Intel). To build just one
architecture for faster iteration:

```bash
ARCH=arm64 ./build_brain_mac.sh   # Apple Silicon only
ARCH=x86_64 ./build_brain_mac.sh  # Intel only
```

Final binary is around 10–15 MB and starts in <100 ms.

---

## Testing

### Unit tests (run on Windows too)

```bash
cd screengpt_mac/Brain
python3 -m pip install -r requirements.txt
python3 test_brain.py
```

This runs:
- LaTeX converter cases (`\frac`, `\sqrt`, `\mathbb`, super/subscripts, Greek)
- Machine ID format check (64-char hex)
- Settings load/save round-trip
- Subprocess IPC integration (spawns the brain, sends ping/get_machine_id/etc.)

Should be all-green on Windows, macOS, and Linux. Login/scan tests are
deliberately not included because they require live credentials.

### Manual IPC test

```bash
echo '{"cmd":"ping"}' | python3 screenai_brain.py
```

Expected output (newline-delimited JSON):

```json
{"evt": "ready", "version": "1.0.0"}
{"evt": "pong", "t": 1715450123.456}
```

### Live login test (requires credentials)

```bash
printf '%s\n' \
  '{"cmd":"login","email":"you@example.com","password":"secret"}' \
  '{"cmd":"shutdown"}' \
  | python3 screenai_brain.py
```

Should print `login_ok` then `shutdown_ok`. If you get `login_err`, the
`code` field tells you whether it's bad credentials, device limit, no plan,
or a network problem.

---

## Settings file

Location: `~/Library/Application Support/ScreenGPT/settings.json`

Schema (loaded into memory at startup, written on every `set_setting`):

```json
{
  "resp_mode":      1,
  "panel_enabled":  true,
  "bubble_enabled": false,
  "bubble_follow":  true,
  "txtsz":          1,
  "display_secs":   12,
  "corner":         0,
  "inv_mul":        3,
  "ctx_on":         false,
  "inv_mode":       false,
  "ai_provider":    "grok",
  "dismiss_zone":   false
}
```

Note: `panel_enabled` and `bubble_enabled` are **independent** booleans —
both can be true at the same time (the Mac-specific "simultaneous modes"
feature). On Windows there was a single `boot_mode` string that picked one
or the other.

---

## Differences vs `screenai_lockdown.py` (Windows)

**Removed:**
- All Win32/ctypes (registry, mutex, hotkeys, window hiding)
- All tkinter / customtkinter UI
- `SharedMemory` class (replaced by stdio IPC)
- DLL injection / `_inject` / `_deject` / `screenai_boot.dat`
- LDB folder auto-detection
- `_app_dir`, `_asset`, `_dll_source` (no bundled assets in the brain)

**Changed:**
- `get_machine_id()` reads `IOPlatformUUID` via `ioreg` instead of Windows registry
- Settings path is `~/Library/Application Support/ScreenGPT/` instead of `%APPDATA%`
- `boot_mode` field replaced by independent `panel_enabled` + `bubble_enabled`
- Scan input is base64 image data from the Swift app (no `d3d_surface.bin` file)

**Unchanged (carried over verbatim):**
- `_delatex` and the Greek/symbol/superscript/subscript tables
- Login HTTP POST flow and error classification
- Scan HTTP POST flow, timeouts, error handling
- Usage GET
- `_DeviceLimitError`

---

## Notes for the Swift integration

- **Buffering**: stdout is line-buffered. Every event is one line, flushed
  immediately. Read line-by-line from the brain's stdout `Pipe`.
- **Encoding**: All JSON is UTF-8.
- **Concurrency**: Each command runs in a daemon thread inside the brain,
  so a long-running scan does not block subsequent reads. Don't send
  concurrent `scan` commands — the brain will run them in parallel and you'll
  get interleaved events.
- **Shutdown**: Send `{"cmd":"shutdown"}` for a clean exit. If the Swift
  app dies, the brain detects EOF on stdin and exits within a few ms.
- **Errors**: All errors come through as JSON events (`login_err`, `scan_err`,
  or `log` with level `err`). The brain never crashes on bad input — bad
  JSON produces an error log event and is otherwise ignored.
- **stderr**: The brain writes free-form log lines to stderr in addition to
  structured `log` events. Capture stderr to a rolling file in
  `~/Library/Logs/ScreenGPT/` for support diagnostics.
