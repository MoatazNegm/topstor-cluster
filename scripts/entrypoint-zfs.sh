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
    if [ "$svc" = "iscsid" ] || [ "$svc" = "iscsi" ]; then
        # iscsiadm needs iscsid to be running so it can talk to the
        # management socket. Without this, `iscsiadm -m discovery ...`
        # fails with "Cannot perform discovery. Initiatorname required."
        # (misleading: the real cause is "could not connect to iscsid").
        # Reuse the entrypoint's launcher so behaviour is identical on a
        # cold start and on `systemctl restart iscsid`.
        if [ -x /usr/local/sbin/start-iscsid.sh ]; then
            /usr/local/sbin/start-iscsid.sh
            exit $?
        fi
        echo "systemctl: /usr/local/sbin/start-iscsid.sh missing" >&2
        exit 1
    fi
    # Other start targets: silently succeed in container
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
    if [ "$svc" = "iscsid" ] || [ "$svc" = "iscsi" ]; then
        # Two liveness signals, in priority order:
        #   1. /var/run/iscsid.pid (when iscsid was started without -f,
        #      i.e. via the standard double-fork — the path used by the
        #      entrypoint launcher).
        #   2. pgrep iscsid — covers the rare case where iscsid was
        #      started under `-f` (no pidfile) and is still running.
        # The AF_UNIX management socket itself is in the abstract
        # namespace (@ISCSIADM_ABSTRACT_NAMESPACE) on Rocky 9, so we
        # cannot check the filesystem socket path.
        if [ -f /var/run/iscsid.pid ] \
           && kill -0 "$(cat /var/run/iscsid.pid)" 2>/dev/null; then
            echo "active"; exit 0
        fi
        if pgrep -x iscsid >/dev/null 2>&1; then
            echo "active"; exit 0
        fi
        echo "inactive"; exit 3
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
    if [ "$svc" = "iscsid" ] || [ "$svc" = "iscsi" ]; then
        if [ -f /var/run/iscsid.pid ] \
           && kill -0 "$(cat /var/run/iscsid.pid)" 2>/dev/null; then
            echo "iscsid is running"; exit 0
        fi
        if pgrep -x iscsid >/dev/null 2>&1; then
            echo "iscsid is running"; exit 0
        fi
        echo "iscsid is not running"; exit 3
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
    if [ "${1:-}" = "iscsid" ] || [ "${1:-}" = "iscsi" ]; then
        # stop/disable/enable/reload: kill the daemon.
        pkill -x iscsid 2>/dev/null
        rm -f /var/run/iscsid.pid
        # restart: kill, then re-launch via the same logic as `start`.
        if [ "$cmd" = "restart" ]; then
            if [ -x /usr/local/sbin/start-iscsid.sh ]; then
                /usr/local/sbin/start-iscsid.sh
                exit $?
            fi
        fi
        exit 0
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
# docker wrapper — only intercepts `docker run` (conflict-resolution).
# Everything else (including `docker exec`) is a pure passthrough to the
# real /usr/bin/docker, so it adds zero latency and emits zero stdout noise.
#
# docker run:
#   "container name already in use"  → remove old container, retry.
#   Diagnostic messages go to stderr, never to stdout.
#
# (Removed: a prior revision intercepted `docker exec etcdclient /pace/...`
#  and pre-populated /pace inside etcdclient with /workspace/pace/*.py.
#  Redundant — docker_setup.sh already bind-mounts /pace into etcdclient
#  via `-v /pace/:/pace`, so the same files are visible without copying.
#  Also slowed every call by ~1 docker exec + N docker cp round-trips.)
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
        echo "[docker run] removing conflicting container '$NAME_ARG'…" >&2
        $DOCKER_REAL rm -f "$NAME_ARG" 2>/dev/null
        rm -f /tmp/docker_err.txt
        exec $DOCKER_REAL "${new_args[@]}"
    fi
    rm -f /tmp/docker_err.txt
    exit $EXIT
fi

