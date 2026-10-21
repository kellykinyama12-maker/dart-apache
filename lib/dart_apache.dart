/// dart-apache: a Dart web server that serves static files and executes PHP
/// through `php-cgi`, following Apache HTTP Server's request-handling model.
library;

export 'src/config.dart';
export 'src/mime_types.dart';
export 'src/php/cgi_backend.dart';
export 'src/php/cgi_params.dart';
export 'src/php/fastcgi.dart';
export 'src/php/php_backend.dart'
    show PhpBackend, PhpResponse, CgiException, parseCgiStream;
export 'src/request_resolver.dart';
export 'src/server.dart';
export 'src/supervisor.dart';
