# 21 — Dartisan: a batteries-included framework for dynamic apps

**Why.** dart-apache already *beats nginx+php-fpm for dynamic app workloads*
(2–3.8×, see [20-beat-the-giants.md](20-beat-the-giants.md)) — but raw speed
isn't enough to win developers. Laravel wins because of **DX**: routing,
controllers, Blade templating, Eloquent, and Livewire. We need the equivalent,
in pure Dart, with **HTTP/3 + WebTransport as the bargaining chip** no PHP stack
can match natively.

## 1. The stack (names are provisional)

| Laravel | **Dartisan** (ours) | What it is |
| --- | --- | --- |
| Routing + controllers | **Dartisan Router / Controllers** | route groups, params, middleware, resourceful controllers |
| Blade | **Blaze** | server-side templating: `{{ }}`, `@if/@foreach/@include`, layouts (`@extends/@section/@yield`) |
| Livewire | **Dartisan Live** | reactive server-rendered components streamed over **WebTransport/HTTP‑3** (our edge) |
| Eloquent | **Dartisan Data** | thin query/record layer (`Database`/`QueryBuilder`) + pure-Dart `InMemoryDatabase`; wire-driver DBs later |
| Artisan CLI | **`dartisan` CLI** | `new`, `make:controller`, `make:view`, `serve`, `routes` |
| Validation / Requests | **FormRequest** | typed request validation |
| Middleware | **Middleware** | before/after hooks (auth, CSRF, logging) — reuse client interceptor shape |

Everything compiles into **one native binary** (server + app), and stays
**backward compatible**: PHP, static, and `--dart-cgi` keep working.

## 2. The differentiator — Dartisan Live over WebTransport

Laravel+Livewire pushes component diffs over HTTP long-polling or a WebSocket
tier (Reverb/Pusher). **Dartisan Live** renders components server-side and
streams updates over a **native WebTransport session** (already built:
`WtHandler`, `WtSession`, and the Livewire-over-WT bridge). No WebSocket server,
no second process — the reactive channel is *in the same binary* on HTTP/3.
This is the thing PHP can't do without bolting on infrastructure.

## 3. Build order (each slice shippable + tested)

- [x] **F1 — Blaze templating engine.** `{{ expr }}` (escaped) / `{!! !!}`
      (raw), `@if/@elseif/@else`, `@foreach`, `@include`, layouts
      (`@extends/@section/@yield`), `{{-- comments --}}`; a safe mini
      expression language (paths, literals, comparisons, logic) that runs under
      AOT (no `eval`). *This doc's first deliverable.*
- [x] **F2 — View + Router/Controller sugar.** `Router.get('/users/:id', …)`
      with `:param` paths, route groups (prefix + middleware), global
      middleware, and a `Request` facade (params/query/body/json +
      view/json/text/html/redirect responders) over the `DartApp` pipeline.
- [x] **F3 — `dartisan` CLI.** `dartisan new <app>` scaffolds a project;
      `make:controller/component/view` generate files; `serve` runs it via
      `dart run`. (`bin/dartisan.dart` + `lib/src/framework/cli/scaffold.dart`.)
- [x] **F4 — Dartisan Live.** reactive components over WebTransport:
      `LiveComponent` (state round-trips to the client), `LiveRegistry`,
      `liveWtHandler` (parses an action, updates + re-renders, streams the new
      HTML back over the WT stream), and `liveMount` (initial render + client
      runtime `public/app/dartisan-live.js`). **Live-verified in Edge** over
      real HTTP/3: a counter's +/- clicks drive state over WebTransport
      (`example/live_app.dart`, `tool/browser-h3-test/live_wt_test.js`).
- [x] **F5 — Data layer.** [x] request validation (`Validator` /
      `req.validate(rules)`, Laravel-style rule strings); [x] a thin
      record/query layer (`Database` / `QueryBuilder` — chainable
      `where/whereIn/orderBy/limit/offset` + `get/first/count/insert/update/
      delete`) with a pure-Dart, no-FFI `InMemoryDatabase` first driver. A real
      driver (e.g. pure-Dart Postgres) can implement `Database` unchanged.
      (`lib/src/framework/data/query.dart`.)
