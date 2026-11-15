import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cipherlib/cipherlib.dart';
import 'package:cipherlib/hashlib.dart';
import 'package:pdfcore/src/codec/pdf_entropy.dart' if (dart.library.js_interop) 'package:pdfcore/src/codec/pdf_entropy_web.dart';
import 'package:pdfcore/src/model/pdf_security.dart';
import 'package:pdfcore/src/model/pdf_value.dart';

/// Standard password security, applied before stream filters and object parsing.
///
/// Implements ISO 32000 algorithms 1–7 and the AES-256 revisions 5/6. Keys are
/// owned only by the codec; returned graphs carry provenance, never secrets.
final class PdfSecurityHandler {
  /// Validated encryption parameters, all direct as required by PDF.
  final PdfDictionary _dictionary;

  /// Authenticated file key, never exposed through a document.
  final Uint8List _key;

  /// Credential-free source security metadata.
  final PdfSecurity security;

  /// Whether metadata streams use the default encryption filter.
  final bool _encryptMetadata;

  /// Creates an authenticated handler.
  PdfSecurityHandler._(this._dictionary, this._key, this.security, this._encryptMetadata);

  /// Creates fresh standard AES-256 security using operating-system entropy.
  factory PdfSecurityHandler.create(PdfEncryption options) {
    if (options.ownerPassword.isEmpty) {
      throw ArgumentError('PDF owner password must not be empty.');
    }
    final Uint8List key = randomBytes(32);
    final Uint8List userPassword = _modernPassword(options.userPassword);
    final Uint8List ownerPassword = _modernPassword(options.ownerPassword);
    final Uint8List userSalt = randomBytes(16);
    final Uint8List ownerSalt = randomBytes(16);
    final Uint8List user = Uint8List.fromList([..._modernHash(userPassword, userSalt.sublist(0, 8), const [], 6), ...userSalt]);
    final Uint8List owner = Uint8List.fromList([..._modernHash(ownerPassword, ownerSalt.sublist(0, 8), user, 6), ...ownerSalt]);
    final Uint8List userKey = _modernHash(userPassword, userSalt.sublist(8), const [], 6);
    final Uint8List ownerKey = _modernHash(ownerPassword, ownerSalt.sublist(8), user, 6);
    final int permissions = options.permissions.value;
    final PdfDictionary dictionary = PdfDictionary(
      values: {
        'Filter': PdfName(value: 'Standard'),
        'V': PdfNumber(value: 5),
        'R': PdfNumber(value: 6),
        'Length': PdfNumber(value: 256),
        'P': PdfNumber(value: permissions),
        'EncryptMetadata': PdfBoolean(value: options.encryptMetadata),
        'U': PdfString(bytes: user),
        'O': PdfString(bytes: owner),
        'UE': PdfString(bytes: AES.noPadding(userKey).cbc(Uint8List(16)).encrypt(key)),
        'OE': PdfString(bytes: AES.noPadding(ownerKey).cbc(Uint8List(16)).encrypt(key)),
        'Perms': PdfString(
          bytes: AES.noPadding(key).ecb().encrypt([
            for (int shift = 0; shift < 32; shift += 8) (permissions >> shift) & 255,
            255,
            255,
            255,
            255,
            if (options.encryptMetadata) 84 else 70,
            97,
            100,
            98,
            ...randomBytes(4),
          ]),
        ),
        'StmF': PdfName(value: 'StdCF'),
        'StrF': PdfName(value: 'StdCF'),
        'CF': PdfDictionary(
          values: {
            'StdCF': PdfDictionary(
              values: {
                'CFM': PdfName(value: 'AESV3'),
                'Length': PdfNumber(value: 32),
                'AuthEvent': PdfName(value: 'DocOpen'),
              },
            ),
          },
        ),
      },
    );
    return PdfSecurityHandler._(dictionary, key, PdfSecurity(revision: 6, permissions: permissions, ownerPassword: true), options.encryptMetadata);
  }

  /// Cipher parameters written as an unencrypted indirect object.
  PdfDictionary get dictionary => _dictionary;

  /// Generates independent salts, initialization vectors and file identifiers.
  static Uint8List randomBytes(int length) => secureRandomBytes(length);

