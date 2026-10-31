part of 'package:pdfcore/src/editing/pdf_editor.dart';

/// An annotation snapshot retaining its appearance and unknown attributes.
final class PdfAnnotation {
  /// Annotation entries, including its subtype, rectangle and appearances.
  final PdfDictionary dictionary;

  /// Existing object identifier, retained when updating the owning page.
  final PdfReference? reference;

  /// Wraps annotation data without rendering its appearance stream.
  const PdfAnnotation({required this.dictionary, this.reference});

  /// Replaces human-readable content while preserving appearance data.
  ///
  /// Hosts must update AP separately when its appearance displays this text.
  PdfAnnotation withText({required String text}) => PdfAnnotation(
    dictionary: dictionary.copyWith(values: {'Contents': PdfString.text(text: text)}),
    reference: reference,
  );

  /// Replaces the rectangle in PDF coordinates without modifying its appearance.
  PdfAnnotation withBounds({required PdfArray bounds}) {
    PdfResources.validateBox(bounds, allowEmpty: true);
    return withProperties(values: {'Rect': bounds});
  }

  /// Replaces selected properties, preserving entries unknown to the host.
  PdfAnnotation withProperties({Map<String, PdfValue> values = const {}, Set<String> remove = const {}}) => PdfAnnotation(
    dictionary: dictionary.copyWith(values: values, remove: remove),
    reference: reference,
  );
}

/// Page-local annotation editing with stable references for replies and links.
extension PdfAnnotationEditing on PdfEditor {
  /// Reads annotations in page order, including their original identifiers.
  List<PdfAnnotation> pageAnnotationObjects({required int pageIndex}) {
    final PdfValue value = _document.resolve(_document.pages[pageIndex].dictionary['Annots'] ?? const PdfNull());
    final List<PdfValue> entries = switch (value) {
      PdfNull() => [],
      PdfArray(:final values) => values,
      _ => throw const FormatException('Expected an annotation array.'),
    };
    return List.unmodifiable(entries.map((entry) => PdfAnnotation(dictionary: _document.dictionary(entry), reference: entry is PdfReference ? entry : null)));
  }

  /// Replaces a page's annotation list, preserving existing annotation identities.
  ///
  /// Use annotations read from this page or new values without a reference.
  /// Widget edits require coordinating AcroForm data and use the object API.
  /// Appearance streams are caller-owned; changing Contents does not render AP.
  void setPageAnnotationObjects({required int pageIndex, required List<PdfAnnotation> annotations}) {
    final List<PdfAnnotation> before = pageAnnotationObjects(pageIndex: pageIndex);
    final Map<PdfReference, PdfDictionary> existing = {
      for (final PdfAnnotation annotation in before)
        if (annotation.reference case final PdfReference reference) reference: annotation.dictionary,
    };
    final Set<PdfReference> reused = {};
    for (final PdfAnnotation annotation in annotations) {
      final PdfReference? reference = annotation.reference;
      if (reference != null && (!existing.containsKey(reference) || !reused.add(reference))) {
        throw ArgumentError('Annotation references must belong to this page and occur once.');
      }
      if (annotation.dictionary.name('Subtype') == null) {
        throw const FormatException('An annotation requires a Subtype.');
      }
      PdfResources.validateBox(_document.resolve(annotation.dictionary['Rect'] ?? const PdfNull()), allowEmpty: true);
      if (annotation.dictionary.name('Subtype') == 'Widget' && (reference == null || !identical(annotation.dictionary, existing[reference]))) {
        throw const PdfUnsupportedException(message: 'Widget editing requires coordinating the AcroForm field tree.');
      }
    }
    for (final PdfAnnotation old in before) {
      if (old.dictionary.name('Subtype') == 'Widget' && !annotations.any((value) => identical(value.dictionary, old.dictionary))) {
        throw const PdfUnsupportedException(message: 'Widget removal requires coordinating the AcroForm field tree.');
      }
    }
    final _PdfGraph edit = _PdfGraph(document: _document);
    if (_document.pages[pageIndex].reference == null) {
      edit.setPages(_document.pages);
    }
    final PdfReference page = edit.build().pages[pageIndex].reference!;
    final List<PdfValue> references = [];
    for (final PdfAnnotation annotation in annotations) {
      final PdfDictionary value = annotation.dictionary.copyWith(
        values: {
          'Type': PdfName(value: 'Annot'),
          'P': page,
        },
      );
      final PdfReference reference = annotation.reference ?? edit.add(value);
      edit.objects[reference] = value;
      references.add(reference);
    }
    edit.objects[page] = (edit.objects[page]! as PdfDictionary).copyWith(values: {'Annots': PdfArray(values: references)});
    _document = edit.build();
  }
}
