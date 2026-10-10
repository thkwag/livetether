import LumixSession

extension LinkIndicator {
    /// The indicator the app publishes for a link phase.
    public init(phase: LinkPhase) {
        switch phase {
        case .searching:
            self = .waitingForCamera
        case .opening:
            self = .connecting
        case .ready, .startingLiveView:
            self = .preparing
        case .streaming:
            self = .streaming
        case .waitingToRetry(_, .openFailed):
            self = .cameraUnavailable
        case .waitingToRetry(_, .communicationFailed):
            self = .communicationError
        }
    }
}