# ── all other subcommands (incl. `docker exec`): pass through directly ──
# NOTE: a previous revision intercepted `docker exec etcdclient /pace/...`
# and pre-populated /pace inside the etcdclient container with files from
# /workspace/pace. That was redundant: docker_setup.sh already starts
# etcdclient with `-v /pace/:/pace` (bind mount), so the same files are
# already visible inside it. The pre-populate also added ~1 docker exec +
# N docker cp round-trips per call and leaked a status line to stdout.
# Removed.
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
# /root/hostname is intentionally NOT seeded here — the app sets it via the
# docker_setup.sh reset flow (dhcpXXXXXX after a reset+reboot cycle), and
# re-writing "zfsnode" on every start would clobber that.
#echo "zfsnode"    | tee /root/hostname           > /dev/null
echo "10.11.11.14" | tee /root/newipaddr        > /dev/null
echo "nameserver 10.11.12.7" | tee /root/gitrepo/resolv.conf > /dev/null
echo "[zfs] seed files ready"

# Force /root/gitrepo/{httpd.conf,dnshosts} to be regular FILES.
# Some provisioning paths leave them as directories, which makes bind-mounts
# onto file targets (Apache httpd.conf, /etc/hosts) fail with
# "not a directory: mount src=... onto a file". Idempotent: leaves real
# configs in place, only replaces missing / empty / wrong-type entries.
for f in /root/gitrepo/httpd.conf /root/gitrepo/dnshosts; do
    if [ -d "$f" ]; then
        echo "[zfs] removing stale directory at $f (must be a file)…"
        rm -rf "$f"
    fi
done
[ -s /root/gitrepo/httpd.conf ] || \
    printf '# Apache httpd.conf placeholder\n# Replace with a real config; an empty file makes httpd-foreground abort.\n' \
    > /root/gitrepo/httpd.conf
[ -s /root/gitrepo/dnshosts ] || \
    printf '127.0.0.1 localhost\n10.11.12.7 intdns\n' \
    > /root/gitrepo/dnshosts

# ────────────────────────────────────────────────────────────────────────
# iscsid launcher — used both on cold start and by `systemctl
# start|restart iscsid`. iscsiadm needs iscsid's AF_UNIX management socket
# (/var/run/iscsid) to perform discovery/login; without it, iscsiadm emits
# "Cannot perform discovery. Initiatorname required." (misleading — the
# real reason is "could not connect to iscsid"). The container shares the
# host kernel, so iscsi_tcp/libiscsi are already loaded — we only need the
# userspace daemon.
#
# `setsid` + double-fork via subshell keeps iscsid reparented to PID 1 so
# it survives the launcher exiting; `&` alone is reaped by the parent
# shell on exit in some Docker setups. `-f` keeps iscsid in the foreground
# of its own session (it's a daemon — it never returns).
#
# HOST NETWORK NAMESPACE (root-cause fix for "iscsid dies on every login"):
# the kernel iSCSI control channel (NETLINK_ISCSI) exists only in the host
# network namespace. An iscsid running in this container's private netns
# can talk TCP to a target but cannot reach the kernel, so it dies at
# login time ("iscsid: sendmsg: bug? ctrl_fd 4") and the target logs
# "rx_data returned 0, expecting 48" because our connection closed without
# a login PDU. Proven by A/B test: the same binary/container filesystem/
# initiator name logs in 20/20 from the host netns and 0/20 from the
# container netns. So iscsid (and iscsiadm — see the wrapper below) run via
# `nsenter --net=/host-ns/net`; /host-ns/net is a bind-mount of the host's
# /proc/1/ns/net (docker-compose.yml / manage.sh). Only one iscsid can exist
# per host netns: keep iscsid.service/iscsid.socket disabled on the host.
# If /host-ns/net is absent (old container definition) we fall back to the
# container's own netns, i.e. the previous behaviour.
# ────────────────────────────────────────────────────────────────────────
cat > /usr/local/sbin/start-iscsid.sh <<'ISD'
#!/bin/bash
HNS=/host-ns/net
if [ -e "$HNS" ]; then NSE="nsenter --net=$HNS"; else NSE=""; fi
# Is iscsid's abstract management socket present in the netns iscsid lives in?
alive()  { $NSE grep -q ISCSIADM_ABSTRACT_NAMESPACE /proc/net/unix 2>/dev/null; }
launch() { $NSE /usr/sbin/iscsid </dev/null >/var/log/iscsid.log 2>&1 & }
# Idempotent: if iscsid is already running, exit 0 immediately.
if [ -f /var/run/iscsid.pid ] && kill -0 "$(cat /var/run/iscsid.pid)" 2>/dev/null; then
    echo "iscsid already running (pid=$(cat /var/run/iscsid.pid))"
    exit 0
