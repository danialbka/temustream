import Foundation

enum MediaContainerSniffer {
    static func detectedMIMEType(
        signature: Data,
        serverMIMEType: String?
    ) -> String? {
        if signature.count >= 4,
           signature[signature.startIndex] == 0x1A,
           signature[signature.startIndex + 1] == 0x45,
           signature[signature.startIndex + 2] == 0xDF,
           signature[signature.startIndex + 3] == 0xA3 {
            let header = String(decoding: signature.prefix(256), as: UTF8.self).lowercased()
            return header.contains("webm") ? "video/webm" : "video/x-matroska"
        }
        if signature.count >= 12,
           signature.subdata(in: 4..<8) == Data("ftyp".utf8) {
            return "video/mp4"
        }
        if signature.count >= 377,
           signature[signature.startIndex] == 0x47,
           signature[signature.startIndex + 188] == 0x47,
           signature[signature.startIndex + 376] == 0x47 {
            return "video/mp2t"
        }
        if String(decoding: signature.prefix(16), as: UTF8.self).hasPrefix("#EXTM3U") {
            return "application/vnd.apple.mpegurl"
        }

        switch serverMIMEType?.lowercased() {
        case "video/mp4", "video/quicktime", "video/mp2t",
             "application/vnd.apple.mpegurl", "application/x-mpegurl",
             "video/x-matroska", "video/webm":
            return serverMIMEType?.lowercased()
        default:
            return nil
        }
    }
}
