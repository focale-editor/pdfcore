import 'dart:typed_data';

import 'package:pdfcore/src/codec/pdf_content.dart';
import 'package:pdfcore/src/codec/pdf_filters.dart';
import 'package:pdfcore/src/editing/pdf_font.dart';
import 'package:pdfcore/src/model/pdf_document.dart';
import 'package:pdfcore/src/model/pdf_value.dart';

/// An immutable editable PDF graphics program with its resource context.
///
/// Operations retain their order, clipping, marked content, transparency and
/// unknown extensions. This model does not flatten graphics into a scene.
final class PdfProgram {
  /// Ordered content instructions, including inline images.
  final List<PdfOperation> operations;

  /// Effective resources in this page or Form XObject's scope.
  final PdfDictionary resources;

  /// Owning graph used to resolve font and other indirect resources.
  final PdfDocument document;

  /// Copies a program's instruction list.
  PdfProgram({required Iterable<PdfOperation> operations, required this.resources, required this.document}) : operations = List.unmodifiable(operations);

  /// Reads a page, resolving its inherited resources and inline color spaces.
  factory PdfProgram.fromPage({required PdfDocument document, required int pageIndex}) {
    final PdfPage page = document.pages[pageIndex];
    final PdfValue? value = page.inherited['Resources'];
    final PdfDictionary resources = value == null || document.resolve(value) is PdfNull ? PdfDictionary() : document.dictionary(value);
    return PdfProgram.decode(bytes: document.pageContent(page), resources: resources, document: document);
  }

  /// Decodes page or form bytes in a specified resource scope.
  factory PdfProgram.decode({required List<int> bytes, required PdfDictionary resources, required PdfDocument document}) {
    final PdfValue? spaces = resources['ColorSpace'];
    return PdfProgram(
      operations: PdfContent.decode(bytes, limits: document.limits, colorSpaces: spaces == null || document.resolve(spaces) is PdfNull ? null : document.dictionary(spaces), resolve: document.resolve),
      resources: resources,
      document: document,
    );
  }

  /// Encodes all instructions, including untouched unknown operations.
  Uint8List encode() => PdfContent.encode(operations, limits: document.limits);

  /// Replaces an instruction range; callers control graphics-state semantics.
  PdfProgram replace({required int start, required int end, required Iterable<PdfOperation> replacement}) {
    RangeError.checkValidRange(start, end, operations.length);
    return PdfProgram(operations: [...operations.take(start), ...replacement, ...operations.skip(end)], resources: resources, document: document);
  }

  /// Returns one resource from the current scope, preserving PDF null semantics.
  PdfValue resource({required String category, required String name}) {
    final PdfValue? group = resources[category];
    if (group == null || document.resolve(group) is PdfNull) {
      return const PdfNull();
    }
    return document.resolve(document.dictionary(group)[name] ?? const PdfNull());
  }

  /// Replaces one scoped resource while retaining unrelated resource bindings.
  ///
  /// Allocate stream values through PdfEditor.addObject before binding them.
  PdfProgram withResource({required String category, required String name, required PdfValue value}) {
    if (value is PdfStream) {
      throw const FormatException('PDF resource streams must be indirect objects.');
    }
    final PdfValue? old = resources[category];
    final PdfDictionary group = old == null || document.resolve(old) is PdfNull ? PdfDictionary() : document.dictionary(old);
    return PdfProgram(
      operations: operations,
      resources: resources.copyWith(
        values: {
          category: group.copyWith(values: {name: value}),
        },
      ),
      document: document,
    );
  }

  /// Finds each painted or clipping path without dropping intervening state.
  List<PdfPathObject> get paths {
    final List<PdfPathObject> result = [];
    final List<int> commands = [];
    for (int index = 0; index < operations.length; index++) {
      final PdfOperation operation = operations[index];
      if (_pathArity[operation.operator] case final int arity) {
        _numbers(operation, arity);
        commands.add(index);
      } else if (_paint.contains(operation.operator)) {
        if (operation.operands.isNotEmpty) {
          throw const FormatException('Path paint operators cannot have operands.');
        }
        if (commands.isNotEmpty) {
          result.add(PdfPathObject._(commandIndices: commands, paintIndex: index, operations: operations));
          commands.clear();
        }
      }
    }
    if (commands.isNotEmpty) {
      throw const FormatException('Content ends with an unterminated path.');
    }
    return List.unmodifiable(result);
  }

