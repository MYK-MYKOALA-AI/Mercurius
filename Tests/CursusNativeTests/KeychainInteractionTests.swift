import Testing
@testable import CursusVox

@Test func passiveKeychainScopeDisablesUIAndRestoresPreviousPolicy() {
    var policy = true
    var writes: [Bool] = []
    let value = KeychainInteraction.perform(allow: false, get: { policy }, set: {
        policy = $0; writes.append($0); return true
    }) { #expect(!policy); return "synthetic credential" }
    #expect(value == "synthetic credential")
    #expect(policy)
    #expect(writes == [false, true])
}
@Test func explicitKeychainScopeRestoresPreviouslyDisabledUI() {
    var policy = false
    let value = KeychainInteraction.perform(allow: true, get: { policy }, set: {
        policy = $0; return true
    }) { #expect(policy); return 1 }
    #expect(value == 1)
    #expect(!policy)
}
@Test func missingOrUnenforceableKeychainPolicyMakesZeroCredentialReads() {
    var reads = 0
    let missing: Int? = KeychainInteraction.perform(allow: false, get: { nil }, set: { _ in
        Issue.record("Missing policy must not be changed"); return true
    }) { reads += 1; return 1 }
    let unenforced: Int? = KeychainInteraction.perform(allow: false, get: { true }, set: { _ in false }) {
        reads += 1; return 1
    }
    #expect(missing == nil); #expect(unenforced == nil); #expect(reads == 0)
}
@Test func failedKeychainPolicyRestoreNeverReturnsCredential() {
    var writes = 0
    let value = KeychainInteraction.perform(allow: false, get: { true }, set: { _ in
        writes += 1; return writes == 1
    }) { "synthetic credential" }
    #expect(value == nil)
    #expect(writes == 2)
}
