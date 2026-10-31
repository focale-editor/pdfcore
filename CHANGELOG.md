# 📰 PdfCore changelog

## Unreleased

* Add an opt-in duplicate dictionary key allowlist, preserving strict defaults.
* Resolve StandardEncoding and pinned Adobe Glyph List names and Unicode clusters.

* Add immutable editing transactions and copy-based page program edits.
* Edit paths, font-encoded and Unicode text, image samples, Form XObjects,
  page resources, annotations, geometry and document information.
* Insert, import, duplicate, reorder and remove pages with bounded object
  remapping and explicit document-wide merge limitations.
* Parse and write binary inline images using raw or filter-defined boundaries.
* Add bounded ToUnicode maps, WinAnsi/Differences conversion and ZCodec encoding.
* Add grouped rollback, typed annotation identity preservation, XMP editing,
  packed sample replacement retaining masks and encoded image replacement.
* Validate edits on Dart VM/Node and independently with QPDF and Poppler.

## 0.1.0

- Initial portable document codec, examples, bounded parsing, and tests.
