import Foundation

/// Broad classification used to group files and folders in scan results.
///
/// Frozen by the Architecture & Shared Contracts document (`docs/ARCHITECTURE.md`).
public enum FileCategory: String, CaseIterable, Codable, Sendable {
    case applications, documents, images, video, audio, archives, code, system, other
}
