// Dartisan Live — reactive, server-rendered components streamed over
// WebTransport (HTTP/3). The Livewire analog: a component holds no server-side
// session state; the client round-trips the component's state with each action,
// the server applies the action, re-renders, and streams the new HTML back over
// the WebTransport session. No WebSocket tier, no second process — in-binary.
import 'dart:convert';

import '../../wt/wt_handler.dart';

/// A reactive component: given a state map, [render] produces HTML; [update]
/// applies a named [action] to produce the next state. State is JSON-round-
/// trippable (it travels to the client and back), so components stay stateless
/// on the server and scale horizontally.
abstract class LiveComponent {
  /// Stable component name (used to route client actions back here).
  String get name;

  /// The state a freshly-mounted component starts with.
  Map<String, Object?> initialState();

  /// Applies [action] (with optional [payload]) to [state], returning the next
  /// state. Unknown actions should return [state] unchanged.
  Map<String, Object?> update(
    String action,
    Map<String, Object?> state,
    Map<String, Object?> payload,
  );

  /// Renders the component's inner HTML for [state].
  String render(Map<String, Object?> state);
}

/// Routes client actions to registered [LiveComponent]s by name.
class LiveRegistry {
  final Map<String, LiveComponent> _byName = {};

  void register(LiveComponent component) =>
      _byName[component.name] = component;

  LiveComponent? operator [](String name) => _byName[name];
}

/// Builds a [WtHandler] that drives Dartisan Live: it parses an inbound action
/// message `{id, component, action, state, payload}`, updates + re-renders the
/// component, and replies `{id, html, state}` on the same WebTransport stream.
WtHandler liveWtHandler(LiveRegistry registry) {
  return (session, message) {
    if (message.isDatagram) return; // Live uses reliable streams.
    final Map<String, Object?> msg;
    try {
      msg = (jsonDecode(utf8.decode(message.data)) as Map).cast<String, Object?>();
    } catch (_) {
      return;
    }
    final component = registry[(msg['component'] as String?) ?? ''];
    if (component == null) return;

    final state = (msg['state'] as Map?)?.cast<String, Object?>() ??
        component.initialState();
    final payload =
        (msg['payload'] as Map?)?.cast<String, Object?>() ?? const {};
    final action = (msg['action'] as String?) ?? '';

    final next = action.isEmpty
        ? state
        : component.update(action, state, payload);
    final reply = jsonEncode({
      'id': msg['id'],
      'html': component.render(next),
      'state': next,
    });
    session.send(utf8.encode(reply));
  };
}

/// Renders a component's initial mount: a container carrying its name + state,
/// plus the bootstrap for the client runtime. [wtPath] is the WebTransport
/// endpoint (matches `--wt-path`). By default the runtime is loaded from
/// [scriptUrl]; pass [inlineRuntime] (the JS source) to embed it in the page
/// instead (one fewer request).
String liveMount(
  LiveComponent component, {
  Map<String, Object?>? state,
  String wtPath = '/wt',
  String scriptUrl = '/app/dartisan-live.js',
  String? inlineRuntime,
}) {
  final s = state ?? component.initialState();
  final attrEsc = const HtmlEscape(HtmlEscapeMode.attribute);
  final stateAttr = attrEsc.convert(jsonEncode(s));
  final boot = inlineRuntime != null
      ? '<script>$inlineRuntime</script>'
      : '<script src="$scriptUrl"></script>';
  return '<div data-live-component="${component.name}" '
      'data-live-state="$stateAttr">${component.render(s)}</div>\n'
      '<script>window.DARTISAN_LIVE_PATH=${jsonEncode(wtPath)};</script>\n'
      '$boot';
}
