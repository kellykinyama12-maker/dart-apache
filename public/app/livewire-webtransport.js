// Livewire → WebTransport transport shim.
//
// Drop this on any page that loads Livewire (before livewire.js). It transparently
// reroutes Livewire's component-update POSTs over a WebTransport (HTTP/3) bidi
// stream to the dart-apache bridge, which forwards them to PHP exactly like the
// original XHR — carrying the CSRF token so Laravel's VerifyCsrfToken passes.
//
// It patches window.fetch and only touches requests to the Livewire update
// endpoint; everything else (and any failure) falls back to native fetch, so it
// is safe to include unconditionally.
(function () {
  'use strict';

  var CONFIG = {
    // WebTransport session endpoint on the server (matches --wt-path).
    wtUrl: (window.LIVEWIRE_WT_URL || ('https://' + location.host + '/wt')),
    // Livewire update endpoint to intercept. Livewire 3 uses /livewire/update;
    // Livewire 4 uses a randomized prefix /livewire-<hash>/update. Override the
    // whole match with window.LIVEWIRE_WT_ENDPOINT (substring) if needed.
    endpoint: (window.LIVEWIRE_WT_ENDPOINT || null),
    // Opaque session-ticket endpoint (matches --wt-ticket-path). When present,
    // the shim carries a ticket instead of document.cookie, so the session
    // cookie can stay HttpOnly. Set to null to disable.
    ticketUrl: (window.LIVEWIRE_WT_TICKET_URL !== undefined
      ? window.LIVEWIRE_WT_TICKET_URL
      : '/wt-ticket'),
  };

  // Graceful enhancement: without WebTransport, leave fetch untouched.
  if (typeof window.WebTransport === 'undefined') return;

  var UPDATE_RE = /\/livewire[\w-]*\/update(\?|$)/;
  function isLivewireUpdate(url, method) {
    if (!url || String(method).toUpperCase() !== 'POST') return false;
    if (CONFIG.endpoint) return url.indexOf(CONFIG.endpoint) !== -1;
    return UPDATE_RE.test(url);
  }

  var wt = null;
  var ready = null;

  function connect() {
    if (ready) return ready;
    wt = new WebTransport(CONFIG.wtUrl);
    ready = wt.ready.then(function () { return wt; }).catch(function (e) {
      wt = null; ready = null; throw e;
    });
    wt.closed.then(reset, reset);
    return ready;
  }
  function reset() { wt = null; ready = null; }

  function csrfToken(headers) {
    if (headers) {
      var h = headers['X-CSRF-TOKEN'] || headers['x-csrf-token'] ||
              headers['X-XSRF-TOKEN'] || headers['x-xsrf-token'];
      if (h) return h;
    }
    var meta = document.querySelector('meta[name="csrf-token"]');
    return meta ? meta.getAttribute('content') : null;
  }

  var nativeFetch = window.fetch.bind(window);

  // Opaque session ticket, refreshed before its server-side TTL (~5 min).
  var ticket = null;
  var ticketAt = 0;
  var ticketPromise = null;
  function getTicket() {
    if (!CONFIG.ticketUrl) return Promise.resolve(null);
    var fresh = ticket && (Date.now() - ticketAt) < 4 * 60 * 1000;
    if (fresh) return Promise.resolve(ticket);
    if (ticketPromise) return ticketPromise;
    ticketPromise = nativeFetch(CONFIG.ticketUrl, { credentials: 'same-origin' })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (j) {
        ticket = (j && j.ticket) || null;
        ticketAt = Date.now();
        ticketPromise = null;
        return ticket;
      })
      .catch(function () { ticketPromise = null; return null; });
    return ticketPromise;
  }

  async function sendOverWt(bodyText, token, uriPath) {
    var conn = await connect();
    var tk = await getTicket();
    var stream = await conn.createBidirectionalStream();
    var w = stream.writable.getWriter();
    var preamble = '';
    // Tell the bridge which app route to deliver this to (so the server need
    // not hard-code Livewire's randomized endpoint prefix).
    if (uriPath) preamble += 'X-Bridge-Uri: ' + uriPath + '\r\n';
    if (token) preamble += 'X-CSRF-TOKEN: ' + token + '\r\n';
    if (tk) {
      // Preferred: opaque ticket; the real session cookie stays HttpOnly.
      preamble += 'X-WT-Ticket: ' + tk + '\r\n';
    } else if (document.cookie) {
      // Fallback (dev): forward readable cookies for session continuity.
      preamble += 'Cookie: ' + document.cookie + '\r\n';
    }
    preamble += 'Content-Type: application/json\r\n\r\n';
    await w.write(new TextEncoder().encode(preamble + (bodyText || '')));
    await w.close();
    var r = stream.readable.getReader();
    var chunks = [];
    var total = 0;
    for (;;) {
      var res = await r.read();
      if (res.done) break;
      chunks.push(res.value);
      total += res.value.length;
    }
    var out = new Uint8Array(total);
    var off = 0;
    for (var i = 0; i < chunks.length; i++) { out.set(chunks[i], off); off += chunks[i].length; }
    return out;
  }

  // Locate the blank line separating the reply's status/header block from body.
  function sepIndex(a) {
    for (var i = 0; i + 3 < a.length; i++) {
      if (a[i] === 13 && a[i + 1] === 10 && a[i + 2] === 13 && a[i + 3] === 10) return i;
    }
    return -1;
  }

  // Parse the bridge reply envelope: `status\r\nHeader: v\r\n…\r\n\r\n<body>`.
  function parseReply(bytes) {
    var sep = sepIndex(bytes);
    if (sep < 0) return { status: 200, headers: {}, setCookies: [], body: bytes };
    var head = new TextDecoder().decode(bytes.subarray(0, sep));
    var body = bytes.subarray(sep + 4);
    var lines = head.split('\r\n');
    var status = parseInt(lines[0], 10) || 200;
    var headers = {};
    var setCookies = [];
    for (var i = 1; i < lines.length; i++) {
      var idx = lines[i].indexOf(':');
      if (idx <= 0) continue;
      var name = lines[i].slice(0, idx).trim();
      var value = lines[i].slice(idx + 1).trim();
      if (name.toLowerCase() === 'set-cookie') setCookies.push(value);
      else headers[name] = value;
    }
    return { status: status, headers: headers, setCookies: setCookies, body: body };
  }

  // The browser does not apply Set-Cookie from a WT stream, so do it here.
  // HttpOnly cookies are ignored by document.cookie; a session rotation
  // invalidates the cached ticket so the next message re-syncs.
  function applySetCookies(setCookies) {
    if (!setCookies.length) return;
    for (var i = 0; i < setCookies.length; i++) {
      try { document.cookie = setCookies[i]; } catch (e) { /* HttpOnly etc. */ }
    }
    ticket = null; // force a ticket refresh on the next message
  }

  window.fetch = async function (input, init) {
    try {
      var url = typeof input === 'string' ? input : (input && input.url);
      var method = (init && init.method) ||
                   (typeof input !== 'string' && input && input.method) || 'GET';
      if (isLivewireUpdate(url, method)) {
        var headers = (init && init.headers)
          ? Object.fromEntries(new Headers(init.headers).entries())
          : {};
        var body = '';
        if (init && init.body != null) {
          body = typeof init.body === 'string'
            ? init.body
            : await new Response(init.body).text();
        }
        var u;
        try { u = new URL(url, location.href); } catch (e) { u = null; }
        var uriPath = u ? (u.pathname + u.search) : url;
        var bytes = await sendOverWt(body, csrfToken(headers), uriPath);
        var reply = parseReply(bytes);
        applySetCookies(reply.setCookies);
        // Observable marker: proves the update traveled over WebTransport.
        window.__livewireWtUsed = (window.__livewireWtUsed || 0) + 1;
        try {
          return new Response(reply.body, { status: reply.status, headers: reply.headers });
        } catch (e) {
          // Some header the Response ctor rejects — fall back to body + status.
          return new Response(reply.body, { status: reply.status });
        }
      }
    } catch (e) {
      // Any WebTransport failure degrades to the normal HTTP path.
      if (window.console) console.warn('[livewire-wt] fallback to fetch:', e && e.message);
    }
    return nativeFetch(input, init);
  };
})();
