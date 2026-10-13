import Foundation

struct WindowClickSequence {
    private var previous: (timestamp: TimeInterval, point: CGPoint)?

    mutating func cancel() { previous = nil }

    mutating func completedClick(timestamp: TimeInterval, point: CGPoint,
                                 doubleClickInterval: TimeInterval) -> Bool {
        guard timestamp.isFinite, point.x.isFinite, point.y.isFinite else {
            previous = nil
            return false
        }
        guard let previous, timestamp >= previous.timestamp,
              timestamp - previous.timestamp <= doubleClickInterval,
              hypot(point.x - previous.point.x, point.y - previous.point.y) <= 6 else {
            self.previous = (timestamp, point)
            return false
        }
        // A third click begins a new pair, rather than resizing twice.
        self.previous = nil
        return true
    }
}
