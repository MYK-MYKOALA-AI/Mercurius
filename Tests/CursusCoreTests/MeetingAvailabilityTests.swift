import Testing
@testable import CursusCore

@Test func meetingShortcutsHaveExplicitUnavailableOutcomes() {
    #expect(MeetingCommand(keyCode: 46)?.unavailable == .captureAndLibraryNotReady)
    #expect(MeetingCommand(keyCode: 35)?.unavailable == .localAnswerEngineNotReady)
    // Ordinary dictation, clipping, window text, Escape and Space keep their existing routes.
    for key: Int64 in [13, 17, 49, 53, 63, -1, 0, 47] {
        #expect(MeetingCommand(keyCode: key) == nil)
    }
}
