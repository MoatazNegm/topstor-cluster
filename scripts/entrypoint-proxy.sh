#!/bin/bash
# proxy entrypoint: re-create symlinks, start sshd + nginx, keep alive.
#
# Robustness notes:
#   * sshd is launched under `setsid` in its own session so it survives
#     a SIGHUP to the entrypoint shell and never accidentally shares a
#     controlling terminal with it.
#   * nginx is run in foreground (`daemon off;`) in a backgrounded
#     subshell so this script can `wait` on it and surface crashes.
#   * The container's PID 1 is expected to be an init that reaps
#     zombies (Docker's built-in `tini` via `init: true` in compose,
#     or the explicit `tini` invocation when running directly). The
#     `tail -f /dev/null` at the end is a deliberate idle anchor so
#     PID 1 stays alive even if init is not present.

set -e

echo "[proxy] preparing /workspace symlinks…"
mkdir -p /workspace

for repo in TopStor pace topstorweb; do
    if [ -d "/workspace/$repo" ] && [ ! -e "/$repo" ]; then
        ln -sf "/workspace/$repo" "/$repo"
        echo "[proxy] /${repo} -> /workspace/${repo}"
    fi
done

if [ -d "/workspace/TopStor" ] && [ ! -e "/TopStor" ]; then
    ln -sf /workspace/TopStor /TopStor
fi

# Ensure sshd host keys exist (idempotent; ssh-keygen -A in Dockerfile already
# creates them, but this protects against bind-mounted /etc/ssh losing them).
ssh-keygen -A >/dev/null 2>&1 || true

echo "[proxy] starting sshd (setsid, its own session)…"
# Detach from this script's process group / controlling tty. sshd forks
# per-session; with `setsid` each session belongs to its own session and
# cannot deadlock the entrypoint if a signal arrives here.
setsid /usr/sbin/sshd -E /var/log/sshd.log

# Give sshd a moment to bind the port and write its host keys' fingerprints
for i in $(seq 1 10); do
    if ss -tln | grep -qE ':22\b'; then
        echo "[proxy] sshd listening after ${i}s"
        break
    fi
    sleep 1
done

echo "[proxy] starting nginx (foreground, backgrounded)…"
nginx -g "daemon off;" &
NGINX_PID=$!

# Watchdog loop: if nginx dies, exit non-zero so the container restarts.
# If sshd dies, try to restart it (sshd is critical for management access).
(
    while true; do
        sleep 5
        if ! pgrep -x sshd >/dev/null 2>&1; then
            echo "[proxy] sshd vanished, restarting…" >&2
            setsid /usr/sbin/sshd -E /var/log/sshd.log || true
        fi
    done
) &

echo "[proxy] ready."
exec tail -f /dev/null