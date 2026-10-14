import Foundation

/// Maps file/directory names onto the frozen `FileCategory` enumeration.
///
/// Classification is by filename extension
/// (case-insensitive), with a few well-known directory kinds recognized
/// (`.app`, `.framework`, `.bundle`, `.kext`). Unknown or extension-less
/// entries fall back to `.other`.
enum FileCategorizer {

    static func category(name: String, isDirectory: Bool) -> FileCategory {
        if isDirectory {
            return directoryCategory(name: name)
        }
        return fileCategory(name: name)
    }

    private static func fileCategory(name: String) -> FileCategory {
        let ext = pathExtension(name)
        if ext.isEmpty { return .other }
        if applicationExtensions.contains(ext) { return .applications }
        if documentExtensions.contains(ext) { return .documents }
        if imageExtensions.contains(ext) { return .images }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if archiveExtensions.contains(ext) { return .archives }
        if codeExtensions.contains(ext) { return .code }
        if systemExtensions.contains(ext) { return .system }
        return .other
    }

    private static func directoryCategory(name: String) -> FileCategory {
        switch pathExtension(name) {
        case "app": return .applications
        case "framework", "bundle", "kext", "xpc", "appex", "prefPane": return .system
        default: return .other
        }
    }

    private static func pathExtension(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    // MARK: - Extension sets

    private static let applicationExtensions: Set<String> = [
        "app", "dmg", "pkg", "ipa", "deb", "rpm", "exe", "msi",
    ]

    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "pages", "numbers", "key", "txt", "rtf", "md", "markdown",
        "csv", "tsv", "odt", "ods", "odp", "epub", "mobi",
    ]

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff",
        "bmp", "webp", "svg", "raw", "cr2", "cr3", "nef", "arw",
        "dng", "psd", "ai", "ico", "icns",
    ]

    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "wmv", "flv", "webm",
        "mpg", "mpeg", "mts", "m2ts", "3gp", "ts",
    ]

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "flac", "aiff", "aif", "ogg",
        "wma", "opus", "alac", "ape", "m4b",
    ]

    private static let archiveExtensions: Set<String> = [
        "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "tgz", "tbz2",
        "txz", "lz", "lz4", "zst", "iso",
    ]

    private static let codeExtensions: Set<String> = [
        "swift", "m", "h", "c", "cpp", "cc", "cxx", "hpp", "hh", "mm",
        "java", "kt", "kts", "py", "js", "ts", "tsx", "jsx", "go", "rs",
        "rb", "php", "sh", "bash", "zsh", "fish", "ps1",
        "json", "yaml", "yml", "xml", "plist", "toml", "ini", "cfg",
        "css", "scss", "less", "html", "htm", "sql", "graphql", "proto",
        "cmake", "cs", "vb", "fs", "r", "jl", "lua", "pl", "scala",
        "dart", "groovy", "gradle",
    ]

    private static let systemExtensions: Set<String> = [
        "dylib", "so", "dll", "sys", "ko", "log", "tmp", "cache",
        "db", "sqlite", "sqlite3",
    ]
}
