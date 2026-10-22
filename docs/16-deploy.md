# 16 — Deploy recipe (Phase 4)

Production deployment of dart-apache serving a Laravel + Livewire app over
HTTP/3 with the WebTransport Livewire bridge. See
[15-webtransport-hardening-plan.md](15-webtransport-hardening-plan.md) Phase 4.

> **Scope:** Phase 5 (chain-to-root PKI on the handshake path, 0-RTT anti-replay)
> is not yet complete, so run this **behind a trusted TLS terminator or on a
> trusted network** until that lands. The flags below load a real certificate,
> but the vendored QUIC stack still pins/self-signs rather than validating a
> full chain.

## 1. Build the Linux binary

On a dev box with Dart 3.13+:

```bash
dart run tool/build_linux.dart   # -> build/dart_apache-linux-x64 (static ELF)
```

Copy `build/dart_apache-linux-x64` to the server (e.g. `/usr/local/bin/dart_apache`).

## 2. Persistent ticket key (required)

Session tickets are AES-GCM-sealed with `--wt-ticket-key`. If omitted, a random
key is generated per run — tickets would break on restart and across workers.
Generate one **once** and keep it stable:

```bash
openssl rand -base64 32 > /etc/dart-apache/wt-ticket.key
chmod 600 /etc/dart-apache/wt-ticket.key
```

## 3. Flags

The convenience bundle:

```bash
dart_apache \
  --laravel=/srv/app/public \
  --address=0.0.0.0 --port=443 --http3 \
  --tls-cert=/etc/ssl/app.crt --tls-key=/etc/ssl/app.key \
  --php-cgi=/usr/bin/php-cgi \
  --workers=4 \
  --wt-ticket-key="$(cat /etc/dart-apache/wt-ticket.key)"
```

`--laravel=<public-dir>` expands to:

| Implied flag                     | Value              |
|----------------------------------|--------------------|
| `--root`                         | the public dir     |
| `--front-controller`             | `/index.php`       |
| `--wt-path`                      | `/wt`              |
| `--wt-bridge-path`               | `/livewire/update` |
| `--wt-ticket-path`               | `/wt-ticket`       |

Any explicit flag overrides its implied value.

## 4. systemd unit

`/etc/systemd/system/dart-apache.service`:

```ini
[Unit]
Description=dart-apache (HTTP/3 + Livewire WebTransport) for Laravel
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=/srv/app
# Keep the key out of the process list / logs.
Environment=WT_TICKET_KEY_FILE=/etc/dart-apache/wt-ticket.key
ExecStart=/bin/sh -c '/usr/local/bin/dart_apache \
  --laravel=/srv/app/public \
  --address=0.0.0.0 --port=443 --http3 \
  --tls-cert=/etc/ssl/app.crt --tls-key=/etc/ssl/app.key \
  --php-cgi=/usr/bin/php-cgi \
  --workers=4 \
  --wt-ticket-key="$(cat "$WT_TICKET_KEY_FILE")"'
# Port 443 without root:
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now dart-apache
journalctl -u dart-apache -f
```

Multi-worker QUIC uses `SO_REUSEPORT` on Linux, so all `--workers` share the
UDP port. The ticket key is passed identically to every worker.

## 5. Laravel app settings

`.env`:

```dotenv
APP_URL=https://your-host
SESSION_DRIVER=file           # or redis/database
SESSION_SECURE_COOKIE=true
SESSION_HTTP_ONLY=true         # safe: the WT ticket carries the session
```

Install the [livewire-webtransport](../packaging/livewire-webtransport/README.md)
package, publish its asset, and add `@webtransport` before `@livewireScripts`.

```bash
php artisan config:cache
php artisan view:cache
```

## 6. TLS

`--tls-cert` / `--tls-key` load a PEM cert + key (the server also accepts a
full chain in the cert file). For local dev use
`dart run tool/gen_dev_cert.dart build`.

The vendored client/handshake path verifies the `CertificateVerify` signature
over the transcript, the leaf SAN against the hostname, the leaf validity
window, and — when a `TrustStore` is configured — full chain-to-root path
validation (RFC 5280 §6 subset: name chaining, CA `basicConstraints`, per-cert
validity, ECDSA/RSA signatures, termination at a trusted anchor). Without trust
anchors configured, trust is pin/transcript based; terminate TLS at a trusted
front end or run on a trusted network for that mode. Note: the chain validator
requires a CA anchor, so a bare self-signed leaf must be pinned, not used as an
anchor.

## Verify

From a browser over HTTP/3, a Livewire interaction should round-trip with
`window.__livewireWtUsed` incrementing and the server log showing
`POST /livewire/update HTTP/3 200` — with automatic `fetch` fallback if
WebTransport is unavailable.
