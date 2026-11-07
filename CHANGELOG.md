# Changelog

All features and improvements implemented in BasedFTP so far. The initial commit combines the preceding development steps; they are not retroactively represented as separate commits.

## [Unreleased]

### Added

- README introduction with an app screenshot and direct download and website links.

- GNU GPLv3-only project license, licensing documentation, and inclusion of the license in app bundles built through the script or Xcode.

- Prebuilt landing page in `docs/index.html` and a GitHub Actions workflow for GitHub Pages deployment, with setup and update instructions.

- Universal app for Apple Silicon (`arm64`) and Intel (`x86_64`), requiring macOS 14 or later. The build script compiles both variants separately, combines them using `lipo`, and signs/verifies the combined bundle. The Xcode project is also configured for both architectures.
- Open remote files directly in an editor after a background download, without an intermediate Finder step or modal upload dialog.
- Native Open With application selection, an application picker, and per-extension BasedFTP defaults without changing global macOS associations.
- Automatic remote uploads on save, detection of atomic editor saves, and visible status rows for multiple editing sessions.
- Immutable SHA256 snapshots and debounced file monitoring; serialized uploads use the latest pending version, including reverted changes.
- Remote editing replaces files exclusively through atomic operations after the complete upload has been acknowledged. Servers without the required extension are rejected without a destructive fallback. Intervening server content changes are overwritten without prompting.
- Retention of local working copies and failed snapshots, manual retry using the latest version, and explicit monitoring termination.
- Tests for rapid and reverted saves, failures and retries, immutable snapshots, application preferences, atomic SFTP replacement, and automatic saving through an isolated SSH test server.
- Per-transfer file counters showing “x of y files transferred”, remaining files, and separate counts for files skipped because of conflicts. Empty files count; directories, links, and special files do not count as transferred files.
- Readable estimated remaining time in days, hours, minutes, and seconds, such as “10 minutes and 5 seconds” instead of “605 s”.
- Tests for time formatting, upload/download file counts, empty files, and correct skipped-file counts when resuming.

### Changed

- Converted all app-owned interface text to English by default: menus, dialogs, status indicators, file counters, remaining times, and errors. The app bundle and Xcode project declare English as the development language.
- Moved SSH host import from the sidebar to **Connections → Import from SSH Configuration**.
- Recursive remote deletion uses up to 16 outstanding delete requests instead of waiting for an individual response per entry. Parent directories are removed only after their children are confirmed deleted.
- Deletion shows the current path and acknowledged deletion count. Errors identify the affected path; cancellation reports entries already deleted.
- Added tests for pipelined recursive deletion, progress, cancellation, permission errors, and symlinks that must not be followed.
- Symbolic links and special files are individually skipped during uploads/downloads instead of failing the entire transfer during preflight. Link targets are not followed.
- The transfer queue shows warning counts and an expandable list of full source paths. Successful jobs with omitted entries display **Completed with Warnings**.
- Skipped links and special files are excluded from total byte progress; warnings from preflight and transfer are deduplicated.
- Added regression tests for recursive uploads/downloads with regular files, broken links, link loops, and a FIFO special file. Other file/connection errors remain failures.

## [0.1.0] – 2026-11-07

First locally runnable development version for macOS 14 and later. Not yet a notarized release or a comprehensively production-hardened version.

### Added

#### Native application and project

- Native SwiftUI application with AppKit, modular view models, and asynchronous file I/O.
- Xcode project with a shared scheme and XCTest target, plus a Swift package using the same sources.
- System-controlled Dark and Light Mode, SF Symbols, toolbar, sidebar, and status bar.
- Custom app icon with a reproducible AppKit drawing template and icon resources.
- Scripts for generating the Xcode project, building a locally signed app bundle, and running tests.
- README covering builds, usage, architectural decisions, and known limitations, plus a separate validation report.
- Local Git repository, initial commit, and this changelog.

#### File browser and navigation

- Two independently navigable panels for local and remote files with a movable divider.
- Path entry, breadcrumbs, parent navigation, back/forward, and double-click opening.
- Native NSOutlineView trees in both panels with expandable folders and multiple hierarchy levels.
- Asynchronous loading of subfolders; expanded branches restored on refresh.
- Native multiple selection and arrow-key tree navigation.
- Display of name, size, type, modification date, and octal permissions.
- Sorting through column headers and the panel menu, in ascending or descending order.
- Hidden-file display and filename filtering; matching loaded children remain visible with their ancestors.
- Context menus and keyboard shortcuts for common file operations.

#### SSH, SFTP, and security

