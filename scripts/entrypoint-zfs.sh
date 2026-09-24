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
    if [ "$svc" = "NetworkManager" ]; then
        mkdir -p /var/run/NetworkManager /var/lib/NetworkManager /run/dbus /var/lib/dbus
        if pgrep -x NetworkManager >/dev/null 2>&1; then
            echo "NetworkManager already running"; exit 0
        fi
        # Install the double-fork daemonizer (idempotent — only if missing).
        if [ ! -x /usr/local/sbin/start-nm.py ]; then
            echo "systemctl: start-nm.py not installed; NetworkManager cannot start" >&2
            exit 1
        fi
        /usr/local/sbin/start-nm.py
        # Wait up to 15s for nmcli to become responsive so callers can use it.
        for i in $(seq 1 15); do
            if nmcli general status >/dev/null 2>&1; then
                echo "NetworkManager started after ${i}s"
                exit 0
            fi
            sleep 1
        done
        echo "NetworkManager failed to start within 15s" >&2
        exit 1
    fi
    if [ "$svc" = "docker" ]; then
        # docker_setup.sh calls `systemctl start docker` after it
        # configures cmynode, expecting DinD to be live. The container
        # has no systemd, so we launch dockerd directly with the same
        # isolated graph root the entrypoint uses.
        if pgrep -x dockerd >/dev/null 2>&1; then
            echo "docker daemon already running"; exit 0
        fi
        # Full isolation from the host's docker: drop any leaked bind
        # mounts of /var/run/docker.sock and /var/lib/docker. `-l` (lazy)
        # works even when the path is busy with active overlay mounts.
        umount /var/run/docker.sock 2>/dev/null || true
        umount -l /var/lib/docker 2>/dev/null || true
        # Clean up stale pidfile/socket from a crashed previous run.
        rm -f /var/run/docker.pid /var/run/docker.sock
        rm -rf /var/run/docker
        rm -rf /docker-data/containerd /docker-data/tmp /docker-data/exec 2>/dev/null || true
        mkdir -p /docker-data
        nohup /usr/bin/dockerd \
            --host=unix:///var/run/docker.sock \
            --storage-driver=vfs \
            --data-root=/docker-data \
            --exec-root=/docker-data/exec \
            > /var/log/dockerd.log 2>&1 &
        disown
        for i in $(seq 1 20); do
            if [ -S /var/run/docker.sock ] && timeout 2 docker info >/dev/null 2>&1; then
                echo "docker daemon started after ${i}s"
                exit 0
            fi
            sleep 1
        done
        echo "docker daemon failed to start within 20s" >&2
        exit 1
    fi
    # Other start targets: iscsid/target — silently succeed in container
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
    if [ "$svc" = "NetworkManager" ]; then
        if nmcli general status >/dev/null 2>&1; then
            echo "active"; exit 0
        else
            echo "inactive"; exit 3
        fi
    fi
    if [ "$svc" = "docker" ]; then
        if [ -S /var/run/docker.sock ] && timeout 2 docker info >/dev/null 2>&1; then
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
    if [ "$svc" = "NetworkManager" ]; then
        if nmcli general status >/dev/null 2>&1; then
            echo "NetworkManager is running"; exit 0
        else
            echo "NetworkManager is not running"; exit 3
        fi
    fi
    if [ "$svc" = "docker" ]; then
        if [ -S /var/run/docker.sock ] && timeout 2 docker info >/dev/null 2>&1; then
            echo "docker daemon is running"; exit 0
        else
            echo "docker daemon is not running"; exit 3
        fi
    fi
    # Unknown service — try real systemctl, then fail gracefully
    if command -v /usr/bin/systemctl >/dev/null 2>&1; then
        exec /usr/bin/systemctl status "$@"
    fi
    echo "service is not running"; exit 3
    ;;

  stop|disable|enable|restart|reload)
    # These are not supported in a container without systemd.
    # For rabbitmq we at least kill the process.
    if [ "${1:-}" = "rabbitmq-server" ]; then
        pkill -f beam.smp 2>/dev/null; rm -f /run/rabbitmq-server.pid
    fi
    if [ "${1:-}" = "NetworkManager" ]; then
        # `restart` is special: kill, then re-launch via start-nm.py.
        # docker_setup.sh line 169 does `systemctl restart NetworkManager`
        # after a cluster config reset, and the rest of the script needs
        # nmcli to be live immediately afterwards.
        if [ "$cmd" = "restart" ]; then
            pkill -x NetworkManager 2>/dev/null
            sleep 1
            /usr/local/sbin/start-nm.py
            for i in $(seq 1 15); do
                if nmcli general status >/dev/null 2>&1; then
                    echo "NetworkManager restarted after ${i}s"
                    exit 0
                fi
                sleep 1
            done
            exit 1
        fi
        # `stop` / `disable` / `enable` / `reload` just kill; the entrypoint
        # will not auto-restart it.
        pkill -x NetworkManager 2>/dev/null
    fi
    if [ "${1:-}" = "docker" ]; then
        if [ "$cmd" = "restart" ]; then
            pkill -x dockerd 2>/dev/null
            pkill -x containerd 2>/dev/null
            sleep 2
            # Re-launch via the same logic as `start`.
            umount /var/run/docker.sock 2>/dev/null || true
            umount -l /var/lib/docker 2>/dev/null || true
            rm -f /var/run/docker.pid /var/run/docker.sock
            rm -rf /var/run/docker
            rm -rf /docker-data/containerd /docker-data/tmp /docker-data/exec 2>/dev/null || true
            mkdir -p /docker-data
            nohup /usr/bin/dockerd \
                --host=unix:///var/run/docker.sock \
                --storage-driver=vfs \
                --data-root=/docker-data \
                --exec-root=/docker-data/exec \
                > /var/log/dockerd.log 2>&1 &
            disown
            for i in $(seq 1 20); do
                if [ -S /var/run/docker.sock ] && timeout 2 docker info >/dev/null 2>&1; then
                    echo "docker daemon restarted after ${i}s"
                    exit 0
                fi
                sleep 1
            done
            exit 1
        fi
        # `stop` / `disable` / `enable` just kill dockerd.
        pkill -x dockerd 2>/dev/null
        pkill -x containerd 2>/dev/null
        rm -f /var/run/docker.pid
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
# Full isolation from the host's docker daemon:
#   1. Unmount the host's docker socket so dockerd creates its own.
#   2. Unmount the host's /var/lib/docker (mounted by docker-compose) so the
#      container cannot accidentally read/write the host's docker graph root.
#      The DinD uses /docker-data (a host bind-mount) for both --data-root
#      and --exec-root; images loaded from /docker-images live entirely on
#      host disk and never enter this container's overlay.
# `-l` does a lazy umount: succeeds even if the path is busy with overlays,
# detaches it from the filesystem tree, and cleans up once references drop.
umount /var/run/docker.sock 2>/dev/null || true
umount -l /var/lib/docker 2>/dev/null || true
# Ensure dockerd graph root is writable (host bind-mount /docker-data)
mkdir -p /docker-data

