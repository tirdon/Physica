import Testing
@testable import Physica

// Genuine MathJax 3.2 tex-svg output (fontCache: "local"), rendered offline —
// the same component the browser loads, so structure drift shows up here.

/// `x^2`
private let xSquaredSVG = #"""
<svg style="vertical-align: -0.025ex;" xmlns="http://www.w3.org/2000/svg" width="2.282ex" height="2.025ex" role="img" focusable="false" viewBox="0 -883.9 1008.6 894.9" xmlns:xlink="http://www.w3.org/1999/xlink"><defs><path id="MJX-1-TEX-I-1D465" d="M52 289Q59 331 106 386T222 442Q257 442 286 424T329 379Q371 442 430 442Q467 442 494 420T522 361Q522 332 508 314T481 292T458 288Q439 288 427 299T415 328Q415 374 465 391Q454 404 425 404Q412 404 406 402Q368 386 350 336Q290 115 290 78Q290 50 306 38T341 26Q378 26 414 59T463 140Q466 150 469 151T485 153H489Q504 153 504 145Q504 144 502 134Q486 77 440 33T333 -11Q263 -11 227 52Q186 -10 133 -10H127Q78 -10 57 16T35 71Q35 103 54 123T99 143Q142 143 142 101Q142 81 130 66T107 46T94 41L91 40Q91 39 97 36T113 29T132 26Q168 26 194 71Q203 87 217 139T245 247T261 313Q266 340 266 352Q266 380 251 392T217 404Q177 404 142 372T93 290Q91 281 88 280T72 278H58Q52 284 52 289Z"></path><path id="MJX-1-TEX-N-32" d="M109 429Q82 429 66 447T50 491Q50 562 103 614T235 666Q326 666 387 610T449 465Q449 422 429 383T381 315T301 241Q265 210 201 149L142 93L218 92Q375 92 385 97Q392 99 409 186V189H449V186Q448 183 436 95T421 3V0H50V19V31Q50 38 56 46T86 81Q115 113 136 137Q145 147 170 174T204 211T233 244T261 278T284 308T305 340T320 369T333 401T340 431T343 464Q343 527 309 573T212 619Q179 619 154 602T119 569T109 550Q109 549 114 549Q132 549 151 535T170 489Q170 464 154 447T109 429Z"></path></defs><g stroke="currentColor" fill="currentColor" stroke-width="0" transform="scale(1,-1)"><g data-mml-node="math"><g data-mml-node="msup"><g data-mml-node="mi"><use data-c="1D465" xlink:href="#MJX-1-TEX-I-1D465"></use></g><g data-mml-node="mn" transform="translate(605,413) scale(0.707)"><use data-c="32" xlink:href="#MJX-1-TEX-N-32"></use></g></g></g></g></svg>
"""#

/// `\frac{a}{b}` — numerator, denominator, and a <rect> fraction bar.
private let fractionSVG = #"""
<svg style="vertical-align: -1.577ex;" xmlns="http://www.w3.org/2000/svg" width="2.192ex" height="4.104ex" role="img" focusable="false" viewBox="0 -1117 969 1814" xmlns:xlink="http://www.w3.org/1999/xlink"><defs><path id="MJX-2-TEX-I-1D44E" d="M33 157Q33 258 109 349T280 441Q331 441 370 392Q386 422 416 422Q429 422 439 414T449 394Q449 381 412 234T374 68Q374 43 381 35T402 26Q411 27 422 35Q443 55 463 131Q469 151 473 152Q475 153 483 153H487Q506 153 506 144Q506 138 501 117T481 63T449 13Q436 0 417 -8Q409 -10 393 -10Q359 -10 336 5T306 36L300 51Q299 52 296 50Q294 48 292 46Q233 -10 172 -10Q117 -10 75 30T33 157ZM351 328Q351 334 346 350T323 385T277 405Q242 405 210 374T160 293Q131 214 119 129Q119 126 119 118T118 106Q118 61 136 44T179 26Q217 26 254 59T298 110Q300 114 325 217T351 328Z"></path><path id="MJX-2-TEX-I-1D44F" d="M73 647Q73 657 77 670T89 683Q90 683 161 688T234 694Q246 694 246 685T212 542Q204 508 195 472T180 418L176 399Q176 396 182 402Q231 442 283 442Q345 442 383 396T422 280Q422 169 343 79T173 -11Q123 -11 82 27T40 150V159Q40 180 48 217T97 414Q147 611 147 623T109 637Q104 637 101 637H96Q86 637 83 637T76 640T73 647ZM336 325V331Q336 405 275 405Q258 405 240 397T207 376T181 352T163 330L157 322L136 236Q114 150 114 114Q114 66 138 42Q154 26 178 26Q211 26 245 58Q270 81 285 114T318 219Q336 291 336 325Z"></path></defs><g stroke="currentColor" fill="currentColor" stroke-width="0" transform="scale(1,-1)"><g data-mml-node="math"><g data-mml-node="mfrac"><g data-mml-node="mi" transform="translate(220,676)"><use data-c="1D44E" xlink:href="#MJX-2-TEX-I-1D44E"></use></g><g data-mml-node="mi" transform="translate(270,-686)"><use data-c="1D44F" xlink:href="#MJX-2-TEX-I-1D44F"></use></g><rect width="729" height="60" x="120" y="220"></rect></g></g></g></svg>
"""#

@Suite @MainActor
struct MathSVGTests {
    @Test func superscriptSitsRaisedAndSmaller() throws {
        let glyphs = try MathSVG.glyphs(fromSVG: xSquaredSVG)
        #expect(glyphs.count == 2)  // x, then the 2 — document order
        let x = glyphs[0].path.bounds
        let two = glyphs[1].path.bounds

        // y-up restored: the superscript's bottom is well above the baseline
        // glyph's bottom, and the scale(0.707) shrinks it.
        #expect(two.min.y > x.min.y + 0.3)
        #expect((two.max.y - two.min.y) < (x.max.y - x.min.y) * 1.1)
        let xWidth = x.max.x - x.min.x
        #expect(xWidth > 0.4 && xWidth < 0.6)  // the glyph is ~0.52 em wide

        // The 2 is right of the x.
        #expect(two.min.x > x.max.x - 0.05)
    }

    @Test func formulaIsCenteredOnItsBounds() throws {
        let glyphs = try MathSVG.glyphs(fromSVG: xSquaredSVG)
        var bounds = Bounds.empty
        for glyph in glyphs {
            bounds = bounds.union(glyph.path.bounds)
        }
        #expect(approx(bounds.min.x + bounds.max.x, 0, tolerance: 1e-3))
        #expect(approx(bounds.min.y + bounds.max.y, 0, tolerance: 1e-3))
    }

    @Test func fractionEmitsBarBetweenNumeratorAndDenominator() throws {
        let glyphs = try MathSVG.glyphs(fromSVG: fractionSVG)
        #expect(glyphs.count == 3)  // a, b, rule
        let numerator = glyphs[0].path.bounds
        let denominator = glyphs[1].path.bounds
        let bar = glyphs[2].path.bounds

        // The <rect> rule arrives as one closed 4-corner contour.
        let barContours = glyphs[2].path.contours
        #expect(barContours.count == 1)
        #expect(barContours[0].isClosed)
        #expect(barContours[0].segments.count == 3)

        // Stacked: numerator above the bar, denominator below (y-up).
        #expect(numerator.min.y > bar.max.y)
        #expect(denominator.max.y < bar.min.y)
        // The bar is thin and wide.
        #expect(approx(bar.max.y - bar.min.y, 0.06, tolerance: 1e-3))
        #expect(bar.max.x - bar.min.x > 0.7)
    }

    @Test func mathEntityWritesLikeText() throws {
        let scene = Scene()
        let formula = try TextEntity.math(svg: fractionSVG, fontSize: 0.8, color: .teal)
        scene.play(.write(formula), for: 1.s, easing: .linear)

        scene.update(deltaTime: 0.5)
        #expect(scene.entities.contains { $0 === formula })  // write auto-adds
        let mid = formula.textComponent.writeProgress
        #expect(mid > 0.3 && mid < 0.7)

        scene.update(deltaTime: 0.6)
        #expect(approx(formula.textComponent.writeProgress, 1))
        // Three glyphs → three path primitives once fully written.
        #expect(scene.snapshot().primitives.count == 3)
    }

    @Test func invisibleOperatorsDoNotOccupyGlyphSlots() throws {
        // The demo formula carries U+2061 (function application, d="")
        // between "sin" and "θ" — it must vanish, or tail slices like
        // formula[(n - 4)...] land off by one ("in θ" instead of "sin θ").
        let glyphs = try MathSVG.glyphs(fromSVG: pendulumFormulaSVG)
        #expect(glyphs.count == 11)  // θ ¨ = − g ℓ bar s i n θ
        for glyph in glyphs {
            #expect(!glyph.path.isEmpty)
        }
        // The tail slice is exactly "sin θ": s starts right of the fraction
        // bar, and s/i/n/θ run left to right.
        let bar = glyphs[6].path.bounds
        #expect(glyphs[7].path.bounds.min.x > bar.max.x)
        for index in 7..<10 {
            #expect(glyphs[index].path.bounds.min.x < glyphs[index + 1].path.bounds.min.x)
        }
    }

    @Test func unknownUseReferenceThrows() {
        let markup = ##"<svg viewBox="0 0 1 1"><g><use xlink:href="#missing"></use></g></svg>"##
        #expect(throws: MathSVGError.unknownReference("missing")) {
            try MathSVG.glyphs(fromSVG: markup)
        }
    }

    @Test func nonSVGMarkupThrows() {
        #expect(throws: MathSVGError.notAnSVGDocument) {
            try MathSVG.glyphs(fromSVG: "<div>not math</div>")
        }
        #expect(throws: MathSVGError.noGlyphs) {
            try MathSVG.glyphs(fromSVG: #"<svg viewBox="0 0 1 1"><g></g></svg>"#)
        }
    }

    @Test func transformListComposesLeftToRight() {
        // translate then scale: p' = translate(10,0) ∘ scale(2) → (2x+10, 2y).
        let transform = Affine2(svgTransform: "translate(10,0) scale(2)")
        let mapped = transform.apply(SIMD2(3, 4))
        #expect(approx(mapped.x, 16))
        #expect(approx(mapped.y, 8))

        // Space-separated arguments, as MathJax emits: translate(317.8 256).
        let spaced = Affine2(svgTransform: "translate(317.8 256)")
        #expect(approx(spaced.apply(SIMD2(0, 0)).x, 317.8, tolerance: 1e-3))
    }
}
