import Foundation

enum FileNaming {
    private static let fallbackName = "download"

    /// Chooses a file name: the user's, then the server's, then the link's.
    static func resolve(custom: String?, contentDisposition: String?, link: String) -> String {
        custom.flatMap(safeName)
            ?? contentDisposition.flatMap(name(fromContentDisposition:)).flatMap(safeName)
            ?? safeName(name(fromLink: link))
            ?? fallbackName
    }

    /// Returns `name`, or a variant of it that doesn't exist yet: `a.bin`, `a_1.bin`, `a_2.bin`.
    /// A name already ending in `_<digit>` has that digit incremented, as in Persepolis.
    static func unique(_ name: String, exists: (String) -> Bool) -> String {
        var current = name
        var counter = 1
        while exists(current) {
            let (stem, fileExtension) = split(current)
            let characters = Array(stem)
            if characters.count >= 2, characters[characters.count - 2] == "_",
               let digit = characters.last?.wholeNumberValue {
                current = String(characters.dropLast()) + String(digit + 1) + fileExtension
            } else {
                current = "\(stem)_\(counter)\(fileExtension)"
                counter += 1
            }
        }
        return current
    }

    /// Shortens a name so that it and its control file both fit the 255-byte name limit.
    static func fittingFileSystem(_ name: String) -> String {
        let limit = 255 - ".\(ControlFile.fileExtension)".utf8.count
        guard name.utf8.count > limit else { return name }
        var (stem, fileExtension) = split(name)
        while !stem.isEmpty, stem.utf8.count + fileExtension.utf8.count > limit {
            stem.removeLast()
        }
        return stem + fileExtension
    }

    /// Splits off the extension, including its dot. A leading dot doesn't count as one.
    private static func split(_ name: String) -> (stem: String, fileExtension: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    /// Reduces a name from outside to a single path component, so a server can't choose where a
    /// file lands.
    private static func safeName(_ name: String) -> String? {
        let lastComponent = name
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) }
        guard let lastComponent, !lastComponent.isEmpty, lastComponent != ".", lastComponent != ".." else {
            return nil
        }
        return lastComponent
    }

    private static func name(fromLink link: String) -> String {
        let path = URLComponents(string: link)?.percentEncodedPath
            ?? link.split(separator: "?").first.map(String.init)
            ?? link
        let lastComponent = path.split(separator: "/").last.map(String.init) ?? ""
        return lastComponent.removingPercentEncoding ?? lastComponent
    }

    private static func name(fromContentDisposition header: String) -> String? {
        var plain: String?
        var extended: String?
        for parameter in parameters(in: header) {
            guard let equals = parameter.firstIndex(of: "=") else { continue }
            let key = parameter[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parameter[parameter.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "filename":
                plain = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "filename*":
                // RFC 5987: charset'language'percent-encoded-value
                let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if pieces.count == 3 { extended = pieces[2].removingPercentEncoding }
            default:
                break
            }
        }
        return extended ?? plain
    }

    /// Splits a header on semicolons that aren't inside quotes.
    private static func parameters(in header: String) -> [String] {
        var parameters: [String] = []
        var current = ""
        var isQuoted = false
        for character in header {
            if character == "\"" { isQuoted.toggle() }
            if character == ";", !isQuoted {
                parameters.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parameters.append(current)
        return parameters
    }
}

enum FileClassifier {
    private static let audio: Set<String> = [
        "act", "aiff", "aac", "amr", "ape", "au", "awb", "dct", "dss", "dvf", "flac", "gsm", "iklax", "ivs",
        "m4a", "m4p", "mmf", "mp3", "mpc", "msv", "ogg", "oga", "opus", "ra", "raw", "sln", "tta", "vox", "wav",
        "wma", "wv",
    ]
    private static let video: Set<String> = [
        "3g2", "3gp", "asf", "avi", "drc", "flv", "m4v", "mkv", "mng", "mov", "qt", "mp4", "mpg", "mp2", "mpeg",
        "mpe", "mpv", "m2v", "mxf", "nsv", "ogv", "rmvb", "roq", "svi", "vob", "webm", "wmv", "yuv", "rm",
    ]
    private static let document: Set<String> = [
        "doc", "docx", "html", "htm", "fb2", "odt", "sxw", "pdf", "ps", "rtf", "tex", "txt", "epub", "pub", "mobi",
        "azw", "azw3", "azw4", "kf8", "chm", "cbt", "cbr", "cbz", "cb7", "cba", "ibooks", "djvu", "md",
    ]
    private static let compressed: Set<String> = [
        "a", "ar", "cpio", "shar", "lbr", "iso", "mar", "tar", "bz2", "f", "gz", "lz", "lzma", "lzo", "rz", "sfark",
        "sz", "xz", "z", "infl", "7z", "s7z", "ace", "afa", "alz", "apk", "arc", "arj", "b1", "ba", "bh", "cab",
        "cfs", "cpt", "dar", "dd", "dgc", "dmg", "ear", "gca", "ha", "hki", "ice", "jar", "kgb", "lzh", "lha", "lzx",
        "pac", "partimg", "paq6", "paq7", "paq8", "pea", "pim", "pit", "qda", "rar", "rk", "sda", "sea", "sen", "sfx",
        "sit", "sitx", "sqx", "tgz", "tbz2", "tlz", "uc", "uc0", "uc2", "ucn", "ur2", "ue2", "uca", "uha", "war",
        "wim", "xar", "xp3", "yz1", "zip", "zipx", "zoo", "zpaq", "zz", "ecc", "par", "par2",
    ]

    /// The folder a finished file moves to inside the default download folder.
    static func subfolder(for fileName: String) -> String {
        var fileExtension = fileName.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        fileExtension = fileExtension.lowercased()
        if let query = fileExtension.firstIndex(of: "?") {
            fileExtension = String(fileExtension[..<query])
        }

        if audio.contains(fileExtension) { return "Audios" }
        // Some servers name video streams `videoplayback`, with no extension.
        if video.contains(fileExtension) || fileName == "videoplayback" { return "Videos" }
        if document.contains(fileExtension) { return "Documents" }
        if compressed.contains(fileExtension) { return "Compressed" }
        return "Others"
    }
}
