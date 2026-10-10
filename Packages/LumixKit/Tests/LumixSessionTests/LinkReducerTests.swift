import Foundation
import LumixTestSupport
import Testing
@testable import LumixSession

@Suite("Link reducer")
struct LinkReducerTests {
    let first = CameraID("first")
    let second = CameraID("second")

    func run(_ events: [LinkEvent], from start: LinkState = LinkState()) -> (LinkState, [[LinkEffect]]) {
        var state = start
        let effects = events.map { LinkReducer.reduce(&state, $0) }
        return (state, effects)
    }

    @Test("A camera that appears is opened; live view starts once a client reads the stream")
    func happyPath() {
        var state = LinkState()
        #expect(LinkReducer.reduce(&state, .cameraAppeared(first)) == [.openSession(first, generation: 1)])
        #expect(LinkReducer.reduce(&state, .sessionOpened(generation: 1)) == [])
        #expect(state.phase == .ready(first))
        #expect(LinkReducer.reduce(&state, .clientsChanged(active: true)) == [.startLiveView(generation: 1)])
        #expect(LinkReducer.reduce(&state, .liveViewStarted(generation: 1)) == [])
        #expect(state.phase == .streaming(first))
        #expect(LinkReducer.reduce(&state, .clientsChanged(active: false)) == [.stopLiveView(generation: 1)])
        #expect(state.phase == .ready(first))
    }

    @Test("A client already waiting starts live view as soon as the session opens")
    func clientBeforeSession() {
        let (state, effects) = run([.clientsChanged(active: true), .cameraAppeared(first), .sessionOpened(generation: 1)])
        #expect(effects.last == [.startLiveView(generation: 1)])
        #expect(state.phase == .startingLiveView(first))
    }

    @Test("Clients leaving while live view starts stop it when the start completes")
    func clientsLeaveDuringStart() {
        let (state, effects) = run([
            .clientsChanged(active: true), .cameraAppeared(first), .sessionOpened(generation: 1),
            .clientsChanged(active: false), .liveViewStarted(generation: 1),
        ])
        #expect(effects.last == [.stopLiveView(generation: 1)])
        #expect(state.phase == .ready(first))
    }

    @Test("A failed open waits and then tries the same camera again with a new generation")
    func retryAfterFailedOpen() {
        let (state, effects) = run([.cameraAppeared(first), .sessionFailed(generation: 1), .retryTimerFired(generation: 1)])
        #expect(effects[1] == [.closeSession(generation: 1), .scheduleRetry(generation: 1)])
        #expect(effects[2] == [.openSession(first, generation: 2)])
        #expect(state.phase == .opening(first))
    }

    @Test("Losing the streaming camera closes its session and opens the next camera")
    func fallBackToNextCamera() {
        let (state, effects) = run([
            .cameraAppeared(first), .cameraAppeared(second), .sessionOpened(generation: 1),
            .clientsChanged(active: true), .liveViewStarted(generation: 1), .cameraDisappeared(first),
        ])
        #expect(effects.last == [.closeSession(generation: 1), .openSession(second, generation: 2)])
        #expect(state.phase == .opening(second))
        #expect(state.cameras == [second])
    }

    @Test("Losing the only camera returns to searching, and late results of its session change nothing")
    func lateResultsAfterRemoval() {
        let (state, effects) = run([.cameraAppeared(first), .cameraDisappeared(first), .sessionOpened(generation: 1), .retryTimerFired(generation: 1)])
        #expect(effects[1] == [.closeSession(generation: 1)])
        #expect(effects[2] == [])
        #expect(effects[3] == [])
        #expect(state.phase == .searching)
    }

    @Test("Invariants hold over random event sequences, including stale generations")
    func invariants() {
        let cameras = [first, second, CameraID("third")]
        for seed in UInt64(0)..<400 {
            var generator = SeededGenerator(seed: seed)
            var state = LinkState()
            for step in 0..<60 {
                let event = randomEvent(cameras: cameras, generation: state.generation, &generator)
                let before = state
                let effects = LinkReducer.reduce(&state, event)
                let context = "seed \(seed) step \(step) event \(event)"
                check(before: before, event: event, after: state, effects: effects, context: context)
            }
        }
    }

    private func check(before: LinkState, event: LinkEvent, after: LinkState, effects: [LinkEffect], context: String) {
        if case .streaming = after.phase {
            #expect(after.clientsActive, "\(context): streaming without clients")
        }
        if let camera = after.phase.camera {
            #expect(after.cameras.contains(camera), "\(context): phase names a camera that is not attached")
        }
        #expect((after.phase == .searching) == after.cameras.isEmpty, "\(context): searching must mean no attached camera")
        for effect in effects {
            switch effect {
            case .openSession(let id, let generation):
                #expect(after.phase == .opening(id) && generation == after.generation, "\(context): open without opening phase")
            case .startLiveView(let generation):
                #expect(generation == after.generation, "\(context): stale start")
                if case .startingLiveView = after.phase {} else { Issue.record("\(context): start without starting phase") }
            case .scheduleRetry(let generation):
                #expect(generation == after.generation, "\(context): stale retry")
                if case .waitingToRetry = after.phase {} else { Issue.record("\(context): retry without waiting phase") }
            case .stopLiveView, .closeSession:
                break
            }
        }
        if let generation = event.resultGeneration, generation != before.generation {
            #expect(after == before && effects.isEmpty, "\(context): a stale result changed the link")
        }
    }

    private func randomEvent(cameras: [CameraID], generation: UInt64, _ generator: inout SeededGenerator) -> LinkEvent {
        let camera = cameras.randomElement(using: &generator)!
        let resultGeneration = Bool.random(using: &generator) ? generation : UInt64.random(in: 0...(generation + 1), using: &generator)
        switch Int.random(in: 0..<8, using: &generator) {
        case 0: return .cameraAppeared(camera)
        case 1: return .cameraDisappeared(camera)
        case 2: return .sessionOpened(generation: resultGeneration)
        case 3: return .sessionFailed(generation: resultGeneration)
        case 4: return .liveViewStarted(generation: resultGeneration)
        case 5: return .communicationFailed(generation: resultGeneration)
        case 6: return .clientsChanged(active: Bool.random(using: &generator))
        default: return .retryTimerFired(generation: resultGeneration)
        }
    }
}

extension LinkEvent {
    /// The generation an asynchronous result belongs to; `nil` for events that are not results.
    var resultGeneration: UInt64? {
        switch self {
        case .sessionOpened(let generation), .sessionFailed(let generation), .liveViewStarted(let generation),
             .communicationFailed(let generation), .retryTimerFired(let generation):
            return generation
        case .cameraAppeared, .cameraDisappeared, .clientsChanged:
            return nil
        }
    }
}
