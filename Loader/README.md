# Loader — kill-shield dylib (Phase 1.5)

Pivot from the original Phase 2 plan (full UI inside LDB) to a simpler
approach: inject a tiny dylib into LockDown Browser that **hooks the
`kill()` syscall** and intercepts any attempts to murder our standalone
app.  Our existing SwiftUI ColorCalibration.app keeps showing the
overlay; LDB tries to kill it; our hook returns success-without-killing;
the app keeps running.

This matches CloakGPT's actual architecture as inferred from their
binary strings: a "shield" dylib that protects the standalone app
from LDB's process-kill scan.

## Files

| File | Role |
|---|---|
| `screengpt_dylib.m` | The dylib source. `__attribute__((constructor))` logs the host process; `DYLD_INTERPOSE` swaps `kill` and `killpg` with our shielded versions. |
| `build_dylib.sh` | clang → universal arm64+x86_64 dylib, ad-hoc sign, deploy to `/usr/local/lib/libscreengpt.dylib` |
| `arm.sh` | `launchctl setenv DYLD_INSERT_LIBRARIES`, kills running LDB so next launch picks up the env |
| `disarm.sh` | `launchctl unsetenv` |

## Prerequisites

- SIP disabled
- AMFI disabled (`amfi_get_out_of_my_way=1`)
- Apple Silicon Permissive Security on
- Xcode Command Line Tools

## How it works

1. `./arm.sh` sets `DYLD_INSERT_LIBRARIES` and `SGPT_TARGET` at the
   launchctl session level.
2. User launches LDB.
3. dyld (with AMFI off) sees the env var, loads `libscreengpt.dylib`
   into LDB's process address space.
4. dyld processes the `__DATA,__interpose` section, swapping LDB's
   `kill` symbol pointer to point at our `my_kill`.
5. LDB's periodic process-kill scan finds our standalone ColorCalibration
   app and calls `kill(our_pid, SIGKILL)`.
6. Our hook is invoked.  It checks if the PID's executable path
   contains "ColorCalibration" / "SystemAuditAgent" / "screengpt".
   If yes AND the signal is fatal, returns 0 without actually
   forwarding to the real `kill()`.
7. LDB thinks it killed us; our app keeps running.

## Test sequence

```bash
# 1. Build the dylib + deploy
cd ~/Desktop/screengpt_mac/Loader
chmod +x build_dylib.sh arm.sh disarm.sh
./build_dylib.sh

# 2. Make sure the standalone ColorCalibration is running first
killall ColorCalibration 2>/dev/null
/Applications/Utilities/ColorCalibration.app/Contents/MacOS/ColorCalibration &
# Log in.

# 3. Arm the shield (kills LDB if running so next launch picks up dylib)
./arm.sh

# 4. Launch LDB manually.

# 5. Watch the intercept log
tail -f /tmp/screengpt_dylib.log | grep -i INTERCEPT
```

Expected: after 2-3 minutes inside an LDB exam, you'll see lines like:

```
[NNNN] INTERCEPTED kill(pid=12345, sig=9) from host=/Applications/LockDown Browser.app/Contents/MacOS/LockDown Browser victim=/Applications/Utilities/ColorCalibration.app/Contents/MacOS/ColorCalibration — returning 0
```

And the standalone ColorCalibration app **keeps running**.

## Disarm

```bash
./disarm.sh
```

Removes the env vars.  Next LDB launch won't have our shield.  Already-
running LDB instances keep whatever they loaded — kill them too if you
want a fully clean state, or just restart your Mac.

## What this DOESN'T do

- Doesn't render UI inside LDB.  Your overlay is the existing
  standalone ColorCalibration.app, completely unchanged.
- Doesn't hook other kill paths (`task_terminate` mach calls,
  `NSRunningApplication.forceTerminate` Cocoa method, AppleScript).
  If LDB uses one of those instead of `kill()`, the shield won't
  catch.  We'll expand to those if needed based on what the
  intercept log shows.

## Phase 2 (if 1.5 works)

Once the shield is confirmed working, we can also add:
- Hook `proc_listpids` / `CGWindowListCopyWindowInfo` to hide our
  process + windows entirely from LDB's enumeration
- Hook `task_terminate` for the mach-based kill path
- Hook NSWorkspace / Foundation APIs as additional layers
