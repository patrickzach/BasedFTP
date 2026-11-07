# Validation

As of November 7, 2026.

## Checks actually performed

Environment: Apple Silicon, macOS 27.2 (26B123), Xcode 27.2 (27B52), Swift 6.4.2. Project deployment target: macOS 14.

| Check | Result |
| --- | --- |
| Swift package debug build | Successful |
| Optimized release build using `Scripts/build-app.sh` | Successful |
| Launch of `build/BasedFTP.app` through macOS | Successful; final release build relaunched |
| App bundle plist and ad hoc signature | `plutil` and `codesign --verify --deep --strict` successful |
| Xcode project file and scheme XML | Syntax validation successful |
| Complete test suite with isolated SSH server | 12 tests, 0 failures, none skipped |
| Additional SSH round trip with RSA-3072 | Successful |
| Additional SSH round trip with ECDSA-P256 | Successful |
| Additional SSH round trip with encrypted Ed25519 key through a dedicated agent | Successful |

The integration script therefore completed 15 successful test executions: twelve distinct test methods and three additional key variants of the same SSH round-trip test. Without a running SSH test server, `Scripts/test.sh` skips two explicitly marked SSH integration tests.

## Automated test coverage

- Binary framing, integer endianness, UTF-8, and truncated/oversized packet fields.
- Navigation history with back/forward and branching.
- Host, port, and filename validation; security-relevant SSH arguments.
- Real local `/usr/libexec/sftp-server`: listing, stat, upload, download, resumption in both directions, chmod, mkdir, exclusive creation, rename, and recursive deletion.
- Byte-exact round trip of a 2.8 MB file, including Unicode, spaces, quotes, glob characters, and a newline in its name.
- Recursive uploads/downloads, conflict strategies, and explicit symlink rejection at this stage.
- Deliberately canceled staged upload: the existing destination remains unchanged; resumption correctly commits the staging file. A job failing before file transfer begins still respects its original Rename strategy when resumed.
- Protocol fixture for out-of-order responses and short reads with multiple outstanding requests. This fixture is used only in tests.
- Real loopback SSH with separately generated host/client keys, isolated `known_hosts`, listing, and file round trip.
- Unknown and deliberately changed host keys actually cause connection failure.

## Visual checks

The app was launched and operated through the native macOS interface:

- Opened and closed the welcome screen and connection dialog.
- Created an unsaved test connection to a closed loopback port; no new user profiles or credentials were saved.
- Checked both panels, the transfer view, and the explanatory SSH error display.
- Navigated the local panel to the project directory using path entry; real file entries appeared.
- Closed the temporary connection tab and relaunched the final release build.

This is not a complete automated UI regression test. In particular, cross-panel upload/download drags, all keyboard combinations, parallel queue behavior, long pauses, Light Mode, and editor re-upload had not yet been fully exercised interactively at this stage.

## Local Xcode installation limitation

The command `xcodebuild -project BasedFTP.xcodeproj -scheme BasedFTP -configuration Debug -derivedDataPath .build/Xcode CODE_SIGNING_ALLOWED=NO build` was attempted. It exits before building the project because the installed `IDESimulatorFoundation` plugin expects a missing symbol from `/Library/Developer/PrivateFrameworks/DVTDownloads.framework`:

```
Symbol not found: _$s12DVTDownloads21DownloadableAssetTypeO22downloadableDependencyyAcA0bF4InfoVcACmFWC
```

The system installation was not modified. The Xcode project, including its XCTest target, exists and passed syntax validation; its build and test run in this IDE could not be confirmed because of this local toolchain issue. The same app sources compile with SwiftPM, which produced a signed `.app` bundle that was actually launched.

## Not yet verified

- Password authentication and direct ASKPASS subprocess access to macOS Keychain using an interactive test account.
- Direct Keychain passphrase authentication without an agent; encrypted keys through an agent are tested.
- Host-key setup through the fingerprint dialog against an external server, ProxyJump, and complex SSH configurations.
- Servers without OpenSSH extensions, different SFTP providers, and unsupported protocol versions other than v3.
- Intel hardware, macOS 14–26, very large directories, and hours-long transfers.
- Notarization and distribution; only a local ad hoc signature is available.

Functional limitations and security decisions are documented in the README. This report does not establish an external security audit or a comprehensively production-hardened version 1.0.

