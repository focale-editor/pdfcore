import 'dart:convert';
import 'dart:typed_data';

import 'package:pdfcore/src/codec/pdf_filters.dart';
import 'package:pdfcore/src/codec/pdf_reader.dart';
import 'package:pdfcore/src/codec/pdf_security_handler.dart';
import 'package:pdfcore/src/codec/pdf_syntax.dart';
import 'package:pdfcore/src/model/pdf_document.dart';
import 'package:pdfcore/src/model/pdf_security.dart';
import 'package:pdfcore/src/model/pdf_value.dart';

/// Complete-document PDF codec with preservation of opaque stream data.
final class PdfCodec extends Codec<PdfDocument, List<int>> {
  /// User or owner password for decoding.
  final String password;

  /// Explicit output protection; omitted output is unencrypted.
  final PdfEncryption? encryption;

  /// Resource policy for reading and writing.
  final PdfLimits limits;

  /// Explicit compatibility allowlist of duplicate keys using the last value.
  ///
  /// Empty by default. Cross references and resource budgets remain strict.
  final Set<String> duplicateKeys;

  /// Creates a portable PDF codec.
  const PdfCodec({this.limits = const PdfLimits(), this.duplicateKeys = const {}, this.password = '', this.encryption});

  @override
  PdfDecoder get decoder => PdfDecoder(limits: limits, duplicateKeys: duplicateKeys, password: password);

  @override
  PdfEncoder get encoder => PdfEncoder(limits: limits, encryption: encryption);

  @override
  Uint8List encode(PdfDocument input) => encoder.convert(input);
}

/// Reads classic, stream, hybrid and incremental cross-reference structures.
final class PdfDecoder extends Converter<List<int>, PdfDocument> {
  /// Password for standard security; the empty password is tried by default.
  final String password;

  /// Resource policy for hostile or oversized input.
  final PdfLimits limits;

  /// Keys explicitly allowed to repeat, with the final value taking precedence.
  final Set<String> duplicateKeys;

  /// Creates a strict decoder; damaged xrefs are not guessed by scanning.
  const PdfDecoder({this.limits = const PdfLimits(), this.duplicateKeys = const {}, this.password = ''});

  @override
  PdfDocument convert(List<int> input) {
    limits.validate();
    if (input.length > limits.maxFileBytes) {
      throw const FormatException('PDF input exceeds the byte limit.');
    }
    if (input.any((byte) => byte < 0 || byte > 255)) {
      throw const FormatException('Input contains values outside the byte range.');
    }
    return PdfFileReader(bytes: Uint8List.fromList(input), limits: limits, duplicateKeys: duplicateKeys, password: password).read();
  }
}

/// Writes a full PDF revision with rebuilt classic cross references.
///
/// Object identifiers and encoded stream payloads are preserved. This is not
/// an incremental or signature-preserving writer; linearization is removed.
final class PdfEncoder extends Converter<PdfDocument, List<int>> {
  /// Fresh AES-256 security, independent of the decoded document's provenance.
  final PdfEncryption? encryption;

  /// Resource policy for the resulting file.
  final PdfLimits limits;

  /// Creates a canonical full-rewrite encoder.
  const PdfEncoder({this.limits = const PdfLimits(), this.encryption});

