import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pdfcore/pdfcore.dart';

/// Imports pinned encrypted internet files and exports independent QA artifacts.
Future<void> main() async {
  final Map<String, Object?> manifest = (jsonDecode(await File('test/corpus/security_manifest.json').readAsString()) as Map).cast<String, Object?>();
  final List<Map<String, Object?>> report = [];
  final Directory output = await Directory('test/corpus/output/security').create(recursive: true);
  for (final Object? value in manifest['files']! as List) {
    final Map<String, Object?> entry = (value! as Map).cast<String, Object?>();
    final String name = entry['file']! as String;
    final bool passwordRequired = entry['expected'] == 'password';
    try {
      final Uint8List bytes = await File('test/corpus/files/security/$name').readAsBytes();
      final PdfDocument source = PdfCodec(password: entry['password']! as String).decode(bytes);
      if (passwordRequired) {
        throw StateError('Expected password rejection.');
      }
      await File('${output.path}/$name.plain.pdf').writeAsBytes(const PdfCodec().encode(source));
      final Uint8List encrypted = const PdfCodec(
        encryption: PdfEncryption.aes256(userPassword: 'export-user', ownerPassword: 'export-owner', permissions: PdfPermissions(copy: false, modify: false)),
      ).encode(source);
      await File('${output.path}/$name.encrypted.pdf').writeAsBytes(encrypted);
      final PdfDocument reopened = const PdfCodec(password: 'export-user').decode(encrypted);
      if (source.pages.length != reopened.pages.length) {
        throw StateError('Page count changed.');
      }
      report.add({'file': name, 'status': 'accepted', 'pages': source.pages.length, 'revision': source.security?.revision});
    } on PdfPasswordException {
      if (!passwordRequired) {
        rethrow;
      }
      report.add({'file': name, 'status': 'password'});
    }
  }
  await File('${output.path}/report.json').writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  stdout.writeln('PdfCore security: ${report.length} expected outcomes.');
}
