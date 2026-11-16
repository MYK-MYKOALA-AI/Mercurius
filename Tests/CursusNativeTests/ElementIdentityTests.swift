import Testing
@testable import CursusVox

@Test func elementIdentitiesRemainBoundedWithoutPermanentExhaustion() {
    var registry = ElementIdentities<String>(capacity: 3, equal: ==)
    let first = registry.identity("first")
    #expect(registry.identity("first") == first)
    for i in 0..<1000 {
        #expect(!registry.identity("field-\(i)").isEmpty)
        #expect(registry.count <= 3)
    }
    #expect(registry.identity("first") != first)
    #expect(registry.count == 3)
    registry.removeAll()
    #expect(registry.count == 0)
    #expect(registry.identity("first") != first)
}
