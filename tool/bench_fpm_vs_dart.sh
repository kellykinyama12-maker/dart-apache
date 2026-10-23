#!/usr/bin/env bash
# Fairer app-speed benchmark: modern PHP (php-fpm, persistent pool) vs compiled
# in-process Dart handlers — same server, same endpoints. The parity app serves
# the PHP files at *.php (routed to php-fpm via --php-fpm) and the Dart
# equivalents at /parity/*.
#   wsl -d Ubuntu-24.04 -u root -- bash /mnt/c/projects/webserver/dart-apache/tool/bench_fpm_vs_dart.sh
set -u

BIN=/mnt/c/projects/webserver/dart-apache/build/parity_app-linux-x64
SRC=/mnt/c/projects/webserver/dart-apache/public
BASE=/tmp/fvd
PORT=8093
FPM=/usr/sbin/php-fpm8.3
WORKERS=4
DUR=10s
CONNS=32
THREADS=4

command -v wrk >/dev/null 2>&1 || { echo "wrk not found in WSL"; exit 1; }
[ -x "$FPM" ] || { echo "$FPM not found (apt-get install php8.3-fpm)"; exit 1; }

rm -rf "$BASE"; mkdir -p "$BASE"
cp -r "$SRC"/. "$BASE/www"
cp "$BIN" "$BASE/parity"; chmod +x "$BASE/parity"
chmod -R a+rx "$BASE/www"   # php-fpm workers run as www-data; must read the scripts

# ---- php-fpm pool on 127.0.0.1:9000 (persistent, static pool) ----
cat > "$BASE/fpm.conf" <<EOF
[global]
pid = $BASE/php-fpm.pid
error_log = $BASE/php-fpm.err
daemonize = no

[www]
user = www-data
group = www-data
listen = 127.0.0.1:9000
pm = static
pm.max_children = 8
catch_workers_output = yes
EOF

rps() { grep -E 'Requests/sec' | awk '{print $2}'; }
lat() { grep -E 'Latency' | head -1 | awk '{print $2}'; }
bench() { # url label
  local out
  out=$(wrk -t$THREADS -c$CONNS -d$DUR "$1" 2>/dev/null)
  printf '%-24s %12s req/s   avglat %9s\n' "$2" "$(echo "$out" | rps)" "$(echo "$out" | lat)"
}

echo "== app-speed: php-fpm vs compiled Dart handlers (wrk ${THREADS}t/${CONNS}c/${DUR}, ${WORKERS} workers) =="

"$FPM" -F -y "$BASE/fpm.conf" > "$BASE/fpm.log" 2>&1 &
FPMPID=$!
sleep 1
"$BASE/parity" --root="$BASE/www" --port=$PORT --workers=$WORKERS --php-fpm=127.0.0.1:9000 --no-access-log > "$BASE/server.log" 2>&1 &
SRV=$!
sleep 2

code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/index.php?name=ada")
echo "sanity: GET /index.php -> HTTP $code (expect 200)"
if [ "$code" != "200" ]; then echo "--- server.log ---"; cat "$BASE/server.log"; echo "--- fpm.log ---"; cat "$BASE/fpm.log"; fi

wrk -t$THREADS -c$CONNS -d3s "http://127.0.0.1:$PORT/parity/" >/dev/null 2>&1

echo "-- index (HTML render) --"
bench "http://127.0.0.1:$PORT/index.php?name=ada" "php-fpm index.php"
bench "http://127.0.0.1:$PORT/parity/?name=ada"   "Dart    /parity/"

echo "-- cacheable (dynamic text) --"
bench "http://127.0.0.1:$PORT/cacheable.php"    "php-fpm cacheable.php"
bench "http://127.0.0.1:$PORT/parity/cacheable" "Dart    /parity/cacheable"

echo "-- fc (JSON) --"
bench "http://127.0.0.1:$PORT/fc.php"    "php-fpm fc.php"
bench "http://127.0.0.1:$PORT/parity/fc" "Dart    /parity/fc"

kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
kill $FPMPID 2>/dev/null; wait $FPMPID 2>/dev/null
echo "== done =="
