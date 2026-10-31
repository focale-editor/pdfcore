import 'package:pdfcore/src/model/pdf_document.dart';
import 'package:pdfcore/src/model/pdf_value.dart';
import 'package:zcodec/zcodec.dart';

/// Creates replacement streams with coherent lengths, filters and parameters.
abstract final class PdfStreams {
  /// Encodes decoded bytes, retaining unrelated attributes from [dictionary].
  ///
  /// Old filter parameters, external file links and decoded-length hints are
  /// removed. Flate encoding uses ZCodec on every platform.
  static PdfStream encode({required List<int> bytes, PdfDictionary? dictionary, bool compress = true, PdfLimits limits = const PdfLimits()}) {
    limits.validate();
    if (bytes.length > limits.maxStreamBytes || bytes.any((byte) => byte < 0 || byte > 255)) {
      throw const FormatException('Invalid or excessive decoded PDF stream.');
    }
    return PdfStream(
      dictionary: (dictionary ?? PdfDictionary()).copyWith(
        values: {if (compress) 'Filter': PdfName(value: 'FlateDecode')},
        remove: {'Length', 'Filter', 'DecodeParms', 'F', 'FFilter', 'FDecodeParms', 'DL'},
      ),
      data: compress ? const ZlibEncoder().convert(bytes) : bytes,
    );
  }
}
