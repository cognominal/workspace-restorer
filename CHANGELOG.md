# Changelog

All notable changes to this project are documented in this file.

## [1.1.3] - 2026-09-11

### Fix

- Fixed a `NameError` in the `lz4jsoncat` fallback of `scripts/capture_tabs.py`: the `shutil` import was dropped during the 1.1.2 hardening but the fallback still calls `shutil.which()`. Restored the import so the CLI fallback works when `python3-lz4` is unavailable. (Found in marketplace security review.)

## [1.1.2] - 2026-09-06

### Hardened profile store and tab capture file reads

- All profile-directory reads, writes, and deletions (create dir, list, save, load, delete) now go through a new hardened helper, `scripts/profile_store.py`, instead of shell `mkdir`/`ls`/`cat`/`rm` on user paths. Every file it touches is opened with `O_NOFOLLOW | O_NONBLOCK`, fstat-checked to be a regular file owned by the user, and read within a byte bound — a planted symlink or FIFO can no longer redirect a read or block the persistent shell on a stale profile path.
- Profile saves stream their JSON over stdin (no temp files, no shell heredocs), and both save and load enforce cardinality limits (max 512 windows, 300 tabs per window, 256 profiles) plus a size cap, so a hand-edited or corrupt profile cannot drive an oversized launch.
- Browser tab capture now reads the Chromium DevTools port file and Firefox/Chromium session files through the same held-descriptor bounded reader (no-follow, regular-file/ownership check, byte caps), bounds SNSS files, and feeds the `lz4jsoncat` fallback from a private 0600 temp copy with bounded chunked output — closing the check-then-open and unbounded-read gaps in capture.
- Restore now revalidates a loaded profile's window/tab cardinality before generating any launch command (mirrored in `restoreLogic.mjs` and the bar widget).

## [1.1.1] - 2026-08-30

### Security hardening for browser tab capture

- Bounded all untrusted local browser inputs read during tab capture: the Chromium DevTools debug port is now constrained to a bare 1-5 digit number (so a crafted `DevToolsActivePort` can no longer redirect a snapshot request to an arbitrary host) and the CDP response is capped in size.
- Bounded Firefox session-store decoding: the compressed file is stat-limited before any read and its declared uncompressed size is validated against a ceiling before decompression, so a crafted `recovery.jsonlz4` cannot force an unbounded memory allocation. The fallback decoder's output is length-checked as well.

## [1.1.0] - 2026-08-30

### Browser tabs now restore correctly

- Fixed browser tab restore when browsers are already running: no more split-screen windows (Firefox), extra session-restore tabs (Vivaldi), or windows landing on the wrong workspace.
- Changed browser windows with captured tabs are now closed and relaunched fresh at restore time, so each opened window shows exactly the tabs from your snapshot — one window, no duplicates, on the correct workspace.
- Fixed a launch-script stall that could stop a restore partway through.

> **Note:** restoring a snapshot with browser tabs will close and reopen the matching browser window. Capture snapshots without browser tabs if you prefer not to have browsers relaunched.

## [1.0.0] - 2026-08-27

Initial release.
