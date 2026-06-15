// Pure-Swift TrueType parser — glyf outlines only (no CFF), cmap formats 4 & 12,
// offset-only composites. Glyph outlines are quadratic Béziers in em units (y-up),
// which lower directly into Path/PathFlatten and the Write stroke pipeline.

public enum FontError: Error, Equatable {
    case invalidFormat
    case missingTable(String)
    case unsupportedCmap
    case malformed(String)
}

public struct Font: Sendable {
    public struct Glyph: Sendable {
        public let index: Int
        /// Horizontal advance in em units.
        public let advance: Real
        /// Outline in em units, origin at baseline/left.
        public let path: Path
    }

    public let unitsPerEm: Real
    /// Em-unit ascent/descent (descent is negative).
    public let ascender: Real
    public let descender: Real
    public let glyphCount: Int

    private let data: [UInt8]
    private let glyfOffset: Int
    private let locaOffsets: [Int]
    private let advances: [Real]
    private let cmap: CharacterMap

    public init(data: [UInt8]) throws {
        self.data = data
        var reader = ByteReader(data: data)

        let version = try reader.u32()
        guard version == 0x0001_0000 || version == 0x7472_7565 else {  // 1.0 | 'true'
            throw FontError.invalidFormat
        }
        let tableCount = Int(try reader.u16())
        reader.skip(6)

        var tables: [String: (offset: Int, length: Int)] = [:]
        for _ in 0..<tableCount {
            let tag = try reader.tag()
            _ = try reader.u32()  // checksum
            let offset = Int(try reader.u32())
            let length = Int(try reader.u32())
            tables[tag] = (offset, length)
        }

        func table(_ tag: String) throws -> ByteReader {
            guard let entry = tables[tag] else { throw FontError.missingTable(tag) }
            return ByteReader(data: data, offset: entry.offset)
        }

        // head — unitsPerEm + loca format
        var head = try table("head")
        head.skip(18)
        let unitsPerEm = Real(try head.u16())
        head.skip(30)  // → offset 50
        let longLoca = try head.i16() == 1
        self.unitsPerEm = unitsPerEm

        // maxp — glyph count
        var maxp = try table("maxp")
        maxp.skip(4)
        let glyphCount = Int(try maxp.u16())
        self.glyphCount = glyphCount

        // hhea — vertical metrics + hmtx entry count
        var hhea = try table("hhea")
        hhea.skip(4)
        self.ascender = Real(try hhea.i16()) / unitsPerEm
        self.descender = Real(try hhea.i16()) / unitsPerEm
        hhea.skip(26)  // → offset 34
        let metricCount = Int(try hhea.u16())

        // hmtx — advances (glyphs past metricCount repeat the last advance)
        var hmtx = try table("hmtx")
        var advances: [Real] = []
        advances.reserveCapacity(glyphCount)
        var lastAdvance: Real = 0
        for index in 0..<glyphCount {
            if index < metricCount {
                lastAdvance = Real(try hmtx.u16()) / unitsPerEm
                _ = try hmtx.i16()  // left side bearing
            }
            advances.append(lastAdvance)
        }
        self.advances = advances

        // loca — glyf record offsets
        var loca = try table("loca")
        var offsets: [Int] = []
        offsets.reserveCapacity(glyphCount + 1)
        for _ in 0...glyphCount {
            offsets.append(longLoca ? Int(try loca.u32()) : Int(try loca.u16()) * 2)
        }
        self.locaOffsets = offsets

        guard let glyf = tables["glyf"] else { throw FontError.missingTable("glyf") }
        self.glyfOffset = glyf.offset

        // cmap — prefer format 12, fall back to format 4
        var cmapTable = try table("cmap")
        let cmapBase = cmapTable.offset
        cmapTable.skip(2)
        let subtableCount = Int(try cmapTable.u16())
        var best: (format: Int, offset: Int)?
        for _ in 0..<subtableCount {
            let platform = try cmapTable.u16()
            let encoding = try cmapTable.u16()
            let offset = Int(try cmapTable.u32())
            let isUnicode = platform == 0 || (platform == 3 && (encoding == 1 || encoding == 10))
            guard isUnicode else { continue }
            var peek = ByteReader(data: data, offset: cmapBase + offset)
            let format = Int(try peek.u16())
            if format == 12 {
                best = (12, cmapBase + offset)
            } else if format == 4, best?.format != 12 {
                best = (4, cmapBase + offset)
            }
        }
        guard let chosen = best else { throw FontError.unsupportedCmap }
        self.cmap = try CharacterMap(data: data, offset: chosen.offset, format: chosen.format)
    }

    // MARK: Lookup

    public func glyphIndex(for scalar: Unicode.Scalar) -> Int? {
        let index = cmap.glyphIndex(for: UInt32(scalar.value))
        return index == 0 ? nil : index
    }

    public func glyph(for scalar: Unicode.Scalar) -> Glyph? {
        guard let index = glyphIndex(for: scalar) else { return nil }
        return try? glyph(at: index)
    }

    public func glyph(at index: Int) throws -> Glyph {
        guard index >= 0, index < glyphCount else {
            throw FontError.malformed("glyph index \(index)")
        }
        let path = try glyphPath(at: index, depth: 0)
        return Glyph(index: index, advance: advances[index], path: path)
    }

    // MARK: glyf parsing

