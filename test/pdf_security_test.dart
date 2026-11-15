import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:pdfcore/pdfcore.dart';
import 'package:pdfcore/src/codec/pdf_security_handler.dart';
import 'package:pdfcore/src/codec/pdf_syntax.dart';
import 'package:test/test.dart';

import 'fixtures/encrypted_pdfs.dart';

/// Reads the plaintext security dictionary from an independent QPDF fixture.
PdfDictionary _securityDictionary(Uint8List bytes) {
  final String source = latin1.decode(bytes);
  for (final RegExpMatch header in RegExp(r'^\d+ \d+ obj', multiLine: true).allMatches(source)) {
    final PdfValue value = PdfSyntaxReader(bytes: bytes, position: header.end).value();
    if (value is PdfDictionary && value.name('Filter') == 'Standard') {
      return value;
    }
  }
  throw StateError('Fixture encryption dictionary is missing.');
}

/// Authenticates the fixture independently of object decryption under test.
PdfSecurityHandler _handler(PdfDictionary dictionary) => PdfSecurityHandler.authenticate(dictionary: dictionary, identifier: Uint8List(0), password: 'lecture');

/// Covers authentication, plaintext ownership and malformed encryption boundaries.
void main() {
  for (final MapEntry<String, Map<String, Object>> fixture in encryptedPdfs.entries) {
    group(fixture.key, () {
      final Uint8List bytes = base64Decode(fixture.value['data']! as String);
      for (final String role in ['user', 'owner']) {
        test('authenticates $role and rewrites readable plaintext', () {
          final String password = fixture.value[role]! as String;
          final PdfDocument source = PdfCodec(password: password).decode(bytes);
          check(source.security!.revision).equals(fixture.value['revision']! as int);
          check(source.security!.ownerPassword).equals(role == 'owner');
          check(source.trailer['Encrypt']).isNull();
          check(source.pages).length.equals(2);
          check(latin1.decode(source.pageContent(source.pages.first))).equals('q 1 0 0 rg 20 30 40 50 re f Q\n');
          final PdfDictionary info = source.dictionary(source.trailer['Info']!);
          check((info['Title']! as PdfString).text).equals('Encrypted synthetic document');
          final PdfStream metadata = source.resolve(source.catalog['Metadata']!) as PdfStream;
          check(utf8.decode(source.decodeStream(metadata))).contains('rdf:RDF');
          final PdfDocument reopened = const PdfCodec().decode(const PdfCodec().encode(source));
          check(reopened.security).isNull();
          check(reopened.pages).length.equals(2);
          check(latin1.decode(reopened.pageContent(reopened.pages.last))).equals('q 1 0 0 rg 20 30 40 50 re f Q\n');
          check((reopened.dictionary(reopened.trailer['Info']!)['Title']! as PdfString).text).equals('Encrypted synthetic document');
        });
      }
      test('rejects incorrect passwords without returning a partial graph', () {
        check(() => const PdfCodec(password: 'incorrect').decode(bytes)).throws<PdfPasswordException>();
        if (fixture.value['user'] != '') {
          check(() => const PdfCodec().decode(bytes)).throws<PdfPasswordException>();
        }
      });
    });
  }
  final Uint8List aes = base64Decode(encryptedPdfs['r6-aes']!['data']! as String);
  final PdfDictionary dictionary = _securityDictionary(aes);
  test('accepts Acrobat XI U/O padding without hashing its trailing bytes', () {
    final PdfDictionary padded = dictionary.copyWith(
      values: {
        for (final String key in ['U', 'O']) key: PdfString(bytes: [...(dictionary[key]! as PdfString).bytes, ...List.filled(79, 17)]),
      },
    );
    check(_handler(padded).security.revision).equals(6);
    check(() => _handler(dictionary.copyWith(values: {'U': PdfString(bytes: List.filled(47, 0))}))).throws<FormatException>();
  });
  test('rejects tampered encrypted permissions and malformed authentication fields', () {
    check(() => _handler(dictionary.copyWith(values: {'P': PdfNumber(value: dictionary.integer('P')! ^ 4)}))).throws<FormatException>();
    check(() => _handler(dictionary.copyWith(values: {'UE': PdfString(bytes: List.filled(31, 0))}))).throws<FormatException>();
    check(() => _handler(dictionary.copyWith(values: {'StrF': PdfNumber(value: 1)}))).throws<FormatException>();
    check(() => _handler(dictionary.copyWith(values: {'Filter': PdfName(value: 'Adobe.PubSec')}))).throws<PdfEncryptionUnsupportedException>();
    check(() => _handler(dictionary.copyWith(values: {'R': PdfNumber(value: 7)}))).throws<PdfEncryptionUnsupportedException>();
  });

  test('rejects unknown crypt filters instead of treating ciphertext as plaintext', () {
    final PdfDictionary filters = dictionary['CF']! as PdfDictionary;
    final PdfDictionary standard = filters['StdCF']! as PdfDictionary;
    check(
      () => _handler(
        dictionary.copyWith(
          values: {
            'CF': filters.copyWith(
              values: {
                'StdCF': standard.copyWith(values: {'CFM': PdfName(value: 'Unknown')}),
              },
            ),
          },
        ),
      ),
    ).throws<PdfEncryptionUnsupportedException>();
  });

  test('Identity streams and signature contents remain plain; malformed AES fails', () {
    final PdfSecurityHandler handler = _handler(dictionary);
    const PdfReference reference = PdfReference(objectNumber: 42, generation: 3);
    final PdfStream stream = handler.decrypt(
      PdfStream(
        dictionary: PdfDictionary(
          values: {
            'Filter': PdfName(value: 'Crypt'),
            'DecodeParms': PdfDictionary(values: {'Name': PdfName(value: 'Identity')}),
          },
        ),
        data: [1, 2, 3],
      ),
      reference,
    ) as PdfStream;
    check(stream.data).deepEquals([1, 2, 3]);
    check(stream.dictionary['Filter']).isNull();
    check(stream.dictionary['DecodeParms']).isNull();
    check(
      () => handler.decrypt(
        PdfStream(
          dictionary: PdfDictionary(
            values: {
              'Filter': PdfName(value: 'Crypt'),
              'DecodeParms': PdfDictionary(values: {'Name': PdfNumber(value: 1)}),
            },
          ),
          data: [1, 2, 3],
        ),
        reference,
      ),
    ).throws<FormatException>();
    for (final String type in ['Sig', 'DocTimeStamp']) {
      final PdfDictionary signature = handler.decrypt(
        PdfDictionary(
          values: {
            'Type': PdfName(value: type),
            'Contents': PdfString(bytes: [1, 2, 3]),
          },
        ),
        reference,
      ) as PdfDictionary;
      check((signature['Contents']! as PdfString).bytes).deepEquals([1, 2, 3]);
    }
    check(() => handler.decrypt(PdfString(bytes: [1, 2, 3]), reference)).throws<FormatException>();
    check(() => handler.decrypt(PdfString(bytes: List.filled(32, 0)), reference)).throws<FormatException>();
    check(
      () => handler.decrypt(
        PdfStream(
          dictionary: PdfDictionary(
            values: {
              'Filter': PdfArray(
                values: [
                  PdfName(value: 'FlateDecode'),
                  PdfName(value: 'Crypt'),
                ],
              ),
            },
          ),
          data: [1],
        ),
        reference,
      ),
    ).throws<FormatException>();
  });
}
