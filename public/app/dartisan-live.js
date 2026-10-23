// Dartisan Live client runtime. Binds elements inside a [data-live-component]
// container and streams their actions over a WebTransport (HTTP/3) session: a
// `live:click="action"` sends {component, action, state} on a fresh bidi
// stream; the server replies {html, state} which morphs the container in place.
// No WebSocket, no polling — the reactive channel is HTTP/3.
(function () {
  'use strict';
  var PATH = window.DARTISAN_LIVE_PATH || '/wt';
  var transport = null;
  var ready = null;
  var msgId = 0;

  function connect() {
    transport = new WebTransport('https://' + location.host + PATH);
    ready = transport.ready;
    transport.closed.catch(function () {}).then(function () {
      transport = null; // lazily reconnect on next action
    });
    return ready;
  }

  async function send(obj) {
    if (!transport) { try { await connect(); } catch (e) { throw e; } }
    await ready;
    var stream = await transport.createBidirectionalStream();
    var w = stream.writable.getWriter();
    await w.write(new TextEncoder().encode(JSON.stringify(obj)));
    await w.close();
    var reader = stream.readable.getReader();
    var chunks = [];
    for (;;) {
      var r = await reader.read();
      if (r.done) break;
      chunks.push(r.value);
    }
    var total = 0;
    chunks.forEach(function (c) { total += c.length; });
    var buf = new Uint8Array(total), off = 0;
    chunks.forEach(function (c) { buf.set(c, off); off += c.length; });
    return JSON.parse(new TextDecoder().decode(buf));
  }

  function state(el) {
    try { return JSON.parse(el.getAttribute('data-live-state') || '{}'); }
    catch (e) { return {}; }
  }

  async function act(el, action) {
    var reply = await send({
      id: ++msgId,
      component: el.getAttribute('data-live-component'),
      action: action,
      state: state(el)
    });
    el.innerHTML = reply.html;
    el.setAttribute('data-live-state', JSON.stringify(reply.state));
    // Expose last state for tests / debugging.
    window.__dartisanLive = reply.state;
    el.dispatchEvent(new CustomEvent('live:updated', { detail: reply.state }));
  }

  function bind(el) {
    if (el.__liveBound) return; // one listener per container, even if the
    el.__liveBound = true;      // runtime script is evaluated more than once
    // Event delegation survives innerHTML morphs (listener stays on container).
    el.addEventListener('click', function (ev) {
      var btn = ev.target.closest('[data-live-click]');
      if (!btn || !el.contains(btn)) return;
      ev.preventDefault();
      act(el, btn.getAttribute('data-live-click')).catch(function (e) {
        console.error('[dartisan-live]', e);
      });
    });
  }

  function boot() {
    var els = document.querySelectorAll('[data-live-component]');
    for (var i = 0; i < els.length; i++) bind(els[i]);
  }

  if (document.readyState === 'loading') {
    window.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
