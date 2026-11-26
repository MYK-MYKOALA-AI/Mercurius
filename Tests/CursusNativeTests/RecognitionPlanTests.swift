import Testing
@testable import CursusVox

// Grok is the default; on-device Apple speech is the backup.
@Test func cloudFirstFallsBackToOnDeviceWhenItIsReady() {
    #expect(RecognitionPlan.engines(selected: .cloud, cloudKey: true, appleReady: true) == [.cloud, .apple])
    #expect(RecognitionPlan.engines(selected: .cloud, cloudKey: true, appleReady: false) == [.cloud])
}
@Test func missingCloudKeyGoesStraightToOnDevice() {
    #expect(RecognitionPlan.engines(selected: .cloud, cloudKey: false, appleReady: true) == [.apple])
    #expect(RecognitionPlan.engines(selected: .cloud, cloudKey: false, appleReady: false).isEmpty)
}
@Test func choosingAppleNeverSendsAudioToTheCloud() {
    #expect(RecognitionPlan.engines(selected: .apple, cloudKey: true, appleReady: true) == [.apple])
    #expect(RecognitionPlan.engines(selected: .apple, cloudKey: true, appleReady: false).isEmpty)
}
@Test func cloudLeavesTimeForAnOnDeviceRetryInsideTheFinalizationDeadline() {
    #expect(CloudSpeech.requestTimeout < 15)
}
