# 17 — Parity checks vs. Apache & nginx

A plan to verify, by **differential testing**, that dart-apache behaves like
Apache httpd and nginx for the features it claims — and to turn every
difference into one of: *spec-compliant (intentional)*, *bug to fix*, or
*explicitly out of scope*.

> Scope note: HTTP/2 is out of scope (see [10-roadmap.md](10-roadmap.md)).
> Parity is measured on **HTTP/1.1 semantics** first (where all three servers
> are directly comparable), then HTTP/3-specific behavior separately.

## 1. Goal & definition of "parity"

For each request in a matrix, the three servers — fed the **same document
root, same PHP app, same config intent** — should return responses that agree
on the *semantically meaningful* parts:

- status code + reason class,
- normative headers (`Content-Type`, `Content-Length`, `Content-Range`,
  `Last-Modified`, `Location`, `Allow`, `Vary`, `Cache-Control`,
  `Content-Encoding`, `Transfer-Encoding`),
- body bytes (for GET; empty for HEAD),
- error semantics (404 vs 403 vs 400 vs 405 vs 413 vs 416).

"Parity" is **not** byte-identical headers. Volatile/implementation headers are
normalized out (see §4).

## 2. Methodology: differential harness

A runner spins up all three servers over the **same docroot** and a shared PHP
backend, issues each matrix request to all three, normalizes, and diffs.

```
tool/parity/
  docker-compose.yml     # apache + nginx + php-fpm (+ shared ./www volume)
  www/                   # fixtures: static files, php scripts, dotfiles, ranges
  matrix/                # request specs (method, path, headers, body) + expectations
  run_parity.(dart|mjs)  # issue to all 3, normalize, diff, emit a report
  normalize.*            # header/body normalization rules
  report/                # generated parity matrix (pass / intentional / gap)
```

- **Apache & nginx** run in Docker (pinned versions, e.g. `httpd:2.4`,
  `nginx:1.27`) with minimal configs that mirror dart-apache's feature set
  (static + `try_files`-style front controller + `fastcgi`/`proxy_pass`).
- **php-fpm** is shared so PHP output differences are server-mapping only, not
  SAPI differences. A second pass uses dart-apache's `php-cgi` path to separate
  CGI-vs-FPM effects.
- **dart-apache** runs from the repo binary on the same `./www` and a matching
  `--front-controller` / `--proxy` config.
- The runner targets **HTTP/1.1 over TCP** for the comparable core; a separate
  `curl --http3` / browser pass covers h3.

## 3. Comparison dimensions (what the matrix exercises)

**A. Static serving**
- `Content-Type` by extension (+ charset), `Content-Length`, `Last-Modified`.
- Conditional: `If-Modified-Since` / `If-None-Match` → `304`; `ETag` presence &
  weak/strong (intentional diff: dart-apache may not emit ETag — decide).
- Range: single range → `206` + `Content-Range`; unsatisfiable → `416`;
  multi-range → `multipart/byteranges` (decide scope); `If-Range`.
- `HEAD` parity with GET headers, empty body.
- Directory handling: index file, trailing-slash redirect (`301`), directory
  listing (off by default — parity = 403/404).
- Not found (`404`), forbidden dotfiles (`.htaccess`, `.git/`), path traversal
  (`../`, `%2e%2e`, encoded slash `%2f`), null byte.

**B. Compression**
- `Accept-Encoding: gzip` → `Content-Encoding: gzip` + `Vary: Accept-Encoding`;
  identity fallback; no double-compress; min-size threshold.

**C. PHP (CGI + FPM)**
- CGI params: `SCRIPT_NAME`, `SCRIPT_FILENAME`, `PATH_INFO`, `PATH_TRANSLATED`,
  `QUERY_STRING`, `REQUEST_URI`, `REMOTE_ADDR`, `HTTPS`, `SERVER_PROTOCOL`.
- Status line passthrough (`Status: 419`), header passthrough (`Set-Cookie`,
  `Location`, custom), `Content-Type` default.
- POST body (urlencoded, multipart, raw JSON), large upload, `100-continue`.
- Front-controller routing (`try_files $uri /index.php?$query`).

