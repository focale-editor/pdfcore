import 'dart:typed_data';

import 'package:pdfcore/src/codec/pdf_content.dart';
import 'package:pdfcore/src/codec/pdf_filters.dart';
import 'package:pdfcore/src/editing/pdf_program.dart';
import 'package:pdfcore/src/editing/pdf_resources.dart';
import 'package:pdfcore/src/editing/pdf_streams.dart';
import 'package:pdfcore/src/model/pdf_document.dart';
import 'package:pdfcore/src/model/pdf_value.dart';

/// An editable image XObject, including opaque compressed image payloads.
final class PdfImage {
  /// Original stream and image interpretation dictionary.
  final PdfStream stream;

  /// Graph that owns masks, profiles and indirect parameters.
  final PdfDocument document;

  /// Requires an image XObject without decoding its pixels.
  PdfImage({required this.stream, required this.document}) {
    if (stream.dictionary.name('Subtype') != 'Image') {
      throw const FormatException('Expected an image XObject.');
    }
  }

  /// Width in samples, resolving indirect parameters.
  int get width => _integer('Width');

  /// Height in samples, resolving indirect parameters.
  int get height => _integer('Height');

  /// Decompresses supported filters without applying color or Decode mappings.
  ///
  /// JPEG, JPEG2000, JBIG2 and CCITT payloads stay available through [stream].
  /// Hosts can decode those with their image codecs when pixels are required.
  Uint8List get samples => document.decodeStream(stream);

  /// Replaces raw samples with a Gray/RGB/CMYK 8-bit image by copy.
  ///
  /// Unknown metadata and interpolation survive. Color-dependent Decode,
  /// masks, alternates and matte entries are removed because they describe the
  /// old pixels; supply replacements explicitly through [withDictionary].
  PdfImage withSamples({required List<int> samples, int? width, int? height, String colorSpace = 'DeviceRGB', bool compress = true}) {
    final PdfStream replacement = PdfResources.image(width: width ?? this.width, height: height ?? this.height, samples: samples, colorSpace: colorSpace, compress: compress, limits: document.limits);
    return PdfImage(
      document: document,
      stream: PdfStream(
        dictionary: stream.dictionary.copyWith(
          values: replacement.dictionary.values,
          remove: {'Filter', 'DecodeParms', 'Length', 'F', 'FFilter', 'FDecodeParms', 'DL', 'Decode', 'SMask', 'SMaskInData', 'Mask', 'ImageMask', 'Matte', 'Alternates'},
        ),
        data: replacement.data,
      ),
    );
  }

  /// Replaces encoded pixels and selected dictionary entries in a copy.
  ///
  /// The caller supplies a matching Filter/DecodeParms and keeps masks, sample
  /// depth, color spaces and dimensions coherent. No binary image format is guessed.
  PdfImage withEncodedData({required List<int> bytes, Map<String, PdfValue> values = const {}, Set<String> remove = const {}}) {
    if (bytes.length > document.limits.maxFileBytes || bytes.any((byte) => byte < 0 || byte > 255)) {
      throw const FormatException('Invalid or excessive encoded image bytes.');
    }
    return PdfImage(
      stream: PdfStream(
        dictionary: stream.dictionary.copyWith(values: values, remove: {...remove, 'Length'}),
        data: bytes,
      ),
      document: document,
    );
  }

  /// Replaces decoded samples while retaining size, masks and color attributes.
  ///
  /// Supply the packed scanline samples required by BitsPerComponent and the
  /// current ColorSpace. Filters and predictor settings are replaced together.
  PdfImage withSampleData({required List<int> samples, bool compress = true}) {
    final bool mask = switch (document.resolve(stream.dictionary['ImageMask'] ?? const PdfNull())) {
      PdfBoolean(value: true) => true,
      _ => false,
    };
    final PdfValue depth = document.resolve(stream.dictionary['BitsPerComponent'] ?? const PdfNull());
    final int bits = mask
        ? 1
        : depth is PdfNumber
        ? depth.integer
        : 0;
    final int components = mask ? 1 : _components();
    if (![1, 2, 4, 8, 16].contains(bits) || width > document.limits.maxStreamBytes || height > document.limits.maxStreamBytes) {
      throw const FormatException('Invalid or excessive image dimensions or depth.');
    }
    final int rowBytes = (width * components * bits + 7) ~/ 8;
    if (rowBytes > document.limits.maxStreamBytes || rowBytes * height > document.limits.maxStreamBytes || samples.length != rowBytes * height) {
      throw const FormatException('Image samples do not match its dimensions and color space.');
    }
    return PdfImage(
      stream: PdfStreams.encode(bytes: samples, dictionary: stream.dictionary, compress: compress, limits: document.limits),
      document: document,
    );
  }