echo "[zfs] starting dockerd (Docker-in-Docker)…"
# Use an isolated graph root on host disk so dockerd has no conflicts with
# the host's docker. /docker-data is bind-mounted from
# /root/topstor/volumes/zfs-docker-data on the host; the host's
# /var/lib/docker mount is ignored (unmounted above). VFS driver avoids
# ZFS kernel module deps.

# Clean up stale pidfile/socket/containerd state from a previous container run.
# dockerd refuses to start when /var/run/docker.pid references a "running"
# process — after `docker stop`, the old PID file survives in the image's
# overlay layer, and the new container's PID namespace may assign that same
# number to an unrelated process, which dockerd then mistakes for a live daemon.
# /var/run/docker/containerd also keeps a containerd-shim/bolt DB lock from the
# previous run, which is enough to make `containerd` exit with "signal: killed"
# during the very first milliseconds of startup. Removing both before launch
# makes every fresh start deterministic.
rm -f /var/run/docker.pid /var/run/docker.sock
rm -rf /var/run/docker
rm -rf /docker-data/containerd /docker-data/tmp /docker-data/exec 2>/dev/null || true
mkdir -p /docker-data

nohup /usr/bin/dockerd \
  --host=unix:///var/run/docker.sock \
  --storage-driver=vfs \
  --data-root=/docker-data \
  --exec-root=/docker-data/exec \
  > /var/log/dockerd.log 2>&1 &
DOCKERD_PID=$!

# Wait for dockerd to be ready (up to 30s). If the first attempt fails (the
# containerd-start race is most likely on a cold boot of the image), wipe the
# stale state once and try one more time before giving up.
echo "[zfs] waiting for dockerd to start…"
STARTED=0
for i in $(seq 1 30); do
    if /usr/bin/docker info >/dev/null 2>&1; then
        echo "[zfs] dockerd ready after ${i}s"
        STARTED=1
        break
    fi
    sleep 1
done

if [ $STARTED -eq 0 ]; then
    echo "[zfs] dockerd did not start on first attempt; cleaning state and retrying…"
    kill -9 $DOCKERD_PID 2>/dev/null || true
    pkill -9 -x dockerd 2>/dev/null || true
    pkill -9 -x containerd 2>/dev/null || true
    sleep 1
    rm -f /var/run/docker.pid /var/run/docker.sock
    rm -rf /var/run/docker
    rm -rf /docker-data/containerd /docker-data/tmp /docker-data/exec 2>/dev/null || true
    mkdir -p /docker-data
    nohup /usr/bin/dockerd \
      --host=unix:///var/run/docker.sock \
      --storage-driver=vfs \
      --data-root=/docker-data \
      --exec-root=/docker-data/exec \
      > /var/log/dockerd.log 2>&1 &
    disown
    for i in $(seq 1 30); do
        if /usr/bin/docker info >/dev/null 2>&1; then
            echo "[zfs] dockerd ready after retry (${i}s)"
            STARTED=1
            break
        fi
        sleep 1
    done
    if [ $STARTED -eq 0 ]; then
        echo "[zfs] WARNING: dockerd failed to start after retry; check /var/log/dockerd.log"
    fi
