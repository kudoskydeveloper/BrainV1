import AppKit
import PhotosUI
import UniformTypeIdentifiers

/// The system Photos picker in a window of its own, over the panel: as a sheet it would be squeezed into the short panel
/// window. It runs out of process, so Brain needs no Photos permission and sees only what the user picks.
@MainActor
final class PhotoPicker: NSObject, PHPickerViewControllerDelegate, NSWindowDelegate {
    static let shared = PhotoPicker()
    var window: NSWindow?
    var done: (([Data]) -> Void)?

    /// Opens the picker (or brings it forward); `done` gets each picked picture's data (empty when cancelled).
    func pick(over anchor: NSWindow?, done: @escaping ([Data]) -> Void) {
        self.done = done
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 6
        config.preferredAssetRepresentationMode = .compatible   // JPEG instead of HEIC when Photos can
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Pripojiť fotku"
        w.contentViewController = picker
        w.setContentSize(NSSize(width: 860, height: 600))   // the size is ours, never the picker's content
        w.contentMinSize = NSSize(width: 560, height: 420)
        w.isReleasedWhenClosed = false
        w.level = .floating + 1   // over the floating panel
        w.delegate = self
        if let a = anchor?.frame { w.setFrameOrigin(NSPoint(x: a.midX - 430, y: max(40, a.maxY - 640))) } else { w.center() }
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        let providers = results.map(\.itemProvider)
        Task { @MainActor in
            close()
            var out: [Data] = []
            for p in providers {
                if let d = await Self.data(p) { out.append(d) } else { AppDelegate.log("photo picker: no image data") }
            }
            done?(out); done = nil
        }
    }

    static func data(_ p: NSItemProvider) async -> Data? {
        let type = p.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) ?? false } ?? UTType.image.identifier
        return await withCheckedContinuation { c in
            p.loadDataRepresentation(forTypeIdentifier: type) { d, _ in c.resume(returning: d) }
        }
    }

    func close() {
        window?.delegate = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ n: Notification) {   // closed with the red button: nothing picked
        window = nil
        done?([]); done = nil
    }
}
