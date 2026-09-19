#!/bin/bash
# proxy entrypoint: re-create symlinks, start sshd + nginx, keep alive.

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

echo "[proxy] starting sshd…"
/usr/sbin/sshd

echo "[proxy] starting nginx…"
nginx -g "daemon off;" &
NGINX_PID=$!

# Keep alive; surface nginx exit
echo "[proxy] ready."
exec tail -f /dev/null
