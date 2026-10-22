#!/usr/bin/env bash
# Three-way static-throughput benchmark: nginx vs Apache httpd (event MPM) vs
# dart-apache -- same files, same tool (wrk), same worker count, native Linux
# (WSL ext4). Run:
#   wsl -d Ubuntu-24.04 -u root -- bash /mnt/c/projects/webserver/dart-apache/tool/bench_apache.sh
set -u

BASE="/tmp/dabench"
BIN=/mnt/c/projects/webserver/dart-apache/build/dart_apache-linux-x64
WORKERS=4
DUR=10s
CONNS=64
THREADS=4
MODS=/usr/lib/apache2/modules

rm -rf "$BASE"; mkdir -p "$BASE/www" "$BASE/logs"
base64 /dev/urandom | head -c 1024   > "$BASE/www/1k.txt"
base64 /dev/urandom | head -c 102400 > "$BASE/www/100k.txt"

# ---------- nginx config ----------
cat > "$BASE/nginx.conf" <<EOF
daemon off;
worker_processes $WORKERS;
pid $BASE/nginx.pid;
error_log $BASE/logs/nginx-error.log crit;
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

# ---------- apache config (event MPM, 4 processes) ----------
cat > "$BASE/httpd.conf" <<EOF
ServerRoot "$BASE"
PidFile "$BASE/httpd.pid"
ServerName 127.0.0.1
Listen 8083
User www-data
Group www-data

LoadModule mpm_event_module $MODS/mod_mpm_event.so
LoadModule authz_core_module $MODS/mod_authz_core.so
LoadModule mime_module $MODS/mod_mime.so
LoadModule dir_module $MODS/mod_dir.so
LoadModule headers_module $MODS/mod_headers.so

TypesConfig /etc/mime.types
ErrorLog "$BASE/logs/httpd-error.log"

# No access log (parity with nginx access_log off / dart --no-access-log).
# Match 4 worker processes x 64 threads.
StartServers 4
ServerLimit 4
ThreadsPerChild 64
MaxRequestWorkers 256
MinSpareThreads 64
MaxSpareThreads 256
KeepAlive On
KeepAliveTimeout 65
MaxKeepAliveRequests 100000

DocumentRoot "$BASE/www"
<Directory "$BASE/www">
  Require all granted
  Options None
  AllowOverride None
</Directory>
EOF

rps() { grep -E 'Requests/sec' | awk '{print $2}'; }
lat() { grep -E 'Latency' | head -1 | awk '{print $2}'; }

bench() { # url label
  local out
  out=$(wrk -t$THREADS -c$CONNS -d$DUR "$1" 2>/dev/null)
  printf '%-26s %12s req/s   avglat %9s\n' "$2" "$(echo "$out" | rps)" "$(echo "$out" | lat)"
}

echo "== 3-way static bench (wrk ${THREADS}t/${CONNS}c/${DUR}, ${WORKERS} workers, access logs OFF) =="

# ---- nginx ----
nginx -c "$BASE/nginx.conf" &
NGINX=$!
sleep 1
curl -s -o /dev/null http://127.0.0.1:8081/1k.txt || echo "nginx not up"
wrk -t$THREADS -c$CONNS -d3s http://127.0.0.1:8081/1k.txt >/dev/null 2>&1
echo "-- nginx --"
bench http://127.0.0.1:8081/1k.txt   "nginx 1KiB"
bench http://127.0.0.1:8081/100k.txt "nginx 100KiB"
kill "$NGINX" 2>/dev/null; wait "$NGINX" 2>/dev/null
sleep 1

# ---- apache httpd ----
apache2 -d "$BASE" -f "$BASE/httpd.conf" -k start 2>"$BASE/logs/httpd-start.log"
sleep 2
curl -s -o /dev/null http://127.0.0.1:8083/1k.txt || { echo "apache not up:"; cat "$BASE/logs/httpd-start.log"; cat "$BASE/logs/httpd-error.log" 2>/dev/null | tail -5; }
wrk -t$THREADS -c$CONNS -d3s http://127.0.0.1:8083/1k.txt >/dev/null 2>&1
echo "-- apache httpd (event MPM) --"
bench http://127.0.0.1:8083/1k.txt   "apache 1KiB"
bench http://127.0.0.1:8083/100k.txt "apache 100KiB"
apache2 -d "$BASE" -f "$BASE/httpd.conf" -k stop 2>/dev/null
sleep 1

# ---- dart-apache ----
"$BIN" --root="$BASE/www" --port=8082 --workers=$WORKERS --no-access-log > "$BASE/logs/da.log" 2>&1 &
DA=$!
sleep 2
curl -s -o /dev/null http://127.0.0.1:8082/1k.txt || echo "dart-apache not up"
wrk -t$THREADS -c$CONNS -d3s http://127.0.0.1:8082/1k.txt >/dev/null 2>&1
echo "-- dart-apache --"
bench http://127.0.0.1:8082/1k.txt   "dart-apache 1KiB"
bench http://127.0.0.1:8082/100k.txt "dart-apache 100KiB"
kill "$DA" 2>/dev/null; wait "$DA" 2>/dev/null

echo "== done =="