- SSH transport through macOS system OpenSSH, without external package dependencies or custom SSH cryptography.
- Binary SFTP v3 client with response ID checks and bounded packet sizes, without parsing terminal directory listings.
- Directory listing, path resolution, file metadata, reading, writing, creation, renaming, deletion, and chmod.
- Password and SSH key authentication through OpenSSH; Ed25519, RSA, ECDSA, and SSH agent support.
- Keychain integration for passwords and key passphrases through a short-lived ASKPASS subprocess.
- Existing SSH configuration, custom ports, and private keys at their existing locations.
- Strict host-key verification using `known_hosts`; no automatic acceptance of unknown or changed keys.
- Dialog for comparing SHA256 fingerprints and explicitly confirming new host keys.
- Connection and inactivity timeouts, SSH keepalives, explanatory errors, and reconnection.
- Host, port, and filename validation; UTF-8 filenames including spaces, quotes, and newlines.
- No telemetry, advertising, accounts, or paid services.

#### Transfers and file operations

- Upload/download of individual files and recursive directory trees.
- Queue with a configurable limit of 1–8 parallel jobs.
- Per-job progress, average speed, estimated remaining time, and status.
- Pause, continue, cancel, retry, and explicit resumption of interrupted transfers.
- Skip, Rename, Overwrite, and Resume conflict strategies; Rename by default.
- 64 KiB blocks with up to eight outstanding requests; handling of reordered responses and short reads.
- Transfer into uniquely named staging files before committing to the final destination; OpenSSH POSIX rename support.
- In-session resume information for staging files and completed files.
- File/folder creation, renaming, moving, deletion, and permission changes.
- Local deletion through Trash; confirmed, permanent recursive server deletion.
- Temporary download of remote files, opening in the associated macOS editor, and explicit re-upload; conflict checks using size and modification time.

#### Drag & Drop

- Upload/download between panels, including directly into a destination folder.
- Actual moves within the local or remote panel.
- Native drop targets covering entire folder rows, breadcrumbs, and empty directory space.
- Native destination highlighting and distinction between moving and transferring.
- Multiple selection with deduplication of drag payloads and overlapping parent/child selections.
- Existing-destination checks before moves; no silent overwriting.
- Protection against moving a folder into itself or a descendant, including canonical path resolution.
- Uploads from Finder into the remote panel.

#### Connections and bookmarks

- Saved server profiles, favorites, and recent connections.
- Multiple simultaneous connections in tabs and unsaved quick connections.
- Connection testing and import of explicit SSH host aliases from the main configuration file.
- Single- and double-click bookmark opening; double clicks create exactly one tab.
- Entire bookmark rows are clickable.
- ⌘W closes the active connection tab; closing the last tab retains the welcome screen in the window.
- ⇧⌘W closes the entire window; closing a tab selects its neighbor.

#### Tests

- Unit tests for packet framing, navigation, input validation, bookmark activation, and tab closing.
- Tests against the real local OpenSSH SFTP subsystem server for file operations, recursive transfers, conflicts, cancellation, and resumption.
- Protocol fixture for reordered responses and short reads, used only in tests.
- Tree view-model tests for expansion, filtering, refresh, nested renaming, and safe moves.
- Isolated loopback SSH test server with dedicated temporary keys and `known_hosts`.
- SSH integration tests for Ed25519, RSA, ECDSA, an encrypted key through a separate agent, and rejection of unknown/changed host keys.

### Fixed and improved

- Replaced cell-based SwiftUI drops with native NSOutlineView drop delegates so drops reliably reach the destination folder.
- Renaming expanded child entries uses their actual parent directory.
- File navigation respects canonical local paths; tree indentation follows the loaded hierarchy.
- Protection against stale navigation results, cancellation of active SSH operations, and cleanup on exit.
- Acknowledged file-handle closure after transfers prevents late server errors from appearing as success.
- Existing destination files remain intact when staged transfers are canceled; resumption retains the original conflict strategy.
- Eight additional points of spacing between the ellipsis icon and menu arrow in both panels.
- Replaced the previous window-closing ⌘W behavior with active-tab closing.
- Coalesced double-click activations to prevent accidental duplicate connection tabs.

### Known limitations and validation

- See [VALIDATION.md](VALIDATION.md) for builds, tests, and visual checks actually performed.
- The SwiftPM release build and locally signed app bundle were built and launched successfully. Direct Xcode building was blocked by a broken plugin in the local Xcode installation.
- Password/Keychain ASKPASS authentication is implemented but has not yet been fully verified end to end with an interactive test account.
- The queue and open tabs are not yet restored across app restarts.
- At this version, symlinks and special files are explicitly rejected during transfers; remote drag export to Finder is missing.
- Resumption assumes identical existing partial contents; remote editing does not provide atomic version comparison.
- No directory synchronization, directory comparison, bandwidth limiting, or notarization yet. Further limitations are documented in the [README](README.md).
