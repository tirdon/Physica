// StoryDocumentIO — JSON (de)serialization for the document.
//
// Foundation's `JSONEncoder`/`JSONDecoder` are used here (and ONLY here in the
// editor). This is the one place the project leans on Foundation: it is shipped
// in the wasi SDK (FoundationEssentials), so the same code serializes on the
// host (tests) and in the browser (save/load). The framework core stays
// Foundation-free — the constraint that actually matters.

import Foundation

enum StoryDocumentIO {
    /// Pretty-printed, key-sorted JSON so saved files diff cleanly and tests are
    /// deterministic.
    static func encode(_ document: StoryDocument) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ json: String) throws -> StoryDocument {
        try JSONDecoder().decode(StoryDocument.self, from: Data(json.utf8))
    }
}
