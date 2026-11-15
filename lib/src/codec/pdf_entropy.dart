import 'dart:math';
import 'dart:typed_data';

/// Obtains fresh operating-system entropy for PDF keys, salts and IVs.
Uint8List secureRandomBytes(int length) {
  final Random random = Random.secure();
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}
