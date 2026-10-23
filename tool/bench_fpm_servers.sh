#!/usr/bin/env bash
# Dynamic-PHP across servers: the SAME PHP app + the SAME php-fpm pool, served by
# nginx, Apache httpd, and dart-apache — plus dart-apache's native in-process
# Dart handler for reference. Apples-to-apples on the PHP path (all talk to the
# one php-fpm on :9000).
#   wsl -d Ubuntu-24.04 -u root -- bash /mnt/c/projects/webserver/dart-apache/tool/bench_fpm_servers.sh
set -u

BIN=/mnt/c/projects/webserver/dart-apache/build/parity_app-linux-x64
SRC=/mnt/c/projects/webserver/dart-apache/public
BASE=/tmp/fsrv
FPM=/usr/sbin/php-fpm8.3
MODS=/usr/lib/apache2/modules
WORKERS=4
DUR=10s
CONNS=32
THREADS=4
NGINX_PORT=8101
DART_PORT=8102
HTTPD_PORT=8103

for c in wrk nginx; do command -v $c >/dev/null 2>&1 || { echo "$c not found"; exit 1; }; done
[ -x "$FPM" ] || { echo "$FPM not found"; exit 1; }

rm -rf "$BASE"; mkdir -p "$BASE/logs"
cp -r "$SRC"/. "$BASE/www"
cp "$BIN" "$BASE/parity"; chmod +x "$BASE/parity"
chmod -R a+rx "$BASE/www"

cat > "$BASE/fpm.conf" <<EOF
[global]
pid = $BASE/php-fpm.pid
error_log = $BASE/logs/php-fpm.err
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
http {
  access_log off;
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  server {
    listen $NGINX_PORT;
    root $BASE/www;
    index index.php index.html;
    location ~ \.php\$ {
      fastcgi_pass 127.0.0.1:9000;
      fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
      include /etc/nginx/fastcgi_params;
    }
  }
}
EOF

cat > "$BASE/httpd.conf" <<EOF
ServerRoot "$BASE"
PidFile "$BASE/httpd.pid"
ServerName 127.0.0.1
Listen $HTTPD_PORT
User www-data
Group www-data
LoadModule mpm_event_module $MODS/mod_mpm_event.so
LoadModule authz_core_module $MODS/mod_authz_core.so
LoadModule mime_module $MODS/mod_mime.so
LoadModule dir_module $MODS/mod_dir.so
LoadModule proxy_module $MODS/mod_proxy.so
LoadModule proxy_fcgi_module $MODS/mod_proxy_fcgi.so
TypesConfig /etc/mime.types
ErrorLog "$BASE/logs/httpd.err"
StartServers 4
ServerLimit 4
ThreadsPerChild 64
MaxRequestWorkers 256
DocumentRoot "$BASE/www"
<Directory "$BASE/www">
  Require all granted
  DirectoryIndex index.php index.html
</Directory>
<FilesMatch \.php\$>
  SetHandler "proxy:fcgi://127.0.0.1:9000"
</FilesMatch>
EOF

rps() { grep -E 'Requests/sec' | awk '{print $2}'; }
lat() { grep -E 'Latency' | head -1 | awk '{print $2}'; }
bench() { # url label
  local out
  out=$(wrk -t$THREADS -c$CONNS -d$DUR "$1" 2>/dev/null)
  printf '%-26s %12s req/s   avglat %9s\n' "$2" "$(echo "$out" | rps)" "$(echo "$out" | lat)"
}

echo "== dynamic PHP across servers (same app + same php-fpm; wrk ${THREADS}t/${CONNS}c/${DUR}, ${WORKERS} workers) =="
"$FPM" -F -y "$BASE/fpm.conf" > "$BASE/logs/fpm.log" 2>&1 &
FPMPID=$!
sleep 1

# ---- nginx + php-fpm ----
nginx -c "$BASE/nginx.conf" & NG=$!
sleep 1
echo "sanity nginx: $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$NGINX_PORT/index.php?name=x)"
wrk -t$THREADS -c$CONNS -d3s "http://127.0.0.1:$NGINX_PORT/index.php" >/dev/null 2>&1
bench "http://127.0.0.1:$NGINX_PORT/index.php?name=ada" "nginx+fpm   index.php"
bench "http://127.0.0.1:$NGINX_PORT/fc.php"             "nginx+fpm   fc.php"
kill $NG 2>/dev/null; wait $NG 2>/dev/null; sleep 1

# ---- apache httpd + php-fpm ----
apache2 -d "$BASE" -f "$BASE/httpd.conf" -k start 2>"$BASE/logs/httpd-start.log"
sleep 2
echo "sanity httpd: $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$HTTPD_PORT/index.php?name=x)"
wrk -t$THREADS -c$CONNS -d3s "http://127.0.0.1:$HTTPD_PORT/index.php" >/dev/null 2>&1
bench "http://127.0.0.1:$HTTPD_PORT/index.php?name=ada" "apache+fpm  index.php"
bench "http://127.0.0.1:$HTTPD_PORT/fc.php"             "apache+fpm  fc.php"
apache2 -d "$BASE" -f "$BASE/httpd.conf" -k stop 2>/dev/null; sleep 1

# ---- dart-apache + php-fpm, and native Dart ----
"$BASE/parity" --root="$BASE/www" --port=$DART_PORT --workers=$WORKERS --php-fpm=127.0.0.1:9000 --no-access-log > "$BASE/logs/dart.log" 2>&1 &
DA=$!
sleep 2
echo "sanity dart: $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$DART_PORT/index.php?name=x)"
wrk -t$THREADS -c$CONNS -d3s "http://127.0.0.1:$DART_PORT/parity/" >/dev/null 2>&1
bench "http://127.0.0.1:$DART_PORT/index.php?name=ada" "dart+fpm    index.php"
bench "http://127.0.0.1:$DART_PORT/fc.php"             "dart+fpm    fc.php"
bench "http://127.0.0.1:$DART_PORT/parity/?name=ada"   "dart NATIVE /parity/"
bench "http://127.0.0.1:$DART_PORT/parity/fc"          "dart NATIVE /parity/fc"
kill $DA 2>/dev/null; wait $DA 2>/dev/null

kill $FPMPID 2>/dev/null; wait $FPMPID 2>/dev/null
echo "== done =="
