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
| Blade | **Blaze** | server-side templating: `{{ }}`, `@if/@foreach/@include`, layouts (`@extends/@section/@yield`), and `<x-component>` with props + slots |
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

## 3h. Phase 8 — scaffold enrichment

Make `dartisan new` produce a *real* starter and add the generators an app
developer reaches for next, so you're productive from the first command.

- [x] **M1 — Embed the Live runtime.** Exposes the client runtime as a Dart
      constant (`liveRuntimeSource`) generated from
      `public/app/dartisan-live.js` by `tool/gen_live_runtime.dart`, so any app
      can `liveMount(…, inlineRuntime: liveRuntimeSource)` with no asset file.
- [x] **M2 — A batteries-included `new` starter.** The generated app ships a
      shared layout + nav, home/about pages, sessions + CSRF, a login/logout +
      a `requireAuth`-guarded dashboard, and a Live counter (inline runtime) —
      a working tour of the framework. Verified: scaffold → `pub get` →
      `dart analyze` (clean) → runs (home/about/guard/CSRF-login/dashboard+Live).
- [x] **M3 — `make:model`.** Generates a typed record + repository over the
      `Database` (`fromRow`/`toMap`, `all/find/create/update/delete` via the
      `QueryBuilder`), wired to a table.
- [x] **M4 — `make:middleware`.** Generates a `Middleware` stub (before/after
      `next()`), ready to `router.use(...)`.

## 3i. Phase 9 — schema-aware generators + migrations

Turn the data layer into a full workflow: describe columns on the command line,
get a typed model and a runnable migration.

- [x] **N1 — Schema-aware `make:model`.** `make:model Post title:text
      views:integer published:boolean` parses `name:type` field specs into a
      typed record (correctly-typed fields, `fromRow`/`toMap`) + repository, and
      embeds the matching `CREATE TABLE` SQL. Types: `text/string`,
      `integer/int`, `real/double`, `boolean/bool`.
- [x] **N2 — `make:migration`.** `make:migration CreatePostsTable title:text …`
      writes `migrations/<timestamp>_<name>.dart` — a `Migration` with
      `up()` = `CREATE TABLE` (from the field specs) and `down()` = `DROP TABLE`
      (an empty `up/down` stub when no fields are given). The target table is
      derived from the name (`create_posts_table` → `posts`) or given as
      `table:posts`.
- [x] **N3 — Migration runtime.** A `Migration` interface + `Migrator`
      (`migrate` runs pending migrations in order, `rollback` undoes the last
      batch) backed by a `schema_migrations` tracking table on `SqlDatabase`.
      Tested against a stateful loopback DB, and **live-verified** against a
      running `dart-db-server` (generated migration → insert/select → rollback).

## 3j. Phase 10 — dynamic sample apps

Real, runnable apps that exercise the pipeline end-to-end — the best docs are
working code.

- [x] **O0 — Live action params.** The client runtime folds a trigger
      element's `data-live-*` attributes into the action payload
      (`data-live-id="5"` → `{id: "5"}`, kebab→camel, reserved names excluded),
      so Live components can act on a specific item (toggle/remove by id).
      Validated over WebTransport in Edge (todo toggle/remove, poll vote).
- [x] **O1 — Todo (Live).** `example/todo_app.dart` — a reactive list:
      `data-live-model` input + add, keyed `<li>` toggle/remove, clear-completed,
      a remaining count. **Playwright-verified over HTTP/3**
      (`tool/browser-h3-test/todo_wt_test.js`): add ×2 → toggle #1 → remove #2.
- [x] **O2 — Poll (Live).** `example/poll_app.dart` — vote buttons with live
      tallies and server-rendered bars; richer state, bigger diff win.
      **Playwright-verified over HTTP/3** (`poll_wt_test.js`): Dart×2 + PHP×1.
- [x] **O3 — Guestbook (MVC).** `example/guestbook_app.dart` +
      `example/guestbook_views/` — the server-rendered side: routes + Blaze +
      validation + CSRF + sessions/flash + the data layer. **Playwright-verified
      over HTTP/1.1**: CSRF token + flash + entry render + `min:2` rejection.

## 3k. Phase 11 — client certificate pinning

- [x] **P1 — `CertificatePinner`.** Client-side certificate pinning for
      `AltSvcHttpClient`: trust comes from a set of SHA-256 pins of the server's
      DER certificate (not a CA). With a pinner set, the HTTP/1.1 client uses a
      roots-less `SecurityContext` and admits only a pinned leaf cert, and
      HTTP/3 auto-upgrade is suppressed so every request rides the pinned
      transport. `CertificatePinner.pinForCertFile/pinForPem/pinForDer` compute
      pins. Unit-tested (`test/cert_pinning_test.dart`) and **live-verified**
      (`tool/smoke_cert_pin.dart`): correct pin → 200, wrong pin →
      `HandshakeException`. (`lib/src/client/cert_pinning.dart`.)

