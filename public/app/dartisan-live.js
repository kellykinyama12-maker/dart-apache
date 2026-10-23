// Dartisan Live client runtime. Binds elements inside a [data-live-component]
// container and streams their actions over a WebTransport (HTTP/3) session:
//   data-live-click="action"   -> on click
//   data-live-input="action"   -> on input (debounced)
//   data-live-change="action"  -> on change
//   data-live-submit="action"  -> on a form's submit
//   data-live-model="field"    -> two-way: the input's value folds into state
//                                 on the next action
//   data-live-model-live="field" -> eager two-way: re-renders on input (debounced)
//   data-live-poll="action"     -> runs the action on an interval
//                                 (data-live-poll-interval="ms", default 2000)
//   data-live-listen="event:action;…" -> runs the action when another component
//                                 emits a matching event
//   data-live-loading           -> element (use `hidden`) shown only while an
//                                   action is in flight
//   data-live-dirty             -> element (use `hidden`) shown while a deferred
//                                   model has uncommitted changes
//   data-live-loading-class="…" -> classes toggled on the element while busy
//   (the container also gets a [data-live-busy] attribute during the request)
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

  // Fold the live value of every model input into [st] so typed input is
  // carried with the action even before it's committed server-side. Both the
  // deferred [data-live-model] and the eager [data-live-model-live] are folded.
  function collectModels(el, st) {
    var inputs = el.querySelectorAll('[data-live-model], [data-live-model-live]');
    for (var i = 0; i < inputs.length; i++) {
      var inp = inputs[i];
      var field = inp.getAttribute('data-live-model') ||
        inp.getAttribute('data-live-model-live');
      st[field] = inputValue(inp);
    }
    return st;
  }

  // ---- action round-trip --------------------------------------------------

  // Toggle loading affordances for the duration of an action: a [data-live-busy]
  // marker on the container, un-hiding [data-live-loading] elements, and adding
  // any [data-live-loading-class] classes (all reversed when the reply lands).
  function setLoading(el, on) {
    if (on) el.setAttribute('data-live-busy', '');
    else el.removeAttribute('data-live-busy');
    var loaders = el.querySelectorAll('[data-live-loading]');
    for (var i = 0; i < loaders.length; i++) {
      if (on) loaders[i].removeAttribute('hidden');
      else loaders[i].setAttribute('hidden', '');
    }
    var classed = el.querySelectorAll('[data-live-loading-class]');
    for (var j = 0; j < classed.length; j++) {
      var classes = (classed[j].getAttribute('data-live-loading-class') || '').split(/\s+/);
      for (var k = 0; k < classes.length; k++) {
        if (classes[k]) classed[j].classList[on ? 'add' : 'remove'](classes[k]);
      }
    }
  }

  async function act(el, action, payload) {
    setLoading(el, true);
    try {
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
      setDirty(el, false); // the state is now committed on the server
      bindWithin(el);   // bind any child components a re-render introduced
      setupPolling(el); // the poll element/interval may have changed in the render
      // Expose last state for tests / debugging.
      window.__dartisanLive = reply.state;
      el.dispatchEvent(new CustomEvent('live:updated', { detail: reply.state }));
      // Fan out any emitted events to listening components (own round-trips).
      if (reply.emit) {
        for (var i = 0; i < reply.emit.length; i++) {
          dispatchLive(reply.emit[i].event, reply.emit[i].payload || {});
        }
      }
    } finally {
      setLoading(el, false);
    }
  }

  // Toggle the "unsaved changes" affordance: a [data-live-dirty] marker on the
  // container, un-hiding [data-live-dirty] elements, and any data-live-dirty-class
  // classes. Deferred [data-live-model] input sets it; a committed action clears.
  function setDirty(el, on) {
    if (on) el.setAttribute('data-live-dirty', '');
    else el.removeAttribute('data-live-dirty');
    var marks = el.querySelectorAll('[data-live-dirty]');
    for (var i = 0; i < marks.length; i++) {
      if (marks[i] === el || !owns(el, marks[i])) continue;
      if (on) marks[i].removeAttribute('hidden');
      else marks[i].setAttribute('hidden', '');
    }
    var classed = el.querySelectorAll('[data-live-dirty-class]');
    for (var j = 0; j < classed.length; j++) {
      if (!owns(el, classed[j])) continue;
      var classes = (classed[j].getAttribute('data-live-dirty-class') || '').split(/\s+/);
      for (var k = 0; k < classes.length; k++) {
        if (classes[k]) classed[j].classList[on ? 'add' : 'remove'](classes[k]);
      }
    }
  }

  // Dispatch a cross-component [event]: every element with a matching entry in
  // its data-live-listen="event:action;…" runs that action on its owning
  // component (a fresh round-trip carrying the event [payload]).
  function dispatchLive(event, payload) {
    var nodes = document.querySelectorAll('[data-live-listen]');
    for (var i = 0; i < nodes.length; i++) {
      var pairs = (nodes[i].getAttribute('data-live-listen') || '').split(';');
      for (var j = 0; j < pairs.length; j++) {
        var kv = pairs[j].split(':');
        if (kv[0] && kv[0].trim() === event && kv[1]) {
          var owner = nodes[i].closest('[data-live-component]');
          if (owner) run(owner, kv[1].trim(), payload);
        }
      }
    }
  }

  // Restart the container's poll timer from its current [data-live-poll] element
  // (if any). data-live-poll="action" + optional data-live-poll-interval="ms".
  function setupPolling(el) {
    if (el.__pollTimer) { clearInterval(el.__pollTimer); el.__pollTimer = null; }
    var p = el.querySelector('[data-live-poll]');
    if (!p || !owns(el, p)) return;
    var ms = parseInt(p.getAttribute('data-live-poll-interval'), 10) || 2000;
    var action = p.getAttribute('data-live-poll') || '';
    el.__pollTimer = setInterval(function () {
      run(el, action, payloadFrom(p));
    }, ms);
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
    // A nested, already-bound component is a boundary: it owns its own state and
    // DOM, so a parent re-render must not touch it (leave it entirely alone).
    if (from.__liveBound && from.hasAttribute('data-live-component')) return;
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

  function debounce(node, fn, ms) {
    clearTimeout(node.__liveTimer);
    node.__liveTimer = setTimeout(fn, ms || 150);
  }

  // Collect a trigger element's data-live-* params into the action payload
  // (e.g. data-live-id="5" -> {id: "5"}; data-live-item-id -> {itemId}).
  var RESERVED = {
    click: 1, input: 1, change: 1, submit: 1, model: 1, 'model-live': 1,
    key: 1, component: 1, state: 1, poll: 1, 'poll-interval': 1,
    loading: 1, 'loading-class': 1, busy: 1, debounce: 1, listen: 1,
    dirty: 1, 'dirty-class': 1
  };
  function payloadFrom(el) {
    var out = {};
    if (!el || !el.attributes) return out;
    for (var i = 0; i < el.attributes.length; i++) {
      var a = el.attributes[i];
      if (a.name.indexOf('data-live-') !== 0) continue;
      var key = a.name.slice(10);
      if (RESERVED[key]) continue;
      out[key.replace(/-([a-z])/g, function (_, c) { return c.toUpperCase(); })] = a.value;
    }
    return out;
  }

  function run(el, action, payload) {
    act(el, action, payload).catch(function (e) {
      console.error('[dartisan-live]', e);
    });
  }

  // A trigger belongs to its nearest [data-live-component] ancestor; this lets
  // nested components' delegated listeners ignore each other's events.
  function owns(el, t) {
    return t.closest('[data-live-component]') === el;
  }

  // Bind every (not-yet-bound) component within [el] — e.g. children a parent
  // re-render just imported into the DOM.
  function bindWithin(el) {
    var ns = el.querySelectorAll('[data-live-component]');
    for (var i = 0; i < ns.length; i++) bind(ns[i]);
  }

  function bind(el) {
    if (el.__liveBound) return; // one set of listeners per container, even if
    el.__liveBound = true;      // the runtime script is evaluated more than once
    // Exact base string from the server's mount render (for patch splicing).
    var init = window.DARTISAN_LIVE_INIT || {};
    el.__liveHtml = init[el.getAttribute('data-live-component')];
    if (el.__liveHtml == null) el.__liveHtml = el.innerHTML;
    // Delegated listeners live on the container, so they survive DOM morphs.
    // `owns` keeps a nested component's events from firing the parent's handler.
    el.addEventListener('click', function (ev) {
      var t = ev.target.closest('[data-live-click]');
      if (!t || !el.contains(t) || !owns(el, t)) return;
      ev.preventDefault();
      run(el, t.getAttribute('data-live-click'), payloadFrom(t));
    });
    el.addEventListener('input', function (ev) {
      var t = ev.target.closest('[data-live-input]');
      if (!t || !el.contains(t) || !owns(el, t)) return;
      debounce(t, function () { run(el, t.getAttribute('data-live-input'), payloadFrom(t)); });
    });
    // Eager two-way model: re-sync + re-render on input (debounced), folding the
    // current value via collectModels — a no-op action that just re-renders.
    el.addEventListener('input', function (ev) {
      var t = ev.target.closest('[data-live-model-live]');
      if (!t || !el.contains(t) || !owns(el, t)) return;
      var ms = parseInt(t.getAttribute('data-live-debounce'), 10);
      debounce(t, function () { run(el, '', {}); }, isNaN(ms) ? 150 : ms);
    });
    // Deferred model input marks the component dirty (uncommitted changes).
    el.addEventListener('input', function (ev) {
      var t = ev.target.closest('[data-live-model]');
      if (!t || !el.contains(t) || !owns(el, t)) return;
      setDirty(el, true);
    });
    el.addEventListener('change', function (ev) {
      var t = ev.target.closest('[data-live-change]');
      if (!t || !el.contains(t) || !owns(el, t)) return;
      run(el, t.getAttribute('data-live-change'), payloadFrom(t));
    });
    el.addEventListener('submit', function (ev) {
      var t = ev.target.closest('[data-live-submit]');
      if (!t || !el.contains(t) || !owns(el, t)) return;
      ev.preventDefault();
      run(el, t.getAttribute('data-live-submit'), payloadFrom(t));
    });
    setupPolling(el);
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
