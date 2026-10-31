# PDF document reference

## Model and ownership

`PdfDocument` owns an immutable map from `PdfReference` to `PdfValue` and an
effective trailer. Concrete values represent null, booleans, finite numbers,
names, byte strings, arrays, dictionaries, references and encoded streams.
Input arrays/maps/bytes are copied; returned byte views and collections are
read-only. `PdfDictionary.copyWith` replaces entries and can remove named keys.
`PdfDocument.copyWith` replaces complete graph components.

Names store decoded Latin-1 bytes. `PdfString` stores arbitrary bytes;
`PdfString.text` creates UTF-16BE text and the `text` getter recognizes UTF-16BE,
UTF-8 BOM and PDFDocEncoding. Font-encoded text in content streams is not
necessarily PDFDocEncoding; preserve its bytes until a font-aware host decodes it.

`resolve` detects reference cycles. Undefined references produce `PdfNull`, as
specified by PDF. `dictionary` rejects non-dictionaries. Page traversal validates
catalog and page-tree types, rejects repeated/cyclic leaves, and carries
Resources, MediaBox, CropBox and Rotate inheritance. `pageContent` concatenates
stream bytes exactly, including producers that split tokens across streams.

## Reader

`PdfFilters.encodeAscii85` shares the PDF/PostScript ASCII85 encoder with native
Illustrator binary records. It writes the `~>` terminator, omits `<~`, handles
zero groups and partial final groups, and bounds both input and encoded output
with `PdfLimits.maxStreamBytes`.

The reader follows the final `startxref`, then the `Prev` chain. New entries,
including free entries, shadow older revisions. Hybrid `XRefStm` entries override
the corresponding table entries. The section pointer authoritatively locates
an xref stream's own object even when a hybrid producer retained a stale self
entry. Other object-header/xref mismatches fail instead of scanning for repairs.

Stream contents are read using their declared length, never by searching binary
data for `endstream`. Object streams are decoded once with validated headers,
indices and offsets. Length/reference cycles and oversized structural expansion
are rejected. All live indirect objects are retained, including unreferenced
extension objects. Earlier revisions are not retained as independent histories.

Headers 1.0–1.7 and 2.0 are recognized; 2.0 extensions remain generic data rather
than an assertion of all PDF 2.0 semantics. Names before 1.2 treat `#` literally.
Leading junk, non-whitespace after final EOF, duplicate dictionary keys (unless
explicitly allowlisted), invalid
xref metadata and damaged/recoverable PDFs are outside strict decoding.

## Streams and operations

`PdfFilters.decode` and `PdfDocument.decodeStream` implement Flate, ASCIIHex,
ASCII85, RunLength and LZW (EarlyChange 0/1). Flate uses ZCodec. TIFF predictor 2
and PNG predictors 10–15 are supported. Image-specific filters such as DCT, JPX,
JBIG2 and CCITT, and Crypt filters, remain opaque. Unknown filters do not block
preserving the original encoded stream; they do block requested decompression.
External stream files are never fetched.

`PdfContent.decode` provides ordered `PdfOperation` values with raw operands.
It retains unknown operator names and does not execute graphics or interpret
blend modes. `PdfProgram` adds path and text views without flattening the program.
Content operands must be direct non-stream values, including inside dictionaries.

`PdfOperation.image` holds a complete `PdfInlineImage`. Abbreviated dictionary
keys, color-space names and filters are normalized. Raw boundaries use packed
row lengths, including image masks and named resource color spaces. Flate uses
ZCodec's DEFLATE prefix length and validates its zlib checksum. LZW uses the same
bounded decoder as ordinary streams, with EarlyChange 0/1. ASCIIHex, ASCII85 and
RunLength use their actual end markers. JPEG skips marker segments and entropy
escapes before recognizing EOI. Binary `EI` substrings never terminate an image.
CCITT and unknown inline filter boundaries throw `PdfUnsupportedException`;
original raw page streams remain preservable. `ID` consumes exactly one PDF
whitespace byte. Expanded raw/Flate/LZW samples share `maxDecodedBytes` while
parsing a program; individual inflation also obeys `maxStreamBytes`.

## Copy-based editing

`document.edited((editor) { ... })` returns a new immutable document. The source
snapshot remains unchanged, including shared dictionaries and stream payloads.
`PdfEditor.document` exposes the latest snapshot for application history. Each
individual editor method commits only after success. A callback that throws does
not return a partially edited document; a separately retained editor can still
contain its earlier successful operations. Use `editor.transaction(...)` to group
multiple synchronous operations on a retained editor: a thrown exception restores
the snapshot from before the group. Asynchronous callbacks are outside this
synchronous transaction contract.

