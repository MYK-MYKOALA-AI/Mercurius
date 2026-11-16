import Testing
@testable import CursusVox

// Copy last / Paste last reserve synchronously, before any suspension, so an
// overlapping request is refused and cannot change the accepted one's restore.
@MainActor @Test func overlappingMenuRequestsAreRefusedUntilTheFirstFinishes() {
    let slot = MenuRequestSlot()
    #expect(slot.reserve())
    #expect(!slot.reserve())
    #expect(!slot.reserve())
    slot.release()
    #expect(slot.reserve())
}