- [x] **F6 — Getting started.** a "build a Dartisan app in 10 minutes"
      tutorial that leads with the HTTP/3 + Live story
      ([22-getting-started.md](22-getting-started.md)).

## 3b. Phase 2 — close the Livewire/Laravel gaps (post-F6)

The F1–F6 core is done. Phase 2 lands the features that make the framework feel
production-real, in value order. Each slice stays shippable + tested + PHP-safe.

- [x] **G1 — Live DOM morphing + input binding.** Replace the client's
      `innerHTML =` full-replace with a **keyed DOM morph** (morphdom-lite) that
      preserves focus, caret/selection, scroll, and uncommitted input state
      across updates. Add two-way `data-live-model` (input value folds into
      state on the next action) and `data-live-input` / `data-live-change` /
      `data-live-submit` delegation (debounced). This closes the last real gap
      vs Livewire and is the HTTP/3 showcase. Live-verified in Edge over real
      HTTP/3 (counter +3/−1 → 2). (`public/app/dartisan-live.js`.)
- [x] **G2 — Auth + sessions.** A stateless **encrypted-cookie** session
      (`SessionManager` / `Session`, AES-GCM — the whole session rides in the
      cookie, so it works across the worker-per-isolate model with no shared
      store), `Request.session` with get/put/forget/pull/flush + one-request
      `flash`, an `Auth` helper (login/logout/check/id), a `requireAuth`
      middleware guard, and Blaze `@auth / @guest` directives.
      (`lib/src/framework/auth/session.dart`.)
- [x] **G3 — Service container (DI).** `bind` / `singleton` / `instance` /
      `make` — a type-keyed IoC container (one per worker isolate), registered
      on the `Router` (`router.singleton<T>(...)`) and resolved in handlers via
      `request.make<T>()`. (`lib/src/framework/container/container.dart`.)
- [x] **G4 — Showcase app.** `example/dartisan_app.dart` — one end-to-end app
      (routing + middleware, Blaze views with `@auth/@guest`, validation, the
      data layer via DI, encrypted-cookie sessions + `requireAuth`, flash
      messages, and a Live counter over WebTransport). A login → notes → logout
      flow that doubles as a living demo. Verified end-to-end over HTTP/1.1
      (auth redirect, cookie session, per-user notes, flash) and the Live
      channel over HTTP/3.
- [ ] *(parked)* **wire DB driver** — a pure-Dart Postgres `Database` impl for
      shared, persistent state across workers. Deprioritized.

## 3c. Phase 3 — application services

With the request/view/reactive stack done, Phase 3 adds the background-service
layer Laravel leans on. All pure Dart, in-process, no sidecars.

- [x] **H1 — Live server-side diffing.** The server is stateless but holds both
      the old state (round-tripped from the client) and the new state, so it can
      render *both* and send a compact **patch** (changed substring) instead of
      the full HTML. The client reconstructs against its exact base string
      (seeded from the mount) and still morphs the DOM. Big wire savings for
      small updates (a counter sends a few bytes, not the whole fragment).
      Default on (`liveWtHandler(registry, diff: true)`); live-verified in Edge
      over HTTP/3. (`lib/src/framework/live/diff.dart`.)
- [x] **H2 — Events + queue.** A type-keyed `EventDispatcher`
      (`listen<T>` / `dispatch`, awaits async listeners) and an in-memory async
      `Queue` (`push` + `CallbackJob`, delayed jobs, retries up to
      `maxAttempts`, `onFailed`, microtask drain + `settle()`) for fire-and-
      forget work off the request path.
      (`lib/src/framework/events/events.dart`, `.../queue/queue.dart`.)
- [x] **H3 — Mail.** A `Mailer` over a `MailTransport` seam with pure-Dart
      `ArrayTransport` (tests) and `LogTransport` (dev); `Message` (to/subject/
      html/text), and `mailer.queue(message, queue)` for background delivery via
      H2. (SMTP is a later transport.) (`lib/src/framework/mail/mail.dart`.)

## 3d. Phase 4 — cohesion & polish

The primitives exist; Phase 4 makes them hang together and backs the claims with
docs + numbers. No new external dependencies.

- [x] **I1 — Wire services through DI.** Register `EventDispatcher`, `Queue`,
      and `Mailer` on the container, expose `request.events` / `request.queue`
      sugar, and demonstrate the flow in the showcase (adding a note fires a
      `NoteAdded` event whose listener queues a `LogTransport` notification,
      delivered off the request path). Verified: `[mail] to=…` logged after a
      note POST.
