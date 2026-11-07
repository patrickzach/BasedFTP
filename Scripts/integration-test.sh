#!/bin/bash
# An isolated loopback sshd. No modifications to ~/.ssh or system configuration.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_ROOT="$(mktemp -d $PWD/.build/basedftp-sshd.XXXXXX)"
SSHD_PID=""
AGENT_PID=""
cleanup() { if [[ -n "$AGENT_PID" ]]; then kill "$AGENT_PID" 2>/dev/null || true; fi; if [[ -n "$SSHD_PID" ]]; then kill "$SSHD_PID" 2>/dev/null || true; fi; rm -rf "$TEST_ROOT"; }
trap cleanup EXIT
chmod 700 "$TEST_ROOT"
ssh-keygen -q -t ed25519 -N '' -f "$TEST_ROOT/host"
ssh-keygen -q -t ed25519 -N '' -f "$TEST_ROOT/client"
ssh-keygen -q -t rsa -b 3072 -N '' -f "$TEST_ROOT/rsa"
ssh-keygen -q -t ecdsa -b 256 -N '' -f "$TEST_ROOT/ecdsa"
ssh-keygen -q -t ed25519 -N 'synthetic-test-passphrase' -f "$TEST_ROOT/encrypted"
ssh-keygen -q -t ed25519 -N '' -f "$TEST_ROOT/wrong-host"
cat "$TEST_ROOT/client.pub" "$TEST_ROOT/rsa.pub" "$TEST_ROOT/ecdsa.pub" "$TEST_ROOT/encrypted.pub" > "$TEST_ROOT/authorized_keys"
TEST_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
cat > "$TEST_ROOT/sshd_config" <<CONFIG
ListenAddress 127.0.0.1
Port $TEST_PORT
HostKey $TEST_ROOT/host
PidFile $TEST_ROOT/pid
AuthorizedKeysFile $TEST_ROOT/authorized_keys
StrictModes yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PermitRootLogin no
AllowUsers $(id -un)
Subsystem sftp /usr/libexec/sftp-server
LogLevel VERBOSE
PerSourcePenalties no
CONFIG
/usr/sbin/sshd -D -e -f "$TEST_ROOT/sshd_config" > "$TEST_ROOT/sshd.log" 2>&1 &
SSHD_PID=$!
# known_hosts derives directly from the generated host key, not from the network.
printf '[127.0.0.1]:%s ' "$TEST_PORT" > "$TEST_ROOT/known_hosts"
cut -d ' ' -f 1,2 "$TEST_ROOT/host.pub" >> "$TEST_ROOT/known_hosts"
export BASEDFTP_TEST_HOST=127.0.0.1 BASEDFTP_TEST_PORT="$TEST_PORT" BASEDFTP_TEST_USER="$(id -un)"
export BASEDFTP_TEST_KEY="$TEST_ROOT/client" BASEDFTP_TEST_DIRECTORY="$TEST_ROOT" BASEDFTP_TEST_KNOWN_HOSTS="$TEST_ROOT/known_hosts"
printf '[127.0.0.1]:%s ' "$TEST_PORT" > "$TEST_ROOT/wrong_known_hosts"
cut -d ' ' -f 1,2 "$TEST_ROOT/wrong-host.pub" >> "$TEST_ROOT/wrong_known_hosts"
export BASEDFTP_TEST_WRONG_KNOWN_HOSTS="$TEST_ROOT/wrong_known_hosts"
if ! bash Scripts/test.sh; then cat "$TEST_ROOT/sshd.log"; exit 1; fi
for KEY in rsa ecdsa; do
    export BASEDFTP_TEST_KEY="$TEST_ROOT/$KEY"
    if ! bash Scripts/test.sh --filter CoreTests.testRealSSHIntegrationWhenConfigured; then cat "$TEST_ROOT/sshd.log"; exit 1; fi
done
# Passphrase-protected key unlocked by a dedicated agent (synthetic secret only).
ssh-agent -D -a "$TEST_ROOT/agent" > "$TEST_ROOT/agent.log" 2>&1 &
AGENT_PID=$!
export SSH_AUTH_SOCK="$TEST_ROOT/agent"
cat > "$TEST_ROOT/askpass" <<'ASKPASS'
#!/bin/sh
printf '%s\n' 'synthetic-test-passphrase'
ASKPASS
chmod 700 "$TEST_ROOT/askpass"
SSH_ASKPASS="$TEST_ROOT/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 ssh-add "$TEST_ROOT/encrypted"
export BASEDFTP_TEST_KEY="$TEST_ROOT/encrypted"
if ! bash Scripts/test.sh --filter CoreTests.testRealSSHIntegrationWhenConfigured; then cat "$TEST_ROOT/sshd.log"; exit 1; fi
