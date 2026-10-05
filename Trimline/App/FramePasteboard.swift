import AppKit
import TrimlineCore

/// Puts a frame on the general pasteboard: PNG at once, TIFF only when an app that reads nothing
/// else asks for it, since encoding it is slow for large frames.
@MainActor
enum FramePasteboard {
    static func write(_ picture: FramePicture) -> Bool {
        let item = NSPasteboardItem()
        guard item.setData(picture.pngData, forType: .png) else { return false }
        let provider = TIFFProvider(image: picture.image)
        item.setDataProvider(provider, forTypes: [.tiff])
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return false }
        TIFFProvider.current = provider
        return true
    }
}

private final class TIFFProvider: NSObject, NSPasteboardItemDataProvider, Sendable {
    // Kept until the pasteboard lets go of it, as the item does not retain its provider.
    @MainActor static var current: TIFFProvider?

    private let image: CGImage

    init(image: CGImage) {
        self.image = image
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard let data = NSBitmapImageRep(cgImage: image).tiffRepresentation else { return }
        item.setData(data, forType: type)
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        Task { @MainActor in
            if Self.current === self {
                Self.current = nil
            }
        }
    }
}
