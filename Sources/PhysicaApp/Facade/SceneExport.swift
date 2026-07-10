// SceneExport — the headless offscreen export behind `PhysicaApplication.write`.
// No window, no NSApp.run: it renders a scene with `MetalRenderer` into a file
// whose medium is chosen from the URL's `UTType`. A still-image type
// (`.png`/`.jpeg`/`.tiff`/…) captures one frame at `time` through ImageIO; a
// movie type (`.mov`/`.mp4`) encodes `[0, duration]` at `fps` through an
// `AVAssetWriter`. Systems (pendulum, physics) and the timeline both advance
// live between frames — the render/verification vehicle that replaced the old
// argv-driven SmokeRunner.

import PhysicaFoundation
import PhysicaKernel

#if os(macOS)
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum SceneExporter {
    enum ExportError: Error, CustomStringConvertible {
        case metalUnavailable
        case unknownType(URL)
        case unsupportedType(UTType)
        case renderFailed(TimeInterval)
        case imageWriteFailed(URL)
        case videoSetupFailed(String)

        var description: String {
            switch self {
            case .metalUnavailable: return "Metal renderer unavailable"
            case .unknownType(let url): return "no UTType for extension .\(url.pathExtension)"
            case .unsupportedType(let type): return "\(type.identifier) is neither an image nor a movie type"
            case .renderFailed(let t): return "offscreen render produced no frame at t=\(fmt(t, decimals: 2))s"
            case .imageWriteFailed(let url): return "could not write image to \(url.path)"
            case .videoSetupFailed(let why): return "video export failed: \(why)"
            }
        }
    }

    /// Renders `scene` to `url`, dispatching on the file's `UTType`.
    static func write(
        scene: Scene, to url: URL, size: CGSize,
        duration: TimeInterval?, fps: Int, time: TimeInterval
    ) throws {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            throw ExportError.unknownType(url)
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = try? MetalRenderer(device: device) else {
            throw ExportError.metalUnavailable
        }

        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        scene.viewportAspect = Real(width) / Real(height)

        // Log the timeline first (smoke / WebRuntime parity).
        print("Physica: scene ready\n" + scene.timeline.debugString)

        if type.conforms(to: .image) {
            try writeImage(
                scene: scene, renderer: renderer, type: type, url: url,
                width: width, height: height, time: time
            )
        } else if type.conforms(to: .movie) {
            try writeVideo(
                scene: scene, renderer: renderer, url: url, type: type,
                width: width, height: height,
                duration: duration ?? scene.timeline.duration, fps: max(1, fps)
            )
        } else {
            throw ExportError.unsupportedType(type)
        }
    }

    // MARK: Still image

    private static func writeImage(
        scene: Scene, renderer: MetalRenderer, type: UTType, url: URL,
        width: Int, height: Int, time: TimeInterval
    ) throws {
        advance(scene, to: time)
        guard let image = renderer.image(of: scene.snapshot(), width: width, height: height) else {
            throw ExportError.renderFailed(time)
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil
        ) else { throw ExportError.imageWriteFailed(url) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.imageWriteFailed(url)
        }
        print("Physica: wrote \(width)×\(height) image at t=\(fmt(time, decimals: 2))s → \(url.path)")
    }

    /// Advances the scene from 0 to `time` at a fixed step so systems and the
    /// timeline both run live (mirrors the old SmokeRunner's step loop).
    private static func advance(_ scene: Scene, to time: TimeInterval) {
        scene.resume()
        let step = 1.0 / 60
        var elapsed = 0.0
        while elapsed < time {
            scene.update(deltaTime: min(step, time - elapsed))
            elapsed += step
        }
    }

    // MARK: Video

    private static func writeVideo(
        scene: Scene, renderer: MetalRenderer, url: URL, type: UTType,
        width: Int, height: Int, duration: TimeInterval, fps: Int
    ) throws {
        // AVAssetWriter refuses to overwrite an existing file.
        try? FileManager.default.removeItem(at: url)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: AVFileType(rawValue: type.identifier))
        } catch {
            throw ExportError.videoSetupFailed(String(describing: error))
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )

        guard writer.canAdd(input) else { throw ExportError.videoSetupFailed("cannot add video input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw ExportError.videoSetupFailed(String(describing: writer.error))
        }
        writer.startSession(atSourceTime: .zero)

        let frameCount = max(1, Int((duration * Double(fps)).rounded()))
        let dt = 1.0 / Double(fps)
        scene.resume()

        for frame in 0..<frameCount {
            // Snapshot the current instant, render it, encode it, then step the
            // scene forward by one frame's worth of time.
            guard let image = renderer.image(of: scene.snapshot(), width: width, height: height),
                  let buffer = pixelBuffer(from: image, width: width, height: height, pool: adaptor.pixelBufferPool)
            else { throw ExportError.renderFailed(Double(frame) * dt) }

            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            let pts = CMTime(seconds: Double(frame) * dt, preferredTimescale: 600)
            adaptor.append(buffer, withPresentationTime: pts)

            scene.update(deltaTime: dt)
        }

        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()

        if writer.status == .failed {
            throw ExportError.videoSetupFailed(String(describing: writer.error))
        }
        print("Physica: wrote \(frameCount)-frame \(width)×\(height) \(fmt(duration, decimals: 2))s video → \(url.path)")
    }

    /// CGImage → BGRA `CVPixelBuffer`. The renderer's CGImage is already
    /// premultiplied-first / little-endian BGRA (matching 32BGRA), so drawing it
    /// through a CGContext is a straight, correctly-oriented copy.
    private static func pixelBuffer(
        from image: CGImage, width: Int, height: Int, pool: CVPixelBufferPool?
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        if buffer == nil {
            CVPixelBufferCreate(
                nil, width, height, kCVPixelFormatType_32BGRA,
                [
                    kCVPixelBufferCGImageCompatibilityKey as String: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                ] as CFDictionary,
                &buffer
            )
        }
        guard let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }
}
#endif
