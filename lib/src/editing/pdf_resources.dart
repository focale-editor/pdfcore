import 'package:pdfcore/src/codec/pdf_content.dart';
import 'package:pdfcore/src/editing/pdf_streams.dart';
import 'package:pdfcore/src/model/pdf_document.dart';
import 'package:pdfcore/src/model/pdf_value.dart';

/// Creates editable PDF resources without a renderer or image codec dependency.
abstract final class PdfResources {
  /// Encodes decoded bytes with ZCodec, clearing stale encoding attributes.
  static PdfStream stream({required List<int> data, PdfDictionary? dictionary, bool compress = true, PdfLimits limits = const PdfLimits()}) =>
      PdfStreams.encode(bytes: data, dictionary: dictionary, compress: compress, limits: limits);

  /// Creates a standard Latin Type 1 font using explicit WinAnsi encoding.
  ///
  /// Standard fonts are not embedded. Symbol and ZapfDingbats require their own
  /// encodings and must be supplied as explicit font dictionaries instead.
  static PdfDictionary standardFont({String baseFont = 'Helvetica'}) {
    if (!const {
      'Helvetica',
      'Helvetica-Bold',
      'Helvetica-Oblique',
      'Helvetica-BoldOblique',
      'Times-Roman',
      'Times-Bold',
      'Times-Italic',
      'Times-BoldItalic',
      'Courier',
      'Courier-Bold',
      'Courier-Oblique',
      'Courier-BoldOblique',
    }.contains(baseFont)) {
      throw ArgumentError.value(baseFont, 'baseFont', 'Expected a standard Latin PDF font.');
    }
    return PdfDictionary(
      values: {
        'Type': PdfName(value: 'Font'),
        'Subtype': PdfName(value: 'Type1'),
        'BaseFont': PdfName(value: baseFont),
        'Encoding': PdfName(value: 'WinAnsiEncoding'),
      },
    );
  }

  /// Creates an 8-bit Gray, RGB or CMYK image from row-major decoded samples.
  ///
  /// Add SMask, Mask, Decode, ICC or rendering attributes through the returned
  /// dictionary when required. Encoded JPEG/JPX images can use PdfStream directly.
  static PdfStream image({required int width, required int height, required List<int> samples, String colorSpace = 'DeviceRGB', bool compress = true, PdfLimits limits = const PdfLimits()}) {
    final int components = switch (colorSpace) {
      'DeviceGray' => 1,
      'DeviceRGB' => 3,
      'DeviceCMYK' => 4,
      _ => throw ArgumentError.value(colorSpace, 'colorSpace', 'Expected a device color space.'),
    };
    if (width <= 0 ||
        height <= 0 ||
        width > limits.maxStreamBytes ||
        height > limits.maxStreamBytes ||
        width * height * components > limits.maxStreamBytes ||
        samples.length != width * height * components) {
      throw const FormatException('Image dimensions do not match bounded sample bytes.');
    }
    return stream(
      data: samples,
      compress: compress,
      limits: limits,
      dictionary: PdfDictionary(
        values: {
          'Type': PdfName(value: 'XObject'),
          'Subtype': PdfName(value: 'Image'),
          'Width': PdfNumber(value: width),
          'Height': PdfNumber(value: height),
          'ColorSpace': PdfName(value: colorSpace),
          'BitsPerComponent': PdfNumber(value: 8),
        },
      ),
    );
  }

  /// Creates a reusable form XObject with its own resources and bounding box.
  static PdfStream form({
    required Iterable<PdfOperation> operations,
    required PdfArray bounds,
    PdfDictionary? resources,
    PdfArray? matrix,
    bool compress = true,
    PdfLimits limits = const PdfLimits(),
  }) {
    validateBox(bounds);
    if (matrix != null && (matrix.values.length != 6 || matrix.values.any((value) => value is! PdfNumber))) {
      throw const FormatException('A PDF form matrix requires six finite numbers.');
    }
    return stream(
      data: PdfContent.encode(operations, limits: limits),
      compress: compress,
      limits: limits,
      dictionary: PdfDictionary(
        values: {
          'Type': PdfName(value: 'XObject'),
          'Subtype': PdfName(value: 'Form'),
          'FormType': PdfNumber(value: 1),
          'BBox': bounds,
          'Resources': resources ?? PdfDictionary(),
          'Matrix': ?matrix,
        },
      ),
    );
  }

  /// Creates an extended graphics state for opacity and a named blend mode.
  static PdfDictionary graphicsState({double fillOpacity = 1, double strokeOpacity = 1, String blendMode = 'Normal'}) {
    if (![fillOpacity, strokeOpacity].every((value) => value.isFinite && value >= 0 && value <= 1)) {
      throw ArgumentError('PDF opacity must be finite and between zero and one.');
    }
    return PdfDictionary(
      values: {
        'Type': PdfName(value: 'ExtGState'),
        'ca': PdfNumber(value: fillOpacity),
        'CA': PdfNumber(value: strokeOpacity),
        'BM': PdfName(value: blendMode),
      },
    );
  }

  /// Creates a PDF rectangle in its native bottom-left coordinate system.
  static PdfArray box({required double left, required double bottom, required double right, required double top}) {
    final PdfArray value = PdfArray(
      values: [
        PdfNumber(value: left),
        PdfNumber(value: bottom),
        PdfNumber(value: right),
        PdfNumber(value: top),
      ],
    );
    validateBox(value);
    return value;
  }

  /// Checks rectangle coordinates without introducing application geometry types.
  static void validateBox(PdfValue value, {bool allowEmpty = false}) {
    if (value is! PdfArray || value.values.length != 4 || value.values.any((item) => item is! PdfNumber)) {
      throw const FormatException('A PDF rectangle requires four finite numbers.');
    }
    final List<num> coordinates = value.values.map((item) => (item as PdfNumber).value).toList();
    if (allowEmpty ? coordinates[2] < coordinates[0] || coordinates[3] < coordinates[1] : coordinates[2] <= coordinates[0] || coordinates[3] <= coordinates[1]) {
      throw const FormatException('PDF rectangle bounds must be ordered.');
    }
  }
}
