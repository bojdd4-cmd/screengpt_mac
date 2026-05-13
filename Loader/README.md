# Loader — Phase 1 dylib injection POC

Minimal Phase 1 deliverable to prove DYLD_INSERT_LIBRARIES injection
works into LockDown Browser on this Mac.  No UI yet — just confirms
our code gets loaded inside LDB's process.

## Files

| File | Role |
|---|---|
| `screengpt_dylib.m` | The dylib source — has a `__attribute__((constructor))` that logs to /tmp/screengpt_dylib.log when loaded |
| `build_dylib.sh` | Compiles `screengpt_dylib.m` → universal arm64+x86_64 dylib, ad-hoc signs it, deploys to `/usr/local/lib/libscreengpt.dylib` |
| `arm.sh` | `launchctl setenv DYLD_INSERT_LIBRARIES + SGPT_TARGET`; kills any running LDB so next launch picks up the env |
| `disarm.sh` | Inverse of arm — `launchctl unsetenv` for those keys |

## Prerequisites

- SIP disabled (`csrutil status` → "disabled")
- AMFI disabled (`nvram -p \| grep amfi` → `amfi_get_out_of_my_way=1`)
- Apple Silicon Permissive Security on
- Xcode Command Line Tools installed (`xcode-select --install`)

## Phase 1 test

```bash
# 1. Build the dylib + deploy to /usr/local/lib
cd ~/Desktop/screengpt_mac/Loader
chmod +x build_dylib.sh arm.sh disarm.sh
./build_dylib.sh

# 2. Arm the injection (also kills running LDB)
./arm.sh

# 3. Launch LDB manually (Spotlight, Applications folder, dock, etc)

# 4. Watch the log for the LOADED line
tail -f /tmp/screengpt_dylib.log
```

You should see a line like:

```
[2026-05-13T15:32:01.123Z] LOADED  pid=12345  bundleID=com.respondus.lockdownbrowser  exe=/Applications/LockDown Browser.app/Contents/MacOS/LockDown Browser
           SGPT_TARGET=LockDownBrowser  SGPT_INLINE_UI=(unset)
           DYLD_INSERT_LIBRARIES=/usr/local/lib/libscreengpt.dylib
           → TARGET MATCH, would init overlay here (Phase 2)
```

If you see `TARGET MATCH` — Phase 1 PASSED.  Move on to Phase 2.

If you only see `not target, exiting constructor cleanly` for processes
like `Finder`, `Safari`, etc. but never `LockDown Browser` — LDB is
rejecting the dylib (likely a sign of an AMFI / signing issue).
Re-check the prerequisites above.

If `/tmp/screengpt_dylib.log` doesn't even appear after arming and
launching LDB — dyld isn't honoring the env var.  Almost always means
AMFI is still on.

## Phase 1 → Phase 2

Once injection is confirmed, Phase 2 replaces the `// would init
overlay here` log line with the actual overlay UI + scan logic.
