import CoreGraphics
import Foundation
import ImageIO
@testable import MumbleKit
import Testing
import UniformTypeIdentifiers

/// A real 2 x 2 PNG with its header rewritten to say `width` x `height`. The file stays tiny however
/// big the header claims to be, which is exactly what an attacker sends.
func craftedPNG(width: UInt32, height: UInt32) -> Data {
    func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c ^= UInt32(b)
            for _ in 0 ..< 8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        }
        return ~c
    }
    func put(_ v: UInt32, _ png: inout [UInt8], at i: Int) {
        png[i] = UInt8(v >> 24); png[i + 1] = UInt8((v >> 16) & 0xFF); png[i + 2] = UInt8((v >> 8) & 0xFF); png[i + 3] = UInt8(v & 0xFF)
    }
    var png = [UInt8](realPicture(width: 2, height: 2, type: .png))
    // Signature (8), IHDR length (4), "IHDR" (4), width (4), height (4), 5 more bytes, CRC (4).
    precondition(Array(png[12 ..< 16]) == Array("IHDR".utf8))
    put(width, &png, at: 16)
    put(height, &png, at: 20)
    put(crc32(png[12 ..< 29]), &png, at: 29)
    return Data(png)
}

/// A real, flat-coloured picture of the given size, encoded as `type`.
func realPicture(width: Int, height: Int, type: UTType = .jpeg) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(dest))
    return out as Data
}

func imgTag(_ data: Data, mime: String = "image/png", extra: String = "") -> String {
    "<img src=\"data:\(mime);base64,\(data.base64EncodedString())\"\(extra) />"
}

struct ChatImageTests {
    /// ImageIO already refuses a small file whose header claims a huge size (the crafted cases below
    /// read as nil). The other attack is a real, all-white picture: tiny when compressed, huge when
    /// decoded. Its header is read and our own budget refuses it before any decode.
    @Test func refusesRealPictureOverTheBudget() throws {
        for (w, h) in [(8001, 5000), (20001, 8)] {
            let png = realPicture(width: w, height: h, type: .png)
            #expect(png.count < ChatLimits.maxImageBytes)
            let size = try #require(ChatImageDecoder.pixelSize(of: png))
            #expect(size == (w, h))
            #expect(ChatHTML.parse(imgTag(png)) == [.refusedImage("Picture too large (\(w) x \(h))")])
            #expect(ChatImageDecoder.decode(png) == nil)
        }
    }

    @Test func pixelBudget() {
        #expect(ChatImageDecoder.isAllowed(width: 4032, height: 3024)) // a phone photo
        #expect(ChatImageDecoder.isAllowed(width: 8000, height: 5000))
        #expect(!ChatImageDecoder.isAllowed(width: 8001, height: 5000))
        #expect(!ChatImageDecoder.isAllowed(width: 10000, height: 10000))
        #expect(!ChatImageDecoder.isAllowed(width: 20001, height: 10))
        #expect(!ChatImageDecoder.isAllowed(width: 0, height: 10))
        #expect(!ChatImageDecoder.isAllowed(width: Int.max, height: Int.max))
    }

    @Test(arguments: [(100_000 as UInt32, 100_000 as UInt32), (65535, 65535), (30000, 1), (15000, 15000), (8000, 5001), (0x7FFF_FFFF, 0x7FFF_FFFF)])
    func refusesHugeDeclaredSize(width: UInt32, height: UInt32) {
        let parts = ChatHTML.parse("look " + imgTag(craftedPNG(width: width, height: height)))
        #expect(parts.count == 2)
        // ImageIO itself rejects some of these headers ("Broken picture"); either way nothing is decoded.
        guard case .refusedImage = parts.last else { Issue.record("not refused: \(parts)"); return }
        #expect(ChatImageDecoder.decode(craftedPNG(width: width, height: height)) == nil)
    }

    @Test func refusesOversizedBase64BeforeDecoding() {
        let big = String(repeating: "A", count: ChatLimits.maxBase64Characters + 1)
        let parts = ChatHTML.parse("<img src=\"data:image/png;base64,\(big)\">")
        #expect(parts == [.refusedImage("Picture too large")])
        // Just over 768 KiB of real bytes: its base64 fits the character cap, the decoded size does not.
        let justOver = Data(repeating: 0, count: ChatLimits.maxImageBytes + 1)
        #expect(ChatHTML.parse(imgTag(justOver)) == [.refusedImage("Picture too large")])
    }

