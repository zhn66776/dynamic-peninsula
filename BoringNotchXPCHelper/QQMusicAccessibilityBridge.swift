//
//  QQMusicAccessibilityBridge.swift
//  BoringNotchXPCHelper
//
//  Reads QQ Music's compact playback control bar through macOS Accessibility.
//  Keeping this work in the existing unsandboxed helper avoids broadening the
//  main application's sandbox exceptions.
//

import AppKit
import ApplicationServices
import Foundation

private struct QQMusicHelperSnapshot: Codable {
    let title: String
    let artist: String
    let isPlaying: Bool
    let isFavorite: Bool
    let isShuffled: Bool
    let repeatMode: Int
}

enum QQMusicAccessibilityBridge {
    private static let bundleIdentifier = "com.tencent.QQMusicMac"

    // These CJK strings are QQ Music's external Accessibility labels. They
    // are protocol values used for matching controls, not user-facing text.

    static func snapshotData() -> Data? {
        guard AXIsProcessTrusted(),
              let playerBar = playerControlBar(),
              let metadata = metadata(in: playerBar)
        else {
            return nil
        }

        let labels = children(of: playerBar).flatMap(accessibilityStrings(for:))
        let playLabel = labels.first(where: {
            $0.localizedCaseInsensitiveContains("\u{6682}\u{505C}\u{64AD}\u{653E}")
                || $0.localizedCaseInsensitiveContains("\u{7EE7}\u{7EED}\u{64AD}\u{653E}")
                || $0 == "\u{64AD}\u{653E}"
        }) ?? ""
        let modeLabel = labels.first(where: { $0.contains("\u{64AD}\u{653E}\u{6A21}\u{5F0F}") }) ?? ""
        let favoriteLabel = labels.first(where: {
            $0.contains("\u{6211}\u{559C}\u{6B22}") || $0.localizedCaseInsensitiveContains("favorite")
        }) ?? ""

        let repeatMode: Int
        if modeLabel.contains("\u{5355}\u{66F2}\u{5FAA}\u{73AF}") {
            repeatMode = 2
        } else if modeLabel.contains("\u{5217}\u{8868}\u{5FAA}\u{73AF}") || modeLabel.contains("\u{5FAA}\u{73AF}\u{64AD}\u{653E}") {
            repeatMode = 3
        } else {
            repeatMode = 1
        }

        let snapshot = QQMusicHelperSnapshot(
            title: metadata.title,
            artist: metadata.artist,
            isPlaying: playLabel.contains("\u{6682}\u{505C}"),
            isFavorite: favoriteLabel.contains("\u{5220}\u{9664}") || favoriteLabel.contains("\u{53D6}\u{6D88}"),
            isShuffled: modeLabel.contains("\u{968F}\u{673A}"),
            repeatMode: repeatMode
        )
        return try? JSONEncoder().encode(snapshot)
    }

    static func perform(action: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        if let playerBar = playerControlBar() {
            let handled: Bool
            switch action {
            case "playPause":
                handled = pressButton(
                    in: playerBar,
                    matchingAny: ["\u{6682}\u{505C}\u{64AD}\u{653E}", "\u{7EE7}\u{7EED}\u{64AD}\u{653E}", "\u{64AD}\u{653E}"]
                )
            case "play":
                handled = isCurrentlyPlaying(in: playerBar)
                    || pressButton(in: playerBar, matchingAny: ["\u{7EE7}\u{7EED}\u{64AD}\u{653E}", "\u{64AD}\u{653E}"])
            case "pause":
                handled = !isCurrentlyPlaying(in: playerBar)
                    || pressButton(in: playerBar, matchingAny: ["\u{6682}\u{505C}\u{64AD}\u{653E}"])
            case "next":
                handled = pressButton(in: playerBar, matchingAny: ["\u{4E0B}\u{4E00}\u{9996}"])
            case "previous":
                handled = pressButton(in: playerBar, matchingAny: ["\u{4E0A}\u{4E00}\u{9996}"])
            case "toggleFavorite":
                handled = pressButton(
                    in: playerBar,
                    matchingAny: ["\u{4ECE}\u{6211}\u{559C}\u{6B22}\u{5220}\u{9664}", "\u{6DFB}\u{52A0}\u{5230}\u{6211}\u{559C}\u{6B22}", "\u{6DFB}\u{52A0}\u{81F3}\u{6211}\u{559C}\u{6B22}", "\u{6211}\u{559C}\u{6B22}"]
                )
            case "cyclePlayMode":
                handled = pressButton(in: playerBar, matchingAny: ["\u{64AD}\u{653E}\u{6A21}\u{5F0F}"])
            default:
                handled = false
            }

            if handled { return true }
        }

        // Never fall back to macOS global media keys for QQ Music. Those keys
        // are routed to whichever app currently owns the system media session
        // and can pause a browser video instead of QQ Music.
        return false
    }