The editor copies object maps and allocates identifiers unused by both live and
dangling references. This prevents adding a new object from accidentally
resurrecting a formerly null reference. `replaceObject` and `replaceStream` are explicit global
edits; each affects every use of that identifier. `addObject` accepts all PDF value
types. Syntax and feature validation still apply when the result is encoded.

### Pages and resources

`setPageContent` writes a new stream rather than changing shared source streams.
`setPageOperations` serializes instructions; `setPageProgram` commits instructions
and effective resources together. `addPageContent` wraps old and added content
in separate `q`/`Q` scopes; it requires existing balanced graphics state. It is
an overlay/underlay helper, not a repair tool for malformed programs.

`pageResources` materializes inherited bindings. `setPageResource` copies both
the page resource dictionary and the selected category dictionary, leaving other
pages unchanged. It allocates stream resources indirectly. An explicit name
replaces every use of that binding on the page; an omitted name allocates a free
name. `replaceXObjectUse` assigns a fresh name and changes only one `Do` operation.
Deleting a resource does not rewrite operations that still refer to it.

`setPageBox` validates MediaBox, CropBox, BleedBox, TrimBox and ArtBox rectangles;
coordinates remain in PDF user space. `setPageRotation` accepts multiples of 90,
normalizing to 0/90/180/270. `setPageAttributes` exposes other page entries but
reserves Type, Parent, Kids and Count for the page-tree editor. It also validates
explicit box and rotation replacements. Annotation arrays can be read
and replaced; their appearance streams, form values and structure associations
remain explicit object edits, not automatic appearance generation.

`insertPage`, `movePage` and `removePage` rebuild the page tree, preserving page
identifiers and materializing inherited attributes before moving them. Root-tree
custom entries survive; old unreferenced nodes are retained. Removing a page or
content is **not redaction**: old objects and encoded streams remain in the file.
Document-level destinations, page labels, tags and field trees are not repaired.
Callers maintaining those features must edit them as part of the transaction.

`importPages` remaps object identifiers once per operation, preserving shared
resources, cycles and links among the selected pages. Annotation `/P` references
are remapped. The imported source parent tree is excluded. `duplicatePage` uses
the same independent cloning path. Imports reject AcroForm, structure trees,
optional-content catalogs, named destinations, widgets, structure associations,
optional-content bindings, and links outside the selected pages. This prevents
silent loss of document-wide semantics; a caller needing those merges must
supply a higher-level merge policy. Unknown private binary payloads are copied
opaquely and cannot have embedded private object identifiers remapped. A newer
source PDF version is reflected in the destination catalog's `/Version`.

### Vector programs

`PdfProgram.operations` exposes all graphics instructions in sequence:
transforms, path construction/paint, clipping, colors, patterns, shadings,
transparency state, marked content, image/form invocations and extension
operators. `replace(start:, end:, replacement:)` allows arbitrary insertions,
removals and replacements. The caller is responsible for maintaining valid
operator arities and graphics/text scopes in these general edits.

`paths` identifies construction instructions ending in a standard paint or `n`
operator. `withPath` replaces geometry while retaining paint, clipping and
intervening state instructions. Geometry stays in the original user coordinate
system; it is not converted into application geometry. Paths with transformations
interleaved between construction commands must be edited at the operation level.
The helper rejects those replacements rather than move coordinates incorrectly.

```dart
final PdfProgram changed = program.withPath(
  pathIndex: 0,
  commands: [
    PdfOperation(operator: 're', operands: [
      PdfNumber(value: 20), PdfNumber(value: 20),
      PdfNumber(value: 80), PdfNumber(value: 40),
    ]),
  ],
  paintOperator: 'B*',
);
```

### Text and fonts

`textRuns` identifies Tj, TJ, apostrophe and quotation-mark instructions. It
tracks font selections through Tf, ExtGState Font and q/Q, including font state
that persists between text objects. Text matrices, size, rise, spacing, render
mode and TJ adjustments stay available as original operations. It does not
infer words, paragraphs or spaces from glyph positions. Form contents have
their own resource scope and are inspected through `PdfForm.program`.

