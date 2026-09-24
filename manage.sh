#!/bin/bash
# /root/TopStor/manage.sh
#
# Plain-shell (no docker-compose) launcher for the TopStor 3-node emulation
# cluster: abdopuppet + zfs + proxy, all on the `topstor_gitnet` bridge at
# 10.11.11.0/24.
#
# Mirrors the equivalent `docker-compose up -d` for the same services so
# the cluster can be brought up by hand, from rc.local, or from any context
# where `docker compose` is unavailable.
#
# Idempotent: re-running the script tears down any existing instance of
# each container and re-creates it from its image, just like the existing
# /root/TopStor/manager.sh does for the wetty/ngrok/filebrowser/nginx
# side-services.
#
# Usage:
#   ./manage.sh           # bring the whole cluster up
#   ./manage.sh start     # same as no-arg
#   ./manage.sh stop      # stop all three
#   ./manage.sh restart   # stop + start all three
#   ./manage.sh status    # show running state of each
#   ./manage.sh recreate  # force re-create from image (no cache)
#   ./manage.sh logs      # tail logs from each container
#
# Key parameters that matter for reboot.sh to work inside the zfs
# container — DO NOT drop these:
#   --privileged             keeps inner dockerd, nmcli, targetcli, etc.
#   --init                   tini as PID 1, forwards SIGTERM to entrypoint
#   --stop-timeout 30s       30s grace before Docker SIGKILLs on stop
#   --restart unless-stopped exit -> restart -> cluster comes back
#
# Persistent bind-mounts (cluster state survives recreate):
#   ./volumes/linux-env/TopStordata -> /TopStordata (zfs state)
#   ./volumes/linux-env              -> /workspace   (TopStor/pace/topstorweb)
#   ./volumes/puppet-srv             -> /srv/git     (abdopuppet git repos)
#   ./volumes/linux-env-proxy        -> /workspace   (proxy workspace)
#   ./volumes/zfs-docker-data        -> /docker-data (DinD graph root)
#   ./volumes/zfs-docker-images      -> /docker-images (RO image tarballs)
#   ./volumes/zfs-tmp/docker_setup_disabled -> /tmp/docker_setup_disabled (flag)

set +e

REPO_ROOT="/root/topstor"
NETWORK_NAME="topstor_gitnet"
NETWORK_SUBNET="10.11.11.0/24"
NETWORK_GATEWAY="10.11.11.1"

# Image registry + tags. Override by exporting these env vars before invoking.
ABDOPUPPET_IMAGE="${ABDOPUPPET_IMAGE:-topstor/abdopuppet:latest}"
ZFS_IMAGE="${ZFS_IMAGE:-moataznegm/topstor-zfs:current}"
PROXY_IMAGE="${PROXY_IMAGE:-topstor/proxy:fixed}"

cd "$REPO_ROOT"

# ----------------------------------------------------------------------------
# ensure_network — create the cluster bridge if it doesn't already exist.
# ----------------------------------------------------------------------------
ensure_network() {
    if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
        return 0
    fi
    echo "[manage] creating network $NETWORK_NAME ($NETWORK_SUBNET, gw=$NETWORK_GATEWAY)"
    docker network create \
        --driver bridge \
        --subnet "$NETWORK_SUBNET" \
        --gateway "$NETWORK_GATEWAY" \
        "$NETWORK_NAME"
}

# ----------------------------------------------------------------------------
# run_abdopuppet — git backplane (git-daemon + lighttpd + sshd).
# ----------------------------------------------------------------------------
run_abdopuppet() {
    echo "[manage] starting abdopuppet ($ABDOPUPPET_IMAGE)"
    docker rm -f abdopuppet >/dev/null 2>&1 || true
    docker run -d \
        --name abdopuppet \
        --hostname abdopuppet \
        --restart unless-stopped \
        -p 5022:22 \
        -p 5080:80 \
        -p 9418:9418 \
        -v "$REPO_ROOT/volumes/puppet-srv:/srv/git" \
        -v "$REPO_ROOT/scripts/entrypoint-abdopuppet.sh:/usr/local/bin/entrypoint.sh:ro" \
        --network "$NETWORK_NAME" \
        --ip 10.11.11.252 \
        "$ABDOPUPPET_IMAGE"
}

