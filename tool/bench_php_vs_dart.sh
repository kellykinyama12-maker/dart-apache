#!/usr/bin/env bash
# App-speed benchmark: SAME server, SAME endpoints, PHP (php-cgi) vs compiled
# in-process Dart handlers. The parity app serves the PHP files at *.php and the
# Dart equivalents at /parity/*; we wrk each pair and compare.
#   wsl -d Ubuntu-24.04 -u root -- bash /mnt/c/projects/webserver/dart-apache/tool/bench_php_vs_dart.sh
set -u

BIN=/mnt/c/projects/webserver/dart-apache/build/parity_app-linux-x64
SRC=/mnt/c/projects/webserver/dart-apache/public
BASE=/tmp/pvd
PORT=8092
WORKERS=4
DUR=10s
CONNS=32
THREADS=4

command -v php-cgi >/dev/null 2>&1 || { echo "php-cgi not found in WSL"; exit 1; }
command -v wrk     >/dev/null 2>&1 || { echo "wrk not found in WSL"; exit 1; }

rm -rf "$BASE"; mkdir -p "$BASE"
cp -r "$SRC"/. "$BASE/www"
cp "$BIN" "$BASE/parity"; chmod +x "$BASE/parity"

rps() { grep -E 'Requests/sec' | awk '{print $2}'; }
lat() { grep -E 'Latency' | head -1 | awk '{print $2}'; }

bench() { # url label
  local out
  out=$(wrk -t$THREADS -c$CONNS -d$DUR "$1" 2>/dev/null)
  printf '%-22s %12s req/s   avglat %9s\n' "$2" "$(echo "$out" | rps)" "$(echo "$out" | lat)"
}

echo "== app-speed: PHP (php-cgi) vs compiled Dart handlers (wrk ${THREADS}t/${CONNS}c/${DUR}, ${WORKERS} workers) =="
"$BASE/parity" --root="$BASE/www" --port=$PORT --workers=$WORKERS --no-access-log > "$BASE/server.log" 2>&1 &
SRV=$!
sleep 2
curl -s -o /dev/null "http://127.0.0.1:$PORT/parity/" || { echo "server not up"; cat "$BASE/server.log"; kill $SRV; exit 1; }

# warmup
wrk -t$THREADS -c$CONNS -d3s "http://127.0.0.1:$PORT/parity/" >/dev/null 2>&1

echo "-- index (HTML render: htmlspecialchars + date) --"
bench "http://127.0.0.1:$PORT/index.php?name=ada" "PHP   index.php"
bench "http://127.0.0.1:$PORT/parity/?name=ada"   "Dart  /parity/"

echo "-- cacheable (dynamic text: timestamp) --"
bench "http://127.0.0.1:$PORT/cacheable.php"    "PHP   cacheable.php"
bench "http://127.0.0.1:$PORT/parity/cacheable" "Dart  /parity/cacheable"

echo "-- fc (JSON) --"
bench "http://127.0.0.1:$PORT/fc.php"    "PHP   fc.php"
bench "http://127.0.0.1:$PORT/parity/fc" "Dart  /parity/fc"

kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
echo "== done =="
