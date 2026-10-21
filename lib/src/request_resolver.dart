import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';

/// The outcome of mapping a request URL onto the filesystem under the
/// DocumentRoot.
enum ResolutionKind {
  /// A static file that should be streamed back as-is.
  staticFile,

  /// A PHP script that should be handed to the CGI handler.
  phpScript,

  /// The path escaped the DocumentRoot or hit a forbidden target (403).
  forbidden,

  /// Nothing matched (404).
  notFound,
}

/// Result of resolving a URL path to something on disk.
class Resolution {
  Resolution.staticFile(this.filePath)
      : kind = ResolutionKind.staticFile,
        scriptName = '',
        pathInfo = '';

  Resolution.phpScript({
    required this.filePath,
    required this.scriptName,
    required this.pathInfo,
  }) : kind = ResolutionKind.phpScript;

  Resolution.forbidden()
      : kind = ResolutionKind.forbidden,
        filePath = '',
        scriptName = '',
        pathInfo = '';

  Resolution.notFound()
      : kind = ResolutionKind.notFound,
        filePath = '',
        scriptName = '',
        pathInfo = '';

  final ResolutionKind kind;

  /// Absolute filesystem path of the target file.
  final String filePath;

  /// For PHP: the URL path of the script (`SCRIPT_NAME`).
  final String scriptName;

  /// For PHP: trailing path after the script (`PATH_INFO`).
  final String pathInfo;
}

/// Translates request URL paths into filesystem targets the way Apache does:
/// mapping under DocumentRoot, applying DirectoryIndex, splitting PATH_INFO at
/// the `.php` script, and refusing to serve anything outside the root.
class RequestResolver {
  RequestResolver(this.config)
      : _root = p.normalize(config.documentRoot);

  final ServerConfig config;
  final String _root;

  /// Resolves the decoded URL [urlPath] (e.g. `/dir/info.php/extra`).
  Resolution resolve(String urlPath) {
    // Split off any PATH_INFO: walk segments and stop at the first that names
    // an existing `.php` file, treating the remainder as PATH_INFO.
    final segments =
        urlPath.split('/').where((s) => s.isNotEmpty).toList(growable: false);

    final consumed = <String>[];
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      if (segment == '..' || segment == '.') {
        // Any traversal component is rejected outright.
        if (segment == '..') return Resolution.forbidden();
        continue;
      }
      consumed.add(segment);
      final candidate = _safeJoin(consumed);
      if (candidate == null) return Resolution.forbidden();

      if (segment.toLowerCase().endsWith('.php') &&
          File(candidate).existsSync()) {
        final pathInfoSegments = segments.sublist(i + 1);
        final pathInfo =
            pathInfoSegments.isEmpty ? '' : '/${pathInfoSegments.join('/')}';
        return Resolution.phpScript(
          filePath: candidate,
          scriptName: '/${consumed.join('/')}',
          pathInfo: pathInfo,
        );
      }
    }

    // No PHP script in the path: resolve the whole URL as a file or directory.
    final fullPath = _safeJoin(segments);
    if (fullPath == null) return Resolution.forbidden();

    final type = FileSystemEntity.typeSync(fullPath);
    if (type == FileSystemEntityType.directory) {
      return _resolveDirectoryIndex(segments, fullPath);
    }
    if (type == FileSystemEntityType.file) {
      if (fullPath.toLowerCase().endsWith('.php')) {
        return Resolution.phpScript(
          filePath: fullPath,
          scriptName: '/${segments.join('/')}',
          pathInfo: '',
        );
      }
      return Resolution.staticFile(fullPath);
    }

    return Resolution.notFound();
  }

  /// Applies DirectoryIndex to a requested directory.
  Resolution _resolveDirectoryIndex(List<String> segments, String dirPath) {
    for (final index in config.directoryIndex) {
      final indexPath = p.join(dirPath, index);
      if (File(indexPath).existsSync()) {
        final scriptName = '/${[...segments, index].join('/')}';
        if (index.toLowerCase().endsWith('.php')) {
          return Resolution.phpScript(
            filePath: indexPath,
            scriptName: scriptName,
            pathInfo: '',
          );
        }
        return Resolution.staticFile(indexPath);
      }
    }
    // Directory with no index file: Apache would show a listing or 403; we
    // deny, matching `Options -Indexes`.
    return Resolution.forbidden();
  }

  /// Joins [segments] under the DocumentRoot, returning null if the result
  /// would escape the root (defense against directory traversal).
  String? _safeJoin(List<String> segments) {
    final joined = p.normalize(p.joinAll([_root, ...segments]));
    if (joined != _root &&
        !p.isWithin(_root, joined)) {
      return null;
    }
    return joined;
  }
}