  @override
  Uint8List convert(PdfDocument input) {
    limits.validate();
    if (!RegExp(r'^(1\.[0-7]|2\.0)$').hasMatch(input.version)) {
      throw const FormatException('Unsupported PDF output version.');
    }
    if (input.trailer['Encrypt'] != null && input.trailer['Encrypt'] is! PdfNull) {
      throw const PdfUnsupportedException(message: 'Decode encrypted source objects before writing.');
    }
    if (input.objects.length > limits.maxObjects) {
      throw const FormatException('PDF object count exceeds the output limit.');
    }
    final PdfDocument checked = PdfDocument(version: input.version, objects: input.objects, trailer: input.trailer, limits: limits);
    if (checked.catalog.name('Type') != 'Catalog') {
      throw const FormatException('PDF output Root must be a Catalog.');
    }
    checked.pages;
    final Map<PdfReference, PdfValue> objects = {...input.objects};
    final List<PdfReference> references = objects.keys.toList()..sort((a, b) => a.objectNumber.compareTo(b.objectNumber));
    final PdfSecurityHandler? security = encryption == null ? null : PdfSecurityHandler.create(encryption!);
    final PdfReference? encryptionReference = security == null ? null : PdfReference(objectNumber: references.isEmpty ? 1 : references.last.objectNumber + 1);
    if (encryptionReference != null) {
      objects[encryptionReference] = security!.dictionary;
      references.add(encryptionReference);
    }
    if (references.length > limits.maxObjects) {
      throw const FormatException('PDF object count exceeds the output limit.');
    }
    final Set<int> numbers = {};
    final PdfSyntaxWriter writer = PdfSyntaxWriter(limits: limits);
    final String version = security != null
        ? '2.0'
        : ['1.0', '1.1'].contains(input.version)
        ? '1.2'
        : input.version;
    writer.text('%PDF-$version\n%\xe2\xe3\xcf\xd3\n');
    final Map<PdfReference, int> offsets = {};
    for (final PdfReference reference in references) {
      if (reference.objectNumber <= 0 || reference.objectNumber > 9007199254740990 || reference.generation < 0 || reference.generation >= 65535 || !numbers.add(reference.objectNumber)) {
        throw const FormatException('Invalid or duplicate PDF output object number.');
      }
      offsets[reference] = writer.length;
      writer.text('${reference.objectNumber} ${reference.generation} obj\n');
      final PdfValue original = objects[reference]!;
      final PdfValue value = security == null || reference == encryptionReference ? original : security.encrypt(original);
      writer.value(value is PdfDictionary && value['Linearized'] != null ? value.copyWith(remove: {'Linearized'}) : value, allowStream: true);
      writer.text('\nendobj\n');
    }
    final int xref = writer.length;
    final int size = references.isEmpty ? 1 : references.last.objectNumber + 1;
    if (size > limits.maxObjects) {
      throw const FormatException('PDF output object-number range exceeds the xref limit.');
    }
    writer.text('xref\n0 $size\n0000000000 65535 f \n');
    final Map<int, PdfReference> byNumber = {for (final PdfReference reference in references) reference.objectNumber: reference};
    for (int number = 1; number < size; number++) {
      final PdfReference? reference = byNumber[number];
      if (reference == null) {
        writer.text('0000000000 65535 f \n');
        continue;
      }
      final int offset = offsets[reference]!;
      if (offset > 9999999999) {
        throw const FormatException('PDF is too large for classic cross references.');
      }
      writer.text('${offset.toString().padLeft(10, '0')} ${reference.generation.toString().padLeft(5, '0')} n \n');
    }
    writer.text('trailer\n');
    final PdfValue? identifiers = input.trailer['ID'];
    final PdfString? originalIdentifier = identifiers is PdfArray && identifiers.values.isNotEmpty && identifiers.values.first is PdfString ? identifiers.values.first as PdfString : null;
    writer.value(
      input.trailer.copyWith(
        values: {
          'Size': PdfNumber(value: references.isEmpty ? 1 : references.last.objectNumber + 1),
          if (encryptionReference != null) ...{
            'Encrypt': encryptionReference,
            'ID': PdfArray(
              values: [
                if (originalIdentifier != null && originalIdentifier.bytes.isNotEmpty) originalIdentifier else PdfString(bytes: PdfSecurityHandler.randomBytes(16)),
                PdfString(bytes: PdfSecurityHandler.randomBytes(16)),
              ],
            ),
          },
        },
        remove: {'Prev', 'XRefStm', 'Type', 'W', 'Index', 'Length', 'Filter', 'DecodeParms', 'Encrypt'},
      ),
    );
    writer.text('\nstartxref\n$xref\n%%EOF\n');
    return writer.takeBytes();
  }
}
