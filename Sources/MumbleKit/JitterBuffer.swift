import Foundation

/// Orders one speaker's packets by frame number and smooths network jitter with a prebuffer that adapts
/// to the speaker's connection (a port of the Android client's JitterBuffer).
///
/// Frame numbers are used only for ordering and duplicate removal, never to infer loss: senders count
/// them differently (per 10 ms frame or per packet), so a gap in numbers is not a lost packet. Loss shows
/// up as an underrun instead, which the player conceals.
///
/// Every underrun mid-talk raises this speaker's target by a packet (up to `maxPrebuffer`) and rebuffers
/// to it before playing on, so someone on a bursty path costs a little latency instead of arriving as a
/// stutter of single packets. A long run without underruns brings the target back down a step at a time.
///
/// Thread safe: the network queue puts, the audio thread takes.
final class JitterBuffer: @unchecked Sendable {
    enum Next: Equatable {
        case packet(Data)
        /// Mid-talk underrun, or rebuffering after one: conceal.
        case gap
        /// Not talking (or still prebuffering).
        case idle
    }

    /// About 30 s of 20 ms packets without an underrun before trusting the path a step more.
    static let steadyToShrink = 1500

    private let prebuffer: Int
    private let maxQueued: Int
    private let maxPrebuffer: Int
    private let lock = NSLock()
    private var queue: [(frame: UInt64, opus: Data)] = [] // sorted by frame
    private var playing = false
    private var rebuffering = false
    private var terminated = false
    private var lastTaken: UInt64?
    private var steadyPackets = 0
    private var _target: Int

    init(prebuffer: Int = 2, maxQueued: Int = 12, maxPrebuffer: Int = 12) {
        self.prebuffer = prebuffer
        self.maxQueued = maxQueued
        self.maxPrebuffer = maxPrebuffer
        _target = prebuffer
    }

    /// Packets to hold before playing; learned per speaker, kept across talk spurts.
    var target: Int { lock.withLock { _target } }
    var count: Int { lock.withLock { queue.count } }

    func put(frame: UInt64, opus: Data, terminator: Bool) {
        lock.withLock {
            if playing, let last = lastTaken, frame <= last { return } // late or duplicate
            if let i = queue.firstIndex(where: { $0.frame >= frame }) {
                if queue[i].frame == frame {
                    queue[i].opus = opus
                } else {
                    queue.insert((frame, opus), at: i)
                }
            } else {
                queue.append((frame, opus))
            }
            if terminator { terminated = true }
            // Latency crept up (clock drift, a burst after a stall): drop the oldest, keeping the target.
            while queue.count > max(maxQueued, _target * 2) { queue.removeFirst() }
        }
    }

    func take() -> Next {
        lock.withLock {
            if !playing {
                if queue.count < _target && !(terminated && !queue.isEmpty) { return .idle }
                playing = true
            }
            if rebuffering {
                if queue.count < _target && !terminated { return .gap }
                rebuffering = false
            }
            guard !queue.isEmpty else {
                if !terminated {
                    _target = min(_target + 1, maxPrebuffer)
                    steadyPackets = 0
                    rebuffering = true
                    return .gap
                }
                playing = false
                terminated = false
                lastTaken = nil
                return .idle
            }
            let entry = queue.removeFirst()
            lastTaken = entry.frame
            steadyPackets += 1
            if steadyPackets >= Self.steadyToShrink && _target > prebuffer {
                _target -= 1
                steadyPackets = 0
            }
            return .packet(entry.opus)
        }
    }
}
