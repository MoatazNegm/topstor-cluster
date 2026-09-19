#!/bin/bash
# zfs entrypoint — behaves like rc.local on a physical server:
#   1. Set up PATH, symlinks, environment
#   2. Start RabbitMQ (via systemctl wrapper)
#   3. Start crond
#   4. Start sshd
#   5. Launch docker_setup.sh in background (loops on etcd until cluster starts)
#   6. Keep container alive with tail -f /dev/null
#
# Docker CLI inside this container uses the host's /var/run/docker.sock
# via bind-mount. This is required: docker_setup.sh acts as a cluster
# bootstrapper and calls `docker run/exec/logs` to orchestrate etcd, intsmb,
# wetty, and other containers on the host's docker daemon. The trade-off is
# that `docker ps` from inside this container will show ALL host containers
# (including those not part of the TopStor cluster) — this is expected and
# not a security boundary (privileged container + docker socket = full host
# docker access).

# NOTE: 'set -e' is NOT used here — many commands in the container environment
# are expected to fail (modprobe, systemctl restart, nmcli, etc.) and must not
# abort the entrypoint before the seed files and background services are set up.
set +e

export PATH="/opt/erlang/bin:/opt/rabbitmq/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

echo "[zfs] preparing /workspace symlinks…"
mkdir -p /workspace

for repo in TopStor pace topstorweb; do
    if [ -d "/workspace/$repo" ] && [ ! -e "/$repo" ]; then
        ln -sf "/workspace/$repo" "/$repo"
        echo "[zfs] /${repo} -> /workspace/${repo}"
    fi
done

if [ -d "/workspace/TopStor" ] && [ ! -e "/TopStor" ]; then
    ln -sf /workspace/TopStor /TopStor
fi

# Symlinks — best-effort; failures here are non-fatal
[ -e /usr/local/bin/zsh ] || ln -sf /usr/bin/zsh /usr/local/bin/zsh  2>/dev/null
[ -e /bin/etcdctl      ] || ln -sf /usr/local/bin/etcdctl /bin/etcdctl  2>/dev/null
[ -e /sbin/zfs         ] || ln -sf /usr/local/sbin/zfs /sbin/zfs          2>/dev/null
[ -e /sbin/zpool       ] || ln -sf /usr/local/sbin/zpool /sbin/zpool       2>/dev/null

# ────────────────────────────────────────────────────────────────────────
# systemctl wrapper — intercepts systemd calls from scripts (docker_setup.sh
# and others) and provides container-safe implementations.
# ────────────────────────────────────────────────────────────────────────
cat > /usr/local/bin/systemctl <<'SYS'
#!/bin/bash
# systemctl wrapper — provides container-safe implementations for scripts that
# expect systemd (docker_setup.sh).  "is-active" returns proper exit codes so
# caller wait-loops (while [ $? -ne 0 ]) work correctly.
#
# Exit code convention (matching systemd):
#   0  = active/running
#   3  = inactive/not running
#   4  = unknown (unhandled service)

cmd="${1:-}"; shift   # peel off the verb

case "$cmd" in
  start)
    # "start rabbitmq-server" or "start rabbitmq-server &" (backgrounded)
    svc="${1:-}"
    if [ "$svc" = "rabbitmq-server" ]; then
        pgrep -f beam.smp >/dev/null 2>&1 && echo "RabbitMQ already running" || \
          (nohup /opt/rabbitmq/sbin/rabbitmq-server > /var/log/rabbitmq.log 2>&1 &
           echo $! > /run/rabbitmq-server.pid)
        exit 0
    fi
    # Other start targets: iscsid/target/docker — silently succeed in container
    exit 0
    ;;

  is-active)
    svc="${1:-}"
    if [ "$svc" = "rabbitmq-server" ]; then
        if pgrep -f beam.smp >/dev/null 2>&1; then
            echo "active"; exit 0
        else
            echo "inactive"; exit 3
        fi
    fi
    echo "inactive"; exit 4
    ;;

  status)
    svc="${1:-}"
    if [ "$svc" = "rabbitmq-server" ]; then
        if pgrep -f beam.smp >/dev/null 2>&1; then
            echo "rabbitmq-server is running"; exit 0
        else
            echo "rabbitmq-server is not running"; exit 3
        fi
    fi
    # Unknown service — try real systemctl, then fail gracefully
    if command -v /usr/bin/systemctl >/dev/null 2>&1; then
        exec /usr/bin/systemctl status "$@"
    fi
    echo "rabbitmq-server is not running"; exit 3
    ;;

  stop|disable|enable|restart|reload)
    # These are not supported in a container without systemd.
    # For rabbitmq we at least kill the process.
    if [ "${1:-}" = "rabbitmq-server" ]; then
        pkill -f beam.smp 2>/dev/null; rm -f /run/rabbitmq-server.pid
    fi
    exit 0
    ;;

  *)
    # Unknown verb — delegate to real systemctl if available
    if command -v /usr/bin/systemctl >/dev/null 2>&1; then
        exec /usr/bin/systemctl "$@"
    fi
    echo "systemctl: not supported in container (unhandled: $cmd $*)" >&2
    exit 1
    ;;