fi

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
# D-Bus system bus — required by NetworkManager. There is no systemd in
# this container, so we launch dbus-daemon manually. Idempotent: if the
# socket already exists and answers, we leave it alone.
#
# `--nofork` keeps dbus-daemon in the foreground but in its own session
# (the wrapper's `&` + `disown` detaches it from bash's job table, so it
# survives the wrapper exiting). `--address` pins the socket path so we
# know exactly what to wait for.
# ────────────────────────────────────────────────────────────────────────
echo "[zfs] starting dbus system bus…"
mkdir -p /run/dbus /var/lib/dbus /var/run/NetworkManager /var/lib/NetworkManager
if [ ! -S /run/dbus/system_bus_socket ] || ! dbus-send --system \
        --dest=org.freedesktop.DBus --type=method_call --print-reply \
        /org/freedesktop/DBus org.freedesktop.DBus.ListNames \
        >/dev/null 2>&1; then
    # Clean any stale pid/socket from a previous container incarnation.
    rm -f /run/dbus/pid /var/run/dbus/pid /run/dbus/system_bus_socket
    # Double-fork via subshell so dbus-daemon is reparented to PID 1 and
    # survives the entrypoint shell continuing. `setsid` puts it in its
    # own session so any signals to the entrypoint's process group miss it.
    cat > /usr/local/sbin/start-dbus.sh <<'DBS'
#!/bin/bash
exec setsid dbus-daemon --system --nofork \
    --address=unix:path=/run/dbus/system_bus_socket \
    >>/var/log/dbus.log 2>&1 </dev/null
DBS
    chmod 755 /usr/local/sbin/start-dbus.sh
    ( /usr/local/sbin/start-dbus.sh & )
    # Wait up to 10s for the socket to appear and start responding.
    for i in $(seq 1 10); do
        if dbus-send --system --dest=org.freedesktop.DBus --type=method_call \
                --print-reply /org/freedesktop/DBus \
                org.freedesktop.DBus.ListNames >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
fi
if dbus-send --system --dest=org.freedesktop.DBus --type=method_call \
        --print-reply /org/freedesktop/DBus \
        org.freedesktop.DBus.ListNames >/dev/null 2>&1; then
    echo "[zfs] dbus is up"
else
    echo "[zfs] WARNING: dbus did not start — NetworkManager will fail" >&2
fi

# ────────────────────────────────────────────────────────────────────────
# NetworkManager — required for the nmcli calls in docker_setup.sh.
# Started directly (no systemd in the container); idempotent.
# Same setsid trick as dbus — bare nohup & silently dies.
# ────────────────────────────────────────────────────────────────────────
echo "[zfs] starting NetworkManager…"
systemctl start NetworkManager
if systemctl is-active NetworkManager >/dev/null 2>&1; then
    echo "[zfs] NetworkManager is up"
else
    echo "[zfs] WARNING: NetworkManager did not come up — nmcli will fail" >&2
fi

# ────────────────────────────────────────────────────────────────────────
# Free the bond0 name (rename any existing kernel bond → eth10) and then
# wire eth10 to the *inner* docker's default bridge (docker0 / "bridge"
# network) as an IP-less device. /TopStor/ensure_eth10_bridge0.sh is
# fully idempotent, so re-runs on every container start are safe.
# (eth0 is taken by the Docker network interface.)
# ────────────────────────────────────────────────────────────────────────
if ip link show bond0 >/dev/null 2>&1; then
    echo "[zfs] renaming existing bond0 → eth10 to free the name for NM bonds…"
    ip link set bond0 down 2>/dev/null || true
    ip link set bond0 name eth10 2>/dev/null && echo "[zfs] bond0 renamed to eth10" || \
        echo "[zfs] WARNING: could not rename bond0 (may be in use or no CARRIER)"
fi

echo "[zfs] ensuring eth10 (no IP) is a port of inner docker's bridge (docker0)…"
/TopStor/ensure_eth10_bridge0.sh || echo "[zfs] WARNING: ensure_eth10_bridge0.sh failed"

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

# ────────────────────────────────────────────────────────────────────────
# Preload Docker images from /docker-images/ (host-backed tarballs)
# into the DinD graph root at /docker-data (also host-backed). Runs
# after dockerd is up and before any docker_setup.sh invocation, so the
# image set required by docker_setup.sh is locally available regardless
# of whether auto-run is enabled. The script is idempotent: re-runs
# short-circuit on already-loaded images.
# ────────────────────────────────────────────────────────────────────────
if [ -d /docker-images ] && [ -x /TopStor/docker-preload.sh ]; then
    echo "[zfs] running docker-preload.sh (host-backed image cache)…"
    /TopStor/docker-preload.sh
elif [ -d /docker-images ]; then
    echo "[zfs] /docker-images mounted but /TopStor/docker-preload.sh not executable; skipping preload"
else
    echo "[zfs] /docker-images not mounted; skipping preload"
fi

# Keep container alive
echo "[zfs] ready."
tail -f /dev/null
