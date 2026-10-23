#!/usr/bin/env bash
# Blended app workload across dynamic:static ratios (the "beat the giants" test).
# Compiled dart-apache (native Dart dynamic + --static-cache) vs nginx + php-fpm.
# Each server is hit with a weighted path list; we sweep from pure-dynamic (API/
# SSR app) to static-heavy (asset-heavy page) to find the crossover.
#   wsl -d Ubuntu-24.04 -u root -- bash /mnt/c/projects/webserver/dart-apache/tool/bench_blended.sh
set -u

BIN=/mnt/c/projects/webserver/dart-apache/build/parity_app-linux-x64
SRC=/mnt/c/projects/webserver/dart-apache/public
BASE=/tmp/blend
FPM=/usr/sbin/php-fpm8.3
WORKERS=4
DUR=8s
CONNS=64
THREADS=4
NG=8301
DA=8302

for c in wrk nginx; do command -v $c >/dev/null 2>&1 || { echo "$c missing"; exit 1; }; done
[ -x "$FPM" ] || { echo "$FPM missing"; exit 1; }

rm -rf "$BASE"; mkdir -p "$BASE/logs"
cp -r "$SRC"/. "$BASE/www"
cp "$BIN" "$BASE/parity"; chmod +x "$BASE/parity"
chmod -R a+rx "$BASE/www"

cat > "$BASE/fpm.conf" <<EOF
[global]
pid = $BASE/php-fpm.pid
error_log = $BASE/logs/fpm.err
daemonize = no
[www]
user = www-data
group = www-data
listen = 127.0.0.1:9000
pm = static
pm.max_children = 8
EOF

cat > "$BASE/nginx.conf" <<EOF
daemon off;
worker_processes $WORKERS;
pid $BASE/nginx.pid;
error_log $BASE/logs/nginx.err crit;
events { worker_connections 2048; }
http { access_log off; include /etc/nginx/mime.types; default_type application/octet-stream;
  sendfile on; tcp_nopush on;
  server { listen $NG; root $BASE/www; index index.php;
    location ~ \.php\$ { fastcgi_pass 127.0.0.1:9000;
      fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
      include /etc/nginx/fastcgi_params; } } }
EOF

# mk_lua <dynamic-path> <num-static> <outfile>
mk_lua() {
  local n="$2" out="$3" list="\"$1\""
  for _ in $(seq 1 "$n"); do list="$list, \"/static.html\""; done
  cat > "$out" <<EOF
local p = { $list }
local i = 0
request = function() i = (i % #p) + 1; return wrk.format("GET", p[i]) end
EOF
}

agg() { grep -E 'Requests/sec' | awk '{print $2}'; }
run() { wrk -t$THREADS -c$CONNS -d3s -s "$2" "$1" >/dev/null 2>&1
  wrk -t$THREADS -c$CONNS -d$DUR -s "$2" "$1" 2>/dev/null | agg; }

MIXES="0 1 4"   # static per 1 dynamic: 0=pure dynamic, 1=1:1, 4=1:4
declare -A NGR DAR

echo "== blended app workload: compiled dart-apache vs nginx+php-fpm (wrk ${THREADS}t/${CONNS}c/${DUR}) =="
"$FPM" -F -y "$BASE/fpm.conf" > "$BASE/logs/fpm.log" 2>&1 & FPMPID=$!
sleep 1

nginx -c "$BASE/nginx.conf" & NGPID=$!; sleep 1
echo "sanity nginx: php=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$NG/index.php) static=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$NG/static.html)"
for m in $MIXES; do mk_lua "/index.php?name=ada" "$m" "$BASE/n$m.lua"; NGR[$m]=$(run "http://127.0.0.1:$NG/" "$BASE/n$m.lua"); done
kill $NGPID 2>/dev/null; wait $NGPID 2>/dev/null; sleep 1

"$BASE/parity" --root="$BASE/www" --port=$DA --workers=$WORKERS --static-cache --no-access-log > "$BASE/logs/dart.log" 2>&1 & DAPID=$!; sleep 2
echo "sanity dart:  dyn=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$DA/parity/) static=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$DA/static.html)"
for m in $MIXES; do mk_lua "/parity/?name=ada" "$m" "$BASE/d$m.lua"; DAR[$m]=$(run "http://127.0.0.1:$DA/" "$BASE/d$m.lua"); done
kill $DAPID 2>/dev/null; wait $DAPID 2>/dev/null

kill $FPMPID 2>/dev/null; wait $FPMPID 2>/dev/null

echo
printf '%-26s %16s %16s\n' "mix (dyn:static)" "nginx+fpm" "dart-apache"
label() { case $1 in 0) echo "1:0 (pure dynamic)";; 1) echo "1:1";; 4) echo "1:4 (static-heavy)";; *) echo "1:$1";; esac; }
for m in $MIXES; do printf '%-26s %12s r/s %12s r/s\n' "$(label $m)" "${NGR[$m]}" "${DAR[$m]}"; done
echo "== done =="