    private func glyphPath(at index: Int, depth: Int) throws -> Path {
        guard depth < 4 else { return Path() }
        let start = locaOffsets[index]
        let end = locaOffsets[index + 1]
        guard end > start else { return Path() }  // empty glyph (space)

        var reader = ByteReader(data: data, offset: glyfOffset + start)
        let contourCount = Int(try reader.i16())
        reader.skip(8)  // bounding box

        if contourCount >= 0 {
            return try simpleGlyph(reader: &reader, contourCount: contourCount)
        }
        return try compositeGlyph(reader: &reader, depth: depth)
    }

    private func simpleGlyph(reader: inout ByteReader, contourCount: Int) throws -> Path {
        var endPoints: [Int] = []
        for _ in 0..<contourCount {
            endPoints.append(Int(try reader.u16()))
        }
        let pointCount = (endPoints.last ?? -1) + 1
        let instructionLength = Int(try reader.u16())
        reader.skip(instructionLength)

        // Flags with run-length repeats.
        var flags: [UInt8] = []
        flags.reserveCapacity(pointCount)
        while flags.count < pointCount {
            let flag = try reader.u8()
            flags.append(flag)
            if flag & 0x08 != 0 {
                let repeats = Int(try reader.u8())
                for _ in 0..<repeats { flags.append(flag) }
            }
        }

        // Deltas: x then y, short/long per flag bits.
        var xs: [Real] = []
        var x: Int = 0
        for flag in flags {
            if flag & 0x02 != 0 {
                let delta = Int(try reader.u8())
                x += (flag & 0x10 != 0) ? delta : -delta
            } else if flag & 0x10 == 0 {
                x += Int(try reader.i16())
            }
            xs.append(Real(x) / unitsPerEm)
        }
        var ys: [Real] = []
        var y: Int = 0
        for flag in flags {
            if flag & 0x04 != 0 {
                let delta = Int(try reader.u8())
                y += (flag & 0x20 != 0) ? delta : -delta
            } else if flag & 0x20 == 0 {
                y += Int(try reader.i16())
            }
            ys.append(Real(y) / unitsPerEm)
        }

        var contours: [Path.Contour] = []
        var first = 0
        for endPoint in endPoints {
            guard endPoint >= first else { continue }
            var points: [(point: SIMD2<Real>, onCurve: Bool)] = []
            for index in first...endPoint {
                points.append((SIMD2(xs[index], ys[index]), flags[index] & 0x01 != 0))
            }
            if let contour = Self.quadraticContour(points) {
                contours.append(contour)
            }
            first = endPoint + 1
        }
        return Path(contours: contours)
    }

    /// TrueType outline → quadratic contour. Consecutive off-curve points imply
    /// an on-curve midpoint; a contour may even start off-curve.
    static func quadraticContour(_ raw: [(point: SIMD2<Real>, onCurve: Bool)]) -> Path.Contour? {
        guard raw.count >= 2 else { return nil }

        // Rotate so we start on-curve (synthesizing a start if all are off-curve).
        var points = raw
        if !points[0].onCurve {
            if let onIndex = points.firstIndex(where: { $0.onCurve }) {
                points = Array(points[onIndex...] + points[..<onIndex])
            } else {
                let mid = (points[0].point + points[points.count - 1].point) / 2
                points.insert((mid, true), at: 0)
            }
        }

        let start = points[0].point
        var segments: [Path.Segment] = []
        var pendingControl: SIMD2<Real>?

        func emit(to target: SIMD2<Real>) {
            if let control = pendingControl {
                segments.append(.quadCurve(control: control, to: target))
                pendingControl = nil
            } else {
                segments.append(.line(to: target))
            }
        }

        for entry in points.dropFirst() {
            if entry.onCurve {
                emit(to: entry.point)
            } else if let control = pendingControl {
                // Two off-curve points → implied on-curve midpoint.
                let mid = (control + entry.point) / 2
                segments.append(.quadCurve(control: control, to: mid))
                pendingControl = entry.point
            } else {
                pendingControl = entry.point
            }
        }
        emit(to: start)  // close back to the start

        return Path.Contour(start: start, segments: segments, isClosed: true)
    }

    private func compositeGlyph(reader: inout ByteReader, depth: Int) throws -> Path {
        var result = Path()
        while true {
            let flags = try reader.u16()
            let componentIndex = Int(try reader.u16())

            var dx: Real = 0
            var dy: Real = 0
            if flags & 0x0001 != 0 {  // words
                let a = Real(try reader.i16())
                let b = Real(try reader.i16())
                if flags & 0x0002 != 0 {  // xy offsets
                    dx = a / unitsPerEm
                    dy = b / unitsPerEm
                }
            } else {
                let a = Real(try reader.i8())
                let b = Real(try reader.i8())
                if flags & 0x0002 != 0 {
                    dx = a / unitsPerEm
                    dy = b / unitsPerEm
                }
            }
            // v1: offset-only composites — skip scale terms.
            if flags & 0x0008 != 0 { reader.skip(2) }
            if flags & 0x0040 != 0 { reader.skip(4) }
            if flags & 0x0080 != 0 { reader.skip(8) }

            let component = try glyphPath(at: componentIndex, depth: depth + 1)
            result = result.appending(component.translated(by: SIMD2(dx, dy)))

            if flags & 0x0020 == 0 { break }  // no MORE_COMPONENTS
        }
        return result
    }
}
