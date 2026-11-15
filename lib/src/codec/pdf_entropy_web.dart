import 'dart:js_interop';
import 'dart:typed_data';

/// Uses the actual global receiver in browsers, workers and modern Node.
///
/// Dart's JS Random.secure reads self.crypto, which package:test's Node wrapper
/// exposes through a different receiver. Node 22 rejects that getter invocation.
@JS('globalThis.crypto')
external _Crypto get _crypto;

/// Minimal Web Crypto binding shared by JavaScript and WebAssembly builds.
extension type _Crypto(JSObject _) implements JSObject {
  /// Fills an integer array with cryptographically secure bytes.
  external JSUint8Array getRandomValues(JSUint8Array bytes);
}

/// Obtains fresh system entropy; no insecure fallback is permitted.
Uint8List secureRandomBytes(int length) => _crypto.getRandomValues(Uint8List(length).toJS).toDart;
