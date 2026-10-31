import 'dart:typed_data';

import 'package:pdfcore/src/codec/pdf_filters.dart';
import 'package:pdfcore/src/codec/pdf_inline_image.dart';
import 'package:pdfcore/src/codec/pdf_syntax.dart';
import 'package:pdfcore/src/model/pdf_document.dart';
import 'package:pdfcore/src/model/pdf_value.dart';

/// A graphics instruction with syntax-level operands, without rendering policy.
final class PdfOperation {
  /// Case-sensitive PDF graphics operator.
  final String operator;

  /// Immutable operands in stack order.
  final List<PdfValue> operands;

  /// Encoded image for a BI/ID/EI instruction, otherwise null.
  final PdfInlineImage? inlineImage;

  /// Creates an instruction, including extension operators.
  PdfOperation({required this.operator, Iterable<PdfValue> operands = const []}) : operands = List.unmodifiable(operands), inlineImage = null {
    if (operator.isEmpty || operator.codeUnits.any((byte) => byte > 126 || PdfSyntaxReader.isDelimiter(byte)) || !RegExp(r'^[A-Za-z\x27\x22][A-Za-z0-9*\x27\x22]*$').hasMatch(operator)) {
      throw const FormatException('Invalid PDF graphics operator.');
    }
  }

  /// Creates one complete inline-image instruction.
  PdfOperation.image({required PdfInlineImage image}) : operator = 'BI', operands = const [], inlineImage = image;

  /// Replaces an ordinary instruction's operands without changing its operator.
  PdfOperation withOperands(Iterable<PdfValue> values) {
    if (inlineImage != null) {
      throw StateError('Replace an inline image with PdfOperation.image.');
    }
    return PdfOperation(operator: operator, operands: values);
  }
}

/// Reads and writes graphics operations while leaving their semantics to hosts.
abstract final class PdfContent {
  /// Parses a complete decoded content stream.
  ///
  /// Inline image boundaries use sample dimensions or the outer filter's end.
  /// Supply color-space resources for unfiltered images with named spaces.
  static List<PdfOperation> decode(List<int> input, {PdfLimits limits = const PdfLimits(), PdfDictionary? colorSpaces, PdfValue Function(PdfValue)? resolve}) {
    limits.validate();
    if (input.length > limits.maxStreamBytes) {
      throw const FormatException('PDF content exceeds the byte limit.');
    }
    if (input.any((byte) => byte < 0 || byte > 255)) {
      throw const FormatException('PDF content contains a non-byte value.');
    }
    final PdfSyntaxReader reader = PdfSyntaxReader(bytes: Uint8List.fromList(input), limits: limits);
    final List<PdfOperation> operations = [];
    final List<PdfValue> operands = [];
    int decodedImageBytes = 0;

    /// Bounds aggregate sample expansion while finding inline image boundaries.
    void consumeImageBytes(int count) {
      decodedImageBytes += count;
      if (decodedImageBytes > limits.maxDecodedBytes) {
        throw const FormatException('Inline images exceed the aggregate decoded byte limit.');
      }
    }

    while (!reader.isDone) {
      final int byte = reader.bytes[reader.position];
      if ((byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 39 || byte == 34) {
        final int saved = reader.position;
        final String word = reader.token();
        if (['true', 'false', 'null'].contains(word)) {
          reader.position = saved;
          operands.add(reader.value(references: false));
        } else {
          if (word == 'BI') {
            if (operands.isNotEmpty) {
              throw const FormatException('Inline images cannot have preceding operands.');
            }
            operations.add(
              PdfOperation.image(
                image: readPdfInlineImage(reader, colorSpaces: colorSpaces, resolve: resolve, onDecoded: consumeImageBytes),
              ),
            );
          } else {
            if (['ID', 'EI'].contains(word)) {
              throw const FormatException('Unmatched inline image delimiter.');
            }
            operations.add(PdfOperation(operator: word, operands: operands));
          }
          operands.clear();
        }
      } else {
        operands.add(reader.value(references: false));
      }
      if (operations.length > limits.maxObjects || operands.length > limits.maxObjects) {
        throw const FormatException('PDF content operation count exceeds the limit.');
      }
    }
    if (operands.isNotEmpty) {
      throw const FormatException('PDF content ends with unused operands.');
    }
    return List.unmodifiable(operations);
  }

  /// Writes syntax-level operations without changing their order.
  static Uint8List encode(Iterable<PdfOperation> operations, {PdfLimits limits = const PdfLimits()}) {
    limits.validate();
    final PdfSyntaxWriter writer = PdfSyntaxWriter(limits: limits);
    int count = 0;
    for (final PdfOperation operation in operations) {
      if (++count > limits.maxObjects) {
        throw const FormatException('PDF content operation count exceeds the limit.');
      }
      if (operation.inlineImage case final PdfInlineImage image) {
        writer.text('BI\n');
        for (final MapEntry<String, PdfValue> entry in image.dictionary.values.entries) {
          writer.value(PdfName(value: entry.key));
          writer.text(' ');
          _validateOperand(entry.value, limits, 0);
          writer.value(entry.value);
          writer.text('\n');
        }
        writer.text('ID\n');
        writer.add(image.data);
        writer.text('\nEI\n');
        continue;
      }
      if (['BI', 'ID', 'EI'].contains(operation.operator)) {
        throw const PdfUnsupportedException(message: 'Inline PDF images need raw content bytes.');
      }
      for (final PdfValue operand in operation.operands) {
        _validateOperand(operand, limits, 0);
        writer.value(operand);
        writer.text(' ');
      }
      writer.text('${operation.operator}\n');
    }
    if (writer.length > limits.maxStreamBytes) {
      throw const FormatException('PDF content exceeds the output byte limit.');
    }
    return writer.takeBytes();
  }
}

/// Rejects indirect objects and streams, which are illegal in content operands.
void _validateOperand(PdfValue value, PdfLimits limits, int depth) {
  if (depth > limits.maxDepth) {
    throw const FormatException('PDF content operand nesting exceeds the limit.');
  }
  switch (value) {
    case PdfReference() || PdfStream():
      throw const FormatException('PDF content operands must be direct non-stream values.');
    case PdfArray(:final values):
      for (final PdfValue item in values) {
        _validateOperand(item, limits, depth + 1);
      }
    case PdfDictionary(:final values):
      for (final PdfValue item in values.values) {
        _validateOperand(item, limits, depth + 1);
      }
    default:
      break;
  }
}