fi
# The socket name is global to the netns: if it is taken but no iscsid of
# ours exists, someone else (e.g. the host's iscsid.service) owns it and
# we must not start a second one that would silently use the wrong initiator.
if ! pgrep -x iscsid >/dev/null 2>&1 && alive; then
    echo "another iscsid already owns @ISCSIADM_ABSTRACT_NAMESPACE in the shared netns (host iscsid.service/socket enabled?); refusing to start" >&2
    exit 1
fi
mkdir -p /var/run /var/lib/iscsi /var/lib/iscsi/nodes \
         /var/lib/iscsi/sls /var/lib/iscsi/static /var/lib/iscsi/isns \
         /var/lock/iscsi
# iscsid creates the AF_UNIX socket at /var/run/iscsid only if the parent
# dir exists; clean any stale socket/pidfile from a previous incarnation.
rm -f /var/run/iscsid /var/run/iscsid.pid
# Clear any stale iSCSI DB lock files. iscsiadm/iscsid take a write lock
# via O_CREAT|O_EXCL on /run/lock/iscsi/lock.write; if a previous
# container crashed mid-transaction the file survives and the next
# iscsiadm call returns "Timeout on acquiring lock ... File exists".
# Safe: we only clear if no live process holds the file.
for lockf in /run/lock/iscsi/lock.write /run/lock/iscsi/lock.read; do
    [ -e "$lockf" ] || continue
    if ! pgrep -f iscsiadm >/dev/null 2>&1 && ! pgrep -x iscsid >/dev/null 2>&1; then
        rm -f "$lockf"
    fi
done
# IMPORTANT: do NOT pass `-f` (foreground) to iscsid in this container.
# Without `-f`, iscsid does the standard double-fork dance and binds the
# AF_UNIX management socket at /var/run/iscsid plus writes a pidfile at
# /var/run/iscsid.pid. Both are required by `iscsiadm -m node -l`
# (login): iscsiadm talks to iscsid over that socket, iscsid then
# performs the kernel-side login via netlink. With `-f` the socket is
# never created and login fails, killing iscsid. Discovery (`-m
# discovery`) still works because iscsiadm just opens a TCP connection to
# the target directly.
#
# Use setsid so iscsid is in its own session (signal-safe) and redirect
# fds so the launcher can exit cleanly.
launch
# Wait up to 30s. Rocky 9 iscsid (iscsi-initiator-utils 6.2.x) binds its
# AF_UNIX management socket in the *abstract* namespace, not at
# /var/run/iscsid (visible in /proc/net/unix as
# `@ISCSIADM_ABSTRACT_NAMESPACE`). So we can NOT use the filesystem
# socket as the readiness signal. We use the pidfile + liveness as the
# first signal — iscsid writes /var/run/iscsid.pid very early in
# startup — but that alone is not sufficient: iscsi-initiator-utils
# 6.2.1.11 can crash its double-forked child within ~200ms of startup
# (same bug as the login-negotiation crash — see the guardian below),
# leaving a stuck parent that still holds the pidfile's PID alive via
# kill -0 even though the abstract socket never bound. So we also
# require the abstract socket to actually be present before declaring
# success; if it never shows up, we kill and retry (up to 3 attempts)
# instead of reporting a false "started" and leaving iscsiadm broken
# for whoever calls it next.
for attempt in 1 2 3; do
    for i in $(seq 1 30); do
        if [ -f /var/run/iscsid.pid ]; then
            DPID=$(cat /var/run/iscsid.pid 2>/dev/null)
            if [ -n "$DPID" ] && kill -0 "$DPID" 2>/dev/null; then
                ELAPSED=$(ps -o etimes= -p "$DPID" 2>/dev/null | tr -d ' ')
                if [ -n "$ELAPSED" ] && [ "$ELAPSED" -ge 2 ] && alive; then
                    echo "iscsid started after ${i}s (pid=$DPID, attempt=$attempt)"
                    exit 0
                fi
            fi
        fi
        sleep 1
    done
    echo "iscsid attempt $attempt: no abstract socket after 30s; killing and retrying" >&2
    pkill -9 -x iscsid 2>/dev/null
    rm -f /var/run/iscsid /var/run/iscsid.pid
    sleep 1
    [ "$attempt" -lt 3 ] && launch
