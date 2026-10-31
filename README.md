<p align="center">
  <img src="screenshots/overview.png" alt="PdfCore package illustration" width="180">
</p>

# PdfCore

Read, inspect, edit and write PDF documents in Dart.

PdfCore gives editors access to pages, vector paths, text, images, reusable forms
and resources while retaining PDF data they do not change. It is pure Dart,
without Flutter or a native PDF engine, and uses Focale's ZCodec for compression.

## Installation

Use the sibling checkout while PdfCore is unpublished:

```yaml
dependencies:
  pdfcore:
    path: ../FocalePackages/PdfCore
```

Adjust the path to your project. The package uses the same SDK, lint and release
configuration conventions as the Focale kits.

## Quick start

Open a document, replace text using its existing font, and save the result:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:pdfcore/pdfcore.dart';

final PdfDocument document = const PdfCodec().decode(
  await File('input.pdf').readAsBytes(),
);
final PdfProgram program = PdfProgram.fromPage(
  document: document,
  pageIndex: 0,
);
final PdfProgram changed = program.withText(
  runIndex: 0,
  text: 'Updated copy',
);
final PdfDocument edited = document.edited((editor) {
  editor.setPageProgram(pageIndex: 0, program: changed);
});
final Uint8List bytes = const PdfCodec().encode(edited);
await File('output.pdf').writeAsBytes(bytes, flush: true);
```

The input page must contain a text run with a supported font mapping and the
replacement characters. Unsupported conversions throw `PdfUnsupportedException`;
encoded glyph bytes remain accessible. See the self-contained runnable
[creation and editing example](example/pdfcore_example.dart) and the
[image, annotation and XMP example](example/pdfcore_editing.dart).

`PdfCodec` implements `Codec<PdfDocument, List<int>>`. Documents, programs,
resources and returned collections are immutable. `withText`, `withPath`,
`withSamples` and `withOperations` return copies. `document.edited(...)` uses an
isolated `PdfEditor`; its snapshots can be retained for undo/redo. A retained
editor can group synchronous operations with `transaction(...)`, which restores
the previous snapshot if the group throws.

## Common tasks

| Goal | API |
| --- | --- |
| Inspect editable page content | `PdfProgram.fromPage(...)` |
| Read or replace text | `program.textRuns`, `program.withText(...)` |
| Work with font-encoded bytes | `run.strings`, `program.withEncodedText(...)` |
| Read or replace vector geometry | `program.paths`, `program.withPath(...)` |
| Edit transforms, paint, clipping or extensions | `program.operations`, `program.replace(...)` |
| Edit images and reusable artwork | `PdfImage`, `PdfForm` |
| Replace packed pixels while retaining masks and color attributes | `image.withSampleData(...)` |
| Replace compressed image bytes and matching attributes | `image.withEncodedData(...)` |
| Commit form instructions and resources together | `form.withProgram(...)` |
| Replace one image/form invocation | `editor.replaceXObjectUse(...)` |
| Update page resources without changing other pages | `editor.setPageResource(...)` |
| Commit content and resource bindings together | `editor.setPageProgram(...)` |
| Insert, copy, import, reorder or remove pages | `insertPage`, `duplicatePage`, `importPages`, `movePage`, `removePage` |
| Change page bounds and display rotation | `setPageBox`, `setPageRotation` |
| Read and edit typed annotations | `pageAnnotationObjects`, `setPageAnnotationObjects`, `PdfAnnotation.withText(...)` |
| Inspect or replace raw annotation bindings | `pageAnnotations`, `setPageAnnotations` |
| Edit metadata or document-level features | `setInformation`, `setMetadata`, `setCatalogEntries`, `replaceObject` |
| Create fonts, images, forms and transparency state | `PdfResources` |

Page content and resource replacements are detached from shared objects. A
replacement resource name affects all uses on that page; `replaceXObjectUse`
changes just one invocation. `replaceObject` deliberately updates all references
to the specified object. Unknown dictionaries, operators and encoded streams are
retained, and unsupported stream filters can be written without decoding them.

## Editing and rendering expectations

A PDF stores a graphics program, not necessarily the original application's
layers, paragraphs or editable shapes. PdfCore edits that program and its resources;
it does not reconstruct an Illustrator document or render an application scene.
Rendering, font embedding/shaping, layout and color management remain host work.

Unicode editing supports ToUnicode maps, WinAnsi/StandardEncoding and pinned
Adobe Glyph List Differences mappings. Replacement text must use existing mapped glyph codes.
Text positioning and raw TJ arrays remain available for hosts that provide
shaping. A replacement run does not reflow a paragraph.

Duplicate dictionary keys remain invalid by default. A host may explicitly allow
selected keys with `PdfCodec(duplicateKeys: {'Group'})`; the last occurrence wins,
with the same parsing budgets. Other duplicate keys still fail.

The codec handles classic, stream and hybrid cross references, object streams,
incremental input revisions and inherited page attributes. Inline images with
raw samples or Flate, LZW, ASCIIHex, ASCII85, RunLength and JPEG boundaries are
editable. Other inline boundaries fail explicitly rather than guess where binary
data ends. Original raw content is still preservable.

Encrypted documents are rejected. Saving writes a full revision and invalidates
signatures and old byte ranges. Page-tree edits do not repair navigation,
page labels, tagging or AcroForm trees. Cross-document imports reject structures
that need a document-wide merge policy. Removing content is **not secure
redaction**: old and unreferenced objects remain preserved.

See the [technical reference](docs/PDF.md) for exact contracts and limits.

## More documentation

- [PDF technical reference](docs/PDF.md)
- [Creation and editing example](example/pdfcore_example.dart)
- [Images, annotations and metadata](example/pdfcore_editing.dart)
- [Validation evidence](docs/VALIDATION.md)
- [Contributing](CONTRIBUTING.md)

## Development

```sh
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze
dart test
dart test --platform node
```

The [external corpus](test/corpus/README.md) includes reproducible QPDF and Poppler
checks for program rewrites and actual edits. Tests run offline by default.
No application integration, publication or complete PDF conformance is implied
by package validation.

---

Built for **[Focale](https://focale-editor.app)**, an advanced local image editor. Discover what these packages make possible in a real creative workflow.
