// FileIO — browser persistence for the document (WASI only).
//
// Autosave + named slots ride `localStorage`; "Save" exports a downloadable
// `.json`. (Importing an arbitrary file from disk lands in a later polish pass —
// headless upload dialogs are awkward to drive; localStorage + reload covers the
// round-trip we verify now.)

#if os(WASI)
import JavaScriptKit

enum FileIO {
    static func saveLocal(key: String, json: String) {
        let storage = JSObject.global.localStorage
        guard storage.object != nil else { return }
        _ = storage.setItem(key, json)
    }

    static func loadLocal(key: String) -> String? {
        let storage = JSObject.global.localStorage
        guard storage.object != nil else { return nil }
        return storage.getItem(key).string
    }

    /// Triggers a browser download of `json` as `filename` via a transient anchor.
    static func download(filename: String, json: String) {
        guard let document = JSObject.global.document.object,
              let blobCtor = JSObject.global.Blob.function,
              let urlClass = JSObject.global.URL.object else { return }

        let options: [String: JSValue] = ["type": .string("application/json")]
        let blob = blobCtor.new([json].jsValue, options.jsValue)
        let url = urlClass.createObjectURL!(blob)

        var anchor = document.createElement!("a")
        anchor.href = url
        anchor.download = .string(filename)
        _ = document.body.appendChild(anchor)
        _ = anchor.click()
        _ = document.body.removeChild(anchor)
        _ = urlClass.revokeObjectURL!(url)
    }
}
#endif
