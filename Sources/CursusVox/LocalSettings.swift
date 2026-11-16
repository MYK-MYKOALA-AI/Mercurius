import Foundation

@MainActor final class LocalSettings<Value: Codable> {
    var value: Value
    private(set) var problem: String?
    private let key: String
    private let defaults: UserDefaults
    init(key: String, initial: Value, defaults: UserDefaults = .standard) {
        self.key = key; self.defaults = defaults
        if let data = defaults.data(forKey: key) {
            do { value = try JSONDecoder().decode(Value.self,from: data) }
            catch { value = initial; problem = "Saved settings could not be read. Existing data preserved." }
        } else { value = initial }
    }
    @discardableResult func save() -> Bool {
        guard problem == nil else { return false }
        do { defaults.set(try JSONEncoder().encode(value),forKey: key); return true }
        catch { problem = "Settings could not be saved."; return false }
    }
}
