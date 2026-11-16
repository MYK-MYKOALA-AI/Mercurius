import Foundation

// Bounded identity history owned by the Accessibility actor. Evicted elements
// receive fresh IDs, so old delivery snapshots fail comparison after eviction.
struct ElementIdentities<Element> {
    private var entries: [(Element, String)] = []
    private let capacity: Int
    private let equal: (Element, Element) -> Bool
    init(capacity: Int = 256, equal: @escaping (Element, Element) -> Bool) {
        precondition(capacity > 0)
        self.capacity = capacity; self.equal = equal
    }
    var count: Int { entries.count }
    mutating func identity(_ element: Element) -> String {
        if let entry = entries.first(where: { equal($0.0, element) }) { return entry.1 }
        if entries.count == capacity { entries.removeFirst() }
        let id = UUID().uuidString
        entries.append((element, id))
        return id
    }
    mutating func removeAll() { entries.removeAll() }
}