**D. HTTP/1.1 semantics & limits**
- Methods: `GET/HEAD/POST/PUT/DELETE/OPTIONS` → `200/405` + `Allow`.
- `Date`/`Server` presence, keep-alive, chunked request & response,
  `Expect: 100-continue`, `Connection` handling.
- Malformed request → `400`; over-long URI → `414`; over-size body → `413`;
  bad `Host` → `400`.
- Request smuggling: conflicting `Content-Length`/`Transfer-Encoding`,
  duplicate CL, header injection (CR/LF in header values).

**E. Reverse proxy**
- Hop-by-hop header stripping (`Connection`, `Keep-Alive`, `TE`, `Upgrade`),
  `X-Forwarded-For/Proto/Host`, `Host` preservation, upstream status/header
  passthrough, response streaming, `101` WebSocket upgrade passthrough.

**F. Logging & misc**
- Access-log format vs Common/Combined; `Alt-Svc` advertisement; TLS/ALPN.

## 4. Normalization (so diffs are meaningful)

Ignore or compare-loosely:
- Volatile: `Date`, `Server`, `Connection`, `Keep-Alive`, `ETag` *value*
  (compare presence/strength, not bytes), `Set-Cookie` session *value*.
- Ordering: compare headers as a case-insensitive multimap, not as a sequence.
- Transfer framing: treat `Content-Length` vs `Transfer-Encoding: chunked` as
  equivalent when the decoded body matches (record framing choice separately).
- Whitespace in header values trimmed.

Everything else is a tracked difference.

## 5. Triage of every difference

| Class | Meaning | Action |
| --- | --- | --- |
| ✅ match | semantically equal | record pass |
| 🟦 intentional | dart-apache differs but is RFC-compliant / documented (e.g. no ETag, no multipart ranges, h3-first `Alt-Svc`) | document in the parity matrix + README |
| 🔴 gap | dart-apache is wrong vs the RFC / both peers agree against us | file + fix |
| ⬜ out-of-scope | Apache/nginx-only feature we don't claim (mod_rewrite, SSI, HTTP/2) | note as non-goal |

## 6. Phasing

Each phase = build that slice of the matrix, run the diff, triage, fix 🔴 gaps,
then lock a CI-able subset.

1. **Phase A — Static parity** (highest value, lowest risk). A+B dimensions.
2. **Phase B — PHP parity.** C dimension, CGI then FPM.
3. **Phase C — HTTP semantics & limits.** D dimension (incl. smuggling/security).
4. **Phase D — Reverse proxy.** E dimension.
5. **Phase E — Logging/TLS/Alt-Svc + h3 pass.** F dimension + `curl --http3`.

**Acceptance per phase:** a generated parity report (pass/intentional/gap/oos),
all 🔴 fixed or ticketed, and a trimmed deterministic subset wired into CI
(reusing the Phase 6 `ci.yml`) that fails on regression.

## 7. Tooling choice

- Runner in **Dart** (reuse `AltSvcHttpClient` / `dart:io` `HttpClient`) or
  **Node** (already present for browser tests). Leaning Dart for the h1 matrix
  (no new runtime) + the existing Node/Playwright harness for the h3 pass.
- Apache/nginx/php-fpm via **Docker** for reproducibility; a WSL-native fallback
  (`apt install apache2 nginx php-fpm`) documented for machines without Docker.

## 8. Risks / non-goals

- **Env variance:** pin Apache/nginx/PHP versions; record them in the report.
- **Volatile headers:** handled by §4 normalization; mis-normalization hides
  real gaps — keep the ignore-list minimal and reviewed.
- **SAPI differences:** php-fpm shared across all three isolates the mapping;
  the php-cgi pass is compared separately, not against FPM.
- **Non-goals:** HTTP/2, `.htaccess`/mod_rewrite, SSI/CGI-bin scripts beyond
  PHP, Apache/nginx-specific tuning. Parity is only over features dart-apache
  claims in [05-features.md](05-features.md).

## 9. Open questions

1. **Docker or WSL-native** for Apache/nginx/php-fpm on this machine?
2. **Runner language:** Dart (h1) + Node (h3), or all-Node?
3. **ETag & multipart byteranges:** add to dart-apache for parity, or declare
   intentional diffs and document?
4. **Start phase:** Phase A (static) first — agreed?