## Addendum: native tree view and Drag & Drop

- Both file panels now use NSOutlineView with native disclosure arrows and keyboard navigation. Subfolders load asynchronously; expanded branches are restored on refresh.
- Two additional view-model tests cover nested expansion, filters retaining ancestors, refresh, renaming inside a subfolder, duplicate drag payloads/overlapping selections, actual moves, and protection against conflicts/self-moves, including a symlink destination alias.
- The real local SFTP subsystem test additionally checks moving a folder with a file inside it.
- In a separate preview app, a real test file was dragged with the mouse in the expanded tree from `Quelle/Unterordner/beispiel.txt` onto `Ziel`. The native outline then showed the file as a child of `Ziel`; filesystem inspection confirmed `Ziel/beispiel.txt` and removal from the original path. These are the original test fixture paths.
- The discovered misrouting of cell-based SwiftUI drops into the root directory was fixed using native NSOutlineView drop delegates. Entire folder rows act as targets; internal moves return `.move`, cross-panel transfers `.copy`.
- Release build, signature verification, and updated Xcode project validation succeeded. The final SSH integration run completed all twelve test methods and three additional key variants without failures.
- The preview was closed after testing. The already-running main app needed to be quit and reopened to load this build.

## Addendum: bookmarks and tab shortcuts

- Single and double clicks on saved servers and recent connections use the same activation path. Activations of the same profile within the macOS double-click interval are coalesced, so a double click creates exactly one tab.
- Replaced the standard Close menu command with Close Tab (⌘W) and Close Window (⇧⌘W). Closing the last tab returns to the welcome screen while keeping the window open. Closing a tab selects its neighbor.
- Two additional unit tests for double-click coalescing and closing active/inactive tabs pass. The local suite ran 14 test methods: 12 passed, and the two separately configured SSH integration tests were skipped in this run.
- In a separate preview app, a real double click on an existing bookmark opened exactly one tab. ⌘W then closed that tab; the welcome screen and window remained visible. Server reachability was not required for this UI check.
- Release app rebuilt successfully.

## Addendum: skipping entries with transfer warnings

- Links and special files are excluded during size calculation and skipped during transfer; the remaining directory tree is transferred. Each warning identifies the full source path and file type, without duplicate preflight/transfer messages.
- The transfer view shows a warning count, detail list, and a completed-with-warnings status after success. Other errors still appear as failures.
- Updated the existing recursion test for the new behavior. An additional test against the real local OpenSSH SFTP subsystem server checks uploads/downloads with regular files, a broken link, a link loop, and a FIFO. It verifies transferred contents, absence of skipped destinations, complete warnings without duplicates, and byte progress excluding omitted entries. An individually selected broken link is also skipped without a transfer failure.
- Local suite: 15 test methods, 13 passed, two separately configured SSH integration tests skipped.

## Addendum: file counters and readable remaining time

- Each job shows transferred, planned, conflict-skipped, and remaining files. A file counts as transferred only after successful commitment to its final destination. Empty files count; directories and unsupported entries do not.
- Resume information distinguishes previously transferred files from conflict-skipped files, preventing incorrect upload counts after resumption.
- Remaining-time formatting supports singular/plural, days, hours, minutes, and seconds. Examples: 600 → “10 minutes”, 605 → “10 minutes and 5 seconds”, 3665 → “1 hour, 1 minute and 5 seconds”. Missing or invalid estimates display “—”. These examples are rendered here in English; the later language addendum records the switch of the app and test expectations to English.
- Additional tests check time boundaries, invalid values, and recursive upload/download counts, empty files/folders, and conflicts including resumption. The link/special-file test additionally verifies their exclusion from file counters.
- Local suite: 17 test methods, 15 passed, two separately configured SSH integration tests skipped.

## Addendum: recursive remote deletion

