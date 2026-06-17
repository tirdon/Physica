// Render a PDF to one PNG per page with macOS PDFKit — no poppler or other
// external dependency, so the Read tool can view design docs/specs. Compile and
// run (the `swift` interpreter can't autolink AppKit/PDFKit, so use swiftc):
//   swiftc scripts/pdf-to-png.swift -o /tmp/pdf-to-png
//   /tmp/pdf-to-png <file.pdf> [outDir=/tmp/pdf-pages] [scale=2]
// `scale` multiplies the page's point size for resolution (2 ≈ 144 dpi). The
// SwiftUI sibling `ImageRenderer` covers the other direction — rasterizing a
// view/scene to PNG/PDF — when that is what you need.
import Foundation
import PDFKit
import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: swift pdf-to-png.swift <file.pdf> [outDir] [scale]\n".utf8))
    exit(2)
}
let pdfURL = URL(fileURLWithPath: args[1])
let outDir = args.count >= 3 ? args[2] : "/tmp/pdf-pages"
let scale = CGFloat(args.count >= 4 ? (Double(args[3]) ?? 2) : 2)

guard let document = PDFDocument(url: pdfURL) else {
    FileHandle.standardError.write(Data("cannot open \(pdfURL.path)\n".utf8))
    exit(1)
}
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

for index in 0 ..< document.pageCount {
    guard let page = document.page(at: index) else { continue }
    let bounds = page.bounds(for: .cropBox)
    let pixelSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    let image = page.thumbnail(of: pixelSize, for: .cropBox)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { continue }
    let out = URL(fileURLWithPath: outDir).appendingPathComponent(String(format: "page-%02d.png", index + 1))
    do {
        try png.write(to: out)
        print("wrote \(out.path)  \(Int(pixelSize.width))x\(Int(pixelSize.height))")
    } catch {
        FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
    }
}