  /// Encrypts an indirect object for full-rewrite AES-256 output.
  PdfValue encrypt(PdfValue value) => switch (value) {
    PdfStream(:final dictionary) when dictionary.name('Type') == 'XRef' => value,
    PdfStream(:final dictionary, :final data) => PdfStream(
      dictionary: encrypt(dictionary) as PdfDictionary,
      data: !_encryptMetadata && dictionary.name('Type') == 'Metadata' ? data : _encryptBytes(data),
    ),
    PdfString(:final bytes) => PdfString(bytes: _encryptBytes(bytes)),
    PdfArray(:final values) => PdfArray(values: values.map(encrypt)),
    PdfDictionary(:final values) => PdfDictionary(
      values: {
        for (final MapEntry<String, PdfValue> entry in values.entries)
          entry.key: entry.key == 'Contents' && const ['Sig', 'DocTimeStamp'].contains(value.name('Type')) ? entry.value : encrypt(entry.value),
      },
    ),
    _ => value,
  };

  /// Prefixes a fresh IV and uses standard PKCS#7 padding for each payload.
  Uint8List _encryptBytes(Uint8List bytes) {
    final Uint8List iv = randomBytes(16);
    return Uint8List.fromList([...iv, ...AES.pkcs7(_key).cbc(iv).encrypt(bytes)]);
  }

  /// Authenticates either password, including the empty opening password.
  factory PdfSecurityHandler.authenticate({required PdfDictionary dictionary, required Uint8List identifier, required String password}) {
    if (dictionary.name('Filter') != 'Standard') {
      throw const PdfEncryptionUnsupportedException();
    }
    for (final String name in ['StrF', 'StmF', 'EFF']) {
      if (dictionary[name] != null && dictionary[name] is! PdfName) {
        throw FormatException('Invalid PDF security /$name.');
      }
    }
    final int revision = dictionary.integer('R') ?? 0;
    final int version = dictionary.integer('V') ?? 0;
    if (!switch ((revision, version)) {
      (2, 1) || (3, 2) || (4, 4) || (5, 5) || (6, 5) => true,
      _ => false,
    }) {
      throw const PdfEncryptionUnsupportedException();
    }
    final int permissions = dictionary.integer('P') ?? (throw const FormatException('Missing PDF security permissions.'));
    if (permissions < -2147483648 || permissions > 4294967295) {
      throw const FormatException('Invalid PDF security permissions.');
    }
    final PdfValue? metadata = dictionary['EncryptMetadata'];
    if (metadata != null && metadata is! PdfBoolean) {
      throw const FormatException('Invalid PDF metadata encryption flag.');
    }
    final bool encryptMetadata = metadata is! PdfBoolean || metadata.value;
    final int bits = revision == 2 ? 40 : dictionary.integer('Length') ?? (revision >= 5 ? 256 : 40);
    if (revision >= 5 ? bits != 256 : bits < 40 || bits > 128 || bits % 8 != 0) {
      throw const FormatException('Invalid PDF encryption key length.');
    }
    final ({Uint8List key, bool owner}) authenticated = revision >= 5
        ? _authenticateAes256(dictionary, password, revision, permissions, encryptMetadata)
        : _authenticateLegacy(dictionary, identifier, password, revision, bits ~/ 8, permissions, encryptMetadata);
    final PdfSecurityHandler handler = PdfSecurityHandler._(
      dictionary,
      authenticated.key,
      PdfSecurity(revision: revision, permissions: permissions, ownerPassword: authenticated.owner),
      encryptMetadata,
    );
    // Reject unsupported filters before yielding any partially decoded graph.
    handler._method(dictionary.name('StrF'));
    handler._method(dictionary.name('StmF'));
    handler._method(dictionary.name('EFF') ?? dictionary.name('StmF'));
    return handler;
  }

