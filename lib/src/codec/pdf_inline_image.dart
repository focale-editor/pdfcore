import 'dart:typed_data';

import 'package:pdfcore/src/codec/pdf_filters.dart';
import 'package:pdfcore/src/codec/pdf_syntax.dart';
import 'package:pdfcore/src/model/pdf_document.dart';
import 'package:pdfcore/src/model/pdf_value.dart';
import 'package:zcodec/zcodec.dart';

/// An inline image with normalized dictionary keys and owned encoded bytes.
final class PdfInlineImage {
  /// Image parameters using full names, suitable for an image XObject.
  final PdfDictionary dictionary;

  /// Encoded image samples, without the ID/EI delimiters.
  final Uint8List _data;

  /// Copies an image payload without interpreting its pixels.
  PdfInlineImage({required this.dictionary, required List<int> data}) : _data = Uint8List.fromList(data) {
    if (data.any((byte) => byte < 0 || byte > 255)) {
      throw const FormatException('Inline image contains a non-byte value.');
    }
  }

  /// Read-only image payload.
  Uint8List get data => _data.asUnmodifiableView();

  /// Converts the inline payload into an independent image stream.
  PdfStream toXObject() => PdfStream(
    dictionary: dictionary.copyWith(
      values: {
        'Type': PdfName(value: 'XObject'),
        'Subtype': PdfName(value: 'Image'),
      },
    ),
    data: _data,
  );
}

/// Reads the body following BI using filter boundaries, never an EI substring.
PdfInlineImage readPdfInlineImage(PdfSyntaxReader reader, {PdfDictionary? colorSpaces, PdfValue Function(PdfValue)? resolve, void Function(int)? onDecoded}) {
  final Map<String, PdfValue> entries = {};
  while (!reader.consume('ID')) {
    final PdfValue key = reader.value(references: false);
    if (key is! PdfName || entries.length >= reader.limits.maxObjects) {
      throw const FormatException('Invalid inline image dictionary.');
    }
    final String name = _keys[key.value] ?? key.value;
    if (entries.containsKey(name)) {
      throw const FormatException('Duplicate inline image parameter.');
    }
    final PdfValue value = reader.value(references: false);
    entries[name] = ['ColorSpace', 'Filter'].contains(name) ? _expand(value) : value;
  }
  if (reader.position >= reader.bytes.length || !PdfSyntaxReader.isSpace(reader.bytes[reader.position])) {
    throw const FormatException('Inline image ID needs a whitespace separator.');
  }
  // ID consumes exactly one whitespace byte; a following LF may be image data.
  reader.position++;
  final int start = reader.position;
  final PdfDictionary dictionary = PdfDictionary(values: entries);
  final int length = _payloadLength(reader, dictionary, colorSpaces, resolve, onDecoded);
  if (length < 0 || length > reader.limits.maxStreamBytes || start + length > reader.bytes.length) {
    throw const FormatException('Truncated or excessive inline image data.');
  }
  reader.position = start + length;
  if (reader.position >= reader.bytes.length || !PdfSyntaxReader.isSpace(reader.bytes[reader.position])) {
    throw const FormatException('Inline image data needs an EI separator.');
  }
  reader.expect('EI');
  return PdfInlineImage(dictionary: dictionary, data: Uint8List.sublistView(reader.bytes, start, start + length));
}

/// Standard inline-image key abbreviations.
const Map<String, String> _keys = {
  'W': 'Width',
  'H': 'Height',
  'BPC': 'BitsPerComponent',
  'CS': 'ColorSpace',
  'D': 'Decode',
  'DP': 'DecodeParms',
  'F': 'Filter',
  'IM': 'ImageMask',
  'I': 'Interpolate',
};

/// Standard inline-image name abbreviations.
const Map<String, String> _names = {
  'G': 'DeviceGray',
  'RGB': 'DeviceRGB',
  'CMYK': 'DeviceCMYK',
  'I': 'Indexed',
  'AHx': 'ASCIIHexDecode',
  'A85': 'ASCII85Decode',
  'LZW': 'LZWDecode',
  'Fl': 'FlateDecode',
  'RL': 'RunLengthDecode',
  'CCF': 'CCITTFaxDecode',
  'DCT': 'DCTDecode',
};

/// Expands names in filter and color-space declarations.
PdfValue _expand(PdfValue value) => switch (value) {
  PdfName(:final value) => PdfName(value: _names[value] ?? value),
  PdfArray(:final values) => PdfArray(values: values.map(_expand)),
  _ => value,
};