- [x] **I2 — CSRF protection.** A session-backed CSRF token
      (`request.csrfToken()`), a `verifyCsrf` middleware for unsafe methods
      (POST/PUT/PATCH/DELETE; token from the `_token` field or `X-CSRF-Token`
      header → 419 on mismatch), and a Blaze `@csrf` directive (hidden field).
      Wired into the showcase; request body is buffered so CSRF + `validate`
      both read it. (`router.dart`, `blaze.dart`.)
- [x] **I3 — Perf receipt for Live diffing.** `tool/bench_live_diff.dart`
      measures bytes-on-the-wire, full-HTML reply vs H1 patch. **Measured:** the
      patch is a flat **~23–36 B** regardless of fragment size — counter 41→42
      **218→23 B html (−89%)**, 50-item list toggle **5,347→34 B (−99.4%)**,
      200-item list toggle **21,597→36 B (−99.8%)**; full replies (incl. state)
      shrink **77–83%**.
- [x] **I4 — Docs refresh.** Folded Phase 2 + Phase 3 (sessions/auth + CSRF,
      DI, events/queue/mail, Live diffing) into the getting-started tutorial
      ([22-getting-started.md](22-getting-started.md) §7–§9) so the end-to-end
      story is complete.
- [ ] *(parked)* **SMTP mail transport** — moved to Phase 6 (§3f) and in
      progress.
- [ ] *(parked)* **wire DB driver** — a pure-Dart Postgres `Database` impl.
      Deprioritized.

## 3e. Phase 5 — tightening & hardening

Features are in; Phase 5 makes them safe and robust under hostile input, in
value order. All framework-layer (Router/Request/middleware), pure Dart, each
slice shippable + tested + PHP-safe.

- [x] **J1 — Request body limits.** A configurable max request-body size
      (`Router(maxBodyBytes:)`): reject on `Content-Length` over the cap and
      stop buffering a stream that exceeds it → `413`, via a
      `PayloadTooLargeException`. Protects `bodyBytes`/`validate`/`formField`/
      CSRF from unbounded-memory DoS. Verified live (70 KB → 413).
- [x] **J2 — Timing-safe token comparison.** A `constantTimeEquals` helper used
      by `verifyCsrf` (and available for session/auth checks) so token checks
      don't leak via timing.
- [x] **J3 — Session + auth hardening.** `session.regenerate()` (rotate the
      CSRF token on privilege change), `Auth.login`/`logout` regenerate, and a
      32-byte session-key assertion.
- [x] **J4 — Error boundary.** A router-level guard around the handler chain:
      `ValidationException → 422` (JSON field errors), any other throw → a
      generic `500` with **no stack-trace leak**, plus a server-side `onError`
      log hook (`Router(onError:)`, safe default to stderr).
- [x] **J5 — Rate limiting.** A `rateLimit(max, window, {keyBy})` middleware —
      in-memory fixed-window per key (client IP by default) → `429` with
      `Retry-After`. Wired onto the showcase login group.

## 3f. Phase 6 — real mail transport (SMTP)

Unparks the SMTP transport. Our `MailTransport` seam (H3) means this is a
drop-in: `Mailer(SmtpTransport(...))` with no other changes.

