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
    // Livewire update endpoint to intercept (Livewire v3 default).
    endpoint: (window.LIVEWIRE_WT_ENDPOINT || '/livewire/update'),
  };

  // Graceful enhancement: without WebTransport, leave fetch untouched.
  if (typeof window.WebTransport === 'undefined') return;

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

  async function sendOverWt(bodyText, token) {
    var conn = await connect();
    var stream = await conn.createBidirectionalStream();
    var w = stream.writable.getWriter();
    var preamble = '';
    if (token) preamble += 'X-CSRF-TOKEN: ' + token + '\r\n';
    preamble += 'Content-Type: application/json\r\n\r\n';
    await w.write(new TextEncoder().encode(preamble + (bodyText || '')));
    await w.close();
    var r = stream.readable.getReader();
    var chunks = [];
    for (;;) {
      var res = await r.read();
      if (res.done) break;
      chunks.push(res.value);
    }
    return await new Blob(chunks).text();
  }

  var nativeFetch = window.fetch.bind(window);

  window.fetch = async function (input, init) {
    try {
      var url = typeof input === 'string' ? input : (input && input.url);
      var method = (init && init.method) ||
                   (typeof input !== 'string' && input && input.method) || 'GET';
      if (url && url.indexOf(CONFIG.endpoint) !== -1 &&
          String(method).toUpperCase() === 'POST') {
        var headers = (init && init.headers)
          ? Object.fromEntries(new Headers(init.headers).entries())
          : {};
        var body = '';
        if (init && init.body != null) {
          body = typeof init.body === 'string'
            ? init.body
            : await new Response(init.body).text();
        }
        var text = await sendOverWt(body, csrfToken(headers));
        return new Response(text, {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        });
      }
    } catch (e) {
      // Any WebTransport failure degrades to the normal HTTP path.
      if (window.console) console.warn('[livewire-wt] fallback to fetch:', e && e.message);
    }
    return nativeFetch(input, init);
  };
})();