  /// Replaces geometry while preserving paint, clipping and interleaved state.
  ///
  /// Commands stay in PDF user coordinates. When a path changes the current
  /// transformation matrix between construction commands, use [replace] to
  /// edit that program explicitly instead of relocating its geometry.
  PdfProgram withPath({required int pathIndex, required Iterable<PdfOperation> commands, String? paintOperator}) {
    final PdfPathObject path = paths[pathIndex];
    final List<PdfOperation> replacement = commands.toList();
    if (replacement.isEmpty || !['m', 're'].contains(replacement.first.operator)) {
      throw const FormatException('A replacement path must start with m or re.');
    }
    for (final PdfOperation command in replacement) {
      final int? arity = _pathArity[command.operator];
      if (arity == null) {
        throw const FormatException('Replacement geometry contains a non-path operator.');
      }
      _numbers(command, arity);
    }
    if (paintOperator != null && !_paint.contains(paintOperator)) {
      throw ArgumentError.value(paintOperator, 'paintOperator');
    }
    for (int index = path.commandIndices.first; index <= path.commandIndices.last; index++) {
      if (['cm', 'q', 'Q'].contains(operations[index].operator)) {
        throw const PdfUnsupportedException(message: 'Edit paths with interleaved transforms through individual operations.');
      }
    }
    final Set<int> removed = path.commandIndices.toSet();
    return PdfProgram(
      operations: [
        for (int index = 0; index < operations.length; index++) ...[
          if (index == path.commandIndices.first) ...replacement,
          if (!removed.contains(index))
            if (index == path.paintIndex && paintOperator != null) PdfOperation(operator: paintOperator) else operations[index],
        ],
      ],
      resources: resources,
      document: document,
    );
  }

  /// Finds text-show instructions with their effective font and raw strings.
  ///
  /// q/Q and ExtGState Font changes are tracked. Text matrices, spacing, rise,
  /// rendering modes and numeric TJ adjustments remain in the program.
  List<PdfTextRun> get textRuns {
    final List<PdfTextRun> result = [];
    final List<(PdfValue?, String?)> stack = [];
    PdfValue? font;
    String? name;
    bool inText = false;
    for (int index = 0; index < operations.length; index++) {
      final PdfOperation operation = operations[index];
      switch (operation.operator) {
        case 'q':
          if (stack.length >= document.limits.maxDepth) {
            throw const FormatException('PDF graphics-state depth exceeds the limit.');
          }
          stack.add((font, name));
        case 'Q':
          if (stack.isEmpty) {
            throw const FormatException('Unmatched PDF graphics-state restore.');
          }
          (font, name) = stack.removeLast();
        case 'BT':
          if (inText) {
            throw const FormatException('Nested PDF text object.');
          }
          inText = true;
        case 'ET':
          if (!inText) {
            throw const FormatException('Unmatched PDF text object end.');
          }
          inText = false;
        case 'Tf':
          if (operation.operands.length != 2 || operation.operands[0] is! PdfName || operation.operands[1] is! PdfNumber) {
            throw const FormatException('Invalid PDF font selection.');
          }
          name = (operation.operands[0] as PdfName).value;
          font = resource(category: 'Font', name: name);
        case 'gs':
          if (operation.operands.length != 1 || operation.operands.single is! PdfName) {
            throw const FormatException('Invalid PDF graphics-state selection.');
          }
          final PdfValue state = resource(category: 'ExtGState', name: (operation.operands.single as PdfName).value);
          if (state is PdfDictionary && state['Font'] != null) {
            final PdfValue selected = document.resolve(state['Font']!);
            if (selected is! PdfArray || selected.values.length != 2) {
              throw const FormatException('Invalid graphics-state font.');
            }
            font = selected.values.first;
            name = null;
          }
        case 'Tj' || 'TJ' || "'" || '"':
          if (!inText) {
            throw const FormatException('Text-show instruction outside a text object.');
          }
          result.add(PdfTextRun(operationIndex: index, operation: operation, fontName: name, fontValue: font, document: document));
      }
    }
    if (inText || stack.isNotEmpty) {
      throw const FormatException('Unbalanced PDF text or graphics-state scope.');
    }
    return List.unmodifiable(result);
  }

  /// Replaces a text run with characters available in its current font.
  ///
  /// The operator and quote spacing operands survive. TJ adjustments are
  /// replaced by one string; the host may supply a custom TJ array through
  /// [replace] when shaping or exact spacing is required.
  PdfProgram withText({required int runIndex, required String text, PdfFont? font}) {
    final PdfTextRun run = textRuns[runIndex];
    final PdfFont mapping = font ?? run.font;
    if (run.strings.map((string) => mapping.decode(string.bytes)).join() == text) {
      return replace(start: run.operationIndex, end: run.operationIndex + 1, replacement: [run.operation]);
    }
    return withEncodedText(operationIndex: run.operationIndex, bytes: mapping.encode(text));
  }

