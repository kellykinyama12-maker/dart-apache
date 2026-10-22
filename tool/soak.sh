#!/usr/bin/env bash
# Multi-worker soak for dart-apache on a native (ext4) Linux checkout.
#
# Stage the binary + certs + public dir on native ext4 (NOT /mnt/c), start the
# server with multiple workers, then run this to drive TLS (h1) + HTTP/3 (QUIC)
# load across the SO_REUSEPORT workers and report failures + worker RSS deltas.
#
# Usage: soak.sh [h1_requests] [h3_requests] [port]
#
#   # on native ext4, e.g. ~/dasoak:
#   ./dart_apache-linux-x64 --root=./public --port=8600 --http3 \
#     --tls-cert=cert.pem --tls-key=key.pem --workers=4 &
#   bash soak.sh 2000 40 8600
set -u

pat=dart_apache-linux
port=${3:-8600}
h1n=${1:-2000}
h3n=${2:-40}
h1url="https://127.0.0.1:${port}/bench.txt"
h3url="https://127.0.0.1:${port}/bench.txt"
h3client=/mnt/c/projects/webserver/dart-apache/build/dart_apache_client-linux-x64

rss_total() {
  local sum=0 p kb
  for p in $(pgrep -f "$pat"); do
    kb=$(awk '/VmRSS/{print $2}' "/proc/$p/status" 2>/dev/null)
    [ -n "${kb:-}" ] && sum=$((sum + kb))
  done
  echo "$sum"
}

echo "workers: $(pgrep -fc "$pat")"
echo "total worker RSS before: $(rss_total) KB"

echo "soak: ${h1n}x h1 TLS GET /bench.txt"
fail=0
start=$(date +%s.%N)
for ((i = 0; i < h1n; i++)); do
  code=$(curl -k -s -o /dev/null -w '%{http_code}' "$h1url")
  [ "$code" = "200" ] || fail=$((fail + 1))
done
end=$(date +%s.%N)
rps=$(awk "BEGIN{printf \"%.0f\", $h1n / ($end - $start)}")
echo "h1 requests=$h1n failures=$fail throughput=${rps} req/s"
echo "total worker RSS after h1: $(rss_total) KB"

if [ -x "$h3client" ] && [ "$h3n" -gt 0 ]; then
  echo "h3 batch: ${h3n}x QUIC GET via prebuilt client"
  h3ok=0
  for ((i = 0; i < h3n; i++)); do
    "$h3client" --insecure "$h3url" >/dev/null 2>&1 && h3ok=$((h3ok + 1))
  done
  echo "h3 requests=$h3n ok=$h3ok"
fi