- The original implementation waited for each REMOVE/RMDIR response individually and displayed only a generic activity indicator. This creates many sequential network waits, especially with numerous small files.
- Independent delete requests are now pipelined with a window of up to 16 requests. All outstanding child deletions are acknowledged before a parent's RMDIR. There is no shell deletion command or automatic retry of write operations.
- A progress area shows the current path, directory listing activity, and acknowledged deletion count. Errors include the affected path and last progress. Cancel terminates the affected process and reports entries already deleted. The count is not a precomputed total; an additional complete preliminary listing is avoided.
- Tests against the real local OpenSSH SFTP subsystem server removed a 73-entry tree, demonstrated at least 16 simultaneously outstanding requests, and checked progress between start and completion. Symlink targets outside the tree remain intact; link loops are not followed, FIFOs and empty files/folders are removed correctly, and `/` is rejected as a deletion target.
- A cancellation test stops after 16 acknowledged deletions and leaves the other 48 files intact. A permission-error test checks that the parent directory remains and the error includes the affected filename.
- Local suite: 20 test methods, 18 passed, two separately configured SSH integration tests skipped. There is no reliable timing measurement for the user-reported directory: no deletion was still visible during read-only inspection of the running app.

## Addendum: direct opening and automatic remote saving

- Native application selection with Open With, Other Application…, and Always Open With. Applications are deduplicated by bundle ID; per-extension associations apply only within BasedFTP.
- Remote files download into private working directories and open immediately. Metadata-based monitoring also detects editor file replacements. After two stable content observations, an immutable SHA256 snapshot is uploaded serially; the latest pending version replaces older pending versions.
- Automatic editor uploads require `posix-rename@openssh.com` and replace the destination only after the staging file has uploaded completely. There is no fallback that deletes the old destination first. Unknown server capabilities, permission errors, and failed replacement preserve working copies; Unix rwx permissions are retained.
- Tests with a controlled backend verify exactly one concurrent upload, coalescing multiple new saves, reverting to the version currently uploading and the original version, failures, retry with the latest version, and stopping monitoring.
- Further tests cover immutable snapshots, rejection of local symlinks/FIFOs, and isolated file-type preferences. Tests against the real local OpenSSH SFTP server verify successful atomic replacement, retained permissions, upload permission errors, failed renaming onto a directory, and rejection of a server without the atomic extension.
- A dedicated integration test uses the production SFTP editor backend and live automatic monitoring: SSH download, atomic save of the local working copy, and automatically acknowledged replacement on the isolated loopback server. A final download verifies the complete content.
- In a separately launched preview app, Open With was opened for an HTML test file. VS Code appeared in the list; selecting TextEdit immediately opened the correct test file. The configured default was not changed, and test windows were closed. A manual long-running test with VS Code autosave and real production servers remains outstanding.
- Local suite: 27 test methods, 24 passed and three separately configured SSH tests skipped. With the isolated SSH server: all 27 passed, plus three successful key variants of the SSH round trip.

## Addendum: English as the default language

- Converted all app-owned text in SwiftUI views, native AppKit menus, file operations, transfer/editor states, remaining-time/file counters, and errors to English. Saved server data and user preferences are not translated or migrated.
- Xcode and app bundle development languages are `en`. The script-built bundle also explicitly declares English as an available app language. No German resource localization exists; date/number formats remain region-dependent.
- Readable-time tests use English expectations, including singular/plural and hours/days. Local suite: 27 test methods, 24 passed, three separately configured SSH tests skipped.
- Release build successful. `CFBundleDevelopmentRegion` is `en`; `CFBundleLocalizations` contains `en`. A separate preview app visibly confirmed the English welcome screen, sidebar, menu bar, and full connection dialog, including New Server, Password, Test Connection, and Connect. No profile was saved; the preview was closed.

## Addendum: universal build

- Compiled release sources with SwiftPM separately for `arm64-apple-macosx14.0` and `x86_64-apple-macosx14.0`. Both builds succeeded and were combined into one executable using `lipo`.
- According to `file` and `lipo -archs`, `build/BasedFTP.app/Contents/MacOS/BasedFTP` contains `x86_64` and `arm64`. Both architecture checks passed.
- `vtool -arch … -show-build` confirms `MACOS` with `minos 14.0` for both slices. The combined app bundle was ad hoc signed; `codesign --verify --deep --strict` succeeded.
- `Scripts/build-app.sh` now creates the universal bundle by default. A repeat run with existing build caches also succeeded. Architecture-specific build directories are separated under `.build/universal/`.
- Set the Xcode project to `arm64 x86_64` and `ONLY_ACTIVE_ARCH = NO`; project syntax validation passed. The known local Xcode plugin limitation remains.
- No runtime test on physical Intel hardware. Intel support is demonstrated by successful cross-compilation and architecture/deployment checks, not a hardware test.
