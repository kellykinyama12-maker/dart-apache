// Live server-side diffing. Because the server renders both the old and the new
// state, it can send just the changed region of HTML (a prefix/suffix string
// splice) instead of the whole fragment. The client reconstructs the new HTML
// against its exact base string (seeded at mount from the server's own render,
// so bytes match) and then morphs the DOM.
import 'dart:math';

/// A single contiguous HTML edit: replace `old[start..end)` with [insert].
/// Applying it to the base the server diffed against yields the new HTML.
class HtmlPatch {
  const HtmlPatch(this.start, this.end, this.insert);

  /// Common-prefix length (first differing index).
  final int start;

  /// Index in the old string where the common suffix begins.
  final int end;

  /// Replacement text for `old[start..end)`.
  final String insert;

  bool get isEmpty => start == end && insert.isEmpty;

  Map<String, Object?> toJson() => {'s': start, 'e': end, 'i': insert};

  /// Rebuilds the new HTML from the [base] the patch was computed against.
  String applyTo(String base) =>
      base.substring(0, start) + insert + base.substring(end);
}

/// Computes the minimal single-splice patch turning [oldHtml] into [newHtml]
/// (strip the common prefix and suffix; what's left in the middle is the edit).
HtmlPatch computeHtmlPatch(String oldHtml, String newHtml) {
  final minLen = min(oldHtml.length, newHtml.length);
  var prefix = 0;
  while (prefix < minLen &&
      oldHtml.codeUnitAt(prefix) == newHtml.codeUnitAt(prefix)) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < (minLen - prefix) &&
      oldHtml.codeUnitAt(oldHtml.length - 1 - suffix) ==
          newHtml.codeUnitAt(newHtml.length - 1 - suffix)) {
    suffix++;
  }
  final end = oldHtml.length - suffix;
  final insert = newHtml.substring(prefix, newHtml.length - suffix);
  return HtmlPatch(prefix, end, insert);
}
