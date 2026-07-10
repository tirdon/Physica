// Locks the orientation contract of `MetalRenderer.texture(from:)`: the whole
// textured-quad path (debug-overlay labels, Sprite/Image entities, emoji glyph
// boxes) maps quad top-left → uv (0,0) → texture row 0, so row 0 MUST be the
// source image's visual top. A stray CTM flip there renders every one of them
// upside down — the debug overlay made it obvious. This is the regression guard.

import Testing
import Foundation
import CoreGraphics
import Metal
@testable import PhysicaApp

@Suite struct TextureOrientationTests {
    @Test @MainActor func rowZeroIsVisualTop() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = try? MetalRenderer(device: device) else {
            return   // no Metal (headless CI) — nothing to assert
        }

        // A 1×2 image whose visual TOP row is red and bottom row is blue. Built
        // straight from bytes so row 0 is unambiguously the visual top (CGImage
        // data is always top-down), independent of any drawing convention.
        let source: [UInt8] = [255, 0, 0, 255,   0, 0, 255, 255]  // row0 red, row1 blue
        let provider = CGDataProvider(data: Data(source) as CFData)!
        let cgImage = CGImage(
            width: 1, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!

        let texture = try #require(renderer.texture(from: cgImage))
        var out = [UInt8](repeating: 0, count: 8)
        texture.getBytes(&out, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 2), mipmapLevel: 0)

        // Texture row 0 = visual top = red; row 1 = blue. (rgba8, red channel first.)
        #expect(out[0] > 200 && out[2] < 55, "texture row 0 should be red (visual top), got \(out[0...3])")
        #expect(out[4] < 55 && out[6] > 200, "texture row 1 should be blue (visual bottom), got \(out[4...7])")
    }
}