    private static func isCurrentlyPlaying(in playerBar: AXUIElement) -> Bool {
        children(of: playerBar).contains { element in
            accessibilityStrings(for: element).contains { $0.contains("\u{6682}\u{505C}\u{64AD}\u{653E}") }
        }
    }

    private static func metadata(in playerBar: AXUIElement) -> (title: String, artist: String)? {
        for element in children(of: playerBar) {
            for text in accessibilityStrings(for: element) {
                guard text.hasPrefix("\u{6B4C}\u{66F2}\u{540D}\u{FF1A}"),
                      let separator = text.range(of: " - \u{6B4C}\u{624B}\u{540D}\u{FF1A}")
                else { continue }

                let titleStart = text.index(text.startIndex, offsetBy: "\u{6B4C}\u{66F2}\u{540D}\u{FF1A}".count)
                let title = String(text[titleStart..<separator.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let artist = String(text[separator.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty, !artist.isEmpty {
                    return (title, artist)
                }
            }
        }
        return nil
    }

    private static func playerControlBar() -> AXUIElement? {
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
        guard let application = applications.first else { return nil }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        let windows = elementsAttribute(appElement, kAXWindowsAttribute as CFString)
        let applicationChildren = children(of: appElement)
        let focusedWindow = elementAttribute(appElement, kAXFocusedWindowAttribute as CFString)
        let mainWindow = elementAttribute(appElement, kAXMainWindowAttribute as CFString)
        var roots = windows
        if let focusedWindow { roots.append(focusedWindow) }
        if let mainWindow { roots.append(mainWindow) }
        roots.append(contentsOf: applicationChildren)
        for window in roots {
            if looksLikePlayerBar(window) {
                return window
            }
            let directChildren = children(of: window)

            if let labeledBar = directChildren.first(where: {
                accessibilityStrings(for: $0).contains(where: { $0.contains("\u{64AD}\u{653E}\u{63A7}\u{5236}\u{680F}") })
            }) {
                return labeledBar
            }

            if let structuralBar = directChildren.first(where: looksLikePlayerBar) {
                return structuralBar
            }

            for container in directChildren where !shouldSkipDescendants(of: container) {
                if let nestedBar = children(of: container).first(where: looksLikePlayerBar) {
                    return nestedBar
                }
            }
        }
        return nil
    }

    private static func looksLikePlayerBar(_ element: AXUIElement) -> Bool {
        let childLabels = children(of: element).flatMap(accessibilityStrings(for:))
        return childLabels.contains(where: { $0.contains("\u{4E0A}\u{4E00}\u{9996}") })
            && childLabels.contains(where: { $0.contains("\u{4E0B}\u{4E00}\u{9996}") })
            && childLabels.contains(where: { $0.hasPrefix("\u{6B4C}\u{66F2}\u{540D}\u{FF1A}") })
    }

    private static func shouldSkipDescendants(of element: AXUIElement) -> Bool {
        guard let role = stringAttribute(element, kAXRoleAttribute as CFString) else { return false }
        return role == "AXWebArea" || role == (kAXScrollAreaRole as String)
    }

    private static func pressButton(in playerBar: AXUIElement, matchingAny candidates: [String]) -> Bool {
        guard let button = children(of: playerBar).first(where: { element in
            guard stringAttribute(element, kAXRoleAttribute as CFString) == (kAXButtonRole as String)
            else { return false }
            let strings = accessibilityStrings(for: element)
            return candidates.contains { candidate in
                strings.contains(where: { $0.localizedCaseInsensitiveContains(candidate) })
            }
        }) else {
            return false
        }

        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    private static func accessibilityStrings(for element: AXUIElement) -> [String] {
        [
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXValueAttribute as CFString,
            kAXHelpAttribute as CFString,
            kAXIdentifierAttribute as CFString,
        ]
        .compactMap { stringAttribute(element, $0) }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        elementsAttribute(element, kAXChildrenAttribute as CFString)
    }

    private static func elementsAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let elements = value as? [AXUIElement]
        else {
            return []
        }
        return elements
    }

    private static func elementAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func stringAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
