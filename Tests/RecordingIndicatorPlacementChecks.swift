import AppKit

@main
struct RecordingIndicatorPlacementChecks {
    static func main() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 200, height: 20)
        let caret = CGRect(x: 500, y: 400, width: 0, height: 18)
        let position = RecordingIndicatorPlacement.origin(near: caret, panelSize: size, visibleFrame: screen)
        precondition(position == CGPoint(x: 500, y: 372))
        let bottom = RecordingIndicatorPlacement.origin(near: CGRect(x: 500, y: 2, width: 0, height: 18), panelSize: size, visibleFrame: screen)
        precondition(bottom.y == 28)
        for display in [screen, CGRect(x: -1920, y: -300, width: 1920, height: 1080)] {
            for corner in [CGPoint(x: display.minX, y: display.minY), CGPoint(x: display.maxX - 1, y: display.maxY - 1)] {
                let origin = RecordingIndicatorPlacement.origin(near: CGRect(origin: corner, size: CGSize(width: 0, height: 18)), panelSize: size, visibleFrame: display)
                precondition(display.contains(CGRect(origin: origin, size: size)))
            }
        }
        print("PASS: caret placement, bottom-edge placement, screen bounds, secondary monitor.")
    }
}
