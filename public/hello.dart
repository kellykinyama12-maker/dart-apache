// A Dart "CGI" script: the Dart analog of a .php file. The server runs this on
// the Dart VM per request (with --dart-cgi) — edit it and the next request runs
// the new code, no compile. Request metadata arrives as environment variables
// (the CGI/1.1 block); the body on stdin; write the response to stdout.
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final env = Platform.environment;
  final name = Uri.splitQueryString(env['QUERY_STRING'] ?? '')['name'] ?? 'world';
  final method = env['REQUEST_METHOD'] ?? 'GET';
  final body = await systemEncoding.decodeStream(stdin);

  stdout
    ..write('Content-Type: text/plain; charset=UTF-8\r\n')
    ..write('X-Powered-By: dart-cgi\r\n')
    ..write('\r\n')
    ..write('Hello, $name!\n')
    ..write('method=$method\n')
    ..write('served-by=dart VM via dart-apache --dart-cgi (no compile)\n')
    ..write('body=$body\n');
}
