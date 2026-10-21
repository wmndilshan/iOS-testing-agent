import Foundation
import CryptoKit

/// The single SHA-256 hex implementation behind every integrity checksum and fingerprint
/// (LearnedSkill, SkillFingerprint, SkillStateFingerprint).
///
/// Centralised so all checksums share one, tested digest format. Callers decide *what* is covered
/// by the digest (their canonical body); this type only hashes it.
public enum IntegrityHash {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }
}