done
echo "iscsid failed to start within 3 attempts; see /var/log/iscsid.log" >&2
pkill -9 -x iscsid 2>/dev/null
rm -f /var/run/iscsid.pid
exit 1
ISD
chmod 755 /usr/local/sbin/start-iscsid.sh

# iscsiadm wrapper — must run in the same (host) netns as iscsid, otherwise
# it cannot find iscsid's abstract socket. Every caller (docker_setup.sh,
# /pace/*.sh, interactive use) invokes /sbin/iscsiadm or `iscsiadm`, both of
# which resolve to /usr/sbin/iscsiadm, so wrapping it here needs no change to
# any app script. The real binary is kept as iscsiadm.real. Idempotent, and
# also self-heals if an rpm update replaces the wrapper with a fresh binary.
if [ -x /usr/sbin/iscsiadm ] && [ "$(head -c 2 /usr/sbin/iscsiadm 2>/dev/null)" != "#!" ]; then
    mv -f /usr/sbin/iscsiadm /usr/sbin/iscsiadm.real
fi
cat > /usr/sbin/iscsiadm <<'IAD'
#!/bin/bash
# Runs the real iscsiadm in the host netns (see start-iscsid.sh).
REAL=/usr/sbin/iscsiadm.real
if [ -e /host-ns/net ]; then
    exec nsenter --net=/host-ns/net "$REAL" "$@"
fi
exec "$REAL" "$@"
IAD
chmod 755 /usr/sbin/iscsiadm

# Cold-start iscsid is intentionally NOT invoked here. It happens later,
# after dbus is up — see the "starting iscsid…" block below the dbus
# section. iscsid's notify machinery talks to dbus; starting it before
# dbus is running makes it silently exit.

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

# Ensure the isolated intdns bridge exists for the in-container DNS service.
# The ZFS container runs its own dockerd (DinD), so this is a separate bridge
# from the host's "bridge0" Docker network — same subnet (10.11.12.0/24) but
# a different namespace, different daemon, and a different Linux device name
# (br-intdns) to avoid any visual conflict with the host's bridge0.
docker network inspect intdns-net >/dev/null 2>&1 || \
    docker network create --driver=bridge \
        --subnet=10.11.12.0/24 --gateway=10.11.12.1 \
        --opt 'com.docker.network.bridge.name=br-intdns' \
        --label 'purpose=intdns-isolated' \
        --label 'managed_by=zfs-docker' \
        intdns-net

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
# iscsid — needs dbus up because its notify-path talks to the system bus.
# Started here (after dbus, before docker_setup.sh) so iscsiadm works the
# very first time it's called inside the container. The launcher is
# idempotent and re-used by `systemctl restart iscsid`.
# ────────────────────────────────────────────────────────────────────────
echo "[zfs] starting iscsid…"
if /usr/local/sbin/start-iscsid.sh; then
    echo "[zfs] iscsid is up"
else
    echo "[zfs] WARNING: iscsid did not come up — iscsiadm will fail" >&2
fi

