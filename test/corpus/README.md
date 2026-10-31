# PdfCore external corpus

The manifest pins 42 internet fixtures with URL, revision, size, SHA-256,
license and expected outcome. 3 are deliberate rejection cases. Run the fetcher and checker from this package:

```sh
python3 tool/fetch_corpus.py
dart run tool/check_corpus.dart
```

`files/` and `output/` are ignored and excluded from publication. The checker
fails on missing files and unexpected outcomes; it does not silently skip
external coverage. Ordinary `dart test` stays offline and independent of this
corpus. See the [technical reference](../../docs/PDF.md).

Decoded documents are written under `output/` for independent validation.
Source works are not redistributed. Consult each manifest license before
copying third-party artwork elsewhere.

## Editable program and resource validation

After the corpus fetch above, run:

```sh
dart run tool/check_editing_corpus.dart
python3 -m venv /tmp/pdfcore-qa
/tmp/pdfcore-qa/bin/pip install -r tool/requirements-interop.txt
/tmp/pdfcore-qa/bin/python tool/verify_editing.py
/tmp/pdfcore-qa/bin/python tool/verify_editing_features.py
```

The Python checks require system Poppler at `/usr/bin/pdftoppm` and
`/usr/bin/pdftotext`. The first
check compares every edited page program to the original render (using the
manifest's QPDF interpretation for the incremental-deletion exception). The
second independently creates source and expected PDFs, performs actual text,
path, image, form, inline-image and metadata edits, and compares both rendering
and extracted Unicode. It also verifies an unchanged page sharing resources, then runs
`example/pdfcore_editing.dart` and compares its actual edits against another
independently authored reference, including annotation identity, private data and
XMP presence.

`output/editing/report.json`, `interop.json` and `features.json` record outcomes.
Unsupported program boundaries are listed as opaque preservation; they are not
counted as rewritten editable pages. Missing sources or any unexpected parse,
syntax, extraction or rendering difference fails the tools. Fixtures generated
for the feature check use only synthetic graphics and standard PDF fonts.

To check the existing downloads without network access or rewriting files:

```sh
python3 tool/fetch_corpus.py --verify-only
```

## Expanded compatibility corpus

`expanded_manifest.json` adds 320 fixtures: 200 from veraPDF/veraPDF-corpus
(CC BY 4.0) and 120 from qpdf/qpdf (Apache-2.0). The manifest attributes each
repository, pins its revision and retains a license URL, source URL, byte length
and SHA-256 for every file. Files were selected deterministically by path hash
from upstream PDFs below 2 MB. They include deliberate conformance failures,
malformed input and encryption; a filename containing `fail` is not itself an
expected decoder rejection.

```sh
python3 tool/fetch_corpus.py --manifest test/corpus/expanded_manifest.json --directory test/corpus/files/expanded
python3 tool/fetch_corpus.py --manifest test/corpus/expanded_manifest.json --directory test/corpus/files/expanded --verify-only
```

`hostResult`, `hostStage` and `hostReason` describe Focale's editable adapter,
not PDF/A conformance. The host checks these exact outcomes, native persistence
and unchanged-page preservation. See Focale's `docs/formats/pdf-validation.md` for the test
command and independent render workflow. Downloaded artwork remains ignored
and excluded from publication; retain upstream attribution if redistributing it.

The October 27, 2026 host run accepts 252 entries and explicitly rejects 68.
This is admission and persistence coverage, not a claim of PDF/A conformance.
