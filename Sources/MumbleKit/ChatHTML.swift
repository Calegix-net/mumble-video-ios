import CoreGraphics
import Foundation
import ImageIO

/// Limits for pictures and text in chat. Anyone in a channel can send a message, and a server relays
/// whatever it gets, so the client checks every picture itself before it allocates anything for it: a
/// tiny PNG that claims to be 100000 x 100000 pixels must never become a 40 GB bitmap.
/// The desktop and Android clients use the same numbers.
public enum ChatLimits {
    /// Largest picture file taken from a data: URI, after base64 decoding: what 1 MiB of base64 holds,
    /// the same cap as desktop and Android (and the most any of our clients sends).
    public static let maxImageBytes = (1 << 20) / 4 * 3
    /// Longest base64 text accepted for one picture before decoding: 1 MiB plus room for the line breaks
    /// and percent-encoding senders wrap it in. The decoded size above is the real limit.
    public static let maxBase64Characters = (1 << 20) + (64 << 10)
    /// Largest picture by the size in its header. Bigger ones are refused, not scaled: a progressive
    /// JPEG decoder keeps about 3 bytes per source pixel however small the thumbnail, so 40 MP is ~120 MB.
    public static let maxImagePixels = 40_000_000
    public static let maxImageSide = 20_000
    /// Pictures are decoded scaled down so their long side is at most this many pixels.
    public static let maxDecodedSide = 2048
    /// Width and height attributes in the HTML are clamped to this.
    public static let maxDisplaySide = 2048
    /// Pictures kept from one message; the rest show as a placeholder.
    public static let maxImagesPerMessage = 8
    /// Text kept from one message.
    public static let maxTextCharacters = 32 * 1024
    /// Chat history kept in memory: the oldest messages go first when either is exceeded.
    public static let maxHistoryMessages = 500
    public static let maxHistoryBytes = 32 << 20
}

/// A picture from a chat message that passed the header checks. Not decoded yet.
public struct ChatImage: Sendable, Equatable {
    /// The encoded file (PNG, JPEG, GIF, ...), at most `ChatLimits.maxImageBytes`.
    public var data: Data
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// From the width/height attributes, clamped; nil when the message gave none.
    public var displayWidth: Int?
    public var displayHeight: Int?
}

public enum ChatPart: Sendable, Equatable {
    case text(String)
    case image(ChatImage)
    /// A picture that was not shown, and why.
    case refusedImage(String)
}

public enum ChatHTML {
    /// Splits a chat message into text and checked pictures. Remote (http) pictures are never fetched:
    /// they show as a placeholder, which also keeps the reader's address private.
    public static func parse(_ html: String) -> [ChatPart] {
        var parts: [ChatPart] = []
        var textBudget = ChatLimits.maxTextCharacters
        var images = 0
        let ns = html as NSString
        var cursor = 0

        func addText(_ range: NSRange) {
            guard range.length > 0, textBudget > 0 else { return }
            var text = plain(ns.substring(with: range))
            if text.count > textBudget { text = String(text.prefix(textBudget)) + "..." }
            textBudget -= text.count
            if !text.isEmpty { parts.append(.text(text)) }
        }

        for match in imgTag.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            addText(NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            images += 1
            if images > ChatLimits.maxImagesPerMessage {
                parts.append(.refusedImage("Too many pictures in one message"))
                continue
            }
            let tag = ns.substring(with: match.range)
            switch image(fromTag: tag) {
            case let .success(image): parts.append(.image(image))
            case let .failure(reason): parts.append(.refusedImage(reason.text))
            }
        }
        addText(NSRange(location: cursor, length: ns.length - cursor))
        return parts
    }

    public struct Refusal: Error, Equatable {
        public var text: String
    }

    static func image(fromTag tag: String) -> Result<ChatImage, Refusal> {
        guard let src = attribute("src", in: tag) else { return .failure(Refusal(text: "Picture without a source")) }
        guard src.count >= 5, src.prefix(5).lowercased() == "data:" else {
            return .failure(Refusal(text: "Picture from the web (not loaded)"))
        }
        // data:[<type>][;base64],<payload>
        guard let comma = src.firstIndex(of: ",") else { return .failure(Refusal(text: "Broken picture")) }
        let header = src[src.index(src.startIndex, offsetBy: 5) ..< comma].lowercased()
        guard header.hasPrefix("image/"), header.hasSuffix(";base64") else {
            return .failure(Refusal(text: "Unsupported picture"))
        }
        let payload = src[src.index(after: comma)...]
        // Check the length before decoding so a huge payload is never copied again.
        guard payload.utf8.count <= ChatLimits.maxBase64Characters else {
            return .failure(Refusal(text: "Picture too large"))
        }
        let cleaned = String(payload).removingPercentEncoding ?? String(payload)
        guard let data = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters) else {
            return .failure(Refusal(text: "Broken picture"))
        }
        guard data.count <= ChatLimits.maxImageBytes else { return .failure(Refusal(text: "Picture too large")) }
        guard let (w, h) = ChatImageDecoder.pixelSize(of: data) else { return .failure(Refusal(text: "Broken picture")) }
        guard ChatImageDecoder.isAllowed(width: w, height: h) else {
            return .failure(Refusal(text: "Picture too large (\(w) x \(h))"))
        }
        let clamp = { (v: Int?) in v.map { max(1, min($0, ChatLimits.maxDisplaySide)) } }
        return .success(ChatImage(data: data, pixelWidth: w, pixelHeight: h,
                                  displayWidth: clamp(attribute("width", in: tag).flatMap(dimension)),
                                  displayHeight: clamp(attribute("height", in: tag).flatMap(dimension))))
    }

    /// Mumble chat is HTML; this is its text.
    public static func plain(_ html: String) -> String {
        html.replacingOccurrences(of: "<br />", with: "\n").replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }

    // `[^>]*` keeps the scan linear; Mumble's own HTML never puts '>' inside an img attribute.
    private static let imgTag = try! NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive])

    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = tag as NSString
        guard let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for i in 1 ... 3 where m.range(at: i).location != NSNotFound {
            return ns.substring(with: m.range(at: i))
        }
        return nil
    }

    /// "640", "640px", " 640 " -> 640. Percentages and junk give nil.
    static func dimension(_ value: String) -> Int? {
        let digits = value.trimmingCharacters(in: .whitespaces).prefix { $0.isASCII && $0.isNumber }
        if digits.isEmpty { return nil }
        return digits.count > 9 ? Int.max : Int(digits)
    }
}

public enum ChatImageDecoder {
    private static var sourceOptions: CFDictionary { [kCGImageSourceShouldCache: false] as CFDictionary }

    /// Width and height from the file header, without decoding any pixels. nil when ImageIO can't read it.
    public static func pixelSize(of data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              w > 0, h > 0 else { return nil }
        return (w, h)
    }

    public static func isAllowed(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0, width <= ChatLimits.maxImageSide, height <= ChatLimits.maxImageSide else { return false }
        return width.multipliedReportingOverflow(by: height).partialValue <= ChatLimits.maxImagePixels
    }

    /// Decodes a picture scaled down to at most `maxSide` pixels on its long side. Checks the header
    /// again, so this is safe to call on any data.
    public static func decode(_ data: Data, maxSide: Int = ChatLimits.maxDecodedSide) -> CGImage? {
        guard data.count <= ChatLimits.maxImageBytes, let (w, h) = pixelSize(of: data), isAllowed(width: w, height: h),
              let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(w, h), max(1, min(maxSide, ChatLimits.maxDecodedSide))),
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
