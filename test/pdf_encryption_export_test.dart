import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:pdfcore/pdfcore.dart';
import 'package:test/test.dart';

/// Original text, metadata and stream fixture, independent of encryption code.
PdfDocument _document() {
  final PdfDocument document = PdfDocument.fromPages(pages: [PdfPageSource(width: 100, height: 100, content: ascii.encode('q 1 0 0 rg 20 20 30 40 re f Q\n'))]);
  const PdfReference info = PdfReference(objectNumber: 20);
  const PdfReference metadata = PdfReference(objectNumber: 21);
  return document.copyWith(
    objects: {
      ...document.objects,
      info: PdfDictionary(values: {'Title': PdfString.text(text: 'Confidential title')}),
      metadata: PdfStream(
        dictionary: PdfDictionary(
          values: {
            'Type': PdfName(value: 'Metadata'),
            'Subtype': PdfName(value: 'XML'),
          },
        ),
        data: utf8.encode('<metadata>Confidential metadata</metadata>'),
      ),
      document.trailer['Root']! as PdfReference: document.catalog.copyWith(values: {'Metadata': metadata}),
    },
    trailer: document.trailer.copyWith(values: {'Info': info}),
  );
}

/// Checks encryption output, randomization and explicit output policy on VM/JS.
void main() {
  for (final String user in ['', 'lecture', 'élève🔒', 'x' * 200]) {
    for (final bool metadata in [false, true]) {
      test('AES-256 export with ${user.length} password units, metadata=$metadata', () {
        final PdfDocument source = _document();
        final PdfCodec codec = PdfCodec(
          encryption: PdfEncryption.aes256(userPassword: user, ownerPassword: 'propriétaire', encryptMetadata: metadata, permissions: const PdfPermissions(copy: false, modify: false, print: false)),
        );
        final Uint8List first = codec.encode(source);
        final Uint8List second = codec.encode(source);
        check(base64Encode(first)).not((value) => value.equals(base64Encode(second)));
        check(latin1.decode(first)).not((value) => value.contains('q 1 0 0 rg'));
        check(latin1.decode(first).contains('Confidential metadata')).equals(!metadata);
        check(() => const PdfCodec(password: 'wrong').decode(first)).throws<PdfPasswordException>();
        if (user.isNotEmpty) {
          check(() => const PdfCodec().decode(first)).throws<PdfPasswordException>();
        }
        for (final String password in [user, 'propriétaire']) {
          final PdfDocument decoded = PdfCodec(password: password).decode(first);
          check(decoded.version).equals('2.0');
          check(decoded.security!.revision).equals(6);
          check(decoded.security!.ownerPassword).equals(password == 'propriétaire');
          check(decoded.security!.permissions & (4 | 8 | 16 | 2048)).equals(0);
          check(decoded.pageContent(decoded.pages.single)).deepEquals(source.pageContent(source.pages.single));
          check((decoded.dictionary(decoded.trailer['Info']!)['Title']! as PdfString).text).equals('Confidential title');
          check(const PdfCodec().decode(const PdfCodec().encode(decoded)).security).isNull();
        }
        check(source.security).isNull();
        check(source.trailer['Encrypt']).isNull();
      });
    }
  }
  test('empty owner passwords are rejected; default export remains plaintext', () {
    check(
      () => const PdfCodec(
        encryption: PdfEncryption.aes256(userPassword: 'secret', ownerPassword: ''),
      ).encode(_document()),
    ).throws<ArgumentError>();
    check(const PdfPermissions().value).equals(-4);
    check(const PdfCodec().decode(const PdfCodec().encode(_document())).security).isNull();
  });
  test('encrypted full rewrites retain the original identifier and renew the revision identifier', () {
    const PdfCodec codec = PdfCodec(
      encryption: PdfEncryption.aes256(userPassword: 'user', ownerPassword: 'owner'),
    );
    for (final PdfValue identifiers in [
      const PdfNull(),
      PdfArray(values: []),
      PdfArray(values: [PdfNumber(value: 1)]),
      PdfArray(
        values: [
          PdfString.text(text: 'original'),
          PdfString.text(text: 'old'),
        ],
      ),
    ]) {
      final PdfDocument source = _document();
      final PdfDocument decoded = const PdfCodec(password: 'user').decode(codec.encode(source.copyWith(trailer: source.trailer.copyWith(values: {'ID': identifiers}))));
      final PdfArray actual = decoded.trailer['ID']! as PdfArray;
      check(actual.values.length).equals(2);
      check((actual.values.last as PdfString).bytes.length).equals(16);
      if (identifiers is PdfArray && identifiers.values.length == 2) {
        check((actual.values.first as PdfString).text).equals('original');
      } else {
        check((actual.values.first as PdfString).bytes.length).equals(16);
      }
    }
  });
}
