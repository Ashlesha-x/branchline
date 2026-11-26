import Foundation

/// Keeps departures, rather than recording programmatic selection updates as visits.
public struct BrowsingHistory<Location: Equatable> {
    public private(set) var back: [Location] = []
    public private(set) var forward: [Location] = []
    public init() {}
    public mutating func depart(from current: Location) {
        if back.last != current { back.append(current) }
        if back.count > 80 { back.removeFirst(back.count - 80) }
        forward.removeAll()
    }
    public mutating func goBack(from current: Location, allowing: (Location) -> Bool) -> Location? {
        while let target = back.popLast() {
            guard allowing(target) else { continue }
            forward.append(current); return target
        }
        return nil
    }
    public mutating func goForward(from current: Location, allowing: (Location) -> Bool) -> Location? {
        while let target = forward.popLast() {
            guard allowing(target) else { continue }
            back.append(current); return target
        }
        return nil
    }
    public mutating func reset() { back.removeAll(); forward.removeAll() }
}