  /// Determines stored sample components without applying a color conversion.
  int _components() {
    final PdfValue space = document.resolve(stream.dictionary['ColorSpace'] ?? const PdfNull());
    if (space is PdfName) {
      switch (space.value) {
        case 'DeviceGray':
          return 1;
        case 'DeviceRGB':
          return 3;
        case 'DeviceCMYK':
          return 4;
      }
    }
    if (space is PdfArray && space.values.isNotEmpty) {
      final PdfValue family = document.resolve(space.values.first);
      if (family is PdfName) {
        switch (family.value) {
          case 'Indexed' || 'Separation' || 'CalGray':
            return 1;
          case 'CalRGB' || 'Lab':
            return 3;
          case 'ICCBased':
            if (space.values.length > 1) {
              final PdfValue profile = document.resolve(space.values[1]);
              if (profile is PdfStream) {
                final PdfValue count = document.resolve(profile.dictionary['N'] ?? const PdfNull());
                if (count is PdfNumber && [1, 3, 4].contains(count.integer)) {
                  return count.integer;
                }
              }
            }
          case 'DeviceN':
            if (space.values.length > 1) {
              final PdfValue names = document.resolve(space.values[1]);
              if (names is PdfArray && names.values.isNotEmpty) {
                return names.values.length;
              }
            }
        }
      }
    }
    throw const PdfUnsupportedException(message: 'Sample replacement requires a resolved image color space.');
  }

  /// Changes mask, profile, interpolation or other attributes without recoding.
  PdfImage withDictionary(PdfDictionary dictionary) => PdfImage(
    document: document,
    stream: PdfStream(dictionary: dictionary, data: stream.data),
  );

  /// Reads a positive integer image dimension.
  int _integer(String key) {
    final PdfValue value = document.resolve(stream.dictionary[key] ?? const PdfNull());
    if (value is! PdfNumber || value.integer <= 0) {
      throw FormatException('Invalid image /$key.');
    }
    return value.integer;
  }
}

/// An editable Form XObject with a local program and reusable resource scope.
final class PdfForm {
  /// Original stream, including matrix, clipping box and transparency group.
  final PdfStream stream;

  /// Graph supplying referenced resources.
  final PdfDocument document;

  /// Fallback for legacy forms that omit a Resources dictionary.
  final PdfDictionary? inheritedResources;

  /// Requires a Form XObject, retaining its encoded bytes until edited.
  PdfForm({required this.stream, required this.document, this.inheritedResources}) {
    if (stream.dictionary.name('Subtype') != 'Form') {
      throw const FormatException('Expected a Form XObject.');
    }
  }

  /// Effective form-local resources, or the explicit caller fallback.
  PdfDictionary get resources {
    final PdfValue? value = stream.dictionary['Resources'];
    return value == null || document.resolve(value) is PdfNull ? inheritedResources ?? PdfDictionary() : document.dictionary(value);
  }

  /// Decodes this form's instructions without recursively expanding other forms.
  PdfProgram get program => PdfProgram.decode(bytes: document.decodeStream(stream), resources: resources, document: document);

  /// Replaces instructions while preserving matrix, group and custom entries.
  PdfForm withOperations({required Iterable<PdfOperation> operations, bool compress = true}) => PdfForm(
    document: document,
    inheritedResources: inheritedResources,
    stream: PdfStreams.encode(
      bytes: PdfContent.encode(operations, limits: document.limits),
      dictionary: stream.dictionary,
      compress: compress,
      limits: document.limits,
    ),
  );

  /// Replaces instructions and resources, retaining bounds, matrix and grouping.
  PdfForm withProgram({required PdfProgram program, bool compress = true}) {
    if (!identical(program.document, document)) {
      throw ArgumentError('Form content must use the same owning document; import foreign graphs first.');
    }
    return PdfForm(
      stream: PdfStreams.encode(
        bytes: program.encode(),
        dictionary: stream.dictionary.copyWith(values: {'Resources': program.resources}),
        compress: compress,
        limits: document.limits,
      ),
      document: document,
      inheritedResources: inheritedResources,
    );
  }

  /// Returns a form with different bounds, preserving its encoded content bytes.
  PdfForm withBounds({required PdfArray bounds}) {
    PdfResources.validateBox(bounds);
    return PdfForm(
      stream: PdfStream(
        dictionary: stream.dictionary.copyWith(values: {'BBox': bounds}),
        data: stream.data,
      ),
      document: document,
      inheritedResources: inheritedResources,
    );
  }

  /// Replaces form-local resources by copy without changing shared dictionaries.
  ///
  /// Streams must already be indirect objects, allocated through PdfEditor.
  PdfForm withResource({required String category, required String name, required PdfValue value}) {
    if (value is PdfStream) {
      throw const FormatException('Allocate a form resource stream as an indirect object first.');
    }
    final PdfValue? old = resources[category];
    final PdfDictionary group = old == null || document.resolve(old) is PdfNull ? PdfDictionary() : document.dictionary(old);
    return withDictionary(
      stream.dictionary.copyWith(
        values: {
          'Resources': resources.copyWith(
            values: {
              category: group.copyWith(values: {name: value}),
            },
          ),
        },
      ),
    );
  }

  /// Replaces form attributes while retaining its original encoded content.
  PdfForm withDictionary(PdfDictionary dictionary) => PdfForm(
    document: document,
    inheritedResources: inheritedResources,
    stream: PdfStream(dictionary: dictionary, data: stream.data),
  );
}

/// Reports XObject types without interpreting application-private streams.
String pdfXObjectType(PdfValue value) => switch (value) {
  PdfStream(:final dictionary) => dictionary.name('Subtype') ?? (throw const FormatException('XObject has no Subtype.')),
  _ => throw const PdfUnsupportedException(message: 'Expected a stream XObject.'),
};
