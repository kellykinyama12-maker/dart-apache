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
- [ ] **F2 — View + Router/Controller sugar.** `View.make('home', {...})`,
      `Route.get('/users/:id', UsersController.show)`, route groups, params,
      middleware — on top of the existing `DartApp` pipeline.
- [ ] **F3 — `dartisan` CLI.** scaffold a project, `make:controller/view`,
      `serve` (dev, hot-reload via `dart run`), `routes` listing.
- [ ] **F4 — Dartisan Live.** reactive components over WebTransport: a
      component base, server-side render + diff, a tiny client runtime that
      applies diffs and sends events back over the WT session.
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