## 3l. Phase 12 — SPKI pins + CLI migrations

- [x] **P2 — SPKI certificate pins.** Add public-key (SubjectPublicKeyInfo)
      pinning alongside whole-cert pins: a tiny ASN.1/DER walk extracts the
      `SubjectPublicKeyInfo` from the certificate and pins SHA-256 of *that*, so
      a pin survives certificate renewal with the same key (and matches the Edge
      harness's `spki-list`). `CertificatePinner` accepts either a cert pin or an
      SPKI pin; `spkiPinForCertFile/Pem/Der` compute them. Cross-validated
      against node's `X509Certificate` reference pins.
- [x] **P3 — `dartisan migrate`.** Runs migrations from the CLI: discovers
      `migrations/*.dart`, orders by the timestamped migration name, generates a
      throwaway runner that imports them + runs `Migrator.migrate()` (or
      `--rollback`) against `--db=host:port`. The generated migration `name` now
      carries its timestamp (fixes ordering). **Live-verified** against
      `dart-db-server`: migrate (ordered) → idempotent → rollback (reverse) →
      re-migrate.

## 3m. Phase 13 — Blade-style view components

- [x] **Q1 — Blaze `<x-component>`.** Reusable view components with **props and
      slots** (the Blade view-component analog; ease-of-use over byte-for-byte):
      `<x-card title="Hello" :count="n + 1">body</x-card>` renders
      `views/components/card.blaze.html` with the attributes as props (string,
      `{{ }}`-interpolated, or `:bound` expression; kebab→camel) plus `slot`
      (default body) and `<x-slot:footer>…</x-slot:footer>` named slots.
      Self-closing (`<x-divider/>`) and nesting supported. Parsed in the Blaze
      tokenizer/tree-parser; 6 tests in `test/blaze_test.dart`.

## 3n. Phase 14 — DX polish

Small quality-of-life wins developers reach for daily.

- [x] **R1 — `make:component --view`.** A view-component generator:
      `dartisan make:component Card --view` scaffolds
      `views/components/card.blaze.html` (props + slot skeleton). Without
      `--view` it still generates a Live component.
- [x] **R2 — `@forelse / @empty / @endforelse`.** Iterate with an empty
      fallback in one construct (Blade's `@forelse`), instead of
      `@if(x.isEmpty) … @else @foreach … @endforeach @endif`.
- [x] **R3 — `@unless / @endunless`.** Negated `@if` sugar.

## 3o. Phase 15 — form DX + route listing

- [x] **S1 — Old input + validation errors in views.** On a failed validation,
      `req.backWithErrors(e)` flashes the errors + old input and redirects back
      (to the `Referer`). `req.view(...)` auto-injects `errors` and `old` from
      the session flash, so Blaze `@error('field') {{ message }} @enderror` and
      `value="{{ old.name }}"` repopulate forms with zero boilerplate.
- [x] **S2 — `dartisan routes`.** Lists an app's routes (method + pattern) by
      loading its `buildApp` and walking `DartApp.routes`.

## 3p. Phase 16 — pagination + template helpers

- [x] **T1 — Pagination.** `query.paginate(page: n, perPage: m)` → a `Paginator`
      (items + `total/page/perPage/lastPage/hasNext/hasPrev/from/to`), backed by
      a driver `runCount` (in-memory + `SELECT COUNT(*)` on SQL). `toMap()` for
      Blaze.
- [x] **T2 — `@json` + auto `flash` in views.** `@json(expr)` emits
      `jsonEncode(expr)` (embed server data into `<script>`), and `req.view`
      injects a `flash` map (current non-internal flash values) so
      `{{ flash.status }}` works without manual passing.

## 3q. Phase 17 — template helper functions

- [ ] **U1 — Expression functions.** A safe set of built-in functions in Blaze
      expressions: `upper/lower/ucfirst/trim/length/default/limit/round/abs/
      join`, e.g. `{{ upper(name) }}`, `{{ limit(body, 100) }}`,
      `{{ default(title, 'Untitled') }}`. No arbitrary calls — only the
      allow-listed helpers.
## 3r. Phase 18 — more validation rules + `@include` data

- [x] **V1 — More validation rules.** `same:field`, `different:field`,
      `between:a,b`, `digits:N`, `not_in:a,b`, `starts_with:a,b`,
      `ends_with:a,b`, `regex:pattern`.
- [x] **W1 — `@include` with data.** `@include('users.row', item)` merges the
      (map) value into the partial's context (the old single-arg form still
      shares the caller's context).

## 3s. Phase 19 — stacks + typed query input

- [x] **X1 — `@push / @stack`.** A child view `@push('scripts') … @endpush`
      appends to a named stack a layout emits with `@stack('scripts')` (scripts/
      styles bubbling up to the layout).
- [x] **X2 — Typed query helpers.** `req.queryInt('page', 1)` and
      `req.queryBool('all')` (`1/true/on/yes`) over query parameters.

## 3t. Phase 20 — Str helpers + inline sections

- [x] **Y1 — `Str` helpers.** A pure, app-facing utility class (exported from
      `package:dart_apache`): `Str.slug`, `title`, `ucfirst`, `limit`, `words`,
      `mask`, `random`, and naive `plural`/`singular`.
- [x] **Y2 — Inline `@section('name', value)`.** The two-argument form sets a
      yielded section without a closing `@endsection` (block form unchanged).

## 3u. Phase 21 — abort helpers

- [x] **Z1 — `abort` / `HttpException`.** `abort(404)`, `abort(403, 'Nope')`,
      `abortIf(cond, 400)`, and `abortUnless(cond, 401)` raise an `HttpException`
      the router's error boundary turns into a response with that status (and a
      sensible default reason phrase when no message is given).

## 3v. Phase 22 — conditional attribute directives

- [x] **AA1 — `@checked/@selected/@disabled/@readonly/@required`.** Each emits
      its HTML boolean attribute when the guarded expression is truthy, e.g.
      `<input @checked(user.active)>` / `<option @selected(v == current)>`.

## 3w. Phase 23 — request helpers

- [x] **AB1 — content negotiation + request helpers.** `req.isMethod('post')`,
      `req.isAjax`, `req.isJson`, `req.wantsJson` (AJAX or a JSON-favouring
      `Accept` header), and `req.cookie('name')` (parsed from the `Cookie`
      header).

## 3x. Phase 24 — collection helpers

- [x] **AC1 — `Iterable` helpers.** `sortedBy`/`sortedByDesc`, `groupBy`,
      `keyBy`, and `pluck` (on rows) for working with query-builder results.

## 3y. Phase 25 — @verbatim

- [x] **AD1 — `@verbatim ... @endverbatim`.** Emits its inner content literally,
      so client-side `{{ }}` (Alpine/Vue) and `@`-directives pass through
      untouched by Blaze.

## 3z. Phase 26 — named routes

- [x] **AE1 — named routes + `urlFor`.** Pass `name:` to any route method
      (`router.get('/users/:id', show, name: 'users.show')`) and build URLs with
      `router.urlFor('users.show', {'id': 42})` (`:param` substitution; leftover
      params become a query string).

## 3aa. Phase 27 — response helpers

- [x] **AF1 — `created` / `noContent` / `back`.** `req.created(data,
      {location})` (201 JSON), `req.noContent()` (204), and `req.back({fallback})`
      (redirect to the `Referer`).

## 3ab. Phase 28 — more validation rules

- [x] **AG1 — `uuid` / `ip` / `json` / `size:N`.** UUID format, IPv4/IPv6
      address, parseable JSON, and exact size (string length or numeric value).

## 3ac. Phase 29 — @switch

- [x] **AH1 — `@switch/@case/@default/@break`.** Value-matching branch selection
      in templates (`@switch(role) @case('admin')…@break @default… @endswitch`).

## 3ad. Phase 30 — redirect with flash

- [x] **AI1 — `redirectWith`.** `req.redirectWith('/done', {'status': 'Saved!'})`
      flashes the data (surviving one redirect) and redirects — the values show
      up in the next view's `flash` map (post/redirect/get).

## 3ae. Phase 31 — conditional includes

- [x] **AJ1 — `@includeIf` / `@includeWhen`.** `@includeIf('view')` renders the
      partial only when it exists; `@includeWhen(cond, 'view'[, data])` renders
      it only when the condition is truthy. `BlazeEngine.exists(name)` backs it.

## 3af. Phase 32 — case helpers

- [x] **AK1 — `Str` case conversions.** `Str.camel`, `Str.studly`, `Str.snake`,
      and `Str.kebab` (split on spaces/`_`/`-`/camelCase boundaries).

## 3ag. Phase 33 — more expression built-ins

- [x] **AL1 — collection/number helpers.** `first`, `last`, `reverse`,
      `contains`, `keys`, `values`, and `number_format(n[, decimals])` added to
      the template expression allow-list.

## 3ah. Phase 34 — view status

- [x] **AM1 — `view` status code.** `req.view('errors.404', data, 404)` renders a
      Blaze view with a custom HTTP status (for error pages).

## 3ai. Phase 35 — collection aggregates

- [x] **AN1 — `sumBy` / `avgBy` / `maxBy` / `minBy`.** Numeric aggregates over
      any `Iterable` (e.g. totals/averages/extremes of query rows).
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
| Blade components (`<x-...>`, props, slots) | Blaze `<x-card>` components | ✅ |
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