# ----------------------------------------------------------------------------
# run_zfs — storage node. The key flags for reboot.sh to work:
#   --privileged        keeps inner dockerd, nmcli, targetcli working
#   --init              tini as PID 1 — forwards SIGTERM, exit -> Docker restart
#   --stop-timeout 30s  graceful 30s before SIGKILL
# ----------------------------------------------------------------------------
run_zfs() {
    echo "[manage] starting zfs ($ZFS_IMAGE)"
    docker rm -f zfs >/dev/null 2>&1 || true
    docker run -d \
        --name zfs \
        --hostname zfs \
        --privileged \
        --init \
        --stop-timeout 30s \
        --restart unless-stopped \
        -p 2222:22 \
        -v "$REPO_ROOT/volumes/linux-env:/workspace" \
        -v "$REPO_ROOT/scripts/entrypoint-zfs.sh:/usr/local/bin/entrypoint.sh:ro" \
        -v /var/lib/docker:/var/lib/docker \
        -v "$REPO_ROOT/volumes/linux-env/TopStordata:/TopStordata" \
        -v "$REPO_ROOT/volumes/zfs-tmp/docker_setup_disabled:/tmp/docker_setup_disabled:ro" \
        -v "$REPO_ROOT/volumes/zfs-docker-images:/docker-images:ro" \
        -v "$REPO_ROOT/volumes/zfs-docker-data:/docker-data" \
        --network "$NETWORK_NAME" \
        --ip 10.11.11.101 \
        "$ZFS_IMAGE"
}

# ----------------------------------------------------------------------------
# run_proxy — management / web UI proxy. Also uses --init for the same
# reason as zfs (clean SIGTERM, no zombie sshd sessions).
# ----------------------------------------------------------------------------
run_proxy() {
    echo "[manage] starting proxy ($PROXY_IMAGE)"
    docker rm -f proxy >/dev/null 2>&1 || true
    docker run -d \
        --name proxy \
        --hostname proxy \
        --init \
        --privileged \
        --restart unless-stopped \
        -p 2223:22 \
        -p 8080:80 \
        -v "$REPO_ROOT/volumes/linux-env-proxy:/workspace" \
        -v "$REPO_ROOT/scripts/entrypoint-proxy.sh:/usr/local/bin/entrypoint.sh:ro" \
        --network "$NETWORK_NAME" \
        --ip 10.11.11.4 \
        "$PROXY_IMAGE"
}

# ----------------------------------------------------------------------------
# start — bring the whole cluster up.
# ----------------------------------------------------------------------------
start() {
    ensure_network
    run_abdopuppet
    run_zfs
    run_proxy
    echo "[manage] cluster up.  ssh into zfs:  ssh -p 2222 root@localhost"
}

# ----------------------------------------------------------------------------
# stop — stop all three (does not remove; restart policy keeps them off
# until explicitly started again because the policy is unless-stopped).
# ----------------------------------------------------------------------------
stop() {
    for name in abdopuppet zfs proxy; do
        if docker ps --format '{{.Names}}' | grep -qx "$name"; then
            echo "[manage] stopping $name"
            docker stop "$name"
        else
            echo "[manage] $name already stopped"
        fi
    done
}

# ----------------------------------------------------------------------------
# recreate — tear down and re-create every container from its image.
# ----------------------------------------------------------------------------
recreate() {
    start
}

# ----------------------------------------------------------------------------
# status — pretty print container states.
# ----------------------------------------------------------------------------
status() {
    for name in abdopuppet zfs proxy; do
        if docker ps --format '{{.Names}}' | grep -qx "$name"; then
            printf '  %-12s %s\n' "$name" "$(docker ps --filter "name=^${name}\$" --format '{{.Status}}')"
        else
            printf '  %-12s %s\n' "$name" "DOWN"
        fi
    done
}

# ----------------------------------------------------------------------------
# logs — tail logs from each. Falls through if a container doesn't exist.
# ----------------------------------------------------------------------------
logs() {
    for name in abdopuppet zfs proxy; do
        echo "===== $name ====="
        docker logs --tail=20 "$name" 2>&1 || echo "(no logs for $name)"
    done
}

# ----------------------------------------------------------------------------
# entrypoint
# ----------------------------------------------------------------------------
case "${1:-start}" in
    start)    start ;;
    stop)     stop ;;
    restart)  stop; start ;;
    status)   status ;;
    recreate) recreate ;;
    logs)     logs ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|recreate|logs}" >&2
        exit 2
        ;;
esac
