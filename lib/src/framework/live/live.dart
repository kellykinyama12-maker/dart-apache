// Dartisan Live — reactive, server-rendered components streamed over
// WebTransport (HTTP/3). The Livewire analog: a component holds no server-side
// session state; the client round-trips the component's state with each action,
// the server applies the action, re-renders, and streams the new HTML back over
// the WebTransport session. No WebSocket tier, no second process — in-binary.
import 'dart:convert';

import '../../wt/wt_handler.dart';
import '../validation.dart';
import 'diff.dart';

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

  /// Validates [data] against [rules] (Laravel-style), throwing a
  /// [ValidationException] on failure — the Live handler catches it and folds
  /// the errors into the re-rendered state (see [liveWtHandler]). Call it from
  /// [update] before applying a mutating action.
  void validate(Map<String, Object?> data, Map<String, String> rules) {
    final errors = Validator.validate(data, rules);
    if (errors.isNotEmpty) throw ValidationException(errors);
  }
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
/// component, and replies on the same WebTransport stream.
///
/// When [diff] is true (default) the reply is `{id, patch, state}` carrying only
/// the changed region of HTML (the server renders both old and new state and
/// splices) — the client rebuilds against its base and morphs. With [diff]
/// false the reply is the full `{id, html, state}`.
WtHandler liveWtHandler(LiveRegistry registry, {bool diff = true}) {
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

    // A ValidationException from update() folds its errors back into the state
    // (keeping the user's input) so the re-render can show the messages.
    Map<String, Object?> next;
    try {
      next = action.isEmpty ? state : component.update(action, state, payload);
    } on ValidationException catch (e) {
      next = {...state, 'errors': e.errors};
    }
    final newHtml = component.render(next);

    final Map<String, Object?> reply;
    if (diff) {
      // Diff against the old state's render — exactly the client's base string.
      final oldHtml = component.render(state);
      reply = {
        'id': msg['id'],
        'patch': computeHtmlPatch(oldHtml, newHtml).toJson(),
        'state': next,
      };
    } else {
      reply = {'id': msg['id'], 'html': newHtml, 'state': next};
    }
    session.send(utf8.encode(jsonEncode(reply)));
  };
}

/// Renders a component's initial mount: a container carrying its name + state,
/// plus the bootstrap for the client runtime. [wtPath] is the WebTransport
/// endpoint (matches `--wt-path`). By default the runtime is loaded from
/// [scriptUrl]; pass [inlineRuntime] (the JS source) to embed it in the page
/// instead (one fewer request). Set [includeRuntime] false for additional
/// components on a page whose runtime was already included by an earlier mount
/// (the runtime binds every component on `DOMContentLoaded`).
String liveMount(
  LiveComponent component, {
  Map<String, Object?>? state,
  String wtPath = '/wt',
  String scriptUrl = '/app/dartisan-live.js',
  String? inlineRuntime,
  bool includeRuntime = true,
}) {
  final s = state ?? component.initialState();
  final attrEsc = const HtmlEscape(HtmlEscapeMode.attribute);
  final stateAttr = attrEsc.convert(jsonEncode(s));
  final initial = component.render(s);
  final boot = !includeRuntime
      ? ''
      : inlineRuntime != null
          ? '\n<script>$inlineRuntime</script>'
          : '\n<script src="$scriptUrl"></script>';
  // Seed the client's exact base string so server-side patches splice cleanly.
  return '<div data-live-component="${component.name}" '
      'data-live-state="$stateAttr">$initial</div>\n'
      '<script>window.DARTISAN_LIVE_PATH=${jsonEncode(wtPath)};'
      '(window.DARTISAN_LIVE_INIT=window.DARTISAN_LIVE_INIT||{})'
      '[${jsonEncode(component.name)}]=${jsonEncode(initial)};</script>'
      '$boot';
}
