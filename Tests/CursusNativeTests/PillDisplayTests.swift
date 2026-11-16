import Testing
import CursusCore
@testable import CursusVox

@Test func activeStatesShowListeningThenTranscribing() {
    #expect(PillDisplay.active(.startingHeld) == .starting)
    #expect(PillDisplay.active(.startingToggle) == .starting)
    #expect(PillDisplay.active(.recordingHeld) == .listening)
    #expect(PillDisplay.active(.recordingToggle) == .listening)
    #expect(PillDisplay.active(.finalizing) == .transcribing)
    #expect(PillDisplay.active(.delivering) == .transcribing)
    #expect(PillDisplay.active(.idle) == nil)
    #expect(PillDisplay.active(.recoverableError) == nil)
}
@Test func resultSaysPastedCopiedOrWhatToDo() {
    #expect(PillDisplay.result([.recognized, .copied, .pasteSentUnconfirmed], onDevice: false) == .done("Paste sent · check editor"))
    #expect(PillDisplay.result([.recognized, .copied, .pasteSentUnconfirmed], onDevice: true) == .done("Paste sent · check editor · on-device"))
    #expect(PillDisplay.result([.recognized, .copied, .deliveryBlocked], onDevice: false) == .done("Copied — ⌘V to paste"))
    #expect(PillDisplay.result([.recognized, .copied], onDevice: false, noTextField: true)
        == .done("Copied, no text field — ⌘V to paste"))
    #expect(PillDisplay.result([.recognized, .deliveryBlocked], onDevice: false)
            == .failed("Couldn't paste. Open Clipboard to copy or retry."))
    #expect(PillDisplay.result([], onDevice: false) == nil)
}

@Test func pillOnlyClaimsConfirmedInsertionWhenItHasAReceipt() {
    #expect(PillDisplay.result([.insertedConfirmed], onDevice: false) == .done("Inserted"))
    #expect(PillDisplay.result([.insertedUnconfirmed], onDevice: false) == .done("Insertion sent · check editor"))
}
@Test func deliveredTranscriptEchoRetainsUncertainty() {
    #expect(PillDisplay.result([.recognized, .pasteSentUnconfirmed], onDevice: true,
                              transcript: "Fresh words")
        == .delivered(status: "Paste sent · check editor · on-device", transcript: "Fresh words"))
    #expect(PillDisplay.result([.recognized, .insertedUnconfirmed], onDevice: false, transcript: "Fresh words")
        == .delivered(status: "Insertion sent · check editor", transcript: "Fresh words"))
    #expect(PillDisplay.result([.recognized, .insertedConfirmed], onDevice: false, transcript: "Fresh words")
        == .delivered(status: "Inserted", transcript: "Fresh words"))
}
@Test func pasteOnlyOrBlockedDeliveryNeverEchoesOldRecoveryText() {
    #expect(PillDisplay.result([.pasteSentUnconfirmed], onDevice: false, transcript: "Old words")
        == .done("Paste sent · check editor"))
    #expect(PillDisplay.result([.recognized, .copied], onDevice: false, transcript: "Old words")
        == .done("Copied — ⌘V to paste"))
    #expect(PillDisplay.result([.recognized, .deliveryBlocked], onDevice: false, transcript: "Old words")
        == .failed("Couldn't paste. Open Clipboard to copy or retry."))
}
@Test func deliveredTranscriptEchoIsBounded() {
    let text = String(repeating: "a", count: 241)
    #expect(PillDisplay.result([.recognized, .insertedConfirmed], onDevice: false, transcript: text)
        == .delivered(status: "Inserted", transcript: String(repeating: "a", count: 240) + "…"))
}


@Test func onlyTheMatchingBlockedDeliveryOffersRecoveryCopy() {
    let offered = PillDisplay.result([.recognized, .deliveryBlocked], onDevice: false,
        recoveryGeneration: 7, controllerGeneration: 9)
    #expect(offered == .blockedDelivery(recoveryGeneration: 7, controllerGeneration: 9))
    #expect(offered?.allowsRecoveryCopy(recoveryGeneration: 7, controllerGeneration: 9) == true)
    #expect(offered?.allowsRecoveryCopy(recoveryGeneration: 8, controllerGeneration: 9) == false)
    #expect(offered?.allowsRecoveryCopy(recoveryGeneration: 7, controllerGeneration: 10) == false)
    #expect(offered?.allowsRecoveryCopy(recoveryGeneration: nil, controllerGeneration: 9) == false)
    for failure in ["Microphone failed", "No speech was heard", "Clip failed", PillDisplay.blockedMessage] {
        #expect(!PillContent.failed(failure).allowsRecoveryCopy(recoveryGeneration: 7, controllerGeneration: 9))
    }
    #expect(PillDisplay.result([.recognized, .copied, .deliveryBlocked], onDevice: false,
        recoveryGeneration: 7, controllerGeneration: 9)?.allowsRecoveryCopy(recoveryGeneration: 7, controllerGeneration: 9) == false)
}

@Test func cleanupStatusIsHonest() {
    func status(_ note: String?, model: String? = nil) -> String? {
        PillDisplay.cleanupStatus(CleanupOutcome(text: "x", model: model, millis: 0, note: note))
    }
    #expect(status(nil, model: "m") == "cleaned")
    #expect(status("technical text") == "code left as spoken")
    #expect(status("AI cleanup off") == "cleanup off")
    #expect(status("a/b rejected: added words; over 1.5s budget") == "not cleaned: model changed your words")
    #expect(status("a/b timed out; over 1.5s budget") == "not cleaned: timed out")
    #expect(status("a/b HTTP 402") == "not cleaned: out of credit")
    #expect(status("a/b rejected: added words") == "not cleaned: model changed your words")
    #expect(status("cleanup key unavailable") == "not cleaned: no OpenRouter key")
    #expect(status("nothing to clean") == nil)
    #expect(PillDisplay.cleanupStatus(nil) == nil)
    let cleaned = CleanupOutcome(text: "x", model: "m", millis: 0, note: nil)
    #expect(PillDisplay.result([.copied], onDevice: false, cleanup: cleaned) == .done("Copied — ⌘V to paste · cleaned"))
    #expect(PillDisplay.result([.pasteSentUnconfirmed], onDevice: false, cleanup: cleaned) == .done("Paste sent · check editor · cleaned"))
}

@Test func theMyKoalaLinkGoesToMyKoala() {
    #expect(MadeByMyKoala.url.host == "mykoala.com.au")
    #expect(MadeByMyKoala.url.scheme == "https")
}
