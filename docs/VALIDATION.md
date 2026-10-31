# PdfCore editing validation

Validated locally on 2026-10-27 with Dart 3.13.5, Node 22.23.1, Linux x64,
pikepdf 10.17.0 / QPDF 12.4.2 and Poppler 26.01.0.

## Package checks

- `dart format --output=none --set-exit-if-changed .`: no changes.
- `dart analyze`: no issues.
- `dart test`: 115 passing tests.
- `dart test --platform node`: the same 115 tests pass after JavaScript compilation.
- `dart run example/pdfcore_example.dart`: creates, edits and reopens two pages.
- `dart run example/pdfcore_editing.dart`: edits text, paths, image pixels, a form,
  annotations, information and XMP.
- AiKit, the sibling consumer: clean analysis and 25 passing unit tests.
- No code-generation inputs changed; no build_runner step is needed.

New coverage exercises immutable snapshots, failed-edit atomicity, shared content
and resource isolation, dangling-reference allocation, inherited page attributes,
page insertion/reordering/removal, multi-page imports, selected-page links and
annotation ownership, import rejection policies, image and Form edits, Unicode
and encoded text, unchanged TJ spacing, ligature segmentation, variable-width
CMaps, supplementary Unicode, inline filter boundaries and hostile byte limits.
Additional cases cover grouped rollback, direct-page inheritance on attribute
removal, stream UseCMap rejection, four-byte code-space ranges, mask-preserving
packed samples, encoded images, typed annotation identities and widget policy.

## Independent checks

The original codec corpus retains **42/42 expected outcomes**: 39 accepted files
and three expected rejections. Rejections are not counted as supported files.

The new editing pass decodes and reserializes **229 page programs in all 39
accepted PDFs**. None needed an opaque-program fallback. Multipage documents are
also reordered and restored to exercise page-tree editing. QPDF reopens every
result without recovery or syntax warnings. Poppler renders all 229 pages
identically to their references, with the existing manifest's QPDF canonical
interpretation for `incremental-3.pdf`.

A separate pikepdf-authored two-page fixture and independently authored expected
output verify actual Unicode text replacement, vector geometry, image samples,
a transparent Form XObject, binary inline-image pixels and document information.
Poppler's rendered output and extracted Unicode match the expected edits. The
second page retains its original rendering and shared-resource bytes.

The [machine-readable report](validation/editing.json) records these outcomes.
The [corpus guide](../test/corpus/README.md) provides exact reproduction commands.
External source provenance, revisions, licenses and hashes remain in the existing
[manifest](../test/corpus/manifest.json); downloaded files are not redistributed.

## Boundaries

These are codec and editing API checks, not complete PDF conformance or proof of
universal visual editing. The package does not implement rendering, font shaping,
font-subset expansion, arbitrary embedded font-encoding recovery, automatic form
appearances or document-wide navigation/tagging repair. Unknown data remains
available as PDF objects; specific unsupported interpretations fail explicitly.

All results above were rerun on the reconciled shared PdfCore checkout.

No Focale UI integration, browser/device run, hosted CI, package publication or
Store/deployment operation was performed. Node tests validate JavaScript execution,
not a browser application.

The validation above predates the package-presentation harmonization. Package
metadata now links to Focale and declares the illustration. The technical
reference retains the sibling kits' `docs` layout. Publication and a standalone
repository remain separate from local package validation.