# ────────────────────────────────────────────────────────────────────────
# iscsi guardian — restarts iscsid automatically when it dies.
#
# Why we need this:
#   The original diagnosis here was an upstream iscsi-initiator-utils
#   6.2.1.11 bug that kills iscsid on any login failure. That was wrong: the
#   real cause was running iscsid in the container's private network
#   namespace, which cannot reach the kernel's iSCSI netlink channel (see
#   the HOST NETWORK NAMESPACE note above start-iscsid.sh). With iscsid in
#   the host netns, logins no longer kill it. The guardian stays as a cheap
#   safety net for any other way iscsid can die (OOM, operator kill, a
#   stuck parent left with no abstract socket, ...).
#
#   Without a guardian, the user has to manually `systemctl restart
#   iscsid` after every failed login. With this guardian, iscsid
#   comes back within 3s of crashing, so the next iscsiadm call works.
#
#   Detection: `pgrep -x iscsid` matches either the parent or the
#   daemon (both have argv[0] == "iscsid"). A live process means at
#   least one of them is up. To detect the actual *daemon* we also
#   require the abstract socket to be present; without it, iscsiadm
#   can't connect, so the daemon is effectively dead even if a stale
#   intermediate parent is still around.
#
#   Deliberately NOT named "iscsid-*": a comm/argv containing "iscsid"
#   as a substring gets caught by a plain `pkill iscsid` / `killall
#   iscsid` (no -x), which operators reach for when iscsid looks stuck.
#   That silently kills the guardian along with the daemon it's meant
#   to resurrect, and nothing was left running to bring iscsid back —
#   exactly the "stays dead" failure this container hit in the field.
#   "iscsi-guardian" contains no "iscsid" substring, so it survives.
#
#   Second line of defense: the guardian process itself can still die
#   for unrelated reasons (OOM, an operator's `pkill -f`, whatever).
#   A cron entry (crond already runs in this container) checks once a
#   minute, independent of the guardian's own process tree, and
#   relaunches it if it's gone — see below.
# ────────────────────────────────────────────────────────────────────────
cat > /usr/local/sbin/iscsi-guardian.sh <<'WGD'
#!/bin/bash
# iscsi guardian. Runs forever; never exits. Logs restarts.
set +e
HNS=/host-ns/net
if [ -e "$HNS" ]; then NSE="nsenter --net=$HNS"; else NSE=""; fi
while true; do
    if ! pgrep -x iscsid >/dev/null 2>&1; then
        echo "$(date '+%F %T') iscsi-guardian: iscsid not running, restarting" >> /var/log/iscsid.log
        /usr/local/sbin/start-iscsid.sh >> /var/log/iscsid.log 2>&1
    elif ! $NSE grep -q ISCSIADM_ABSTRACT_NAMESPACE /proc/net/unix 2>/dev/null; then
        # Process alive but no abstract socket — iscsid 6.2.1.11 crash
        # leaves an intermediate parent stuck in hrtimer_nanosleep with
        # all fds closed. Kill everything iscsid-named and restart.
        echo "$(date '+%F %T') iscsi-guardian: iscsid alive but abstract socket missing, killing" >> /var/log/iscsid.log
        pkill -9 -x iscsid 2>/dev/null
        sleep 1
        /usr/local/sbin/start-iscsid.sh >> /var/log/iscsid.log 2>&1
    fi
    sleep 3
done
WGD
chmod 755 /usr/local/sbin/iscsi-guardian.sh
( setsid /usr/local/sbin/iscsi-guardian.sh </dev/null >>/var/log/iscsid.log 2>&1 & )
disown 2>/dev/null || true
echo "[zfs] iscsi guardian started (monitors every 3s)"

# Cron safety net: if the guardian process itself ever disappears, crond
# (independent of the guardian's own process tree, and already running
# in this container) notices within a minute and relaunches it. Guard
# against duplicate crontab entries across container restarts.
( crontab -l 2>/dev/null | grep -v 'iscsi-guardian.sh'
  echo "* * * * * pgrep -f /usr/local/sbin/iscsi-guardian.sh >/dev/null 2>&1 || (setsid /usr/local/sbin/iscsi-guardian.sh </dev/null >>/var/log/iscsid.log 2>&1 &)"
) | crontab -
echo "[zfs] iscsi-guardian cron safety net installed (checks every 60s)"

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
