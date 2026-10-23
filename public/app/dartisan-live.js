// Dartisan Live client runtime. Binds elements inside a [data-live-component]
// container and streams their actions over a WebTransport (HTTP/3) session:
//   data-live-click="action"   -> on click
//   data-live-input="action"   -> on input (debounced)
//   data-live-change="action"  -> on change
//   data-live-submit="action"  -> on a form's submit
//   data-live-model="field"    -> two-way: the input's value folds into state
//                                 on the next action
// Each action sends {component, action, state, payload} on a fresh bidi stream;
// the server replies {html, state}, and the client MORPHS the container's DOM in
// place (preserving focus, caret/selection, scroll, and uncommitted input) — not
// a destructive innerHTML replace. No WebSocket, no polling — the channel is h3.
(function () {
  'use strict';
  var PATH = window.DARTISAN_LIVE_PATH || '/wt';
  var transport = null;
  var ready = null;
  var msgId = 0;

  // ---- transport ----------------------------------------------------------

  function connect() {
    transport = new WebTransport('https://' + location.host + PATH);
    ready = transport.ready;
    transport.closed.catch(function () {}).then(function () {
      transport = null; // lazily reconnect on next action
    });
    return ready;
  }

  async function send(obj) {
    if (!transport) { await connect(); }
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

  // ---- state + models -----------------------------------------------------

  function state(el) {
    try { return JSON.parse(el.getAttribute('data-live-state') || '{}'); }
    catch (e) { return {}; }
  }

  function inputValue(inp) {
    var type = (inp.getAttribute('type') || inp.type || 'text').toLowerCase();
    if (type === 'checkbox') return inp.checked;
    if (type === 'number' || type === 'range') {
      return inp.value === '' ? null : Number(inp.value);
    }
    return inp.value;
  }

  // Fold the live value of every [data-live-model] input into [st] so typed
  // input is carried with the action even before it's committed server-side.
  function collectModels(el, st) {
    var inputs = el.querySelectorAll('[data-live-model]');
    for (var i = 0; i < inputs.length; i++) {
      st[inputs[i].getAttribute('data-live-model')] = inputValue(inputs[i]);
    }
    return st;
  }

  // ---- action round-trip --------------------------------------------------

  async function act(el, action, payload) {
    var st = collectModels(el, state(el));
    var reply = await send({
      id: ++msgId,
      component: el.getAttribute('data-live-component'),
      action: action,
      state: st,
      payload: payload || {}
    });
    // Server may send a full `html`, or a `patch` (changed region) to splice
    // against our exact base string (seeded at mount, so bytes match).
    var html;
    if (reply.patch) {
      var base = el.__liveHtml != null ? el.__liveHtml : el.innerHTML;
      var p = reply.patch;
      html = base.slice(0, p.s) + p.i + base.slice(p.e);
    } else {
      html = reply.html;
    }
    el.__liveHtml = html;
    morph(el, html);
    el.setAttribute('data-live-state', JSON.stringify(reply.state));
    // Expose last state for tests / debugging.
    window.__dartisanLive = reply.state;
    el.dispatchEvent(new CustomEvent('live:updated', { detail: reply.state }));
  }

  // ---- DOM morphing (morphdom-lite) --------------------------------------
  // Reconciles the container's children against freshly rendered HTML, reusing
  // matching nodes (keyed by data-live-key/id, else by position + tag) so focus,
  // caret, scroll, and in-flight input survive the update.

  function keyOf(node) {
    if (node.nodeType !== 1) return null;
    return node.getAttribute('data-live-key') || node.id || null;
  }

  function compatible(a, b) {
    if (a.nodeType !== b.nodeType) return false;
    if (a.nodeType === 1) return a.nodeName === b.nodeName;
    return true; // text / comment
  }

  function morph(container, html) {
    var tmpl = document.createElement('template');
    tmpl.innerHTML = html;
    morphChildren(container, tmpl.content);
  }

  function morphChildren(fromParent, toParent) {
    var toNodes = Array.prototype.slice.call(toParent.childNodes);
    var keyed = {};
    var fn = fromParent.childNodes;
    for (var i = 0; i < fn.length; i++) {
      var k = keyOf(fn[i]);
      if (k) keyed[k] = fn[i];
    }
    for (var j = 0; j < toNodes.length; j++) {
      var toNode = toNodes[j];
      var key = keyOf(toNode);
      var slot = fromParent.childNodes[j] || null;
      var match = null;
      if (key && keyed[key]) {
        match = keyed[key];
      } else if (slot && !keyOf(slot) && compatible(slot, toNode)) {
        match = slot;
      }
      if (match && compatible(match, toNode)) {
        if (match !== slot) fromParent.insertBefore(match, slot);
        morphNode(match, toNode);
      } else {
        fromParent.insertBefore(document.importNode(toNode, true), slot);
      }
    }
    while (fromParent.childNodes.length > toNodes.length) {
      fromParent.removeChild(fromParent.lastChild);
    }
  }

  function morphNode(from, to) {
    if (from.nodeType === 3 || from.nodeType === 8) { // text / comment
      if (from.nodeValue !== to.nodeValue) from.nodeValue = to.nodeValue;
      return;
    }
    if (from.nodeType !== 1) return;
    morphAttrs(from, to);
    var tag = from.nodeName;
    if (tag === 'INPUT' || tag === 'TEXTAREA') {
      morphFormValue(from, to);
      return; // don't recurse into leaf form controls
    }
    morphChildren(from, to);
  }

  function morphAttrs(from, to) {
    var toAttrs = to.attributes;
    for (var i = 0; i < toAttrs.length; i++) {
      var a = toAttrs[i];
      if (from.getAttribute(a.name) !== a.value) from.setAttribute(a.name, a.value);
    }
    var fromAttrs = from.attributes;
    for (var j = fromAttrs.length - 1; j >= 0; j--) {
      var name = fromAttrs[j].name;
      if (!to.hasAttribute(name)) from.removeAttribute(name);
    }
  }

  function morphFormValue(from, to) {
    var focused = (document.activeElement === from);
    if (from.nodeName === 'INPUT') {
      var type = (to.getAttribute('type') || 'text').toLowerCase();
      if (type === 'checkbox' || type === 'radio') {
        from.checked = to.hasAttribute('checked');
      } else if (!focused) {
        var nv = to.getAttribute('value');
        from.value = nv == null ? '' : nv;
      }
    } else if (from.nodeName === 'TEXTAREA' && !focused) {
      from.value = to.textContent;
    }
  }

  // ---- binding ------------------------------------------------------------

  function debounce(node, fn) {
    clearTimeout(node.__liveTimer);
    node.__liveTimer = setTimeout(fn, 150);
  }

  function run(el, action, payload) {
    act(el, action, payload).catch(function (e) {
      console.error('[dartisan-live]', e);
    });
  }

  function bind(el) {
    if (el.__liveBound) return; // one set of listeners per container, even if
    el.__liveBound = true;      // the runtime script is evaluated more than once
    // Exact base string from the server's mount render (for patch splicing).
    var init = window.DARTISAN_LIVE_INIT || {};
    el.__liveHtml = init[el.getAttribute('data-live-component')];
    if (el.__liveHtml == null) el.__liveHtml = el.innerHTML;
    // Delegated listeners live on the container, so they survive DOM morphs.
    el.addEventListener('click', function (ev) {
      var t = ev.target.closest('[data-live-click]');
      if (!t || !el.contains(t)) return;
      ev.preventDefault();
      run(el, t.getAttribute('data-live-click'));
    });
    el.addEventListener('input', function (ev) {
      var t = ev.target.closest('[data-live-input]');
      if (!t || !el.contains(t)) return;
      debounce(t, function () { run(el, t.getAttribute('data-live-input')); });
    });
    el.addEventListener('change', function (ev) {
      var t = ev.target.closest('[data-live-change]');
      if (!t || !el.contains(t)) return;
      run(el, t.getAttribute('data-live-change'));
    });
    el.addEventListener('submit', function (ev) {
      var t = ev.target.closest('[data-live-submit]');
      if (!t || !el.contains(t)) return;
      ev.preventDefault();
      run(el, t.getAttribute('data-live-submit'));
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
