# livewire-webtransport

Transparent **WebTransport (HTTP/3)** transport for Livewire component updates,
served by the [dart-apache](https://github.com/) webserver bridge.

Livewire's component-update POSTs are transparently rerouted over a WebTransport
bidi stream to the dart-apache bridge, which forwards them to PHP exactly like
the original XHR (CSRF token and session carried along). Any failure — or a
browser without WebTransport — falls back to native `fetch`, so it is safe to
include unconditionally.

## Requirements

- Laravel 11+ with Livewire 3 or 4
- The app served by **dart-apache** over HTTP/3 with the Livewire WT bridge
  enabled (simplest: `--laravel=<public-dir>`; see below)

## Install

```bash
composer require dartapache/livewire-webtransport
php artisan vendor:publish --tag=webtransport-assets
php artisan vendor:publish --tag=webtransport-config   # optional
```

Add the directive to your layout `<head>`, **before** `@livewireScripts`:

```blade
<head>
    <!-- ... -->
    @webtransport
    @livewireScripts
</head>
```

`@webtransport` emits the `<meta name="csrf-token">` tag, a small config blob,
and the shim `<script>`. That is all the markup you need — no manual JS copy.

## Server

Serve the Laravel `public/` dir through dart-apache with the convenience flag:

```bash
dart_apache --laravel=/srv/app/public --port=443 --http3 \
  --tls-cert=/etc/ssl/app.crt --tls-key=/etc/ssl/app.key \
  --wt-ticket-key="$(cat /etc/dart-apache/wt-ticket.key)"
```

`--laravel` implies `--front-controller=/index.php`, `--wt-path=/wt`,
`--wt-bridge-path=/livewire/update`, and `--wt-ticket-path=/wt-ticket`. Any of
those may be overridden by passing the explicit flag.

> **Production:** always pass a persistent `--wt-ticket-key` (base64 of 32
> random bytes) so session tickets survive restarts and are shared across all
> workers. Generate one with `dart_apache` or
> `openssl rand -base64 32`.

See the dart-apache deploy recipe (`docs/16-deploy.md`) for a systemd unit and
the full flag reference.

## Configuration

`config/webtransport.php`:

| Key          | Env                        | Default        | Purpose |
|--------------|----------------------------|----------------|---------|
| `url`        | `LIVEWIRE_WT_URL`          | current origin `/wt` | WebTransport endpoint (`--wt-path`) |
| `ticket_url` | `LIVEWIRE_WT_TICKET_URL`   | `/wt-ticket`   | Session-ticket endpoint; keeps the cookie HttpOnly |
| `endpoint`   | `LIVEWIRE_WT_ENDPOINT`     | auto           | Override the update-endpoint match |
| `enabled`    | `LIVEWIRE_WT_ENABLED`      | `true`         | Master switch |

## How it works

The shim patches `window.fetch` and intercepts only POSTs to the Livewire
update endpoint (`/livewire/update` or Livewire 4's randomized
`/livewire-<hash>/update`). It opens a WebTransport session, sends the request
body with a short header preamble (CSRF token + session ticket), and reconstructs
a real `Response` from the server's framed reply. Everything else is untouched.

## Publishing

This package lives in the dart-apache monorepo under
`packaging/livewire-webtransport`. To release it on Packagist:

1. Mirror this directory to its own public repo (or use a
   [git subtree split](https://www.subtreesplit.com/)).
2. Validate and tag a semver release:
   ```bash
   composer validate --strict
   git tag v0.1.0 && git push --tags
   ```
3. Submit the repo URL once at <https://packagist.org/packages/submit>; a
   webhook then auto-updates Packagist on each new tag.

Consumers then `composer require dartapache/livewire-webtransport`. Until then,
use a path repository (see **Server** above).

## License

MIT
