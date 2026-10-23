// Perf receipt for Live server-side diffing (H1): measures bytes-on-the-wire
// per update, full-HTML reply vs patch reply, for representative components.
//
// Run: dart run tool/bench_live_diff.dart
import 'dart:convert';

import 'package:dart_apache/dart_apache.dart';

int _bytes(String s) => utf8.encode(s).length;

String _counter(int n) =>
    '<p style="font-size:1.6rem">Count: <strong id="live-count">$n</strong></p>'
    '<button data-live-click="decrement">- 1</button> '
    '<button data-live-click="increment">+ 1</button> '
    '<button data-live-click="reset">reset</button>';

String _todoList(int count, {int? toggled}) {
  final b = StringBuffer('<ul>');
  for (var i = 0; i < count; i++) {
    final checked = i == toggled ? ' checked' : '';
    b.write('<li data-live-key="$i"><label>'
        '<input type="checkbox"$checked data-live-change="toggle"> '
        'Task number $i</label></li>');
  }
  b.write('</ul>');
  return b.toString();
}

void _row(String label, String oldHtml, String newHtml,
    Map<String, Object?> state) {
  final full = jsonEncode({'id': 1, 'html': newHtml, 'state': state});
  final patch = jsonEncode({
    'id': 1,
    'patch': computeHtmlPatch(oldHtml, newHtml).toJson(),
    'state': state,
  });
  final htmlFull = _bytes(newHtml);
  final patchOnly = _bytes(jsonEncode(computeHtmlPatch(oldHtml, newHtml).toJson()));
  final saveHtml = (100 * (1 - patchOnly / htmlFull)).toStringAsFixed(1);
  final saveReply = (100 * (1 - _bytes(patch) / _bytes(full))).toStringAsFixed(1);
  print('${label.padRight(28)}'
      'html ${htmlFull.toString().padLeft(6)}B  '
      'patch ${patchOnly.toString().padLeft(5)}B  '
      '(-$saveHtml% html)   '
      'reply ${_bytes(full).toString().padLeft(6)}->${_bytes(patch).toString().padLeft(6)}B (-$saveReply%)');
}

void main() {
  print('== Live diffing wire size: full-HTML reply vs patch reply ==');
  _row('counter 41 -> 42', _counter(41), _counter(42), {'count': 42});

  final items = List.generate(50, (i) => {'id': i, 'done': false});
  _row('50-item list, toggle #25', _todoList(50), _todoList(50, toggled: 25),
      {'items': items});

  final big = List.generate(200, (i) => {'id': i, 'done': false});
  _row('200-item list, toggle #100', _todoList(200),
      _todoList(200, toggled: 100), {'items': big});
  print('== done ==');
}
