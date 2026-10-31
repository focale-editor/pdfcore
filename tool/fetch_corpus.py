#!/usr/bin/env python3
"""Fetch this kit's pinned external corpus, or verify already downloaded files."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def fetch(entry, directory, verify_only):
    """Check bounded bytes and their checksum before replacing a local fixture."""
    relative = Path(entry['file'])
    if relative.is_absolute() or '..' in relative.parts:
        raise ValueError(f"Invalid corpus path: {relative}")
    target = directory / relative
    data = target.read_bytes() if target.is_file() else None
    valid = data is not None and len(data) == entry['size'] and hashlib.sha256(data).hexdigest() == entry['sha256']
    if valid:
        return entry['file']
    if verify_only:
        raise ValueError(f"Missing or changed fixture: {entry['file']}")
    with urllib.request.urlopen(entry['url'], timeout=60) as response:
        data = response.read(entry['size'] + 1)
    if len(data) != entry['size'] or hashlib.sha256(data).hexdigest() != entry['sha256']:
        raise ValueError(f"Corpus checksum mismatch: {entry['file']}")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    return entry['file']


def main():
    """Resolve the manifest relative to this package, independently of the cwd."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify-only', action='store_true', help='Check local files without network access or writes')
    parser.add_argument('--manifest', type=Path, default=ROOT / 'test/corpus/manifest.json', help='Pinned manifest to fetch or verify')
    parser.add_argument('--directory', type=Path, default=ROOT / 'test/corpus/files', help='Destination for paths within the manifest')
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        results = list(pool.map(lambda entry: fetch(entry, args.directory, args.verify_only), manifest['files']))
    print(f'{ROOT.name}: verified {len(results)} files')


if __name__ == '__main__':
    main()
