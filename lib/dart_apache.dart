/// dart-apache: a Dart web server that serves static files and executes PHP
/// through `php-cgi`, following Apache HTTP Server's request-handling model.
library;

export 'src/config.dart';
export 'src/mime_types.dart';
export 'src/php_handler.dart' show CgiResponse, CgiException, PhpCgiHandler;
export 'src/request_resolver.dart';
export 'src/server.dart';
export 'src/supervisor.dart';
