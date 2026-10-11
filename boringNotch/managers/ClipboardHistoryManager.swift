//
//  ClipboardHistoryManager.swift
//  boringNotch
//
//  Polls NSPasteboard.general.changeCount (there's no native
//  change-notification API for the pasteboard) and keeps the most recent
//  plain-text and image copies in memory for the Clipboard tab. In-memory
//  only — cleared on restart, nothing written to disk — and skips anything
//  a password manager marks with the org.nspasteboard.ConcealedType
//  convention so copied passwords never land in this history.
//
//  Images are downscaled to maxImageDimension at capture time (not just
//  for the row's thumbnail — the same capped copy is what re-copy writes
//  back too). Keeping the original resolution for up to maxItems images
//  (screenshots routinely run several MB each) risks real memory growth
//  for a "just glance at recent copies" feature; a slightly softer re-paste
//  of a huge image is a reasonable trade for that.
//

import AppKit
import Foundation

enum ClipboardContent {
    case text(String)
    case image(NSImage)
}

struct ClipboardEntry: Identifiable {
    let id: UUID
    let content: ClipboardContent
    let copiedAt: Date
}

final class ClipboardHistoryManager: ObservableObject {
    static let shared = ClipboardHistoryManager()

    @Published private(set) var items: [ClipboardEntry] = []

    private static let maxItems = 20
    private static let maxImageDimension: CGFloat = 512
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var pollTimer: Timer?

    private init() {
        lastChangeCount = pasteboard.changeCount
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.pollPasteboard()
        }
        pollTimer?.tolerance = 0.5
    }

    /// Re-copies this entry to the pasteboard, bumping the change count —
    /// the next poll tick will see its own write and correctly treat it
    /// as "already newest" rather than appending a duplicate.
    func recopy(_ entry: ClipboardEntry) {
        pasteboard.clearContents()
        switch entry.content {
        case .text(let text):
            pasteboard.setString(text, forType: .string)
        case .image(let image):
            if let tiff = image.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
        }
        lastChangeCount = pasteboard.changeCount
    }

    private func pollPasteboard() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        guard pasteboard.types?.contains(Self.concealedType) != true else { return }

        // Prefer text when present — a copy that carries both a string and
        // some incidental image representation (e.g. a Finder file's icon)
        // should still land as a text entry, matching the previous
        // text-only behavior exactly for anything that isn't a "real"
        // image copy (screenshots, images from Preview/Photos/web, etc.,
        // which carry no string type at all).
        if let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            guard !isDuplicateOfNewest(text: text) else { return }
            var updated = items
            updated.removeAll {
                if case .text(let existing) = $0.content { return existing == text }
                return false
            }
            updated.insert(ClipboardEntry(id: UUID(), content: .text(text), copiedAt: Date()), at: 0)
            trim(&updated)
            items = updated
            return
        }

        if let image = readPasteboardImage() {
            var updated = items
            updated.insert(ClipboardEntry(id: UUID(), content: .image(image), copiedAt: Date()), at: 0)
            trim(&updated)
            items = updated
        }
    }

    private func isDuplicateOfNewest(text: String) -> Bool {
        if case .text(let newest) = items.first?.content { return newest == text }
        return false
    }

    private func trim(_ items: inout [ClipboardEntry]) {
        if items.count > Self.maxItems {
            items.removeLast(items.count - Self.maxItems)
        }
    }

    private func readPasteboardImage() -> NSImage? {
        guard let objects = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
              let image = objects.first,
              image.size.width > 0, image.size.height > 0
        else { return nil }
        return Self.capped(image, maxDimension: Self.maxImageDimension)
    }

    private static func capped(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        let size = image.size
        let longestSide = max(size.width, size.height)
        guard longestSide > maxDimension else { return image }

        let scale = maxDimension / longestSide
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)
        let resized = NSImage(size: newSize)
        resized.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1.0
        )
        resized.unlockFocus()
        return resized
    }
}
