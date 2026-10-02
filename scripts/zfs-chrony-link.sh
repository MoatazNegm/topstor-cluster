#!/bin/bash
# zfs-chrony-link.sh — make the zfs container's `chronyc` talk to (and, as root,
# adjust the clock through) the HOST's running chronyd.
#
# chronyc only gets privileged access (makestep, settime, burst, ...) over
# chronyd's local unix socket, /run/chrony/chronyd.sock. The socket lives on the
# host, and Docker cannot add a bind mount to a running container, so this
# script clones the host's /run/chrony mount into the container's mount
# namespace (open_tree + setns + move_mount, kernel >= 5.2). No container
# recreate needed. Idempotent. Runs on the HOST as root.
#
# The mount does NOT survive `docker restart zfs` (only -v mounts do), so
# manage.sh run_zfs calls this after every start. To make it a real -v mount
# on the next recreate, add:   -v /run/chrony:/run/chrony
#
# Undo:  nsenter -t $(docker inspect -f '{{.State.Pid}}' zfs) -m umount /run/chrony
set -e

CONTAINER="${1:-zfs}"
SRC=/run/chrony

[ "$(id -u)" -eq 0 ] || { echo "[chrony-link] must run as root" >&2; exit 1; }
[ -S "$SRC/chronyd.sock" ] || { echo "[chrony-link] host chronyd socket $SRC/chronyd.sock not found (is host chronyd running?)" >&2; exit 1; }

PID=$(docker inspect -f '{{.State.Pid}}' "$CONTAINER" 2>/dev/null)
[ -n "$PID" ] && [ "$PID" != 0 ] || { echo "[chrony-link] container $CONTAINER is not running" >&2; exit 1; }

if nsenter -t "$PID" -m test -S "$SRC/chronyd.sock" 2>/dev/null; then
    echo "[chrony-link] already linked in $CONTAINER"
    exit 0
fi

python3 - "$PID" "$SRC" <<'EOF'
import ctypes, os, sys
pid, src = sys.argv[1], sys.argv[2]
libc = ctypes.CDLL(None, use_errno=True)
SYS_open_tree, SYS_move_mount = 428, 429            # x86_64
OPEN_TREE_CLONE, OPEN_TREE_CLOEXEC, AT_RECURSIVE = 1, 0o2000000, 0x8000
MOVE_MOUNT_F_EMPTY_PATH = 4
AT_FDCWD = -100

def check(r, what):
    if r < 0:
        e = ctypes.get_errno()
        sys.exit("[chrony-link] %s failed: %s" % (what, os.strerror(e)))
    return r

# 1. clone the host mount while still in the host mount namespace
tree = check(libc.syscall(SYS_open_tree, AT_FDCWD, src.encode(),
                          OPEN_TREE_CLONE | OPEN_TREE_CLOEXEC | AT_RECURSIVE),
             "open_tree")
# 2. enter the container's mount namespace
ns = os.open("/proc/%s/ns/mnt" % pid, os.O_RDONLY)
check(libc.setns(ns, 0), "setns")
# 3. attach the clone at the same path inside the container
os.makedirs(src, exist_ok=True)
check(libc.syscall(SYS_move_mount, tree, b"", AT_FDCWD, src.encode(),
                   MOVE_MOUNT_F_EMPTY_PATH), "move_mount")
EOF
echo "[chrony-link] linked host $SRC into $CONTAINER"
