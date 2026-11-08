import Foundation

/// Supplement MLSD with lstat-style Unix LIST information. MLSD alone may follow links.
/// Unknown formats or inconsistent names fail closed for recursive operations.
enum FTPUnixListing {
    enum Failure: LocalizedError {
        case inconsistentSnapshot
        var errorDescription: String? { "The FTP directory changed between MLSD and LIST. Refresh and try again." }
    }
    static func merge(_ data: Data, entries: [FileEntry], directory: String, requireConsistent: Bool = true) throws -> [FileEntry] {
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw FTPError.message("Unsupported Unix LIST encoding.") }
        let pattern = #"^([bcdlps-])([r-][w-][xsS-][r-][w-][xsS-][r-][w-][xtT-])[+@.]?[ \t]+[0-9]+[ \t]+\S+[ \t]+\S+[ \t]+(?:[0-9]+|[0-9]+,[ \t]*[0-9]+)[ \t]+\S+[ \t]+[0-9]+[ \t]+\S+ (.*)$"#
        let regex = try NSRegularExpression(pattern: pattern)
        var result: [String: FileEntry] = [:]
        let originals = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") where !line.isEmpty {
            if line.hasPrefix("total "), UInt64(line.dropFirst(6)) != nil { continue }
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let kindRange = Range(match.range(at: 1), in: line), let modeRange = Range(match.range(at: 2), in: line),
                  let nameRange = Range(match.range(at: 3), in: line) else { throw FTPError.message("The FTP server does not provide a supported Unix LIST format.") }
            let kind = String(line[kindRange]), suffix = String(line[nameRange])
            let name: String
            if kind == "l" {
                let matches = entries.filter { suffix == $0.name || suffix.hasPrefix($0.name + " -> ") }
                if matches.count == 1 { name = matches[0].name }
                else if matches.isEmpty, let arrow = suffix.range(of: " -> "), !suffix[arrow.upperBound...].contains(" -> ") { name = String(suffix[..<arrow.lowerBound]) }
                else { throw FTPError.message("Ambiguous symbolic link name in FTP LIST.") }
            } else { name = suffix }
            if name == "." || name == ".." { continue }
            try LocalFiles.validName(name); try FTPPaths.validate(name)
            guard result[name] == nil else { throw FTPError.message("Duplicate name in FTP LIST: \(name)") }
            let type: UInt32 = ["d": 0o040000, "-": 0o100000, "l": 0o120000, "p": 0o010000, "s": 0o140000, "b": 0o060000, "c": 0o020000][kind] ?? 0
            var mode: UInt32 = 0
            let chars = Array(line[modeRange])
            for (index, char) in chars.enumerated() {
                if "rwxst".contains(char) { mode |= UInt32(1 << (8 - index)) }
            }
            if chars[2] == "s" || chars[2] == "S" { mode |= 0o4000 }
            if chars[5] == "s" || chars[5] == "S" { mode |= 0o2000 }
            if chars[8] == "t" || chars[8] == "T" { mode |= 0o1000 }
            var entry: FileEntry
            if let original = originals[name] { entry = original }
            else if kind == "l" { entry = FileEntry(name: name, path: FileEntry.join(directory, name), sizeAvailable: false) }
            else { if requireConsistent { throw Failure.inconsistentSnapshot }; continue }
            if kind == "l" { entry.size = 0; entry.sizeAvailable = false; entry.modified = .distantPast }
            entry.permissions = type | mode; entry.permissionsAvailable = true; entry.linkInformationAvailable = true
            result[name] = entry
        }
        if requireConsistent {
            guard entries.allSatisfy({ result[$0.name] != nil }) else { throw Failure.inconsistentSnapshot }
        } else {
            for entry in entries where result[entry.name] == nil { result[entry.name] = entry }
        }
        return result.values.sorted { $0.name < $1.name }
    }
}
