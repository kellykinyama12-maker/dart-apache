import 'dart:io';

import '../config.dart';

/// Builds the CGI/1.1 parameter block shared by the `php-cgi` (env vars) and
/// FastCGI (PARAMS records) backends. The mapping follows Apache's `mod_cgi` /
/// `mod_proxy_fcgi`.
Map<String, String> buildCgiParams({
  required ServerConfig config,
  required HttpRequest request,
  required String scriptFilename,
  required String scriptName,
  required String pathInfo,
}) {
  final uri = request.uri;
  final connectionInfo = request.connectionInfo;
  final contentLength = request.contentLength;

  final params = <String, String>{
    'GATEWAY_INTERFACE': 'CGI/1.1',
    'SERVER_SOFTWARE': config.serverSoftware,
    'SERVER_PROTOCOL': 'HTTP/${request.protocolVersion}',
    'SERVER_NAME': config.serverName,
    'SERVER_ADDR': config.address,
    'SERVER_PORT': '${config.port}',
    'DOCUMENT_ROOT': config.documentRoot,
    'REQUEST_METHOD': request.method,
    'REQUEST_URI': uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path,
    'QUERY_STRING': uri.query,
    'SCRIPT_NAME': scriptName,
    'SCRIPT_FILENAME': scriptFilename,
    'PATH_TRANSLATED': scriptFilename,
    'REMOTE_ADDR': connectionInfo?.remoteAddress.address ?? '',
    'REMOTE_PORT': '${connectionInfo?.remotePort ?? 0}',
    // php-cgi refuses to run as a CGI binary unless this is set; Apache's
    // mod_cgi sets it implicitly. 200 means "not an internal redirect".
    'REDIRECT_STATUS': '200',
  };

  if (pathInfo.isNotEmpty) {
    params['PATH_INFO'] = pathInfo;
  }

  final contentType = request.headers.contentType;
  if (contentType != null) {
    params['CONTENT_TYPE'] = contentType.toString();
  }
  if (contentLength >= 0) {
    params['CONTENT_LENGTH'] = '$contentLength';
  }

  // Every request header becomes HTTP_<UPPER_SNAKE_CASE>, per CGI.
  request.headers.forEach((name, values) {
    final key = 'HTTP_${name.toUpperCase().replaceAll('-', '_')}';
    params[key] = values.join(', ');
  });

  return params;
}
