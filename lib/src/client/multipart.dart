import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// One file part of a [MultipartBody].
class MultipartFile {
  MultipartFile(
    this.field,
    this.bytes, {
    this.filename = 'file',
    this.contentType = 'application/octet-stream',
  });

  final String field;
  final List<int> bytes;
  final String filename;
  final String contentType;
}

/// A `multipart/form-data` request body (RFC 7578): text [fields] plus binary
/// [files], encoded with a random boundary. Use [contentType] as the request's
/// `Content-Type` and [encode] as the body bytes.
class MultipartBody {
  MultipartBody({
    Map<String, String> fields = const {},
    List<MultipartFile> files = const [],
    String? boundary,
  })  : fields = Map.of(fields),
        files = List.of(files),
        boundary = boundary ?? _randomBoundary();

  final Map<String, String> fields;
  final List<MultipartFile> files;
  final String boundary;

  String get contentType => 'multipart/form-data; boundary=$boundary';

  /// Encodes the full multipart body to bytes.
  Uint8List encode() {
    final out = BytesBuilder();
    void write(String s) => out.add(utf8.encode(s));

    fields.forEach((name, value) {
      write('--$boundary\r\n');
      write('Content-Disposition: form-data; name="$name"\r\n\r\n');
      write('$value\r\n');
    });
    for (final f in files) {
      write('--$boundary\r\n');
      write('Content-Disposition: form-data; name="${f.field}"; '
          'filename="${f.filename}"\r\n');
      write('Content-Type: ${f.contentType}\r\n\r\n');
      out.add(f.bytes);
      write('\r\n');
    }
    write('--$boundary--\r\n');
    return out.takeBytes();
  }

  static String _randomBoundary() {
    final rng = Random();
    final hex = List.generate(16, (_) => rng.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '----dartApache$hex';
  }
}
