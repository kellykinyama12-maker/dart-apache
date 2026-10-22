<?php

return [

    /*
    |--------------------------------------------------------------------------
    | WebTransport session endpoint
    |--------------------------------------------------------------------------
    |
    | The HTTP/3 WebTransport URL the browser shim connects to. It must match
    | the dart-apache `--wt-path` (default `/wt`). Leave the host empty to use
    | the current origin at runtime (recommended).
    |
    */
    'url' => env('LIVEWIRE_WT_URL'),

    /*
    |--------------------------------------------------------------------------
    | Session-ticket endpoint
    |--------------------------------------------------------------------------
    |
    | Opaque, server-sealed session ticket endpoint (matches the dart-apache
    | `--wt-ticket-path`, default `/wt-ticket`). Lets the session cookie stay
    | HttpOnly. Set to null to fall back to document.cookie forwarding.
    |
    */
    'ticket_url' => env('LIVEWIRE_WT_TICKET_URL', '/wt-ticket'),

    /*
    |--------------------------------------------------------------------------
    | Update endpoint override
    |--------------------------------------------------------------------------
    |
    | Substring the shim uses to detect the Livewire update endpoint. Leave
    | null to auto-match both Livewire 3 (`/livewire/update`) and Livewire 4
    | (randomized `/livewire-<hash>/update`).
    |
    */
    'endpoint' => env('LIVEWIRE_WT_ENDPOINT'),

    /*
    |--------------------------------------------------------------------------
    | Enabled
    |--------------------------------------------------------------------------
    |
    | Master switch. When false, @webtransport renders nothing and Livewire
    | uses its normal fetch transport.
    |
    */
    'enabled' => env('LIVEWIRE_WT_ENABLED', true),

];
