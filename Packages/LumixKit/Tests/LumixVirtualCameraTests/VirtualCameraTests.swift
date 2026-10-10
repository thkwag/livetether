import Foundation
import LumixSession
import LumixTestSupport
import LumixVideo
import os
import Testing
@testable import LumixVirtualCamera

@Suite("Status word")
struct StatusWordTests {
    @Test("Every indicator and time survive encoding")
    func roundTrip() {
        forEachSeed { seed, generator in
            let indicator = LinkIndicator.allCases.randomElement(using: &generator)!
            let time = Date(timeIntervalSince1970: TimeInterval(UInt32.random(in: 0...UInt32.max, using: &generator)))
            let word = StatusWord(indicator: indicator, publishedAt: time)
            #expect(StatusWord(encoded: word.encoded) == word, "seed \(seed)")
            #expect(word.encoded & 0xFF == UInt64(indicator.rawValue), "seed \(seed)")
        }
    }

    @Test("A status older than six seconds means the app is not running")
    func staleness() {
        let published = Date(timeIntervalSince1970: 1_800_000_000)
        let word = StatusWord(indicator: .streaming, publishedAt: published)
        #expect(word.effectiveIndicator(at: published.addingTimeInterval(6)) == .streaming)
        #expect(word.effectiveIndicator(at: published.addingTimeInterval(6.5)) == .appNotRunning)
        #expect(word.effectiveIndicator(at: published.addingTimeInterval(-10)) == .appNotRunning)
        #expect(StatusWord(encoded: 0).effectiveIndicator(at: Date()) == .appNotRunning)
    }

    @Test("An unknown indicator value decodes as the app not running")
    func unknownIndicator() {
        #expect(StatusWord(encoded: 0xFE).indicator == .appNotRunning)
    }
}

@Suite("Output policy")
struct OutputPolicyTests {
    @Test("A picture up to one second old is shown; otherwise the standby for the indicator")
    func decisions() {
        #expect(OutputPolicy.decide(lastFrameAge: 0, indicator: .streaming) == .cameraFrame)
        #expect(OutputPolicy.decide(lastFrameAge: 1, indicator: .streaming) == .cameraFrame)
        #expect(OutputPolicy.decide(lastFrameAge: 1.01, indicator: .streaming) == .standby(StandbyCopy.message(for: .streaming)))
        #expect(OutputPolicy.decide(lastFrameAge: nil, indicator: .waitingForCamera) == .standby(StandbyCopy.message(for: .waitingForCamera)))
        #expect(OutputPolicy.decide(lastFrameAge: -1, indicator: .connecting) == .standby(StandbyCopy.message(for: .connecting)))
    }

    @Test("Every indicator has a standby title, and the ones a person can act on say what to do")
    func copyCoverage() {
        for indicator in LinkIndicator.allCases {
            #expect(!StandbyCopy.message(for: indicator).title.isEmpty, "\(indicator)")
        }
        for indicator in [LinkIndicator.appNotRunning, .waitingForCamera, .cameraUnavailable] {
            #expect(StandbyCopy.message(for: indicator).detail != nil, "\(indicator)")
        }
    }
}

@Suite("Darwin state channel")
struct DarwinStateChannelTests {
    @Test("A published value is readable and observed through another registration")
    func publishAndObserve() async throws {
        let name = "com.github.thkwag.lumixwebcam.test.\(UUID().uuidString)"
        let publisher = try DarwinStateChannel(name: name)
        let reader = try DarwinStateChannel(name: name)
        let received = OSAllocatedUnfairLock<[UInt64]>(initialState: [])
        let observation = try reader.observe(on: .global()) { value in received.withLock { $0.append(value) } }
        publisher.publish(0x1234_5678_0000_0005)
        #expect(reader.currentValue() == 0x1234_5678_0000_0005)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while received.withLock({ $0.isEmpty }) {
            guard clock.now < deadline else {
                Issue.record("Never happened within 10 s: the observer saw the post")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(received.withLock { $0 } .first == 0x1234_5678_0000_0005)
        _ = observation
    }
}

@Suite("Virtual camera identity")
struct IdentityTests {
    @Test("Formats are distinct and the default index is valid")
    func formats() {
        #expect(Set(VirtualCameraFormats.all).count == VirtualCameraFormats.all.count)
        #expect(VirtualCameraFormats.all.indices.contains(VirtualCameraFormats.defaultIndex))
        #expect(VirtualCameraFormats.all.allSatisfy { $0.framesPerSecond == 30 })
    }

    @Test("Device and stream identifiers are distinct")
    func identifiers() {
        #expect(Set([VirtualCameraIdentity.deviceID, VirtualCameraIdentity.sourceStreamID, VirtualCameraIdentity.sinkStreamID]).count == 3)
        #expect(VirtualCameraIdentity.sourceActiveNotification != VirtualCameraIdentity.linkStatusNotification)
    }
}

@Suite("Link indicator mapping")
struct LinkIndicatorMappingTests {
    @Test("Every link phase maps to the indicator the standby text needs")
    func mapping() {
        let camera = CameraID("camera")
        #expect(LinkIndicator(phase: .searching) == .waitingForCamera)
        #expect(LinkIndicator(phase: .opening(camera)) == .connecting)
        #expect(LinkIndicator(phase: .ready(camera)) == .preparing)
        #expect(LinkIndicator(phase: .startingLiveView(camera)) == .preparing)
        #expect(LinkIndicator(phase: .streaming(camera)) == .streaming)
        #expect(LinkIndicator(phase: .waitingToRetry(camera, .openFailed)) == .cameraUnavailable)
        #expect(LinkIndicator(phase: .waitingToRetry(camera, .communicationFailed)) == .communicationError)
    }
}
