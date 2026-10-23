# Browser HTTP/3 test

Verifies a **real browser** connects to dart-apache over **HTTP/3 (QUIC)**, using
[`playwright-core`](https://www.npmjs.com/package/playwright-core) to drive an
already-installed **Edge or Chrome** (no browser download).

The self-signed dev certificate is accepted via **certificate pinning**: the
cert's SPKI SHA-256 is passed to Chromium's
`--ignore-certificate-errors-spki-list` (plain `--ignore-certificate-errors`
does **not** enable QUIC to a self-signed origin). A real CA/Let's Encrypt cert
removes the need for the pin.

## Run

```sh
# 1. generate a dev cert (from the repo root)
dart run tool/gen_dev_cert.dart build

# 2. start the unified HTTPS/1.1 + HTTP/3 server
dart run bin/dart_apache.dart --root=./public --port=8443 --http3 \
    --tls-cert=build/cert.pem --tls-key=build/key.pem --workers=1

# 3. run the browser test
cd tool/browser-h3-test
npm install                       # playwright-core only; no browser download
node h3_test.js --port 8443 --cert ../../build/cert.pem
```

Expected output (QUIC forced on the origin):

```json
{
  "forcedQuic": true,
  "nextHopProtocol": "h3",
  "status": 200,
  "h1": "Hello, Browser!"
}
```

Pass `--no-force` to test the natural `Alt-Svc` discovery path instead: the first
navigation is `http/1.1` and the response carries `alt-svc: h3=":8443"; ma=...`,
which the browser uses to upgrade on a later connection.

## How the flags work

- `--enable-quic` — enable the QUIC/HTTP-3 client.
- `--origin-to-force-quic-on=host:port` — use HTTP/3 directly (skip `Alt-Svc`
  discovery) so we test the h3 datapath in one navigation.
- `--ignore-certificate-errors-spki-list=<base64 SHA-256 of SPKI>` — trust our
  self-signed cert by pinning its public key.

## WebTransport test

With the server started with `--wt-path=/wt`, verify a browser opens a
WebTransport session over HTTP/3 and echoes a datagram:

```sh
node wt_test.js --port 8443 --cert ../../build/cert.pem --path /wt
# -> { "ok": true, "echoed": "ping-webtransport" }
```

## Dartisan Live tests

Each exercises a **Dartisan Live** feature end-to-end over real HTTP/3 +
WebTransport, driving `example/live_app.dart`:

```sh
# start the Live demo over h3 (from the repo root)
dart run example/live_app.dart --root=./public --port=8651 --http3 \
    --wt-path=/wt --tls-cert=build/cert.pem --tls-key=build/key.pem

cd tool/browser-h3-test
node live_wt_test.js        --port 8651 --cert ../../build/cert.pem  # counter (actions)
node live_signup_wt_test.js --port 8651 --cert ../../build/cert.pem  # validation round-trip
node live_b2_wt_test.js     --port 8651 --cert ../../build/cert.pem  # polling + live search
node live_b3_wt_test.js     --port 8651 --cert ../../build/cert.pem  # nested components
node live_b4_wt_test.js     --port 8651 --cert ../../build/cert.pem  # cross-component events
node live_b5_wt_test.js     --port 8651 --cert ../../build/cert.pem  # dirty state
# each prints { "ok": true, ... } on success
```

