#!/usr/bin/env bash
# Cache value: the SAME dart-apache + PHP endpoint, with vs without --cache.
# Uncached spawns php-cgi per request; cached replays from memory (X-Cache: HIT).
#   wsl -d Ubuntu-24.04 -u root -- bash /mnt/c/projects/webserver/dart-apache/tool/bench_cache.sh
set -u

BASE="$HOME/dabench"
BIN=/mnt/c/projects/webserver/dart-apache/build/dart_apache-linux-x64
WORKERS=4
DUR=5s
CONNS=16
THREADS=4

rm -rf "$BASE"; mkdir -p "$BASE/www" "$BASE/logs"
cat > "$BASE/www/dyn.php" <<'PHP'
<?php
header('Cache-Control: max-age=60');
header('Content-Type: text/plain; charset=UTF-8');
echo "dynamic " . str_repeat('x', 512) . "\n";
PHP

rps() { grep -E 'Requests/sec' | awk '{print $2}'; }
lat() { grep -E 'Latency' | head -1 | awk '{print $2}'; }

run() { # flags label
  "$BIN" --root="$BASE/www" --port=8090 --workers=$WORKERS --no-access-log $1 \
    > "$BASE/logs/da.log" 2>&1 &
  local pid=$!
  sleep 2
  curl -s -o /dev/null http://127.0.0.1:8090/dyn.php
  local xc
  xc=$(curl -s -D - -o /dev/null http://127.0.0.1:8090/dyn.php | grep -i '^x-cache' | tr -d '\r')
  wrk -t$THREADS -c$CONNS -d3s http://127.0.0.1:8090/dyn.php >/dev/null 2>&1 # warmup
  local out
  out=$(wrk -t$THREADS -c$CONNS -d$DUR http://127.0.0.1:8090/dyn.php 2>/dev/null)
  printf '%-26s %12s req/s   lat %9s   [%s]\n' "$2" "$(echo "$out" | rps)" "$(echo "$out" | lat)" "${xc:-none}"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  sleep 1
}

echo "== PHP endpoint: cache off vs on (wrk ${THREADS}t/${CONNS}c/${DUR}, ${WORKERS} workers) =="
run ""        "php-cgi (uncached)"
run "--cache" "php-cgi + --cache"
echo "== done =="
