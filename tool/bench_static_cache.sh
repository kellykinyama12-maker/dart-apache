#!/usr/bin/env bash
# Static hot-path cache: dart-apache static WITHOUT vs WITH --static-cache, and
# nginx for reference. Same files, same wrk.
#   wsl -d Ubuntu-24.04 -u root -- bash /mnt/c/projects/webserver/dart-apache/tool/bench_static_cache.sh
set -u

BIN=/mnt/c/projects/webserver/dart-apache/build/dart_apache-linux-x64
BASE=/tmp/scache
WORKERS=4
DUR=10s
CONNS=64
THREADS=4

command -v wrk >/dev/null 2>&1 || { echo "wrk not found"; exit 1; }

rm -rf "$BASE"; mkdir -p "$BASE/www"
base64 /dev/urandom | head -c 1024   > "$BASE/www/1k.txt"
base64 /dev/urandom | head -c 102400 > "$BASE/www/100k.txt"
cp "$BIN" "$BASE/da"; chmod +x "$BASE/da"

cat > "$BASE/nginx.conf" <<EOF
daemon off;
worker_processes $WORKERS;
pid $BASE/nginx.pid;
error_log $BASE/nginx.err crit;
events { worker_connections 2048; }
http { access_log off; include /etc/nginx/mime.types; default_type application/octet-stream;
  sendfile on; tcp_nopush on; server { listen 8201; root $BASE/www; } }
EOF

rps() { grep -E 'Requests/sec' | awk '{print $2}'; }
lat() { grep -E 'Latency' | head -1 | awk '{print $2}'; }
bench() { local out; out=$(wrk -t$THREADS -c$CONNS -d$DUR "$1" 2>/dev/null)
  printf '%-28s %12s req/s   avglat %9s\n' "$2" "$(echo "$out" | rps)" "$(echo "$out" | lat)"; }

echo "== static hot-path cache (wrk ${THREADS}t/${CONNS}c/${DUR}, ${WORKERS} workers) =="

nginx -c "$BASE/nginx.conf" & NG=$!; sleep 1
wrk -t$THREADS -c$CONNS -d3s http://127.0.0.1:8201/1k.txt >/dev/null 2>&1
bench http://127.0.0.1:8201/1k.txt   "nginx 1KiB"
bench http://127.0.0.1:8201/100k.txt "nginx 100KiB"
kill $NG 2>/dev/null; wait $NG 2>/dev/null; sleep 1

"$BASE/da" --root="$BASE/www" --port=8202 --workers=$WORKERS --no-access-log > "$BASE/da1.log" 2>&1 & DA=$!; sleep 2
wrk -t$THREADS -c$CONNS -d3s http://127.0.0.1:8202/1k.txt >/dev/null 2>&1
bench http://127.0.0.1:8202/1k.txt   "dart-apache 1KiB (no cache)"
bench http://127.0.0.1:8202/100k.txt "dart-apache 100KiB (no cache)"
kill $DA 2>/dev/null; wait $DA 2>/dev/null; sleep 1

"$BASE/da" --root="$BASE/www" --port=8203 --workers=$WORKERS --no-access-log --static-cache > "$BASE/da2.log" 2>&1 & DA=$!; sleep 2
wrk -t$THREADS -c$CONNS -d3s http://127.0.0.1:8203/1k.txt >/dev/null 2>&1
bench http://127.0.0.1:8203/1k.txt   "dart-apache 1KiB (--static-cache)"
bench http://127.0.0.1:8203/100k.txt "dart-apache 100KiB (--static-cache)"
kill $DA 2>/dev/null; wait $DA 2>/dev/null

echo "== done =="
