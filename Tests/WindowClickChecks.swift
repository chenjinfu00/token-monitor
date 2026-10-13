import Foundation

@main struct WindowClickChecks {
    static func main() {
        var clicks = WindowClickSequence()
        func click(_ time: Double, _ x: Double = 10, _ y: Double = 10) -> Bool {
            clicks.completedClick(timestamp: time, point: CGPoint(x: x, y: y), doubleClickInterval: 0.5)
        }
        precondition(!click(1) && click(1.2), "First-mouse clicks must form a double click without AppKit clickCount")
        precondition(!click(1.3), "Triple click must not resize twice")
        clicks.cancel()
        precondition(!click(2) && !click(2.6), "Slow clicks must remain single")
        clicks.cancel()
        precondition(!click(3) && !click(3.2, 20), "Distant clicks must not resize")
        clicks.cancel()
        precondition(!click(4)); clicks.cancel()
        precondition(!click(4.2), "Dragging must cancel the pending first click")
        precondition(click(4.4, 12), "Small pointer jitter should still recognize a double click")
        precondition(!click(5) && !click(4.9), "Reversed timestamps must start a new sequence")
        precondition(!click(.nan) && !click(5.1), "Invalid timestamps must cancel pairing")
        print("PASS 7 window double-click and drag sequence checks")
    }
}
