import Testing
import Physica
@testable import StoryStudio

@Suite struct DocumentCodableTests {
    @Test func starterRoundTrips() throws {
        let doc = StoryDocument.starter()
        let back = try StoryDocumentIO.decode(StoryDocumentIO.encode(doc))
        #expect(back == doc)
    }

    @Test func allElementKindsRoundTrip() throws {
        var slide = SlideDoc(title: "S", caption: "c")
        slide.elements = [
            ElementDoc(id: 1, name: "t", kind: .text("hi", fontSize: 0.5), position: Vec2(1, 2), colorHex: 0x112233),
            ElementDoc(id: 2, name: "c", kind: .circle(radius: 1.5), position: Vec2(-1, 0), colorHex: 0xAABBCC),
            ElementDoc(id: 3, name: "r", kind: .rectangle(width: 2, height: 3), position: Vec2(0, 0), colorHex: 0xFFFFFF),
            ElementDoc(id: 4, name: "tri", kind: .triangle(side: 1.2), position: Vec2(2, 2), colorHex: 0x000000),
        ]
        let doc = StoryDocument(slides: [slide], nextElementID: 5)
        let back = try StoryDocumentIO.decode(StoryDocumentIO.encode(doc))
        #expect(back == doc)
    }

    @Test func stepsAndTransitionsRoundTrip() throws {
        var slide = SlideDoc(title: "Anim", transition: .pushRight)
        slide.elements = [
            ElementDoc(id: 1, name: "c", kind: .circle(radius: 1), position: Vec2(0, 0), colorHex: 0x5CD0B3)
        ]
        slide.steps = [
            StepDoc(id: 1, elementID: 1, verb: .write, start: 0, duration: 1),
            StepDoc(id: 2, elementID: 1, verb: .fade(to: 0.5), start: 1, duration: 0.5),
            StepDoc(id: 3, elementID: 1, verb: .color(hex: 0xFF0000), start: 1.5, duration: 0.5),
        ]
        let doc = StoryDocument(slides: [slide], nextElementID: 2, nextStepID: 4)
        let back = try StoryDocumentIO.decode(StoryDocumentIO.encode(doc))
        #expect(back == doc)
    }
}

@Suite struct CommandStackTests {
    @Test func undoThenRedoRestoresStates() {
        var stack = CommandStack<Int>()
        #expect(!stack.canUndo)
        stack.record(0)        // before 0 → 1
        stack.record(1)        // before 1 → 2   (current is now 2)
        #expect(stack.canUndo)
        #expect(stack.undo(current: 2) == 1)
        #expect(stack.undo(current: 1) == 0)
        #expect(!stack.canUndo)
        #expect(stack.redo(current: 0) == 1)
        #expect(stack.canRedo)   // 2 is still on the redo stack
    }

    @Test func recordClearsRedo() {
        var stack = CommandStack<Int>()
        stack.record(0)
        _ = stack.undo(current: 1)
        #expect(stack.canRedo)
        stack.record(0)          // a fresh edit invalidates redo
        #expect(!stack.canRedo)
    }

    @Test func sameLabelCoalescesToOneEntry() {
        var stack = CommandStack<Int>()
        stack.record(0, coalescingLabel: "drag")
        stack.record(1, coalescingLabel: "drag")
        stack.record(2, coalescingLabel: "drag")
        #expect(stack.undo(current: 3) == 0)   // collapses to the pre-drag state
        #expect(!stack.canUndo)
    }
}

@Suite struct ElementKindEditingTests {
    @Test func editableTextReadsTextAndTeX() {
        #expect(ElementKind.text("hi", fontSize: 0.5).editableText == "hi")
        #expect(ElementKind.math(tex: "x^2", fontSize: 0.5).editableText == "x^2")
        #expect(ElementKind.circle(radius: 1).editableText == nil)
        #expect(ElementKind.rectangle(width: 1, height: 2).editableText == nil)
        #expect(ElementKind.triangle(side: 1).editableText == nil)
    }

    @Test func withEditableTextReplacesAndPreservesFontSize() {
        #expect(ElementKind.text("a", fontSize: 0.8).withEditableText("b") == .text("b", fontSize: 0.8))
        #expect(ElementKind.math(tex: "a", fontSize: 0.3).withEditableText("\\beta")
                == .math(tex: "\\beta", fontSize: 0.3))
    }

    @Test func withEditableTextLeavesShapesUnchanged() {
        let circle = ElementKind.circle(radius: 1.2)
        #expect(circle.withEditableText("nope") == circle)
    }

    @Test func roundTripsThroughItself() {
        let kind = ElementKind.text("Story Studio", fontSize: 0.9)
        #expect(kind.withEditableText(kind.editableText ?? "") == kind)
    }
}

@Suite @MainActor struct CompilerTests {
    @Test func buildsSlidesAndEntityMap() {
        var slide = SlideDoc(title: "One", caption: "hi")
        slide.elements = [
            ElementDoc(id: 7, name: "c", kind: .circle(radius: 1), position: Vec2(0, 0), colorHex: 0x5CD0B3),
            ElementDoc(id: 8, name: "r", kind: .rectangle(width: 1, height: 1), position: Vec2(1, 1), colorHex: 0xFFD479),
        ]
        let doc = StoryDocument(slides: [slide, SlideDoc(title: "Two")], nextElementID: 9)
        let build = StoryCompiler.build(doc, font: nil)
        #expect(build.story.slides.count == 2)
        #expect(build.entities[7] != nil)   // shapes need no font
        #expect(build.entities[8] != nil)
    }

    @Test func textDropsWithoutAFont() {
        var slide = SlideDoc(title: "One")
        slide.elements = [
            ElementDoc(id: 1, name: "t", kind: .text("hi", fontSize: 0.5), position: Vec2(0, 0), colorHex: 0xFFFFFF)
        ]
        let doc = StoryDocument(slides: [slide], nextElementID: 2)
        let build = StoryCompiler.build(doc, font: nil)
        #expect(build.entities[1] == nil)   // text needs a font
    }

    @Test func lowersStepsIntoTimedSlide() {
        var slide = SlideDoc(title: "Anim")
        slide.elements = [
            ElementDoc(id: 1, name: "c", kind: .circle(radius: 1), position: Vec2(0, 0), colorHex: 0x5CD0B3)
        ]
        slide.steps = [
            StepDoc(id: 1, elementID: 1, verb: .fade(to: 0), start: 0, duration: 1),
            StepDoc(id: 2, elementID: 1, verb: .scaleTo(1.5), start: 1, duration: 0.5),
        ]
        let doc = StoryDocument(slides: [slide], nextElementID: 2, nextStepID: 3)
        let build = StoryCompiler.build(doc, font: nil)
        #expect(build.story.slides.count == 1)
        // fade (1s) + scale (0.5s) = 1.5s span, no trailing wait when steps exist.
        #expect(abs(build.story.slides[0].duration - 1.5) < 1e-3)
    }
}
