# BasedFTP

**Your server files. Right at home on your Mac.**

BasedFTP is a free, open-source SFTP client for macOS. Browse local and remote files side by side, drag and drop to transfer, and edit server files in your favorite editor—with automatic uploads when you save. Native Mac feel. No accounts, ads, or telemetry.

**[Download for Mac](https://github.com/patrickzach/BasedFTP/releases)** · [Visit the website](https://patrickzach.github.io/BasedFTP/)

![BasedFTP for macOS showing local and remote file browsing side by side, saved servers, and the transfer queue](Resources/Screenshots/basedftp-app.webp)

Requires macOS 14 or later. Universal app for Apple Silicon and Intel. Built with SwiftUI and AppKit, without external package dependencies. This is an early release; see the validation notes and limitations below.

Features and improvements are documented in the [Changelog](CHANGELOG.md).

## Interface language

BasedFTP defaults to English, including on Macs configured in German. App menus, dialogs, status indicators, and error messages are in English. Date and number formats, as well as operating system or server messages, may still follow their respective regional settings or language. Saved profile names and filenames remain unchanged. A separate German localization is not currently included.

## Building and running

Requirements: Xcode with the macOS SDK and Swift 6 or later. The build script produces a universal app for Apple Silicon (`arm64`) and Intel (`x86_64`). Both variants have compiled successfully; the app has not yet been tested on Intel hardware.

- Open `BasedFTP.xcodeproj`, select the **BasedFTP** scheme and **My Mac** destination, then run.
- Alternatively, run `bash Scripts/build-app.sh`. This creates `build/BasedFTP.app` as a universal bundle (`arm64` + `x86_64`) with a local ad hoc signature. Both architectures require macOS 14 or later. Launch the app in Finder afterward.
- `bash Scripts/test.sh` runs unit tests and local SFTP subsystem tests.
- `bash Scripts/integration-test.sh` additionally starts a temporary SSH server **bound only to 127.0.0.1**, using a random port and dedicated keys. It does not change system or user SSH settings. Requirements: `/usr/sbin/sshd`, `/usr/libexec/sftp-server`, Python 3, and permission to access the loopback network. Test files and the agent are removed afterward.

Regenerate the project without additional tools using `python3 Scripts/generate-project.py`. The Swift package and Xcode project use the same source files. The build script also provides an alternative if the local Xcode IDE installation is broken.

## First connection

1. Add a server. The host can be a DNS name, IPv4 address, or alias from `~/.ssh/config`. For IPv6, use an SSH alias for now. Leave the username and port blank to use the OpenSSH configuration.
2. Select an SSH key or use your existing SSH agent. OpenSSH handles Ed25519, RSA with modern signatures, and ECDSA. Passphrase-protected keys can be unlocked through the agent or a passphrase stored in Keychain.
3. For password authentication, enter the password and leave the Keychain option enabled. Entering a secret visibly enables this option. To delete a stored secret, clear the field and enable the replacement option. Existing secrets are otherwise left unchanged.
4. For an unknown host, use the host-key verification action. Independently compare every offered SHA256 fingerprint with the administrator and explicitly confirm it. `ssh-keyscan` alone does not establish trust. Existing keys are never replaced here. Changed keys cause the connection to fail.
5. Test the connection, then connect. For a quick connection, turn off **Save server profile**.

For ProxyJump/ProxyCommand, verify host keys once using the standard OpenSSH client in Terminal. Subsequent SFTP connections support this configuration through OpenSSH. Import is available under **Connections → Import from SSH Configuration** and lists explicit host aliases from the main configuration file. Include files and wildcards are not expanded during import, but OpenSSH evaluates them normally when connecting.

## Usage

- Open saved servers and recent connections with a single or double click. A double click creates exactly one tab. The entire bookmark row is clickable.
- **⌘W** closes the active connection tab. After the last tab closes, the window remains open with the welcome screen. **⇧⌘W** closes the entire window.
- Two independently navigable file panels provide a movable divider, path entry, breadcrumbs, back/forward navigation, and double-click opening. Both use native NSOutlineView trees: expand folders using their disclosure arrows, with subfolders loaded asynchronously. Right/Left Arrow expands or collapses the selection. Refreshing preserves expanded branches.
- Native tables support multiple selection. Name, size, type, modification time, and octal permissions are visible. Select the sort field and direction using column headers or the panel menu. A search field filters the current directory locally by filename.
- Upload/download using panel buttons, the toolbar, context menus, **⌘T**, or **F5**. Drag files and folders between panels. Drop onto a destination folder to transfer directly into it. Dragging within the same panel **moves** items: drop onto folder rows, including collapsed folders, breadcrumbs, or empty space for the current directory. Moves never overwrite existing destinations; moving into the source itself or a descendant is rejected. Selected folders and their children are moved only once. Uploads from Finder into the remote panel are supported. Dragging remote files out to Finder is not yet implemented.
- **⌘R** refreshes the active panel, **⌘↑** opens its parent directory, **⌘[ / ⌘]** navigates back/forward, **⇧⌘.** toggles hidden files, **⇧⌘N** creates a folder, **⌘Return** renames the selection, and **⌘⌫** opens delete confirmation. Clicking or selecting determines the active panel.
- Context menus provide file/folder creation, renaming, moving to an absolute destination directory, chmod, and deletion. Local deletion uses Trash; confirmed remote deletion is permanent and recursive. Up to 16 independent delete requests can be in flight; parent folders are removed only after their children. The panel shows the current path and number of acknowledged deletions. Cancellation cannot restore entries already removed.
- Each transfer shows “x of y files transferred” and the remaining file count. Files skipped because of conflicts are listed separately. Empty files count; directories and skipped links/special files do not. Estimated remaining time uses days, hours, minutes, and seconds, such as “10 minutes and 5 seconds”. The transfer view configures 1–8 parallel jobs and the conflict strategy for **newly added** jobs. The default is Rename. Overwrite, Skip, and explicit Resume are also available.
- Pause suspends the job's local SSH process; continuing resumes it. Long pauses may cause server timeouts. Cancel terminates that process. Retry starts a new job with the same strategy. Resuming a failed/canceled job uses its retained staging files and remembers completed files while the app remains open.
- Double-click a remote file or choose **Edit Remote File**: BasedFTP downloads it in the background and opens it directly in the preferred application. No Finder detour or modal editing dialog is required.
- Right-click → **Open With** lists suitable installed applications and **Other Application…**. **Always Open With** saves a per-extension association, such as `.html` → VS Code. This applies only to BasedFTP, including local files; it does not change macOS/Finder defaults. **Use macOS Default** removes the BasedFTP association.
- **Simply save in your editor:** the app monitors the working copy and automatically uploads changes. The remote editing area shows monitoring, upload, success, or error status. Multiple edited files have separate working copies; reopening the same remote file in the same workspace reuses its active session.
- Uploads run sequentially from immutable snapshots. If you save again during an upload, the latest stable version is uploaded afterward. Intervening server changes are deliberately overwritten without a conflict prompt.
- Upload failures retain the edited working copy and failed snapshots. **Try Again** uses the latest local version. **Working Copy** reveals the file in Finder for recovery. **Stop** disables automatic uploading without deleting the local file.

## Architecture and technical decisions

- `Models.swift`: profiles, file metadata, navigation, and conflict strategies.
- `RemoteFileSystem.swift`: protocol-independent remote file operations and the central connection factory. Browsing, transfers, connection testing, and remote editing use this interface. Only SFTP is currently implemented; FTP/FTPS support is a later step. Missing entries are distinguished from permission and connection failures inside each backend.
- `OperationControl.swift`: shared operation lifetime, cancellation, pause, and process timeout handling. The existing process-based implementation is retained.
- `SFTP.swift`: binary SFTP v3 framing and file commands over stdin/stdout of `/usr/bin/ssh -s … sftp`. No shell command chains, `ls` parsing, or custom SSH cryptography.
- `FileSystem.swift`: local file access and asynchronous panel view models with protection against stale navigation results.
- `Transfers.swift`: bounded parallel queue, recursive transfers, conflicts, progress, average speed, and estimated remaining time.
- `Security.swift`: macOS Keychain and secret-free JSON profiles in `~/Library/Application Support/BasedFTP/profiles.json`.
- `FileOutlineView.swift`: native AppKit tree with selection, drag sources, row-specific drop targets, column sorting, and context menus.
- `RemoteEdit.swift`: monitored editing sessions, stable SHA256 snapshots, serialized automatic uploads, and status display.
- `EditorApplications.swift`: native application selection and BasedFTP-specific per-extension associations.
- `Workspace.swift`, `FilePane.swift`, `ProfileEditor.swift`: SwiftUI views and connection state.

**SSH backend:** Instead of bundling an additional SSH library, the app uses Apple's maintained system OpenSSH. This provides an established SSH implementation without an external dependency and preserves compatibility with agents, `Include`, `Match`, IdentityFile, and ProxyJump. The app implements only SFTP v3 file commands, not transport encryption. [libssh2](https://github.com/libssh2/libssh2), also evaluated, would add a C build/distribution dependency. [SwiftNIO SSH](https://github.com/apple/swift-nio-ssh) describes itself as an SSH building block rather than a complete client and lists Ed25519/ECDSA in its documented asymmetric algorithm set. The requirement for RSA and existing OpenSSH configurations led to choosing the system client.

Each navigation request, file operation, or transfer job uses its own SSH subsystem process. Canceling one job therefore does not affect other connections. There is currently no persistent, app-managed connection pool or automatic retry of write operations. Retry reconnects. User-configured OpenSSH multiplexing settings may still apply.

Protocol I/O runs outside the Main Actor. The interface receives throttled progress updates. Transfers use 64 KiB blocks with up to eight outstanding requests. Response IDs are checked, out-of-order responses buffered, and short server reads completed. Cross-connection bandwidth limiting and adaptive window sizes are not currently implemented.

References consulted during implementation:

- [OpenSSH SFTP client and capabilities](https://man.openbsd.org/sftp)
- [OpenSSH configuration and precedence](https://man.openbsd.org/ssh_config)
- [SFTP v3 protocol](https://www.ietf.org/archive/id/draft-ietf-secsh-filexfer-02.txt)
- [OpenSSH SFTP extensions](https://github.com/openssh/openssh-portable/blob/master/PROTOCOL)

## Security and limitations

- `StrictHostKeyChecking=yes`, no agent forwarding, LocalCommand execution, or port forwarding. The app enforces `~/.ssh/known_hosts` and `/etc/ssh/ssh_known_hosts`; alternative KnownHosts paths from SSH configuration are deliberately ignored. Automatic DNS-based host-key acceptance and automatic key updates are disabled.
- Passwords and passphrases are stored only in macOS Keychain. A dedicated, short-lived ASKPASS subprocess supplies them to OpenSSH through a pipe. Secrets are absent from process arguments, environment variables, profile JSON, and logs. Private keys remain at their existing locations.
- Profile names and filenames are never executed as shell code. Hosts and ports are validated, and protocol packets have size limits. UTF-8 filenames, including spaces, quotes, Unicode, and newlines, are supported. Non-UTF-8 filenames are explicitly rejected.
- New transfers first write a uniquely named `.partial` file in the destination folder. It is committed only after successful completion. OpenSSH servers use `posix-rename@openssh.com`; overwriting after a completed upload is not atomic on servers without this extension. Hidden staging files may remain after failures and require manual cleanup.
- **Resume** writes directly into the existing destination file. Use it only with an identical prefix: SFTP v3 cannot guarantee a content comparison of existing partial data. A larger destination file causes failure. Retry retains the original strategy. Resume on a canceled job uses its saved staging paths; after restarting the app, leftover staging files must be identified/renamed manually. First ensure the source is unchanged.
- Symlinks and special files are individually skipped during uploads/downloads, allowing recursive transfers to continue without following links. The queue shows their count and full paths under **items skipped – Details**; successful jobs with skipped entries display **Completed with Warnings**. Navigation to a known destination path remains possible. There is no complete protection against concurrent malicious filesystem changes.
- **Automatic remote editing only replaces files atomically:** the new version is uploaded completely into an exclusively created staging file in the same server directory, then committed using `posix-rename@openssh.com`. If the server lacks this extension or the target is not a regular file, the operation fails with an explanatory error. Remote editing has no delete-and-rename fallback. If the connection drops after renaming, acknowledgment may be lost; the server then contains either the old or the complete new file. There is no version comparison or backup history: intervening changes are deliberately overwritten.
- Editing sessions check local metadata approximately every 700 ms. On changes, two stable content observations are compared using SHA256; snapshots protect active uploads from subsequent local modifications. Atomic editor saves are detected too. Large unchanged files are not continuously rehashed.
- Working copies are retained in private directories under `~/Library/Application Support/BasedFTP/Edits/<session-ID>/`. Failed server staging files may require manual cleanup. Monitoring ends when the window/app closes and is not yet restored automatically after restart. Closing a connection tab keeps its still-visible editing session active. Unix rwx permissions are preserved; ownership, ACLs, and other metadata are not yet fully preserved.
- The queue and open tabs do not survive app restarts. Directory synchronization, directory comparison, bandwidth limiting, and Quick Look are not implemented.
- The app is intended for local builds and direct use, currently without App Sandbox, a distribution signature, or notarization. It has no App Store approval. Access to macOS-protected folders follows normal system permissions.

## Validation of this version

See [VALIDATION.md](VALIDATION.md) for details and checks actually performed. Password authentication and the Keychain/ASKPASS chain additionally require an interactive test with a suitable test account; they are implemented but not claimed as fully tested end to end. Large production directories, hours-long transfers, different third-party servers, and older macOS versions need further practical testing before this version can be considered a professionally hardened 1.0.

## Landing page (GitHub Pages)

The prebuilt landing page lives in `docs/index.html`. It includes its styles and images, so no Node.js or Astro build is required in this repository.

1. In the GitHub repository, open **Settings → Pages** and select **GitHub Actions** as the source.
2. Push the changes to `main`. The **Deploy landing page** workflow publishes changes to `docs/` or the workflow itself. It can also be run manually from the Actions tab.
3. The default site address is https://patrickzach.github.io/BasedFTP/.

To update the page, replace `docs/index.html` with a fresh export from the landing-page project, commit, and push. The workflow uploads only `docs/`, not app sources or build artifacts.

## License

Copyright (C) 2026 Patrick Zach.

BasedFTP is licensed under the **GNU General Public License, version 3 only** (`GPL-3.0-only`). See [LICENSE](LICENSE) for the full terms.

You may use, modify, redistribute, and sell the software. When distributing modified versions or binaries, you must comply with GPLv3, including providing the corresponding source code under GPLv3. Private modifications do not require publication. The software is provided without warranty, to the extent permitted by applicable law.

When distributing an app build, include this license and make the corresponding source for that exact build available in a GPLv3-compliant manner. A link to a changing branch alone is not a substitute for the corresponding source of the distributed version.
