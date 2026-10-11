//
//  ClipboardHistoryView.swift
//  boringNotch
//
//  Simple scrollable list backed by ClipboardHistoryManager — click a row
//  to re-copy that entry to the pasteboard, text or image. Deliberately its
//  own thing rather than reusing Shelf's ShelfItem/drag-drop model:
//  clipboard entries aren't file/link artifacts and don't need
//  security-scoped bookmarks.
//

import SwiftUI

struct ClipboardHistoryView: View {
    @ObservedObject private var manager = ClipboardHistoryManager.shared
    @State private var copiedID: UUID?

    var body: some View {
        Group {
            if manager.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(manager.items) { entry in
                            row(for: entry)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: 123)
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.3))
            Text("Copy something to see it here")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for entry: ClipboardEntry) -> some View {
        Button {
            manager.recopy(entry)
            copiedID = entry.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if copiedID == entry.id { copiedID = nil }
            }
        } label: {
            HStack(spacing: 8) {
                switch entry.content {
                case .text(let text):
                    VStack(alignment: .leading, spacing: 1) {
                        Text(text)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(entry.copiedAt, format: .relative(presentation: .numeric))
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                case .image(let image):
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Image")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.85))
                        Text(entry.copiedAt, format: .relative(presentation: .numeric))
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                Spacer(minLength: 0)
                if copiedID == entry.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
