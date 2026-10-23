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
| Eloquent | **(later) Dartisan ORM** | start with a thin query/record layer; DB drivers later |
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
- [ ] **F3 — `dartisan` CLI.** scaffold a project, `make:controller/view`,
      `serve` (dev, hot-reload via `dart run`), `routes` listing.
- [x] **F4 — Dartisan Live.** reactive components over WebTransport:
      `LiveComponent` (state round-trips to the client), `LiveRegistry`,
      `liveWtHandler` (parses an action, updates + re-renders, streams the new
      HTML back over the WT stream), and `liveMount` (initial render + client
      runtime `public/app/dartisan-live.js`). **Live-verified in Edge** over
      real HTTP/3: a counter's +/- clicks drive state over WebTransport
      (`example/live_app.dart`, `tool/browser-h3-test/live_wt_test.js`).
- [ ] **F5 — Data layer.** request validation (FormRequest), then a thin
      record/query layer and a first DB driver.
- [ ] **F6 — Docs site.** guides, API reference, a "build a Dartisan app in 10
      minutes" tutorial; lead with the HTTP/3 + Live story.

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
| Validation / FormRequest | typed request validation | ⬜ F5 |
| Eloquent ORM + migrations | record/query layer + a DB driver | ⬜ F5 |
| Artisan CLI | `dartisan` CLI (`new`, `make:*`, `serve`) | ⬜ F3 |
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
| `flutter create` scaffolding | `dartisan new` | ⬜ F3 |

**Positioning:** *Laravel's batteries + Livewire's reactivity + Flutter's
Dart/declarative model — in one compiled binary, reactive over HTTP/3.*