esac
SYS
chmod 755 /usr/local/bin/systemctl

# ────────────────────────────────────────────────────────────────────────
# Combined docker wrapper — handles both 'run' and 'exec' subcommands.
#
# docker run:
#   1. "container name already in use"  → remove old container, retry
#   2. Port-binding to an unreachable host IP → strip that -p arg only;
#      container still starts without that host port (fine for internal svc)
#   NOTE: We no longer exit 0 on port failure — we let docker attempt the run.
#
# docker exec:
#   When targeting etcdclient and the command starts with /pace/*.py,
#   copy the scripts from /workspace/pace (linux-env volume) into etcdclient's
#   /pace before executing. This works around the empty /pace bind mount.
# ────────────────────────────────────────────────────────────────────────
cat > /usr/local/bin/docker <<'DOCK'
#!/bin/bash
DOCKER_REAL="/usr/bin/docker"

# ── docker run ──────────────────────────────────────────────────────────
if [ "$1" = "run" ]; then
    # Parse args
    args=("$@")
    NAME_ARG=""
    new_args=()
    i=0
    while [ $i -lt ${#args[@]} ]; do
        arg="${args[$i]}"
        if [ "$arg" = "--name" ]; then
            NAME_ARG="${args[$((i+1))]}"
            new_args+=("$arg" "${args[$((i+1))]}")
            i=$((i+2))
            continue
        fi
        # Pass through -p arguments as-is; Docker will handle binding errors
        # (e.g. -p hostip:port when hostip is not on any host interface).
        # The script relies on these port bindings — do not strip or modify them.
        new_args+=("$arg")
        i=$((i+1))
    done

    $DOCKER_REAL "${new_args[@]}" 2>/tmp/docker_err.txt
    EXIT=$?

    if grep -q "Conflict. Container name" /tmp/docker_err.txt 2>/dev/null; then
        echo "[docker run] removing conflicting container '$NAME_ARG'…"
        $DOCKER_REAL rm -f "$NAME_ARG" 2>/dev/null
        rm -f /tmp/docker_err.txt
        exec $DOCKER_REAL "${new_args[@]}"
    fi
    rm -f /tmp/docker_err.txt
    exit $EXIT
fi

# ── docker exec ─────────────────────────────────────────────────────────
if [ "$1" = "exec" ]; then
    # Extract container name and check if command targets etcdclient /pace/*.py
    args=("$@")
    CONTAINER=""
    CMD_START_IDX=2
    i=0
    for arg in "$@"; do
        if [ "$i" -eq 1 ]; then
            CONTAINER="$arg"
        fi
        if [ "$i" -ge 2 ]; then
            if [[ "$arg" == /* ]]; then
                CMD_START_IDX=$i
                break
            fi
        fi
        i=$((i+1))
    done

    # If targeting etcdclient and command starts with /pace/, pre-populate /pace
    if [ "$CONTAINER" = "etcdclient" ]; then
        cmd="${args[$CMD_START_IDX]:-}"
        if [[ "$cmd" == /pace/* ]]; then
            # Wait for etcdclient to be responsive (up to 30s)
            for retry in $(seq 1 30); do
                if $DOCKER_REAL exec "$CONTAINER" true 2>/dev/null; then
                    break
                fi
                sleep 1
            done
            # Copy all *.py files from /workspace/pace into etcdclient:/pace
            if [ -d /workspace/pace ] && [ -n "$(ls -A /workspace/pace/ 2>/dev/null)" ]; then
                echo "[docker exec] populating /pace inside etcdclient from /workspace/pace…"
                $DOCKER_REAL exec "$CONTAINER" mkdir -p /pace 2>/dev/null
                for f in /workspace/pace/*.py; do
                    [ -f "$f" ] || continue
                    fname=$(basename "$f")
                    $DOCKER_REAL cp "$f" "$CONTAINER:/pace/$fname" 2>/dev/null
                done
            fi
        fi
    fi
    exec $DOCKER_REAL "$@"
fi

# ── all other subcommands: pass through directly ────────────────────────
exec $DOCKER_REAL "$@"
DOCK
chmod 755 /usr/local/bin/docker

# ────────────────────────────────────────────────────────────────────────
# Seed data required by docker_setup.sh on every start.
# ────────────────────────────────────────────────────────────────────────
mkdir -p /TopStordata /root/gitrepo /root/etcddata
# NOTE: /TopStordata/diskchange must be a REGULAR FILE, not a directory.
# docker_setup.sh line 75 does: echo stop stop stop stop > $mypid
# where $mypid=/TopStordata/diskchange — a directory would cause "Is a directory".
touch /TopStordata/diskchange
# Force-create each seed file atomically using tee
echo "no"         | tee /root/nodeconfigured      > /dev/null
echo "zfsnode"    | tee /root/hostname           > /dev/null
echo "10.11.11.14" | tee /root/newipaddr        > /dev/null
echo "nameserver 10.11.12.7" | tee /root/gitrepo/resolv.conf > /dev/null
echo "[zfs] seed files ready"

# ────────────────────────────────────────────────────────────────────────
# Docker-in-Docker: unmount the host's docker socket so this container can
# run its own dockerd and have isolated container visibility (docker ps shows
# only containers started by this ZFS node, not all host containers).
# ────────────────────────────────────────────────────────────────────────
echo "[zfs] setting up Docker-in-Docker…"
# Unmount host socket so dockerd can claim it
umount /var/run/docker.sock 2>/dev/null || true
# Ensure dockerd graph root is writable (isolated from host's /var/lib/docker)
mkdir -p /var/lib/docker-inner

echo "[zfs] starting dockerd (Docker-in-Docker)…"
# Use an isolated graph root so dockerd has no conflicts with the host's docker.
# /var/lib/docker-inner is local to this container; the host's /var/lib/docker
# mount is ignored (unmounted above). VFS driver avoids ZFS kernel module deps.
nohup /usr/bin/dockerd \
  --host=unix:///var/run/docker.sock \
  --storage-driver=vfs \
  --data-root=/var/lib/docker-inner \
  --exec-root=/var/run/docker \
  > /var/log/dockerd.log 2>&1 &

# Wait for dockerd to be ready (up to 30s)
echo "[zfs] waiting for dockerd to start…"
for i in $(seq 1 30); do
    if /usr/bin/docker info >/dev/null 2>&1; then
        echo "[zfs] dockerd ready after ${i}s"
        break
    fi
    sleep 1
done

# ────────────────────────────────────────────────────────────────────────
# Start services
# ────────────────────────────────────────────────────────────────────────
echo "[zfs] starting rabbitmq-server…"
pgrep -x beam.smp >/dev/null 2>&1 || \
  (nohup /opt/rabbitmq/sbin/rabbitmq-server > /var/log/rabbitmq.log 2>&1 &)
sleep 2

echo "[zfs] starting crond…"
/usr/sbin/crond -n &

echo "[zfs] starting sshd…"
/usr/sbin/sshd

# ────────────────────────────────────────────────────────────────────────
# docker_setup.sh — runs automatically on every start (like rc.local)
# ────────────────────────────────────────────────────────────────────────
if [ ! -f /tmp/docker_setup_disabled ]; then
    echo "[zfs] starting docker_setup.sh (background, loops on etcd)…"
    cd /TopStor || cd /workspace/TopStor || true
    nohup bash ./docker_setup.sh > /var/log/docker_setup.log 2>&1 &
    DOCKER_SETUP_PID=$!
    echo "[zfs] docker_setup.sh running as PID $DOCKER_SETUP_PID"
else
    echo "[zfs] docker_setup.sh auto-run disabled"
fi

# Keep container alive
echo "[zfs] ready."
tail -f /dev/null
