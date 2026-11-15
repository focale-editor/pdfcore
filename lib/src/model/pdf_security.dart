/// Authentication failed for a standard password-encrypted PDF.
///
/// Retry decoding with a user or owner password. No credential is included in
/// this exception; malformed or unsupported security uses separate exceptions.
final class PdfPasswordException extends FormatException {
  /// Requests a password without exposing authentication material.
  const PdfPasswordException() : super('A valid PDF password is required.');
}

/// A security handler or crypt filter is not supported by this decoder.
final class PdfEncryptionUnsupportedException extends FormatException {
  /// Reports a capability limit, distinct from an incorrect password.
  const PdfEncryptionUnsupportedException() : super('Unsupported PDF encryption.');
}

/// Source security information for an authenticated, decrypted object graph.
///
/// Contains no password or encryption key. Hosts decide how source permission
/// flags affect their UI. Output encryption is selected separately by the encoder.
final class PdfSecurity {
  /// Standard security handler revision, from 2 through 6.
  final int revision;

  /// Source permission bit field as recorded by the encryption dictionary.
  final int permissions;

  /// Whether authentication succeeded using the owner password.
  final bool ownerPassword;

  /// Records source provenance without retaining credentials.
  const PdfSecurity({required this.revision, required this.permissions, required this.ownerPassword});
}

/// Permissions requested from viewers when opening with the user password.
///
/// PDF permission flags are advisory; they do not prevent a reader from copying
/// decrypted content. Accessibility extraction is always permitted.
final class PdfPermissions {
  /// Allows printing at low resolution.
  final bool print;

  /// Allows general changes to document content.
  final bool modify;

  /// Allows extracting text and graphics.
  final bool copy;

  /// Allows annotations and interactive form changes.
  final bool annotate;

  /// Allows filling existing interactive form fields.
  final bool fillForms;

  /// Allows inserting, rotating and deleting pages.
  final bool assemble;

  /// Allows full-resolution printing when [print] is also true.
  final bool highQualityPrint;

  /// Allows all viewer operations unless explicitly restricted.
  const PdfPermissions({this.print = true, this.modify = true, this.copy = true, this.annotate = true, this.fillForms = true, this.assemble = true, this.highQualityPrint = true});

  /// Signed 32-bit permission field with the standard reserved bits set.
  int get value =>
      (-3904 | (print ? 4 : 0) | (modify ? 8 : 0) | (copy ? 16 : 0) | (annotate ? 32 : 0) | (fillForms ? 256 : 0) | 512 | (assemble ? 1024 : 0) | (print && highQualityPrint ? 2048 : 0)).toSigned(32);
}

/// Explicit AES-256 revision 6 protection for a newly encoded PDF 2.0 file.
///
/// Keep this credential-bearing configuration transient. It is never attached
/// to a document. Passwords use up to 127 UTF-8 bytes without SASLprep; supply
/// normalized text if needed. The owner password must be nonempty. An empty
/// user password permits opening without a prompt, with advisory permissions.
final class PdfEncryption {
  /// Password allowing document opening with [permissions].
  final String userPassword;

  /// Nonempty password granting unrestricted viewer access.
  final String ownerPassword;

  /// Viewer permissions associated with the user password.
  final PdfPermissions permissions;

  /// Whether XMP metadata streams are encrypted with document content.
  final bool encryptMetadata;

  /// Requests modern password security; legacy algorithms are read-only.
  const PdfEncryption.aes256({required this.userPassword, required this.ownerPassword, this.permissions = const PdfPermissions(), this.encryptMetadata = true});
}
