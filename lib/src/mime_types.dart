import 'package:path/path.dart' as p;

/// Minimal MIME lookup table covering the file types a web server commonly
/// hands out. Mirrors Apache's `mime.types` / nginx for the common cases.
const Map<String, String> _mimeByExtension = {
  // Markup / text
  '.html': 'text/html; charset=UTF-8',
  '.htm': 'text/html; charset=UTF-8',
  '.xhtml': 'application/xhtml+xml; charset=UTF-8',
  '.css': 'text/css; charset=UTF-8',
  '.js': 'text/javascript; charset=UTF-8',
  '.mjs': 'text/javascript; charset=UTF-8',
  '.map': 'application/json; charset=UTF-8',
  '.json': 'application/json; charset=UTF-8',
  '.xml': 'application/xml; charset=UTF-8',
  '.rss': 'application/rss+xml; charset=UTF-8',
  '.atom': 'application/atom+xml; charset=UTF-8',
  '.txt': 'text/plain; charset=UTF-8',
  '.csv': 'text/csv; charset=UTF-8',
  '.md': 'text/markdown; charset=UTF-8',
  '.vtt': 'text/vtt; charset=UTF-8',
  '.ics': 'text/calendar; charset=UTF-8',
  '.yaml': 'text/yaml; charset=UTF-8',
  '.yml': 'text/yaml; charset=UTF-8',
  '.webmanifest': 'application/manifest+json; charset=UTF-8',
  // Images
  '.png': 'image/png',
  '.apng': 'image/apng',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.avif': 'image/avif',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.bmp': 'image/bmp',
  '.tif': 'image/tiff',
  '.tiff': 'image/tiff',
  '.heic': 'image/heic',
  '.jxl': 'image/jxl',
  // Fonts
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.eot': 'application/vnd.ms-fontobject',
  // Audio
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav',
  '.oga': 'audio/ogg',
  '.ogg': 'audio/ogg',
  '.weba': 'audio/webm',
  '.m4a': 'audio/mp4',
  '.aac': 'audio/aac',
  '.flac': 'audio/flac',
  '.mid': 'audio/midi',
  '.midi': 'audio/midi',
  // Video
  '.mp4': 'video/mp4',
  '.m4v': 'video/mp4',
  '.webm': 'video/webm',
  '.ogv': 'video/ogg',
  '.mov': 'video/quicktime',
  '.avi': 'video/x-msvideo',
  '.mkv': 'video/x-matroska',
  '.mpeg': 'video/mpeg',
  '.mpg': 'video/mpeg',
  '.3gp': 'video/3gpp',
  '.ts': 'video/mp2t',
  // Documents / archives / binary
  '.pdf': 'application/pdf',
  '.rtf': 'application/rtf',
  '.doc': 'application/msword',
  '.docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xls': 'application/vnd.ms-excel',
  '.xlsx':
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.ppt': 'application/vnd.ms-powerpoint',
  '.pptx':
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  '.zip': 'application/zip',
  '.gz': 'application/gzip',
  '.br': 'application/x-brotli',
  '.bz2': 'application/x-bzip2',
  '.7z': 'application/x-7z-compressed',
  '.rar': 'application/vnd.rar',
  '.tar': 'application/x-tar',
  '.wasm': 'application/wasm',
};

/// Returns the MIME type for [path], defaulting to
/// `application/octet-stream` like Apache's `DefaultType`.
String mimeTypeFor(String path) {
  final ext = p.extension(path).toLowerCase();
  return _mimeByExtension[ext] ?? 'application/octet-stream';
}
