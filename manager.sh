#!/bin/bash
# Patched 2026-09-17:
#   - use the longer-timeout wetty image (moataznegm/aiwork:wetty-patched)
#   - deduplicate wetty: only manager.sh starts it now, on port 3000
#   - remap therokcmd 4042 -> 4044 to coexist with manage.sh's therok2 on 4042
#   - fix filebrowser mount typo:  /common/:srv/  ->  /common/:/srv/
#   - drop nginx volume mount (source /common/nginx.conf/default.conf is an empty
#     directory and can't be bind-mounted onto a file). Nginx falls back to its
#     built-in default.conf and serves the welcome page on host port 4000.
#   - add `docker rm -f <name>` before each `docker run` so the script is
#     idempotent and safe to re-run from rc.local on every boot.
#
# NOTE: the NGROK_AUTHTOKEN below for therokcmd is currently INVALID (ERR_NGROK_107)
# — the token was revoked or rotated. Replace with a fresh token from
# https://dashboard.ngrok.com/get-started/your-authtoken and the container will start.

docker rm -f wetty     >/dev/null 2>&1 || true
docker run  -d --rm  --name wetty -p 3000:3000  moataznegm/aiwork:wetty-patched --ssh-host=192.168.8.62 --ssh-user=root --base=/

docker rm -f therokcmd >/dev/null 2>&1 || true
docker run  --rm  -p 4044:4040 -d -it --name therokcmd -e  NGROK_AUTHTOKEN=3liP4kiF9E2yuCWE7Kdqw6Aqety_NcNNLjma1h15gwg2VxPc   ngrok/ngrok:latest http http://192.168.8.62:3000 --url=scope-uncurled-sloppy.ngrok-free.dev

docker rm -f filebrowser >/dev/null 2>&1 || true
docker  run -d  --name  filebrowser -v /common/:/srv/  -v /moataz-work/filebrowser:/database  -p 192.168.8.62:8080:80 --rm filebrowser/filebrowser --database /database/filebrowser.db --baseurl /fileman

docker rm -f nginx     >/dev/null 2>&1 || true
docker run  --name nginx  --rm  -p 4000:80 -d nginx