  /// Decrypts one uncompressed indirect object; embedded objects are plaintext.
  PdfValue decrypt(PdfValue value, PdfReference reference) {
    if (value is PdfStream) {
      if (value.dictionary.name('Type') == 'XRef') {
        return PdfStream(
          dictionary: value.dictionary.copyWith(remove: {'Encrypt'}),
          data: value.data,
        );
      }
      PdfDictionary dictionary = value.dictionary;
      final PdfValue? filters = dictionary['Filter'];
      final List<PdfValue> names = filters is PdfArray ? filters.values : [?filters];
      final int crypt = names.indexWhere((filter) => filter is PdfName && filter.value == 'Crypt');
      String method;
      if (crypt >= 0) {
        if (crypt != 0 || names.skip(1).any((filter) => filter is PdfName && filter.value == 'Crypt')) {
          throw const FormatException('PDF Crypt must be the first and only crypt filter.');
        }
        final PdfValue? parameters = dictionary['DecodeParms'];
        final PdfValue? first = parameters is PdfArray ? (parameters.values.isEmpty ? null : parameters.values.first) : parameters;
        if (first != null && first is! PdfDictionary && first is! PdfNull) {
          throw const FormatException('Invalid PDF Crypt parameters.');
        }
        if (first is PdfDictionary && first['Name'] != null && first['Name'] is! PdfName) {
          throw const FormatException('Invalid PDF Crypt filter name.');
        }
        method = _method(first is PdfDictionary ? first.name('Name') : 'Identity');
        dictionary = dictionary.copyWith(
          remove: {'Filter', 'DecodeParms'},
          values: {
            if (names.length > 1) 'Filter': PdfArray(values: names.skip(1)),
            if (names.length > 1 && parameters is PdfArray) 'DecodeParms': PdfArray(values: parameters.values.skip(1)),
          },
        );
      } else if (!_encryptMetadata && dictionary.name('Type') == 'Metadata') {
        method = 'None';
      } else {
        method = _method(dictionary.name('Type') == 'EmbeddedFile' ? _dictionary.name('EFF') ?? _dictionary.name('StmF') : _dictionary.name('StmF'));
      }
      final Uint8List data = _decryptBytes(value.data, reference, method);
      return PdfStream(
        dictionary: (decrypt(dictionary, reference) as PdfDictionary).copyWith(values: {'Length': PdfNumber(value: data.length)}),
        data: data,
      );
    }
    return switch (value) {
      PdfString(:final bytes) => PdfString(bytes: _decryptBytes(bytes, reference, _method(_dictionary.name('StrF')))),
      PdfArray(:final values) => PdfArray(values: values.map((item) => decrypt(item, reference))),
      PdfDictionary(:final values) => PdfDictionary(
        values: {
          for (final MapEntry<String, PdfValue> entry in values.entries)
            entry.key: entry.key == 'Contents' && const ['Sig', 'DocTimeStamp'].contains(value.name('Type')) ? entry.value : decrypt(entry.value, reference),
        },
      ),
      _ => value,
    };
  }

  /// Resolves an explicitly selected crypt filter, or the revision's default.
  String _method(String? name) {
    if (security.revision < 4) {
      return 'V2';
    }
    if (name == null || name == 'Identity') {
      return 'None';
    }
    final PdfValue? filters = _dictionary['CF'];
    final PdfValue? filter = filters is PdfDictionary ? filters[name] : null;
    if (filter is! PdfDictionary) {
      throw const FormatException('Missing PDF crypt filter.');
    }
    if (filter['CFM'] != null && filter['CFM'] is! PdfName) {
      throw const FormatException('Invalid PDF crypt filter method.');
    }
    final String method = filter.name('CFM') ?? 'None';
    if (method == 'None') {
      return method;
    }
    final int? length = filter.integer('Length');
    if (length != null && length != _key.length) {
      throw const FormatException('Inconsistent PDF crypt filter key length.');
    }
    if (security.revision >= 5 ? method != 'AESV3' : method != 'V2' && method != 'AESV2') {
      throw const PdfEncryptionUnsupportedException();
    }
    if (method == 'AESV2' && _key.length != 16) {
      throw const FormatException('AESV2 requires a 128-bit key.');
    }
    return method;
  }

  /// Derives the object key, then removes RC4 or AES-CBC encryption.
  Uint8List _decryptBytes(Uint8List bytes, PdfReference reference, String method) {
    if (method == 'None') {
      return bytes;
    }
    final Uint8List key = method == 'AESV3'
        ? _key
        : Uint8List.sublistView(
            md5.convert([
              ..._key,
              reference.objectNumber & 255,
              (reference.objectNumber >> 8) & 255,
              (reference.objectNumber >> 16) & 255,
              reference.generation & 255,
              (reference.generation >> 8) & 255,
              if (method == 'AESV2') ...[0x73, 0x41, 0x6c, 0x54],
            ]).bytes,
            0,
            math.min(_key.length + 5, 16),
          );
    if (method == 'V2') {
      return _rc4(key, bytes);
    }
    if (bytes.length < 32 || bytes.length % 16 != 0) {
      throw const FormatException('Invalid PDF AES payload length.');
    }
    final Uint8List clear = AES.noPadding(key).cbc(Uint8List.sublistView(bytes, 0, 16)).decrypt(Uint8List.sublistView(bytes, 16));
    final int padding = clear.last;
    if (padding < 1 || padding > 16 || clear.skip(clear.length - padding).any((byte) => byte != padding)) {
      throw const FormatException('Invalid PDF AES padding.');
    }
    return Uint8List.sublistView(clear, 0, clear.length - padding);
  }
}

