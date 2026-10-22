# 13 — WSL / Linux Integration Testing

Some capabilities are **POSIX-oriented** and cannot be exercised on Windows.
This document lists exactly what must be done on a real Linux environment (WSL
or a container) to verify them. Dart cross-compiles the binaries from Windows
(see `tool/build_linux.dart`); Linux is only needed to **run** them against
Linux-only services.

## Why Linux is required

| Capability | Why it needs Linux |
| --- | --- |
| **FastCGI → PHP-FPM** | PHP-FPM is Unix-only; Windows ships `php-cgi`, not `php-fpm`. |
| **SIGHUP reload / SIGTERM** | Those signals don't exist on Windows; reload/graceful-stop are POSIX-only. |
| **Unix-domain sockets** | `--php-fpm=unix:/path` needs AF_UNIX. |
| **`SO_REUSEPORT` UDP fan-out** | The HTTP/3 multi-isolate acceptor (planned) relies on Linux socket semantics. |
| **Privilege drop on :80/:443** | Binding low ports + dropping capabilities is a Linux concern. |

## One-time WSL setup

The only distro present is `docker-desktop` (the Docker backend, not a shell).
Install a general-purpose distro:

```powershell
wsl --install -d Ubuntu
```

Inside Ubuntu:

```bash
sudo apt update
sudo apt install -y dart php-fpm php-cli curl
# or install Dart from https://dart.dev/get-dart
```

## Build (from Windows or WSL)

```powershell
dart run tool/build_linux.dart          # -> build/*-linux-x64 (ELF)
```

The `build/` binaries are self-contained; copy them into WSL and run directly.

## Tasks to verify on Linux

### 1. FastCGI against real PHP-FPM
```bash
# ensure php-fpm is listening (default: 127.0.0.1:9000 or a unix socket)
sudo service php8.3-fpm start
./build/dart_apache-linux-x64 --root=./public --port=8080 \
  --php-fpm=127.0.0.1:9000   # or --php-fpm=unix:/run/php/php8.3-fpm.sock
curl -s 'http://127.0.0.1:8080/?name=FPM'
```
**Expected:** the PHP page renders via FastCGI (persistent FPM workers, no
per-request process spawn). Verify `$_SERVER` vars and a POST body round-trip.

### 2. Zero-downtime reload (SIGHUP)
```bash
./build/dart_apache-linux-x64 --root=./public --port=8080 --workers=4 &
PID=$!
# drive traffic in another shell: while true; do curl -s localhost:8080/ >/dev/null; done
kill -HUP $PID     # expect a fresh worker generation, zero dropped requests
kill -TERM $PID    # graceful drain + exit
```
**Expected:** `reload complete` logged; in-flight requests finish; no connection
errors during the swap.

### 3. Crash-loop backoff
Point `--php-cgi` / `--php-fpm` at a bad target or force a worker to throw;
confirm respawns back off exponentially and the supervisor **gives up after 5
rapid crashes** (see `backoffDelay` / crash-loop protection).

### 4. HTTP/3 over the network
```bash
./build/dart_apache_h3-linux-x64 --root=./public --port=4433 &
# with a real h3 client:
curl --http3 -k 'https://127.0.0.1:4433/'
```
**Expected:** HTTP/3 response from PHP. Also test `curl --http3` interop and the
multi-isolate UDP acceptor once implemented (see
[12-http3-integration-plan.md](12-http3-integration-plan.md)).

### 5. End-to-end Alt-Svc upgrade (HTTPS)
Real browsers only honor `Alt-Svc` over **HTTPS**, so this needs the TLS h1
listener (Phase 1). Until then, verify with our Dart client
(`bin/dart_apache_client.dart`), which upgrades over plain HTTP too.

## Containerized alternative (no WSL distro)

If only Docker is available, a `php-fpm` container plus the Linux binary covers
tasks 1–3:

```dockerfile
# (sketch) FROM debian:stable-slim; COPY build/dart_apache-linux-x64 /app/;
# run alongside a php:fpm container, --php-fpm=php:9000
```

A ready-made `Dockerfile` + compose for the dart-apache ⇄ PHP-FPM pair is a
good next deliverable.

## Definition of done

Tasks 1–4 pass on Linux, closing the "unverified on Windows" caveats in
[02-gap-analysis.md](02-gap-analysis.md) for FastCGI and SIGHUP reload.
