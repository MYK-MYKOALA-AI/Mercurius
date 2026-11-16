import Testing
@testable import CursusCore

@Test func setupObservationNeverAdmitsAPermissionRequest() {
    var setup = PermissionSetup()
    for _ in 0..<10 {
        #expect(setup.receive(.opened) == nil)
        #expect(setup.receive(.refreshed) == nil)
        #expect(setup.pending == nil)
    }
}

@Test func setupSerializesExplicitRequestsWithoutChainingOrAcceptingOtherCompletions() {
    var setup = PermissionSetup()
    #expect(setup.receive(.request(.microphone)) == .microphone)
    for permission in PermissionSetup.Permission.allCases {
        #expect(setup.receive(.request(permission)) == nil)
    }
    #expect(setup.receive(.completed(.speech)) == nil)
    #expect(setup.pending == .microphone)
    #expect(setup.receive(.refreshed) == nil)
    #expect(setup.receive(.completed(.microphone)) == nil)
    #expect(setup.pending == nil)
    #expect(setup.receive(.request(.speech)) == .speech)
}

@Test func settingsHandoffRequiresExplicitResumeAndDoesNotAssertAGrant() {
    var setup = PermissionSetup()
    #expect(setup.receive(.request(.accessibility)) == .accessibility)
    _ = setup.receive(.resumed)
    #expect(setup.pending == .accessibility)
    _ = setup.receive(.handedOff(.speech))
    #expect(!setup.awaitingSettings)
    _ = setup.receive(.handedOff(.accessibility))
    #expect(setup.awaitingSettings)
    #expect(setup.receive(.request(.microphone)) == nil)
    _ = setup.receive(.opened)
    _ = setup.receive(.refreshed)
    #expect(setup.pending == .accessibility)
    _ = setup.receive(.resumed)
    #expect(setup.pending == nil)
    #expect(!setup.awaitingSettings)
}

@Test func credentialSaveRequiresExplicitValidActionAndKeepsPendingOwnershipOnClose() {
    var setup = CredentialSetup()
    func receive(_ event: CredentialSetup.Event) -> Bool { setup.receive(event) }
    #expect(!receive(.opened))
    #expect(!receive(.edited))
    #expect(!receive(.save(valid: false)))
    #expect(!setup.isSaving)
    #expect(receive(.save(valid: true)))
    #expect(!receive(.closed) && setup.isSaving)
    #expect(!receive(.opened) && setup.isSaving)
    #expect(!receive(.save(valid: true)))
    #expect(!receive(.completed) && !setup.isSaving)
    #expect(receive(.save(valid: true)))
}
