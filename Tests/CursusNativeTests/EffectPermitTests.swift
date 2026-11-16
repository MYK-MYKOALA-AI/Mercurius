import Foundation
import Testing
@testable import CursusVox

@Test func deliveryPermitIsSingleUseAndRevocable() {
    let permit = EffectPermit(expiresAt: ProcessInfo.processInfo.systemUptime + 10)
    #expect(permit.valid)
    #expect(permit.claim())
    #expect(!permit.claim())
    #expect(!permit.valid)
    let revoked = EffectPermit(expiresAt: ProcessInfo.processInfo.systemUptime + 10)
    revoked.revoke()
    #expect(!revoked.valid)
    #expect(!revoked.claim())
    let expired = EffectPermit(expiresAt: 0)
    #expect(!expired.claim())
}
