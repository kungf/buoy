import Foundation

/// Selection persistence abstraction (allows injecting an in-memory impl for tests, isolating UserDefaults).
protocol SelectionStorage {
    func loadSelectedIds() -> [String]
    func saveSelectedIds(_ ids: [String])
}

/// Per-ball screen-position persistence. Each selected provider owns an independent panel that the
/// user can freely drag; positions survive restart so balls stay where the user left them.
protocol BallPositionStorage {
    func loadOrigin(for id: String) -> CGPoint?
    func saveOrigin(_ origin: CGPoint, for id: String)
}

/// User preferences backed by UserDefaults.
/// - Selection: key `tokenrunway.selectedProviderIds`, value `[String]` (ordered providerId array).
/// - Ball positions: key `tokenrunway.ballPositions`, value `[String: [Double]]` where each pair is `[x, y]`.
struct Preferences: SelectionStorage, BallPositionStorage {
    private static let selectionKey = "tokenrunway.selectedProviderIds"
    private static let positionsKey = "tokenrunway.ballPositions"
    private let defaults = UserDefaults.standard

    // MARK: Selection

    func loadSelectedIds() -> [String] {
        defaults.array(forKey: Self.selectionKey) as? [String] ?? []
    }

    func saveSelectedIds(_ ids: [String]) {
        defaults.set(ids, forKey: Self.selectionKey)
    }

    // MARK: Ball positions

    func loadOrigin(for id: String) -> CGPoint? {
        guard let dict = defaults.dictionary(forKey: Self.positionsKey) as? [String: [Double]],
              let pair = dict[id], pair.count == 2 else { return nil }
        return CGPoint(x: pair[0], y: pair[1])
    }

    func saveOrigin(_ origin: CGPoint, for id: String) {
        var dict = (defaults.dictionary(forKey: Self.positionsKey) as? [String: [Double]]) ?? [:]
        dict[id] = [origin.x, origin.y]
        defaults.set(dict, forKey: Self.positionsKey)
    }
}
