#!/usr/bin/env bash
# Static-throughput benchmark: dart-apache vs nginx, same file, same tool (wrk),
# same worker count, on native Linux (WSL ext4). Run:
#   wsl -d Ubuntu-24.04 -u root -- bash /mnt/c/projects/webserver/dart-apache/tool/bench_static.sh
set -u

BASE="$HOME/dabench"
BIN=/mnt/c/projects/webserver/dart-apache/build/dart_apache-linux-x64
WORKERS=4
DUR=10s
CONNS=64
THREADS=4

rm -rf "$BASE"; mkdir -p "$BASE/www" "$BASE/logs"
# 1 KiB and 100 KiB static assets.
base64 /dev/urandom | head -c 1024 > "$BASE/www/1k.txt"
base64 /dev/urandom | head -c 102400 > "$BASE/www/100k.txt"

cat > "$BASE/nginx.conf" <<EOF
daemon off;
worker_processes $WORKERS;
pid $BASE/nginx.pid;
error_log $BASE/logs/error.log crit;
events { worker_connections 2048; }
http {
  access_log off;
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  sendfile on;
  tcp_nopush on;
  keepalive_timeout 65;
  server { listen 8081; root $BASE/www; }
}
EOF

rps() { grep -E 'Requests/sec' | awk '{print $2}'; }
lat() { grep -E 'Latency' | head -1 | awk '{print $2}'; }

bench() { # url label
  local out
  out=$(wrk -t$THREADS -c$CONNS -d$DUR "$1" 2>/dev/null)
  printf '%-28s %12s req/s   p?lat %8s\n' "$2" "$(echo "$out" | rps)" "$(echo "$out" | lat)"
}

echo "== warming up and benchmarking (wrk ${THREADS}t/${CONNS}c/${DUR}, ${WORKERS} workers) =="

# ---- nginx ----
nginx -c "$BASE/nginx.conf" &
NGINX=$!
sleep 1
curl -s -o /dev/null http://127.0.0.1:8081/1k.txt || echo "nginx not up"
wrk -t$THREADS -c$CONNS -d3s http://127.0.0.1:8081/1k.txt >/dev/null 2>&1 # warmup
echo "-- nginx --"
bench http://127.0.0.1:8081/1k.txt   "nginx 1KiB"
bench http://127.0.0.1:8081/100k.txt "nginx 100KiB"
kill "$NGINX" 2>/dev/null; wait "$NGINX" 2>/dev/null
sleep 1

# ---- dart-apache ----
"$BIN" --root="$BASE/www" --port=8082 --workers=$WORKERS --no-access-log > "$BASE/logs/da.log" 2>&1 &
DA=$!
sleep 2
curl -s -o /dev/null http://127.0.0.1:8082/1k.txt || echo "dart-apache not up"
wrk -t$THREADS -c$CONNS -d3s http://127.0.0.1:8082/1k.txt >/dev/null 2>&1 # warmup
echo "-- dart-apache --"
bench http://127.0.0.1:8082/1k.txt   "dart-apache 1KiB"
bench http://127.0.0.1:8082/100k.txt "dart-apache 100KiB"
kill "$DA" 2>/dev/null; wait "$DA" 2>/dev/null

echo "== done =="