- [x] **K1 — SMTP submission transport.** A self-contained
      `SmtpTransport implements MailTransport` on `dart:io` only (no new
      dependencies): connect (implicit-TLS / STARTTLS / plain), `EHLO`,
      `AUTH LOGIN`/`PLAIN`, `MAIL FROM` / `RCPT TO` / `DATA` with RFC-5322
      headers (`multipart/alternative` when both text + html), dot-stuffing and
      CRLF. Tested against a loopback fake SMTP server (no external services).
      For a full MTA (direct-MX delivery, DKIM, SPF/DMARC, DSN) the heavyweight
      [`dart-email-server`](https://github.com/KellyKinyama/dart-email-server)
      package can implement the same `MailTransport` instead.

## 3g. Phase 7 — wire DB driver

Unparks the last item. The `Database` seam (F5) makes this a drop-in: build the
same `QueryBuilder` API against a networked SQL server instead of the in-memory
map — giving **shared, persistent state across worker isolates**.

- [x] **L1 — `SqlDatabase` wire driver.** A pure-`dart:io` `Database` impl that
      speaks [`dart-db-server`](https://github.com/KellyKinyama/dart-db-server)'s
      newline-delimited JSON protocol (`{"id","sql"}` →
      `{"ok","columns","rows","affected"}`): translates `QueryBuilder`
      `where/whereIn/orderBy/limit/offset` → `SELECT`, `insert` →
      `INSERT … RETURNING *`, `update`/`delete` → `UPDATE`/`DELETE … affected`;
      plus a raw `execute(sql)` for DDL/migrations. Request multiplexing by
      `id`, lazy connect, single-quote escaping. Tested against a loopback fake
      server (default suite) and **live-verified** against a running
      `dart-db-server` via `tool/smoke_sql_db.dart` (CREATE → insert w/ returned
      auto-id → filtered select/first/count → update → delete).

## 4. Principles

- **DX first** — the happy path should feel like Laravel: a route, a controller,
  a view, done.
- **Pure Dart, one binary** — no FFI, no sidecars; compile and ship.
- **h3/WebTransport native** — reactivity is a first-class, in-binary feature.
- **Backward compatible** — never break PHP/static/`--dart-cgi`.
- **Measured** — every perf claim backed by `tool/bench_*`.

## 5. Parity map — vs Laravel (features)

Tracked as we build. Status: ✅ done · 🟡 in progress · ⬜ planned.

| Laravel | Dartisan | Status |
| --- | --- | --- |
| Blade templating | Blaze (`{{ }}`, `@if/@foreach/@include`, layouts) | ✅ |
| Livewire (reactive) | Dartisan Live over WebTransport/HTTP‑3 | ✅ |
| Routing (`Route::get`, params) | `Router.get('/users/:id', …)` + params | ✅ F2 |
| Controllers | handler classes / methods bound to routes | ✅ F2 |
| Request / Response | `Request` (params/query/body/json) + responders | ✅ F2 |
| Middleware | before/after hooks, groups | ✅ F2 |
| Views / `view()` helper | `req.view('home', {...})` (Blaze) | ✅ F2 |
| Validation / FormRequest | `Validator` / `req.validate(rules)` | ✅ F5 |
| Eloquent ORM + migrations | record/query layer + a DB driver | ⬜ F5 |
| Artisan CLI | `dartisan` CLI (`new`, `make:*`, `serve`) | ✅ F3 |
| Service container / DI | per-worker app container | ⬜ F3 |
| Auth / sessions | session + auth guards (WT ticket already exists) | ⬜ later |
| Queues / events / mail | background isolates + event bus | ⬜ later |
| Cache | `--cache` (dynamic) + app cache API | 🟡 partial |

## 6. Parity map — vs Flutter (programming model)

Dartisan Live borrows Flutter's **declarative, reactive, same-language** model —
but renders on the server and streams updates over HTTP/3 instead of painting a
canvas. The goal: a Flutter developer feels at home writing server UI.

| Flutter | Dartisan Live | Status |
| --- | --- | --- |
| `Widget` (composable UI) | `LiveComponent` (composable server UI) | ✅ |
| `StatelessWidget` | a component that only `render`s | ✅ |
| `StatefulWidget` + `setState` | `LiveComponent` state + `update(action, …)` | ✅ |
| `build(context)` | `render(state)` → HTML (via Blaze) | ✅ |
| Reactive rebuild on state change | re-render + stream diff/HTML over WebTransport | ✅ (full HTML today; diffing ⬜) |
| Hot reload | `dart run` edit-refresh / `--dart-cgi` | ✅ |
| One language (Dart) front-to-back | Dart server + Dart client (+ tiny JS runtime) | ✅ |
| Widget tree composition / slots | nested components + Blaze `@include`/sections | 🟡 |
| Navigator / routing | Dartisan Router | ✅ F2 |
| Provider / Riverpod (state mgmt) | component state + (later) shared stores | ⬜ later |
| `flutter create` scaffolding | `dartisan new` | ✅ F3 |

**Positioning:** *Laravel's batteries + Livewire's reactivity + Flutter's
Dart/declarative model — in one compiled binary, reactive over HTTP/3.*

