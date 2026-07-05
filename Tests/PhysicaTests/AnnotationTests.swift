import Foundation
import Testing
@testable import PhysicaFoundation
@testable import PhysicaAlgebra
@testable import PhysicaTypesetting
@testable import PhysicaKernel
@testable import PhysicaCharts
@testable import PhysicaPhysics
@testable import PhysicaEquationGame

@Suite @MainActor struct AnnotationTests {
    private func target() -> Circle {
        let dot = Circle(radius: 0.5)
        dot.position = Position(1, 2, 0)
        return dot
    }

    @Test func surroundingRectangleFramesTarget() {
        let dot = target()
        let box = SurroundingRectangle(of: dot, padding: 0.3)
        let tb = dot.worldBounds
        let bb = box.worldBounds
        // Centered on the target, larger by ~2·padding on each axis.
        #expect(abs(bb.center.x - tb.center.x) < 1e-3)
        #expect(abs(bb.center.y - tb.center.y) < 1e-3)
        #expect(bb.size.x >= tb.size.x + 0.6 - 0.05)
        #expect(bb.size.y >= tb.size.y + 0.6 - 0.05)
        #expect(!box.style.isFilled)               // stroke-only frame
    }

    @Test func underlineSitsBelowTarget() {
        let dot = target()
        let line = Underline(of: dot, padding: 0.1, gap: 0.12)
        let lb = line.worldBounds
        let tb = dot.worldBounds
        #expect(lb.max.y < tb.min.y + 1e-3)        // entirely below
        #expect(lb.min.x <= tb.min.x + 1e-3)       // spans the full width + padding
        #expect(lb.max.x >= tb.max.x - 1e-3)
        #expect(!line.style.isFilled)
    }

    @Test func pointerSitsOutsideEdgePointingIn() {
        let dot = target()
        let p = Pointer(at: dot, from: .top, gap: 0.15, size: 0.45)
        let pb = p.worldBounds
        let tb = dot.worldBounds
        #expect(pb.min.y > tb.max.y - 1e-3)        // above the top edge
        #expect(p.style.isFilled)                  // solid caret
        #expect(!p.path.isEmpty)
    }

    @Test func spotlightPunchesHole() {
        let dot = target()
        let s = Spotlight(on: dot, padding: 0.3, coverage: 50)
        // Outer cover quad + inner hole = two contours; even-odd fill subtracts.
        #expect(s.path.contours.count == 2)
        #expect(s.style.isFilled)
        #expect(s.style.opacity < 1)               // translucent dim
        let outer = Path(contours: [s.path.contours[0]]).bounds
        let inner = Path(contours: [s.path.contours[1]]).bounds
        #expect(outer.size.x > 40)                 // covers the frame
        #expect(inner.size.x < 2)                  // window is target-sized
        #expect(abs(inner.center.x - dot.worldBounds.center.x) < 1e-3)
    }

    @Test func calloutHasLabelAndLeaderOffsetFromTarget() throws {
        let candidates = [
            "/System/Library/Fonts/Supplemental/Arial.ttf",
            "/System/Library/Fonts/Supplemental/Tahoma.ttf",
        ]
        var font: Font?
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let data = FileManager.default.contents(atPath: path), let f = try? Font(data: [UInt8](data)) {
                font = f
                break
            }
        }
        guard let font else { return }   // environment-dependent — skip

        let dot = target()
        let note = Callout("bob", pointingAt: dot, font: font, edge: .topRight, distance: 1.3)
        // Group of leader (drawn under) + label (on top).
        #expect(note.children.count == 2)
        #expect(note.children[0] === note.leader)
        #expect(note.children[1] === note.label)
        // The label is set off the target toward the requested edge.
        let tb = dot.worldBounds
        #expect(note.label.position.x > tb.center.x)
        #expect(note.label.position.y > tb.center.y)
        #expect(!note.leader.path.isEmpty)
    }

    @Test func annotationsAreDrawable() {
        // Path-based annotations reveal via `.draw` (snapshot shows their contours).
        let scene = Scene()
        let dot = target()
        scene.add(dot)
        let box = SurroundingRectangle(of: dot)
        scene.play(.draw(box), for: 0.5.s)
        scene.seek(to: 0.5)
        #expect(scene.entities.contains { $0 === box })
        let snapshot = scene.snapshot()
        #expect(snapshot.primitives.contains { if case .path = $0 { return true } else { return false } })
    }
}
