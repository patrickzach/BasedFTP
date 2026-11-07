#!/bin/bash
# Real FTP servers bound only to loopback; no system configuration is modified.
set -euo pipefail
cd "$(dirname "$0")/.."
FTP_TEST_PYTHON="${FTP_TEST_PYTHON:-$PWD/.build/ftp-test-venv/bin/python}"
if ! "$FTP_TEST_PYTHON" -c 'import pyftpdlib' 2>/dev/null; then
    printf '%s\n' 'Install the test-only dependency first:' 'python3 -m venv .build/ftp-test-venv' '.build/ftp-test-venv/bin/python -m pip install pyftpdlib==2.2.0' >&2
    exit 1
fi
FTP_TEST_ROOT="$(mktemp -d "$PWD/.build/basedftp-ftp.XXXXXX")"
FTP_TEST_PIDS=()
cleanup() {
    for pid in "${FTP_TEST_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    for pid in "${FTP_TEST_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    rm -rf "$FTP_TEST_ROOT"
}
trap cleanup EXIT
export BASEDFTP_FTP_TEST_PASSWORD='synthetic-"password\with:colon'
for mode in epsv pasv; do
    "$FTP_TEST_PYTHON" Tests/Fixtures/ftp-server.py "$FTP_TEST_ROOT" "$mode" > "$FTP_TEST_ROOT/$mode.log" 2>&1 &
    FTP_TEST_PIDS+=("$!")
done
for attempt in {1..100}; do
    if [[ -s "$FTP_TEST_ROOT/port-epsv" && -s "$FTP_TEST_ROOT/port-pasv" ]]; then break; fi
    sleep 0.1
done
if [[ ! -s "$FTP_TEST_ROOT/port-epsv" || ! -s "$FTP_TEST_ROOT/port-pasv" ]]; then
    cat "$FTP_TEST_ROOT/epsv.log" "$FTP_TEST_ROOT/pasv.log" >&2
    exit 1
fi
export BASEDFTP_FTP_TEST_ROOT="$FTP_TEST_ROOT"
export BASEDFTP_FTP_TEST_PORT="$(cat "$FTP_TEST_ROOT/port-epsv")"
export BASEDFTP_FTP_TEST_PASV_PORT="$(cat "$FTP_TEST_ROOT/port-pasv")"
if [[ "$#" -gt 0 ]]; then
    # Allow the SSH suite to run inside this FTP environment for combined coverage.
    "$@"
else
    bash Scripts/test.sh --filter 'BasedFTPTests.FTP(Transfer)?Tests'
fi
