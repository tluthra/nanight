import Foundation
import Testing
@testable import Nanight

struct RestStateTests {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func briefNegativeAndMovementStayInOneBlock() {
        var state = NanightRestState()
        for t in stride(from: 0, through: 150, by: 3) {
            _ = state.record(presence: .present, moving: false, at: origin.addingTimeInterval(Double(t)))
        }
        let bed = state.inBed?.id, sleep = state.sleeping?.id
        #expect(sleep != nil)
        _ = state.record(presence: .empty, moving: true, at: origin.addingTimeInterval(153))
        _ = state.record(presence: .present, moving: true, at: origin.addingTimeInterval(156))
        _ = state.record(presence: .present, moving: false, at: origin.addingTimeInterval(159))
        #expect(state.inBed?.id == bed)
        #expect(state.sleeping?.id == sleep)
        #expect(state.inBed?.duration == 159)
    }

    @Test func prolongedAbsenceAndObservationGapsSplitBlocks() {
        var state = NanightRestState()
        _ = state.record(presence: .present, moving: false, at: origin)
        _ = state.record(presence: .present, moving: false, at: origin.addingTimeInterval(3))
        let first = state.inBed?.id
        for t in stride(from: 6, through: 129, by: 3) {
            _ = state.record(presence: .empty, moving: false, at: origin.addingTimeInterval(Double(t)))
        }
        #expect(state.inBed == nil)
        _ = state.record(presence: .present, moving: false, at: origin.addingTimeInterval(132))
        _ = state.record(presence: .present, moving: false, at: origin.addingTimeInterval(135))
        #expect(state.inBed?.id != first)
        _ = state.record(presence: .present, moving: false, at: origin.addingTimeInterval(180))
        #expect(state.inBed == nil)
        #expect(state.sleeping == nil)
    }

    @Test func sleepRequiresQuietPresenceAndSustainedMovementClearsIt() {
        var state = NanightRestState()
        for t in stride(from: 0, through: 120, by: 3) {
            _ = state.record(presence: .present, moving: false, at: origin.addingTimeInterval(Double(t)))
        }
        #expect(state.sleeping == nil)
        _ = state.record(presence: .present, moving: false, at: origin.addingTimeInterval(123))
        #expect(state.sleeping != nil)
        for t in stride(from: 126, through: 156, by: 3) {
            _ = state.record(presence: .present, moving: true, at: origin.addingTimeInterval(Double(t)))
        }
        #expect(state.sleeping == nil)
        #expect(state.inBed != nil)
        _ = state.record(presence: .present, moving: nil, at: origin.addingTimeInterval(159))
        #expect(state.sleeping == nil)
    }

    @Test func borderlineReadingsAndBriefInterruptionsDoNotSplitPresence() {
        var state = NanightRestState()
        _ = state.record(presence: .present, moving: false, at: origin)
        _ = state.record(presence: .present, moving: false, at: origin.addingTimeInterval(3))
        let id = state.inBed?.id
        for t in stride(from: 6, through: 90, by: 3) {
            _ = state.record(presence: .uncertain, moving: false, at: origin.addingTimeInterval(Double(t)))
        }
        #expect(state.inBed?.id == id)
        #expect(state.inBed?.end == origin.addingTimeInterval(3))
        state.interrupt()
        _ = state.record(presence: .present, moving: nil, at: origin.addingTimeInterval(105))
        #expect(state.inBed?.id == id)
        #expect(state.sleeping == nil)
        _ = state.record(presence: .present, moving: false, at: origin.addingTimeInterval(150))
        #expect(state.inBed == nil)
    }

    @Test func prolongedUncertaintyEventuallyClearsPresence() {
        var state = NanightRestState()
        _ = state.record(presence: .present, moving: false, at: origin)
        _ = state.record(presence: .present, moving: false, at: origin.addingTimeInterval(3))
        for t in stride(from: 6, through: 183, by: 3) {
            _ = state.record(presence: .uncertain, moving: false, at: origin.addingTimeInterval(Double(t)))
        }
        #expect(state.inBed == nil)
    }

}
