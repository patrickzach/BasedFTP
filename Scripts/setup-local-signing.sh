#!/bin/bash
# One-time local signing setup. Never commit/export the private signing key.
set -euo pipefail
SIGNING_NAME='BasedFTP Local Development'
if /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -F "\"$SIGNING_NAME\"" >/dev/null; then
    printf '%s\n' 'The local signing certificate already exists; leaving it unchanged.'
    exit 0
fi
if /usr/bin/security find-certificate -c "$SIGNING_NAME" >/dev/null 2>&1; then
    printf '%s\n' 'A certificate with this name exists but is not a valid signing identity. Inspect its private key, expiration and Code Signing trust in Keychain Access; it will not be replaced automatically.' >&2
    exit 1
fi
umask 077
SIGNING_TEMP="$(mktemp -d "${TMPDIR:-/tmp/}basedftp-signing.XXXXXX")"
trap 'rm -rf "$SIGNING_TEMP"' EXIT
cat > "$SIGNING_TEMP/certificate.cnf" <<'CONFIG'
[req]
distinguished_name = dn
x509_extensions = extensions
prompt = no
[dn]
CN = BasedFTP Local Development
[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONFIG
/usr/bin/openssl req -new -newkey rsa:3072 -nodes -x509 -sha256 -days 3650 \
    -config "$SIGNING_TEMP/certificate.cnf" -keyout "$SIGNING_TEMP/key.pem" \
    -out "$SIGNING_TEMP/certificate.pem" 2>/dev/null
# A nonempty random PKCS#12 password avoids macOS/LibreSSL empty-password incompatibility.
python3 - "$SIGNING_TEMP" <<'PY'
import pathlib, secrets, subprocess, sys
root = pathlib.Path(sys.argv[1])
password = secrets.token_urlsafe(32)
(root / 'password').write_text(password)
subprocess.run(['/usr/bin/openssl', 'pkcs12', '-export', '-inkey', str(root/'key.pem'),
    '-in', str(root/'certificate.pem'), '-out', str(root/'identity.p12'),
    '-passout', 'file:'+str(root/'password')], check=True)
keychain = pathlib.Path.home()/'Library/Keychains/login.keychain-db'
subprocess.run(['/usr/bin/security', 'import', str(root/'identity.p12'), '-k', str(keychain),
    '-P', password, '-T', '/usr/bin/codesign'], check=True)
PY
# User trust for code signing only: never trust this certificate for TLS.
/usr/bin/security add-trusted-cert -r trustRoot -p codeSign "$SIGNING_TEMP/certificate.pem"
printf '%s\n' 'Local signing identity created. Keep this identity across future builds.'