  /// Replaces encoded glyph bytes without assuming a Unicode mapping.
  PdfProgram withEncodedText({required int operationIndex, required List<int> bytes}) {
    final PdfOperation operation = operations[operationIndex];
    _textStrings(operation);
    if (bytes.any((byte) => byte < 0 || byte > 255)) {
      throw const FormatException('Text contains a non-byte value.');
    }
    final PdfString string = PdfString(bytes: bytes);
    final List<PdfValue> operands = switch (operation.operator) {
      'TJ' => [
        PdfArray(values: [string]),
      ],
      '"' => [...operation.operands.take(2), string],
      _ => [string],
    };
    return replace(start: operationIndex, end: operationIndex + 1, replacement: [operation.withOperands(operands)]);
  }
}

/// A path's geometry locations and terminating paint/clipping instruction.
final class PdfPathObject {
  /// Indices of m/l/c/v/y/h/re instructions in the owning program.
  final List<int> commandIndices;

  /// Index of the S/f/B/n or related terminating instruction.
  final int paintIndex;

  /// Original program, allowing exact inspection of interleaved state.
  final List<PdfOperation> _operations;

  /// Creates a read-only path view.
  PdfPathObject._({required Iterable<int> commandIndices, required this.paintIndex, required this._operations}) : commandIndices = List.unmodifiable(commandIndices);

  /// Construction commands in their original order and coordinate system.
  List<PdfOperation> get commands => List.unmodifiable(commandIndices.map((index) => _operations[index]));

  /// Paint operator, including n for a clipping-only or unpainted path.
  String get paintOperator => _operations[paintIndex].operator;
}

/// One text-show instruction, retaining glyph bytes and positioning adjustments.
final class PdfTextRun {
  /// Index of the instruction in the owning program.
  final int operationIndex;

  /// Original Tj, TJ, apostrophe or quotation-mark instruction.
  final PdfOperation operation;

  /// Resource name selected by Tf, or null for an ExtGState font.
  final String? fontName;

  /// Effective font dictionary or indirect reference, if present.
  final PdfValue? fontValue;

  /// Graph that owns font resources.
  final PdfDocument document;

  /// Creates a validated text-show view.
  PdfTextRun({required this.operationIndex, required this.operation, required this.fontName, required this.fontValue, required this.document}) {
    _textStrings(operation);
  }

  /// Strings as encoded by the font, without TJ numeric spacing adjustments.
  List<PdfString> get strings => List.unmodifiable(_textStrings(operation));

  /// Reads the current font's Unicode mapping, failing explicitly if unavailable.
  PdfFont get font => PdfFont.read(
    document: document,
    value: fontValue ?? (throw const PdfUnsupportedException(message: 'Text has no selected font.')),
  );

  /// Decoded characters, without inferring spaces from numeric positioning.
  String get text {
    final PdfFont mapping = font;
    return strings.map((string) => mapping.decode(string.bytes)).join();
  }
}

/// Path construction arities in the PDF imaging model.
const Map<String, int> _pathArity = {'m': 2, 'l': 2, 'c': 6, 'v': 4, 'y': 4, 'h': 0, 're': 4};

/// Standard path-ending operators, including the obsolete F alias.
const Set<String> _paint = {'S', 's', 'f', 'F', 'f*', 'B', 'B*', 'b', 'b*', 'n'};

/// Requires a numeric operand vector of the expected length.
void _numbers(PdfOperation operation, int count) {
  if (operation.operands.length != count || operation.operands.any((value) => value is! PdfNumber)) {
    throw FormatException('Invalid operands for PDF ${operation.operator}.');
  }
}

/// Validates text-show operands and returns their strings without guessing fonts.
List<PdfString> _textStrings(PdfOperation operation) {
  final List<PdfValue> operands = operation.operands;
  if (operation.operator == 'TJ' && operands.length == 1 && operands.single is PdfArray) {
    final List<PdfValue> values = (operands.single as PdfArray).values;
    if (values.any((value) => value is! PdfString && value is! PdfNumber)) {
      throw const FormatException('TJ accepts only character strings and numeric adjustments.');
    }
    return values.whereType<PdfString>().toList();
  }
  if (['Tj', "'"].contains(operation.operator) && operands.length == 1 && operands.single is PdfString) {
    return [operands.single as PdfString];
  }
  if (operation.operator == '"' && operands.length == 3 && operands[0] is PdfNumber && operands[1] is PdfNumber && operands[2] is PdfString) {
    return [operands[2] as PdfString];
  }
  throw const FormatException('Invalid PDF text-show operands.');
}
