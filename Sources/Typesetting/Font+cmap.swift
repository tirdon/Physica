// Font+cmap — character-to-glyph mapping (TrueType cmap formats 4 and 12).
// Split from Font.swift for navigability; CharacterMap is internal so the Font
// parser can hold one. See Font.swift.

// MARK: - cmap

import PhysicaFoundation

struct CharacterMap: Sendable {
    enum Storage: Sendable {
        case format4(endCodes: [UInt16], startCodes: [UInt16], idDeltas: [Int16], idRangeOffsets: [UInt16], rangeBase: Int)
        case format12(groups: [(start: UInt32, end: UInt32, glyph: UInt32)])
    }

    let storage: Storage
    private let data: [UInt8]

    init(data: [UInt8], offset: Int, format: Int) throws {
        self.data = data
        var reader = ByteReader(data: data, offset: offset)
        let actualFormat = Int(try reader.u16())

        if actualFormat == 4 {
            reader.skip(4)  // length, language
            let segCountX2 = Int(try reader.u16())
            let segments = segCountX2 / 2
            reader.skip(6)  // searchRange, entrySelector, rangeShift
            var endCodes: [UInt16] = []
            for _ in 0..<segments { endCodes.append(try reader.u16()) }
            reader.skip(2)  // reserved pad
            var startCodes: [UInt16] = []
            for _ in 0..<segments { startCodes.append(try reader.u16()) }
            var idDeltas: [Int16] = []
            for _ in 0..<segments { idDeltas.append(try reader.i16()) }
            let rangeBase = reader.offset
            var idRangeOffsets: [UInt16] = []
            for _ in 0..<segments { idRangeOffsets.append(try reader.u16()) }
            storage = .format4(
                endCodes: endCodes, startCodes: startCodes, idDeltas: idDeltas,
                idRangeOffsets: idRangeOffsets, rangeBase: rangeBase
            )
        } else if actualFormat == 12 {
            reader.skip(10)  // reserved, length, language
            let groupCount = Int(try reader.u32())
            var groups: [(UInt32, UInt32, UInt32)] = []
            groups.reserveCapacity(groupCount)
            for _ in 0..<groupCount {
                groups.append((try reader.u32(), try reader.u32(), try reader.u32()))
            }
            storage = .format12(groups: groups)
        } else {
            throw FontError.unsupportedCmap
        }
    }

    func glyphIndex(for character: UInt32) -> Int {
        switch storage {
        case .format12(let groups):
            var low = 0
            var high = groups.count - 1
            while low <= high {
                let mid = (low + high) / 2
                let group = groups[mid]
                if character < group.start {
                    high = mid - 1
                } else if character > group.end {
                    low = mid + 1
                } else {
                    return Int(group.glyph + (character - group.start))
                }
            }
            return 0

        case .format4(let endCodes, let startCodes, let idDeltas, let idRangeOffsets, let rangeBase):
            guard character <= 0xFFFF else { return 0 }
            let c = UInt16(character)
            for segment in 0..<endCodes.count where endCodes[segment] >= c {
                guard startCodes[segment] <= c else { return 0 }
                let rangeOffset = idRangeOffsets[segment]
                if rangeOffset == 0 {
                    return Int(UInt16(truncatingIfNeeded: Int(c) + Int(idDeltas[segment])))
                }
                // Spec's pointer-arithmetic lookup into the glyph index array.
                let address = rangeBase + segment * 2 + Int(rangeOffset)
                    + Int(c - startCodes[segment]) * 2
                guard address + 1 < data.count else { return 0 }
                let glyph = UInt16(data[address]) << 8 | UInt16(data[address + 1])
                guard glyph != 0 else { return 0 }
                return Int(UInt16(truncatingIfNeeded: Int(glyph) + Int(idDeltas[segment])))
            }
            return 0
        }
    }
}
