import Foundation
import LumixSession
import LumixTestSupport
import LumixVideo
import os
import Testing
@testable import LumixVirtualCamera

@Suite("Status word")
struct StatusWordTests {
    @Test("Every indicator, language and time survive encoding")
    func roundTrip() {
        forEachSeed { seed, generator in
            let indicator = LinkIndicator.allCases.randomElement(using: &generator)!
            let language = StandbyLanguage.allCases.randomElement(using: &generator)!
            let time = Date(timeIntervalSince1970: TimeInterval(UInt32.random(in: 0...UInt32.max, using: &generator)))
            let word = StatusWord(indicator: indicator, language: language, publishedAt: time)
            #expect(StatusWord(encoded: word.encoded) == word, "seed \(seed)")
            #expect(word.encoded & 0xFF == UInt64(indicator.rawValue), "seed \(seed)")
            #expect((word.encoded >> 8) & 0xFF == UInt64(language.rawValue), "seed \(seed)")
        }
    }

    @Test("A status older than six seconds means the app is not running")
    func staleness() {
        let published = Date(timeIntervalSince1970: 1_800_000_000)
        let word = StatusWord(indicator: .streaming, language: .korean, publishedAt: published)
        #expect(word.effectiveIndicator(at: published.addingTimeInterval(6)) == .streaming)
        #expect(word.effectiveIndicator(at: published.addingTimeInterval(6.5)) == .appNotRunning)
        #expect(word.effectiveIndicator(at: published.addingTimeInterval(-10)) == .appNotRunning)
        #expect(StatusWord(encoded: 0).effectiveIndicator(at: Date()) == .appNotRunning)
    }

    @Test("Unknown indicator and language values decode as the app not running and English")
    func unknownValues() {
        #expect(StatusWord(encoded: 0xFE).indicator == .appNotRunning)
        #expect(StatusWord(encoded: 0xFE00).language == .english)
    }

    @Test("The first supported preferred language wins; anything else is English")
    func languageResolution() {
        #expect(StandbyLanguage(preferredLanguages: ["ko-KR", "en-US"]) == .korean)
        #expect(StandbyLanguage(preferredLanguages: ["fr-FR", "ja-JP"]) == .japanese)
        #expect(StandbyLanguage(preferredLanguages: ["fr-FR"]) == .english)
        #expect(StandbyLanguage(preferredLanguages: []) == .english)
    }
}

@Suite("Output policy")
struct OutputPolicyTests {
    @Test("A picture up to one second old is shown; otherwise the standby for the indicator")
    func decisions() {
        let language = StandbyLanguage.english
        #expect(OutputPolicy.decide(lastFrameAge: 0, indicator: .streaming, language: language) == .cameraFrame)
        #expect(OutputPolicy.decide(lastFrameAge: 1, indicator: .streaming, language: language) == .cameraFrame)
        #expect(OutputPolicy.decide(lastFrameAge: 1.01, indicator: .streaming, language: language) == .standby(StandbyCopy.message(for: .streaming, language: language)))
        #expect(OutputPolicy.decide(lastFrameAge: nil, indicator: .waitingForCamera, language: language) == .standby(StandbyCopy.message(for: .waitingForCamera, language: language)))
        #expect(OutputPolicy.decide(lastFrameAge: -1, indicator: .connecting, language: language) == .standby(StandbyCopy.message(for: .connecting, language: language)))
    }

    @Test("Every standby key is translated in every language, and the translations are not English")
    func translationsComplete() {
        for key in StandbyCopy.allKeys {
            let english = StandbyCopy.translation(key, language: .english)
            #expect(english != nil, "English lacks \(key)")
            for language in [StandbyLanguage.korean, .japanese] {
                let translated = StandbyCopy.translation(key, language: language)
                #expect(translated != nil, "\(language) lacks \(key)")
                #expect(translated != english, "\(language) repeats the English text of \(key)")
            }
        }
    }

    @Test("Standby messages come from the requested language, and the actionable ones say what to do")
    func messagesFollowLanguage() {
        #expect(StandbyCopy.message(for: .waitingForCamera, language: .english).title == "Connect a camera")
        #expect(StandbyCopy.message(for: .waitingForCamera, language: .korean).title == "카메라를 연결해 주세요")
        #expect(StandbyCopy.message(for: .waitingForCamera, language: .japanese).title == "カメラを接続してください")
        for language in StandbyLanguage.allCases {
            for indicator in [LinkIndicator.appNotRunning, .waitingForCamera, .cameraUnavailable] {
                #expect(StandbyCopy.message(for: indicator, language: language).detail != nil, "\(indicator) \(language)")
            }
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

@Suite("Source activity")
struct SourceActivityTests {
    @Test("Activity and format survive the round trip, and inactivity is 0")
    func roundTrip() {
        for index in VirtualCameraFormats.all.indices {
            let activity = SourceActivity(isActive: true, formatIndex: index)
            #expect(SourceActivity(activity.encoded) == activity)
            #expect(activity.encoded & 1 == 1)
        }
        #expect(SourceActivity(isActive: false, formatIndex: 2).encoded == 0)
        #expect(SourceActivity(1) == SourceActivity(isActive: true, formatIndex: nil))
        #expect(SourceActivity(1 | 0x7F << 8).formatIndex == nil)
    }
}
