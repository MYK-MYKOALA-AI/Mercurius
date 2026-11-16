import Foundation
import Testing
@testable import CursusVox

@Test @MainActor func blankRetryReportsSilenceAndRefreshesHomeWithItsCharge() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    for text in ["", " \n\t "] {
        let billed = DeliveryRecord.addToDay(speech: 0.012, cleanup: nil, count: false,
            day: nil, total: 0, dictations: 0, now: now)
        var events: [String] = []
        let stopped = Application.handleEmptyRetry(text, failure: { events.append($0) }, refresh: {
            events.append(DeliveryRecord.daySummary(day: billed.day, total: billed.total,
                words: billed.words, now: now) ?? "missing cost")
        })
        #expect(stopped)
        #expect(events == ["No speech was heard. Try recording again", "Today $0.012"])
        #expect(billed.dictations == 0)
    }
    var refreshed = false
    // A newer dictation may suppress the pill; Home must still show the charge.
    #expect(Application.handleEmptyRetry("", failure: { _ in }, refresh: { refreshed = true }))
    #expect(refreshed)
}

@Test @MainActor func retryFailureAndSuccessfulSpeechKeepDistinctFeedback() {
    var messages: [String] = [], refreshes = 0
    #expect(Application.handleEmptyRetry(nil, failure: { messages.append($0) }, refresh: { refreshes += 1 }))
    #expect(messages == ["Retry failed. Check the network and try again"])
    #expect(refreshes == 1)
    #expect(!Application.handleEmptyRetry(" Ship it today. ", failure: { messages.append($0) }, refresh: { refreshes += 1 }))
    #expect(messages.count == 1)
    #expect(refreshes == 1)
}