    @Test func refusesGarbageAndRemote() {
        #expect(ChatHTML.parse("<img src=\"data:image/png;base64,bm90IGFuIGltYWdl\">") == [.refusedImage("Broken picture")])
        #expect(ChatHTML.parse("<img src=\"https://example.com/a.png\">") == [.refusedImage("Picture from the web (not loaded)")])
        #expect(ChatHTML.parse("<img src=\"data:text/html;base64,PGI+\">") == [.refusedImage("Unsupported picture")])
    }

    @Test func showsANormalPhotoScaledDown() throws {
        let photo = realPicture(width: 4032, height: 3024)
        #expect(photo.count < ChatLimits.maxImageBytes)
        let parts = ChatHTML.parse("<p>holiday</p>" + imgTag(photo, mime: "image/jpeg"))
        #expect(parts.first == .text("holiday"))
        guard case let .image(image) = parts.last else { Issue.record("no picture: \(parts)"); return }
        #expect(image.pixelWidth == 4032 && image.pixelHeight == 3024)
        let decoded = try #require(ChatImageDecoder.decode(image.data))
        #expect(max(decoded.width, decoded.height) == ChatLimits.maxDecodedSide)
        #expect(decoded.width == 2048 && decoded.height == 1536)
    }

    @Test func smallPictureKeepsItsSize() throws {
        let parts = ChatHTML.parse(imgTag(realPicture(width: 320, height: 200, type: .png)))
        guard case let .image(image) = parts.first else { Issue.record("no picture: \(parts)"); return }
        let decoded = try #require(ChatImageDecoder.decode(image.data))
        #expect(decoded.width == 320 && decoded.height == 200)
    }

    @Test func clampsDeclaredWidthAndHeight() {
        let tag = imgTag(realPicture(width: 16, height: 16, type: .png), extra: " width=\"99999999999\" height='50000px'")
        guard case let .image(image) = ChatHTML.parse(tag).first else { Issue.record("no picture"); return }
        #expect(image.displayWidth == ChatLimits.maxDisplaySide)
        #expect(image.displayHeight == ChatLimits.maxDisplaySide)
    }

    @Test func capsPicturesAndTextPerMessage() {
        let tiny = imgTag(realPicture(width: 4, height: 4, type: .png))
        let parts = ChatHTML.parse(String(repeating: tiny, count: ChatLimits.maxImagesPerMessage + 3))
        #expect(parts.filter { if case .image = $0 { true } else { false } }.count == ChatLimits.maxImagesPerMessage)
        #expect(parts.count == ChatLimits.maxImagesPerMessage + 3)

        let long = ChatMessage(sender: nil, senderName: "x", body: String(repeating: "a", count: 8 << 20))
        #expect(long.body.count == ChatLimits.maxTextCharacters)
        guard case let .text(t) = long.parts.first else { Issue.record("no text"); return }
        #expect(t.count <= ChatLimits.maxTextCharacters + 3)
    }

    /// The "flood the phone" report: the server can relay message after message of up to 8 MB each.
    @Test func historyStaysWithinBudget() {
        var history: [ChatMessage] = []
        let bulky = String(repeating: "b", count: 64 << 10)
        for _ in 0 ..< 600 { history.appendBounded(ChatMessage(sender: nil, senderName: "flood", body: bulky)) }
        #expect(history.count <= ChatLimits.maxHistoryMessages)
        #expect(history.reduce(0) { $0 + $1.cost } <= ChatLimits.maxHistoryBytes)

        var normal: [ChatMessage] = []
        for i in 0 ..< 600 { normal.appendBounded(ChatMessage(sender: nil, senderName: "a", body: "hi \(i)")) }
        #expect(normal.count == ChatLimits.maxHistoryMessages)
        #expect(normal.last?.body == "hi 599")
    }

    @Test func plainTextIsUnchanged() {
        #expect(ChatHTML.parse("hello <b>there</b><br />&amp; bye") == [.text("hello there\n& bye")])
        #expect(ChatHTML.parse("") == [])
    }
}
