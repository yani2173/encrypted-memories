/// Known photos from an unfinished metadata listing. This value cannot certify completeness or a server revision.
public struct ProvisionalTimelineSnapshot: Sendable {
    public let sections: [TimelineSection]

    public init(sections: [TimelineSection]) {
        self.sections = sections
    }
}
