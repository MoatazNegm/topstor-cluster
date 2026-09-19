#!/bin/bash
# abdopuppet entrypoint: start git-daemon, lighttpd, sshd.

set -e

echo "[abdopuppet] starting services…"

# Ensure required directories exist
mkdir -p /srv/git
chmod 755 /srv/git

mkdir -p /var/cache/lighttpd/uploads \
         /var/cache/lighttpd/compress \
         /var/log/lighttpd \
         /run/lighttpd
chown -R lighttpd:lighttpd /var/cache/lighttpd /var/log/lighttpd /run/lighttpd || true

# Start sshd
/usr/sbin/sshd
echo "[abdopuppet] sshd started"

# Mark every bare repo as git-daemon-exportable
find /srv/git -maxdepth 2 -type d -name "*.git" -exec touch {}/git-daemon-export-ok \; 2>/dev/null || true

# Start git-daemon (receive-pack + export-all + reuseaddr)
git daemon \
    --reuseaddr \
    --export-all \
    --enable=receive-pack \
    --base-path=/srv/git \
    --listen=0.0.0.0 \
    --port=9418 \
    --detach \
    --pid-file=/var/run/git-daemon.pid \
    /srv/git
echo "[abdopuppet] git-daemon started on :9418"

# Start lighttpd in foreground (PID 1)
echo "[abdopuppet] starting lighttpd in foreground…"
exec /usr/sbin/lighttpd -D -f /etc/lighttpd/lighttpd.conf
