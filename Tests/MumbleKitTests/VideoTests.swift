import CoreGraphics
import Foundation
@testable import MumbleKit
import Testing

/// A synthetic I420 frame: flat colour from Y/U/V values, with a moving bright bar so frames differ.
func testFrame(width: Int, height: Int, y: UInt8, u: UInt8, v: UInt8, bar: Int = 0) -> I420Frame {
    var yp = Data(repeating: y, count: width * height)
    for row in 0 ..< height where (row + bar) % 40 < 4 {
        yp.replaceSubrange(row * width ..< row * width + width / 4, with: Data(repeating: 235, count: width / 4))
    }
    let c = ((width + 1) / 2) * ((height + 1) / 2)
    return I420Frame(width: width, height: height, y: yp, u: Data(repeating: u, count: c), v: Data(repeating: v, count: c))
}

/// RGB of the pixel at (x, y) in a CGImage.
func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
    var buf = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &buf, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return (Int(buf[0]), Int(buf[1]), Int(buf[2]))
}

struct FrameAssemblerTests {
    func unit(_ n: UInt64, key: Bool = false, x: UInt32 = 0, y: UInt32 = 0, _ payload: [UInt8] = [1]) -> VideoUnit {
        VideoUnit(senderSession: 1, streamID: 0, frameNumber: n, unitID: 0, isKeyframe: key, isFrameEnd: true, captureTimestampUsec: 0,
                  x: x, y: y, width: 0, height: 0, payload: Data(payload))
    }

    @Test func waitsForKeyframeThenFollowsSequence() {
        let a = FrameAssembler(codec: .vp8)
        #expect(a.add(unit(1)).frame == nil) // no keyframe yet
        #expect(a.add(unit(2, key: true)).frame?.frameNumber == 2)
        #expect(a.add(unit(3)).frame?.frameNumber == 3)
        let afterGap = a.add(unit(5)) // 4 lost
        #expect(afterGap.frame == nil)
        #expect(afterGap.needKeyframe)
        #expect(a.add(unit(6, key: true)).frame?.frameNumber == 6)
        #expect(a.add(unit(6, key: true)).frame == nil) // duplicate
    }

    @Test func joinsH264UnitsInOrder() {
        let a = FrameAssembler(codec: .h264)
        #expect(a.add(unit(1, key: true, x: 1, y: 3, [2])).frame == nil)
        #expect(a.add(unit(1, key: true, x: 0, y: 3, [1])).frame == nil)
        let f = a.add(unit(1, key: true, x: 2, y: 3, [3])).frame
        #expect(f?.data == Data([1, 2, 3]))
    }

    @Test func splitsAnnexB() {
        let d = Data([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5])
        #expect(H264FrameDecoder.nalUnits(d) == [Data([0x67, 1, 2]), Data([0x68, 3]), Data([0x65, 4, 5])])
    }
}

struct VP8RoundTripTests {
    @Test func encodesAndDecodesToTheRightColour() throws {
        let enc = try #require(VP8Encoder(width: 320, height: 240))
        let dec = try #require(VPXFrameDecoder(codec: 8))
        // Video-range BT.601 reddish: Y 81, U 90, V 240.
        var image: CGImage?
        for n in 0 ..< 5 {
            for (data, key) in enc.encode(testFrame(width: 320, height: 240, y: 81, u: 90, v: 240, bar: n), pts: Int64(n), forceKeyframe: n == 0) {
                image = dec.decode(FrameAssembler.Frame(data: data, isKeyframe: key, frameNumber: UInt64(n))) ?? image
            }
        }
        let img = try #require(image)
        #expect(img.width == 320 && img.height == 240)
        let (r, g, b) = pixel(img, 300, 120)
        #expect(r > 200 && g < 60 && b < 60)
    }
}
