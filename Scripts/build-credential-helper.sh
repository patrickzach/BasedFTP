#!/bin/bash
# Keep the helper's code hash stable across main-app rebuilds and .build cleanup.
set -euo pipefail
cd "$(dirname "$0")/.."
DESTINATION="${1:?Pass the app Contents/Helpers directory}"
SIGNING_IDENTITY="${BASEDFTP_SIGNING_IDENTITY:-${EXPANDED_CODE_SIGN_IDENTITY:-BasedFTP Local Development}}"
if [[ "$SIGNING_IDENTITY" == '-' ]]; then
    printf '%s\n' 'Ad hoc preview: credential helper unavailable; use a certificate-signed build for saved credentials.' >&2
    rm -f "$DESTINATION/BasedFTPCredentials"
    exit 0
fi
SIGNING_HASH="$(/usr/bin/security find-identity -v -p codesigning | python3 -c '
import re, sys
selector=sys.argv[1]
identities=re.findall(r"\) ([0-9A-F]{40}) \"([^\"]+)\"", sys.stdin.read())
matches=[h for h,n in identities if selector==n or selector.upper()==h]
if len(matches)!=1: raise SystemExit("Choose one valid signing certificate by its exact name or SHA-1.")
print(matches[0])' "$SIGNING_IDENTITY")"
HELPER_KEY="$(cat Sources/CredentialSupport/*.swift Sources/BasedFTPCredentials/main.swift Scripts/build-credential-helper.sh | shasum -a 256 | cut -d ' ' -f 1)"
HELPER_CACHE="${BASEDFTP_HELPER_CACHE:-$HOME/Library/Application Support/BasedFTP/Signing/Helpers}"
HELPER_DIRECTORY="$HELPER_CACHE/$SIGNING_HASH/$HELPER_KEY"
mkdir -p "$HELPER_DIRECTORY" "$DESTINATION"
chmod 700 "$HELPER_CACHE" "$HELPER_DIRECTORY"
# Concurrent Xcode/script builds must reuse the same first-built executable.
HELPER_LOCK="$HELPER_DIRECTORY/.compile-lock"
for ATTEMPT in {1..60}; do
    if mkdir "$HELPER_LOCK" 2>/dev/null; then break; fi
    if [[ "$ATTEMPT" == 60 ]]; then echo 'Credential helper build is locked; another build may still be running.' >&2; exit 1; fi
    sleep 1
done
HELPER_TEMP=''
cleanup_helper() {
    if [[ -n "$HELPER_TEMP" ]]; then rm -rf "$HELPER_TEMP"; fi
    rmdir "$HELPER_LOCK"
}
trap cleanup_helper EXIT
HELPER="$HELPER_DIRECTORY/BasedFTPCredentials"
REQUIREMENT="identifier \"app.basedftp.credentials-helper\" and certificate leaf = H\"$SIGNING_HASH\""
if [[ -f "$HELPER" ]]; then
    # Do not silently regenerate a corrupt cache or accept a different signer.
    codesign --verify --strict -R "=$REQUIREMENT" "$HELPER"
else
    HELPER_TEMP="$(mktemp -d "$HELPER_DIRECTORY/compile.XXXXXX")"
    for HELPER_ARCH in arm64 x86_64; do
        swiftc -O -target "$HELPER_ARCH-apple-macosx14.0" Sources/CredentialSupport/*.swift \
            Sources/BasedFTPCredentials/main.swift -o "$HELPER_TEMP/$HELPER_ARCH"
    done
    lipo -create "$HELPER_TEMP/arm64" "$HELPER_TEMP/x86_64" -output "$HELPER_TEMP/BasedFTPCredentials"
    codesign --force --sign "$SIGNING_HASH" --identifier app.basedftp.credentials-helper "$HELPER_TEMP/BasedFTPCredentials"
    codesign --verify --strict -R "=$REQUIREMENT" "$HELPER_TEMP/BasedFTPCredentials"
    mv "$HELPER_TEMP/BasedFTPCredentials" "$HELPER"
fi
cp "$HELPER" "$DESTINATION/BasedFTPCredentials.new"
mv -f "$DESTINATION/BasedFTPCredentials.new" "$DESTINATION/BasedFTPCredentials"