/// Finds a filter-defined end, or computes the exact unfiltered row length.
int _payloadLength(PdfSyntaxReader reader, PdfDictionary dictionary, PdfDictionary? spaces, PdfValue Function(PdfValue)? resolve, void Function(int)? onDecoded) {
  final Uint8List bytes = Uint8List.sublistView(reader.bytes, reader.position);
  final PdfValue? filter = dictionary['Filter'];
  final PdfValue? first = filter is PdfArray ? filter.values.firstOrNull : filter;
  if (first == null || first is PdfNull) {
    final int? width = dictionary.integer('Width');
    final int? height = dictionary.integer('Height');
    final bool mask = switch (dictionary['ImageMask']) {
      PdfBoolean(value: true) => true,
      _ => false,
    };
    final int? bits = mask ? 1 : dictionary.integer('BitsPerComponent');
    if (width == null || height == null || bits == null) {
      throw const PdfUnsupportedException(message: 'Inline image dimensions and sample depth are required.');
    }
    if (width <= 0 || height <= 0 || ![1, 2, 4, 8, 16].contains(bits)) {
      throw const FormatException('Invalid inline image dimensions or sample depth.');
    }
    final int components = mask ? 1 : _components(dictionary['ColorSpace'], spaces, resolve, reader.limits, 0);
    final double length = ((width.toDouble() * components * bits / 8).ceilToDouble()) * height;
    if (length > reader.limits.maxStreamBytes) {
      throw const FormatException('Inline image exceeds the sample byte limit.');
    }
    onDecoded?.call(length.toInt());
    return length.toInt();
  }
  if (first is! PdfName) {
    throw const FormatException('Invalid inline image filter.');
  }
  switch (first.value) {
    case 'FlateDecode':
      if (bytes.length < 6) {
        throw const FormatException('Truncated inline Flate image.');
      }
      final DeflateDecodeResult decoded = DeflateDecoder(maxOutputBytes: reader.limits.maxStreamBytes).convertPrefix(Uint8List.sublistView(bytes, 2));
      onDecoded?.call(decoded.data.length);
      final int length = decoded.bytesRead + 6;
      if (length > bytes.length) {
        throw const FormatException('Truncated inline Flate checksum.');
      }
      // Validate the zlib envelope as well as the DEFLATE boundary.
      ZlibDecoder(maxOutputBytes: reader.limits.maxStreamBytes).convert(Uint8List.sublistView(bytes, 0, length));
      return length;
    case 'ASCIIHexDecode':
      final int end = bytes.indexOf(62);
      if (end >= 0) {
        return end + 1;
      }
    case 'ASCII85Decode':
      for (int index = 0; index + 1 < bytes.length; index++) {
        if (bytes[index] == 126 && bytes[index + 1] == 62) {
          return index + 2;
        }
      }
    case 'RunLengthDecode':
      int offset = 0;
      while (offset < bytes.length) {
        final int control = bytes[offset++];
        if (control == 128) {
          return offset;
        }
        offset += control < 128 ? control + 1 : 1;
      }
    case 'LZWDecode':
      final PdfValue? parameters = dictionary['DecodeParms'];
      final PdfValue? firstParameters = parameters is PdfArray ? parameters.values.firstOrNull : parameters;
      if (firstParameters != null && firstParameters is! PdfNull && firstParameters is! PdfDictionary) {
        throw const FormatException('Invalid inline LZW decode parameters.');
      }
      final (Uint8List data, int length) = decodePdfLzwPrefix(bytes, reader.limits.maxStreamBytes, firstParameters is PdfDictionary ? firstParameters.integer('EarlyChange') ?? 1 : 1);
      onDecoded?.call(data.length);
      return length;
    case 'DCTDecode':
      return _jpegLength(bytes);
    default:
      throw PdfUnsupportedException(message: 'Inline image boundary for /${first.value} is unsupported; retain the raw content stream.');
  }
  throw const FormatException('Truncated inline image filter.');
}

/// Resolves the number of interleaved samples in an inline color space.
int _components(PdfValue? value, PdfDictionary? spaces, PdfValue Function(PdfValue)? resolve, PdfLimits limits, int depth) {
  if (depth > limits.maxDepth) {
    throw const FormatException('Cyclic inline image color space.');
  }
  final PdfValue? space = value == null ? null : resolve?.call(value) ?? value;
  if (space is PdfName) {
    switch (space.value) {
      case 'DeviceGray':
        return 1;
      case 'DeviceRGB':
        return 3;
      case 'DeviceCMYK':
        return 4;
      default:
        if (spaces?[space.value] case final PdfValue resource) {
          return _components(resource, spaces, resolve, limits, depth + 1);
        }
    }
  }
  if (space is PdfArray && space.values.isNotEmpty && space.values.first is PdfName) {
    final String family = (space.values.first as PdfName).value;
    if (['Indexed', 'Separation', 'CalGray'].contains(family)) {
      return 1;
    }
    if (['CalRGB', 'Lab'].contains(family)) {
      return 3;
    }
    if (family == 'ICCBased' && space.values.length > 1) {
      final PdfValue profile = resolve?.call(space.values[1]) ?? space.values[1];
      if (profile is PdfStream && [1, 3, 4].contains(profile.dictionary.integer('N'))) {
        return profile.dictionary.integer('N')!;
      }
    }
    if (family == 'DeviceN' && space.values.length > 1) {
      final PdfValue names = resolve?.call(space.values[1]) ?? space.values[1];
      if (names is PdfArray && names.values.isNotEmpty) {
        return names.values.length;
      }
    }
  }
  throw const PdfUnsupportedException(message: 'Cannot determine inline image color-space sample count.');
}

/// Skips JPEG marker segments and entropy bytes until the actual EOI marker.
int _jpegLength(Uint8List bytes) {
  if (bytes.length < 2 || bytes[0] != 255 || bytes[1] != 216) {
    throw const FormatException('Invalid inline JPEG header.');
  }
  int position = 2;
  bool entropy = false;
  while (position < bytes.length) {
    if (bytes[position++] != 255) {
      if (!entropy) {
        throw const FormatException('Invalid inline JPEG marker.');
      }
      continue;
    }
    while (position < bytes.length && bytes[position] == 255) {
      position++;
    }
    if (position >= bytes.length) {
      break;
    }
    final int marker = bytes[position++];
    if (marker == 217) {
      return position;
    }
    if ((entropy && marker == 0) || (marker >= 208 && marker <= 215) || marker == 1) {
      continue;
    }
    if (position + 2 > bytes.length) {
      break;
    }
    final int length = bytes[position] * 256 + bytes[position + 1];
    if (length < 2 || position + length > bytes.length) {
      break;
    }
    position += length;
    entropy = marker == 218;
  }
  throw const FormatException('Truncated inline JPEG image.');
}
