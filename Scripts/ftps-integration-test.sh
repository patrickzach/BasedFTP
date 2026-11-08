#!/bin/bash
# Ephemeral private CA and loopback TLS servers; no system trust/keychain changes.
set -euo pipefail
cd "$(dirname "$0")/.."
FTPS_TEST_PYTHON="${FTP_TEST_PYTHON:-$PWD/.build/ftp-test-venv/bin/python}"
if ! "$FTPS_TEST_PYTHON" -c 'import pyftpdlib, OpenSSL, cryptography' 2>/dev/null; then
    printf '%s\n' 'Install test-only dependencies first:' 'python3 -m venv .build/ftp-test-venv' '.build/ftp-test-venv/bin/python -m pip install pyftpdlib==2.2.0 pyOpenSSL==26.4.0' >&2
    exit 1
fi
FTPS_TEST_ROOT="$(mktemp -d "$PWD/.build/basedftp-ftps.XXXXXX")"
FTPS_TEST_PIDS=()
cleanup() {
    for pid in "${FTPS_TEST_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    for pid in "${FTPS_TEST_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    rm -rf "$FTPS_TEST_ROOT"
}
trap cleanup EXIT
"$FTPS_TEST_PYTHON" Tests/Fixtures/ftps-certificates.py "$FTPS_TEST_ROOT"
export BASEDFTP_FTP_TEST_PASSWORD='synthetic-"password\with:colon'
for mode in ftps ftps-pasv ftps-implicit ftps-expired ftps-no-data ftps-bad-data ftps-legacy ftps-rotate plain; do
    "$FTPS_TEST_PYTHON" Tests/Fixtures/ftp-server.py "$FTPS_TEST_ROOT" "$mode" > "$FTPS_TEST_ROOT/$mode.log" 2>&1 &
    FTPS_TEST_PIDS+=("$!")
done
for mode in ftps ftps-pasv ftps-implicit ftps-expired ftps-no-data ftps-bad-data ftps-legacy ftps-rotate plain; do
    for attempt in {1..100}; do
        if [[ -s "$FTPS_TEST_ROOT/port-$mode" ]]; then break; fi
        sleep 0.1
    done
    if [[ ! -s "$FTPS_TEST_ROOT/port-$mode" ]]; then cat "$FTPS_TEST_ROOT/$mode.log" >&2; exit 1; fi
done
export BASEDFTP_FTPS_TEST_ROOT="$FTPS_TEST_ROOT"
if [[ "$#" -gt 0 ]]; then "$@"; else bash Scripts/test.sh --filter 'BasedFTPTests.FTPSTests'; fi