`PdfFont.read` supports bounded ToUnicode `bfchar`, consecutive `bfrange` and
array `bfrange` sections. Source codes can contain one to four bytes, including
unambiguous mixed widths; Unicode destinations support surrogate pairs and
ligatures. Inherited CMaps (`usecmap` and stream `UseCMap`) and ambiguous source prefixes are
rejected. Four-byte code-space ranges are inspected without expanding their entire
range; actual mappings remain subject to object and decoded-byte budgets. Without
ToUnicode, explicit WinAnsiEncoding and recognized Differences names are
supported; unknown glyph names remain unmapped. There is no assumed Latin-1
fallback for an unspecified built-in, composite, Symbol or Dingbats encoding.
Hosts can provide a `PdfFont` with an explicit lowercase hexadecimal code map.

`run.text` decodes only known character codes. `withText` inversely encodes the
replacement with existing mapped codes, choosing a valid ligature segmentation.
Missing characters throw; the kit does not insert new glyphs into embedded font
subsets. Embedded font files, metrics and unknown font entries remain preserved.
The host must embed/shape a replacement font when new glyphs are needed.

Replacing a TJ run with different text replaces its numeric spacing adjustments
with one string. Setting identical text retains the original glyph codes, string
segmentation and numeric adjustments.
The operator and quote spacing parameters are retained. This changes text
advance according to the new characters; it does not reflow later lines or
preserve the old text width. Use raw operations for host-generated shaping and
positioning. `withEncodedText` supports edits without a Unicode map.

### Images, reusable forms and other features

`PdfImage` exposes the original stream and decoded sample bytes for supported
filters. Samples are not color-converted; Decode arrays and ICC transforms are
not applied. JPEG, JPEG2000, JBIG2 and CCITT payloads stay accessible as encoded
streams for a host image codec. `withSamples` creates an 8-bit Gray/RGB/CMYK
replacement and clears old color-dependent Decode, masks, matte and alternates;
unrelated metadata survives. Supply new masks/profiles through `withDictionary`.

`withSampleData` instead replaces packed samples without changing dimensions,
sample depth, color interpretation, Decode or masks. It validates per-row padding
and byte length for device, indexed, calibrated, ICCBased, Separation and DeviceN
color spaces; unresolved named spaces require the host to resolve them first.
Filters and predictors are replaced through ZCodec. `withEncodedData` copies new
encoded image bytes with explicit dictionary replacements/removals; the host must
provide matching filters, dimensions and color metadata. No encoded image format
is guessed.

`PdfForm.program` decodes a reusable artwork stream in its local resource scope,
with an explicit inherited-resource fallback for legacy forms. `withOperations`
retains BBox, Matrix, transparency Group and unknown entries. `withProgram`
commits both instructions and resource bindings and requires the same owning
document. `withBounds` changes BBox while preserving encoded bytes. `withResource`
detaches local bindings. To avoid modifying every invocation, replace the page
binding or use `replaceXObjectUse` rather than globally replacing the form object.

`PdfResources` creates standard Latin fonts, device-color sample images, Form
XObjects, rectangles and opacity/blend ExtGState dictionaries. Font creation
uses explicit WinAnsi encoding and does not embed fonts. `PdfStreams.encode`
uses ZCodec and clears stale filters, decode parameters and external-file fields.

Patterns, shadings, soft masks, optional-content groups, annotations, AcroForm,
outlines, links, attachments, XMP and accessibility structure remain available
as editable PDF objects. There is no automatic gradient-to-editor conversion,
form appearance generation, navigation repair, font shaping or accessibility
certification. Keeping their bytes is distinct from interpreting their semantics.

### Typed annotations and metadata

`pageAnnotationObjects` returns `PdfAnnotation` snapshots with original indirect
identifiers. `withText`, `withBounds` and `withProperties` create copied values;
`setPageAnnotationObjects` updates the list, preserves existing identifiers used
by replies, allocates new annotations and binds P to the page. Foreign/repeated
identifiers fail before publishing an edit. Untouched widgets can be retained;
widget changes or removal require coordinating AcroForm and use the explicit
object API. `pageAnnotations`/`setPageAnnotations` remain available for raw binding
edits with application-owned policies.

Annotation AP appearances remain caller-owned: changing Contents or Rect does
not regenerate an appearance stream. Removed annotation objects stay in the
file. Neither annotation nor page removal implements secure redaction.

`setInformation` updates information entries while preserving custom keys.
`setMetadata` replaces the catalog's uncompressed XML/XMP stream. Those stores
are independent; hosts synchronize them when required. Changing PDF ActualText,
accessibility tags or other alternate descriptions also requires corresponding
explicit metadata edits.

## Writer