/// PDF's fixed 32-byte legacy password padding (ISO 32000-1, algorithm 2).
const List<int> _padding = [
  0x28,
  0xbf,
  0x4e,
  0x5e,
  0x4e,
  0x75,
  0x8a,
  0x41,
  0x64,
  0,
  0x4e,
  0x56,
  0xff,
  0xfa,
  1,
  8,
  0x2e,
  0x2e,
  0,
  0xb6,
  0xd0,
  0x68,
  0x3e,
  0x80,
  0x2f,
  0x0c,
  0xa9,
  0xfe,
  0x64,
  0x53,
  0x69,
  0x7a,
];

/// Requires authentication bytes, accepting bounded Adobe padding when allowed.
Uint8List _bytes(PdfDictionary dictionary, String name, int length, {int? maximumLength}) {
  final PdfValue? value = dictionary[name];
  if (value is! PdfString || value.bytes.length < length || value.bytes.length > (maximumLength ?? length)) {
    throw FormatException('Invalid PDF security /$name.');
  }
  return Uint8List.sublistView(value.bytes, 0, length);
}

/// Compares fixed-length authentication values without early content exits.
bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  int difference = 0;
  for (int index = 0; index < a.length; index++) {
    difference |= a[index] ^ b[index];
  }
  return difference == 0;
}

/// Encodes a legacy password using PDFDocEncoding, never lossy substitutions.
Uint8List _legacyPassword(String password) {
  final Map<int, int> encoding = {
    for (int byte = 0; byte < 256; byte++) PdfString(bytes: [byte]).text.runes.single: byte,
  };
  final List<int> result = [];
  for (final int rune in password.runes.take(32)) {
    final int? byte = encoding[rune];
    if (byte == null || rune == 0xfffd) {
      throw const PdfPasswordException();
    }
    result.add(byte);
  }
  return Uint8List.fromList([...result, ..._padding].take(32).toList());
}

/// Authenticates RC4/AES-128 standard security with user or owner passwords.
({Uint8List key, bool owner}) _authenticateLegacy(PdfDictionary dictionary, Uint8List identifier, String password, int revision, int length, int permissions, bool encryptMetadata) {
  final Uint8List owner = _bytes(dictionary, 'O', 32);
  final Uint8List user = _bytes(dictionary, 'U', 32);
  if (identifier.isEmpty) {
    throw const FormatException('Encrypted PDF requires a file identifier.');
  }
  final Uint8List padded = _legacyPassword(password);
  Uint8List derive(List<int> candidate) {
    Uint8List digest = md5.convert([
      ...candidate,
      ...owner,
      for (int shift = 0; shift < 32; shift += 8) (permissions >> shift) & 255,
      ...identifier,
      if (revision >= 4 && !encryptMetadata) ...[255, 255, 255, 255],
    ]).bytes;
    if (revision >= 3) {
      for (int round = 0; round < 50; round++) {
        digest = md5.convert(Uint8List.sublistView(digest, 0, length)).bytes;
      }
    }
    return Uint8List.sublistView(digest, 0, length);
  }

  bool valid(Uint8List key) {
    Uint8List expected = _rc4(key, revision == 2 ? _padding : md5.convert([..._padding, ...identifier]).bytes);
    if (revision >= 3) {
      for (int round = 1; round <= 19; round++) {
        expected = _rc4(key.map((byte) => byte ^ round).toList(), expected);
      }
    }
    return _equal(expected, revision == 2 ? user : Uint8List.sublistView(user, 0, 16));
  }

  final Uint8List userKey = derive(padded);
  if (valid(userKey)) {
    return (key: userKey, owner: false);
  }
  Uint8List ownerKey = md5.convert(padded).bytes;
  if (revision >= 3) {
    for (int round = 0; round < 50; round++) {
      ownerKey = md5.convert(ownerKey).bytes;
    }
  }
  ownerKey = Uint8List.sublistView(ownerKey, 0, length);
  Uint8List candidate = owner;
  for (int round = revision == 2 ? 0 : 19; round >= 0; round--) {
    candidate = _rc4(ownerKey.map((byte) => byte ^ round).toList(), candidate);
  }
  final Uint8List key = derive(candidate);
  if (!valid(key)) {
    throw const PdfPasswordException();
  }
  return (key: key, owner: true);
}

