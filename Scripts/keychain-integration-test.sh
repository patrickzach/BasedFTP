#!/bin/bash
# Real Keychain regression using only random synthetic accounts and disabled UI.
set -euo pipefail
cd "$(dirname "$0")/.."
SIGNING_IDENTITY="${BASEDFTP_SIGNING_IDENTITY:-BasedFTP Local Development}"
[[ "$SIGNING_IDENTITY" != '-' ]] || { echo 'A certificate-based signing identity is required.' >&2; exit 1; }
mkdir -p .build
TEST_ROOT="$(mktemp -d "$PWD/.build/keychain-test.XXXXXX")"
TEST_ACCOUNT="$(uuidgen)"
cleanup() {
    if [[ -x "$TEST_ROOT/current.app/Contents/MacOS/BasedFTP" ]]; then
        "$TEST_ROOT/current.app/Contents/MacOS/BasedFTP" delete "$TEST_ACCOUNT" >/dev/null 2>&1 || true
    fi
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
python3 - "$TEST_ROOT" <<'PY'
from pathlib import Path
import plistlib, sys
root=Path(sys.argv[1])
store=Path('Sources/BasedFTP/Security.swift').read_text().split('@MainActor final class ProfileStore:')[0]
helper=r'''
let operation = CommandLine.arguments[1]
let id = UUID(uuidString: CommandLine.arguments[2])!
let account = id.uuidString + ".password"
if operation == "denied" {
    // Bypass the app-side check to exercise the helper's actual caller check.
    let process = Process(); let input = Pipe(); let output = Pipe()
    process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/BasedFTPCredentials")
    process.standardInput = input; process.standardOutput = output
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(CredentialRequest(operation: .read, account: account)))
    try input.fileHandleForWriting.close()
    let result = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    guard process.terminationStatus != 0, result.isEmpty else { fatalError("Unrelated signer was allowed") }
    print("Unrelated parent rejected without revealing data")
} else if operation == "delete" {
    try CredentialStore.save("", profile: id, purpose: "password")
    guard try CredentialStore.read(account: account) == nil else { fatalError("Deletion failed") }
} else if operation == "create" {
    try CredentialStore.save("synthetic-v1", profile: id, purpose: "password")
} else {
    let expected = operation == "update" ? "synthetic-v1" : "synthetic-v2"
    guard try CredentialStore.read(account: account) == expected else { fatalError("Incorrect synthetic credential") }
    if operation == "update" { try CredentialStore.save("synthetic-v2", profile: id, purpose: "password") }
}
'''
(root/'main.swift').write_text(store + helper)
for name in ['version1', 'version2']:
    contents=root/(name+'.app')/'Contents'
    (contents/'MacOS').mkdir(parents=True)
    (contents/'Helpers').mkdir()
    (contents/'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'BasedFTP', 'CFBundleIdentifier':'app.basedftp.client', 'CFBundlePackageType':'APPL'}))
PY
if [[ -n "${BASEDFTP_TEST_APP:-}" ]]; then
    cp "$BASEDFTP_TEST_APP/Contents/Helpers/BasedFTPCredentials" "$TEST_ROOT/BasedFTPCredentials"
else
    swiftc -O -D CREDENTIAL_TEST_NO_UI Sources/CredentialSupport/*.swift Sources/BasedFTPCredentials/main.swift -o "$TEST_ROOT/BasedFTPCredentials"
    codesign --force --sign "$SIGNING_IDENTITY" --identifier app.basedftp.credentials-helper "$TEST_ROOT/BasedFTPCredentials"
fi
for VERSION in version1 version2; do
    swiftc Sources/CredentialSupport/*.swift "$TEST_ROOT/main.swift" -o "$TEST_ROOT/$VERSION.app/Contents/MacOS/BasedFTP"
    cp "$TEST_ROOT/BasedFTPCredentials" "$TEST_ROOT/$VERSION.app/Contents/Helpers/"
    codesign --force --sign "$SIGNING_IDENTITY" "$TEST_ROOT/$VERSION.app"
    codesign --verify --deep --strict "$TEST_ROOT/$VERSION.app"
    printf '\nlet buildVariant = 2\n' >> "$TEST_ROOT/main.swift"
done
python3 - "$TEST_ROOT" <<'PYCODE'
import pathlib, re, subprocess, sys
root=pathlib.Path(sys.argv[1])
def digest(name):
    result=subprocess.run(['codesign', '-dvvv', str(root/(name+'.app'))], capture_output=True, text=True, check=True)
    return re.search(r'CDHash=(\w+)', result.stderr).group(1)
assert digest('version1') != digest('version2'), 'The app builds must have different code hashes'
assert (root/'version1.app/Contents/Helpers/BasedFTPCredentials').read_bytes() == (root/'version2.app/Contents/Helpers/BasedFTPCredentials').read_bytes()
PYCODE
cp -R "$TEST_ROOT/version2.app" "$TEST_ROOT/unrelated.app"
codesign --force --sign - "$TEST_ROOT/unrelated.app"
cp -R "$TEST_ROOT/version2.app" "$TEST_ROOT/wrong-id.app"
codesign --force --sign "$SIGNING_IDENTITY" --identifier app.basedftp.unrelated "$TEST_ROOT/wrong-id.app"
cp -R "$TEST_ROOT/version1.app" "$TEST_ROOT/current.app"
"$TEST_ROOT/current.app/Contents/MacOS/BasedFTP" create "$TEST_ACCOUNT"
rm -rf "$TEST_ROOT/current.app"
cp -R "$TEST_ROOT/version2.app" "$TEST_ROOT/current.app"
"$TEST_ROOT/current.app/Contents/MacOS/BasedFTP" update "$TEST_ACCOUNT"
rm -rf "$TEST_ROOT/current.app"
cp -R "$TEST_ROOT/version1.app" "$TEST_ROOT/current.app"
"$TEST_ROOT/current.app/Contents/MacOS/BasedFTP" read "$TEST_ACCOUNT"
"$TEST_ROOT/unrelated.app/Contents/MacOS/BasedFTP" denied "$TEST_ACCOUNT"
"$TEST_ROOT/wrong-id.app/Contents/MacOS/BasedFTP" denied "$TEST_ACCOUNT"
if [[ -n "${BASEDFTP_TEST_APP:-}" ]]; then
    python3 - "$BASEDFTP_TEST_APP" "$TEST_ACCOUNT" <<'PYCODE'
import os, pathlib, subprocess, sys
app, account = sys.argv[1:]
env = dict(os.environ, BASEDFTP_PROFILE=account, SSH_ASKPASS_REQUIRE='force')
result = subprocess.run([str(pathlib.Path(app)/'Contents/MacOS/BasedFTP'), 'Password:'],
    env=env, capture_output=True, check=True)
assert result.stdout == b'synthetic-v2\n', 'Actual app ASKPASS did not retrieve the synthetic credential'
print('Actual app ASKPASS retrieved the synthetic credential through the production helper.')
PYCODE
fi
"$TEST_ROOT/current.app/Contents/MacOS/BasedFTP" delete "$TEST_ACCOUNT"
printf '%s\n' 'Keychain cross-build read/update, stable helper, deletion, and unrelated-caller rejection passed.'