`PdfEncoder` preserves live object identifiers/generations and encoded stream
bytes, recalculates stream lengths and writes complete classic cross references,
including free entries in gaps. It emits a full file, not an incremental update.
Old revision pointers and structural trailer fields are removed; stale
linearization markers are removed. Original signatures and byte ranges become
invalid. Old opaque xref/object streams may remain as unreferenced preserved
objects, but the new trailer and xref table are authoritative.

PDF 1.0/1.1 files are promoted to 1.2 on output for escaped names. The writer
rejects streams embedded as direct array/dictionary values, duplicate object
numbers, invalid generations and encrypted trailers. References to absent
objects retain PDF null semantics. `PdfDocument.fromPages` supplies a catalog,
page tree and content streams; font/image resources are supplied by the caller.

## Resource policy

| Limit | Default |
| --- | --- |
| Input / output file | 128 MiB |
| Decoded individual stream | 64 MiB |
| Aggregate decoded structural streams / page content | 256 MiB |
| Xref entries / objects / maximum output xref range | 200,000 |
| Syntax, graph, page-tree and revision nesting | 128 |
| Page count | 10,000 |

Integers and real values are constrained to finite JavaScript-safe magnitude
(2^53−1). Xref stream fields wider than six bytes are unsupported. Numeric
exponents are not accepted in PDF syntax; the writer expands small Dart real
values to PDF decimal notation. Invalid limits raise `ArgumentError`; malformed
files raise `FormatException`; unsupported capabilities use its subtype
`PdfUnsupportedException`. ZCodec errors retain their format diagnostics.

## Independent validation

The optional QPDF corpus covers classic/hybrid/stream xrefs, incremental updates,
object streams, indirect lengths, names, images, forms, predictors and inherited
page attributes. Encryption and damaged/cyclic fixtures have expected rejections.
QPDF/pikepdf reopens rewritten files without recovery, checks page counts and
stream payloads, and compares supported decompressed streams. Poppler renders
before and after. One incremental-deletion fixture is compared against QPDF's
canonical interpretation because Poppler's repair of the original resurrects
a deleted content stream. The manifest records this exception explicitly.

### Editing validation

`tool/check_editing_corpus.dart` reserializes accepted corpus page programs using
`PdfProgram` and `PdfEditor`, and moves pages out and back to exercise inherited
attributes. `tool/verify_editing.py` independently reopens the results using
QPDF, rejects syntax warnings and compares all Poppler page renders. Unsupported
program boundaries are reported explicitly as opaque preservation, never counted
as a successful program rewrite.

`tool/verify_editing_features.py` independently authors source and expected PDFs
with pikepdf, invokes the Dart editing API and compares Poppler rendering and
Unicode extraction. It checks real text, path, image, inline-image, Form and
metadata changes, including an untouched page sharing the original resources.
See [validation evidence](VALIDATION.md) and the [corpus guide](../test/corpus/README.md).

## References

- [Adobe PDF 1.7 reference](https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/pdfreference1.7old.pdf)
- [Adobe PDF 1.2 reference](https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/pdfreference1.2.pdf)
- [QPDF source and test suite](https://github.com/qpdf/qpdf)
- [QPDF content-preserving transformations](https://qpdf.readthedocs.io/en/stable/cli.html)
- [ZCodec](https://pub.dev/packages/zcodec)

### Encoded glyph clusters

`PdfFont.decodeGlyphs(bytes)` returns immutable `PdfDecodedGlyph` values with
`code`, `byteLength`, `text` and a lowercase hexadecimal `key`. A glyph's Unicode
text can contain several scalars, and several codes can map to the same text.
Retaining the original code is necessary for PDF widths and outline selection;
`encode(decode(bytes))` can legitimately select a different code when mappings
are non-injective. `decode` retains its previous concatenated-Unicode behavior.
Font outline conversion and rendering remain host responsibilities.

## Explicit legacy compatibility

`PdfCodec.duplicateKeys` defaults to an empty set. Named exceptions accept the
last dictionary occurrence while counting every entry against the parser budget;
Focale permits only `Group` for legacy LaTeX producers. Parsing and canonical
writing retain the object graph and encoded streams, not duplicate syntax.

`PdfFont.read` resolves StandardEncoding, WinAnsi and Adobe Glyph List Differences.
`unicodeForGlyph` also handles Unicode glyph names and underscore-separated
clusters. Unknown names need a host mapping; Type 3 codes are not Unicode.
The pinned AGL data, license and offline generator are under `tool/agl` and
`tool/generate_glyph_names.py`; see `THIRD_PARTY_NOTICES.md`.