/// Authenticates AES-256 and verifies its encrypted permission block.
({Uint8List key, bool owner}) _authenticateAes256(PdfDictionary dictionary, String password, int revision, int permissions, bool encryptMetadata) {
  // Acrobat XI pads U/O to 127 bytes. Only their first 48 bytes participate
  // in authentication; treating the padding as hash input breaks real PDFs.
  final Uint8List user = _bytes(dictionary, 'U', 48, maximumLength: 127);
  final Uint8List owner = _bytes(dictionary, 'O', 48, maximumLength: 127);
  final Uint8List userKey = _bytes(dictionary, 'UE', 32);
  final Uint8List ownerKey = _bytes(dictionary, 'OE', 32);
  final Uint8List permissionBlock = _bytes(dictionary, 'Perms', 16);
  // The modern handler consumes at most 127 UTF-8 bytes, including partial code
  // points at that boundary, as required by the PDF key derivation algorithm.
  final Uint8List encoded = _modernPassword(password);
  final bool isOwner = _equal(_modernHash(encoded, owner.sublist(32, 40), user, revision), owner.sublist(0, 32));
  if (!isOwner && !_equal(_modernHash(encoded, user.sublist(32, 40), const [], revision), user.sublist(0, 32))) {
    throw const PdfPasswordException();
  }
  final Uint8List wrappingKey = _modernHash(encoded, (isOwner ? owner : user).sublist(40, 48), isOwner ? user : const [], revision);
  final Uint8List key = AES.noPadding(wrappingKey).cbc(Uint8List(16)).decrypt(isOwner ? ownerKey : userKey);
  final Uint8List clear = AES.noPadding(key).ecb().decrypt(permissionBlock);
  if (!_equal(clear.sublist(0, 12), [for (int shift = 0; shift < 32; shift += 8) (permissions >> shift) & 255, 255, 255, 255, 255, if (encryptMetadata) 84 else 70, 97, 100, 98])) {
    throw const FormatException('PDF encrypted permissions do not match.');
  }
  return (key: key, owner: isOwner);
}

/// Bounded UTF-8 representation shared by password reading and writing.
Uint8List _modernPassword(String password) => Uint8List.fromList(utf8.encode(password.substring(0, math.min(password.length, 128))).take(127).toList());

/// Performs the revision 5 hash or bounded revision 6 strengthening rounds.
Uint8List _modernHash(List<int> password, List<int> salt, List<int> user, int revision) {
  Uint8List digest = sha256.convert([...password, ...salt, ...user]).bytes;
  if (revision == 5) {
    return digest;
  }
  int round = 0;
  int last = 0;
  do {
    final List<int> block = [...password, ...digest, ...user];
    final Uint8List repeated = Uint8List(block.length * 64);
    for (int offset = 0; offset < repeated.length; offset += block.length) {
      repeated.setRange(offset, offset + block.length, block);
    }
    final Uint8List encrypted = AES.noPadding(digest.sublist(0, 16)).cbc(digest.sublist(16, 32)).encrypt(repeated);
    final int selector = encrypted.take(16).fold(0, (sum, byte) => sum + byte) % 3;
    digest = switch (selector) {
      0 => sha256.convert(encrypted).bytes,
      1 => sha384.convert(encrypted).bytes,
      _ => sha512.convert(encrypted).bytes,
    };
    last = encrypted.last;
    round++;
  } while (round < 64 || last > round - 32);
  return Uint8List.sublistView(digest, 0, 32);
}

/// Legacy RC4 used only for reading historical PDF encryption, never new output.
Uint8List _rc4(List<int> key, List<int> input) {
  final Uint8List state = Uint8List.fromList(List.generate(256, (index) => index));
  int other = 0;
  for (int index = 0; index < 256; index++) {
    other = (other + state[index] + key[index % key.length]) & 255;
    final int old = state[index];
    state[index] = state[other];
    state[other] = old;
  }
  final Uint8List output = Uint8List(input.length);
  int index = 0;
  other = 0;
  for (int offset = 0; offset < input.length; offset++) {
    index = (index + 1) & 255;
    other = (other + state[index]) & 255;
    final int old = state[index];
    state[index] = state[other];
    state[other] = old;
    output[offset] = input[offset] ^ state[(state[index] + state[other]) & 255];
  }
  return output;
}
