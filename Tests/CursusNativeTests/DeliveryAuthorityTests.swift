import Testing
@testable import CursusVox

@Test func olderRecoveryRemainsAdmissibleUntilControllerOrRecoveryChanges() {
    // Stop before capture preserves an older transcript while advancing the
    // controller generation. Explicit Copy Last must still be available.
    let authority = DeliveryAuthority(controllerGeneration: 3, recoveryGeneration: 1)
    #expect(authority.valid(controller: 3, recovery: 1, secure: false))
    #expect(!authority.valid(controller: 4, recovery: 1, secure: false))
    #expect(!authority.valid(controller: 3, recovery: 2, secure: false))
    #expect(!authority.valid(controller: 3, recovery: nil, secure: false))
    #expect(!authority.valid(controller: 3, recovery: 1, secure: true))
}
