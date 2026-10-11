# Dynamic Peninsula

Dynamic Peninsula is a macOS notch app for music controls, system monitoring, clipboard history, file sharing, and coding-agent status. Built with Swift, SwiftUI, and AppKit.

[Release page](https://github.com/zhn66776/dynamic-peninsula/releases/tag/public-2.7.3-20260929) · macOS 26 or later · Apple silicon and Intel · Xcode 27 · Swift / SwiftUI / AppKit

## Public Release

- Universal app: `arm64` and `x86_64`.
- English user interface.
- Ad-hoc signed and not notarized.
- DMG installation: open the DMG, drag `Dynamic Peninsula.app` to `Applications`, and launch it there.
- At first launch, open **System Settings > Privacy & Security**, select **Open Anyway** in the security notice, and confirm the launch. See [Apple's guidance](https://support.apple.com/102445).

## Upstream and fork additions

The application is based on [Boring Notch by TheBoredTeam](https://github.com/TheBoredTeam/boring.notch). The fork additions in this source tree include:

- **QQ Music integration:** metadata, local playback control, timeline support, and Accessibility-backed actions in [`QQMusicController.swift`](boringNotch/MediaControllers/QQMusicController.swift), [`QQMusicLocalPlayerClient.swift`](boringNotch/MediaControllers/QQMusicLocalPlayerClient.swift), and [`QQMusicAccessibilityBridge.swift`](BoringNotchXPCHelper/QQMusicAccessibilityBridge.swift).
- **System Monitor:** public CPU, memory, storage, disk-I/O, network, and thermal sampling in [`SystemPublicMetricsProvider.swift`](boringNotch/SystemMonitor/Providers/SystemPublicMetricsProvider.swift), coordinated by [`SystemMonitorSampler.swift`](boringNotch/SystemMonitor/Sampling/SystemMonitorSampler.swift) and [`SystemMonitorStore.swift`](boringNotch/SystemMonitor/SystemMonitorStore.swift). GPU, temperature, and fan sampling runs through the XPC helper in [`SystemMonitorPrivateMetricsProvider.swift`](BoringNotchXPCHelper/SystemMonitorPrivateMetricsProvider.swift) and [`XPCHelperClient.swift`](boringNotch/XPCHelperClient/XPCHelperClient.swift).
- **Clipboard history:** in-memory clipboard entries and the Clipboard tab in [`ClipboardHistoryManager.swift`](boringNotch/managers/ClipboardHistoryManager.swift) and [`ClipboardHistoryView.swift`](boringNotch/components/Notch/ClipboardHistoryView.swift).
- **Codex and Claude:** account quota queries, reset-credit displays, usage charts, approval status, and local agent indicators in [`CodexAccountClient.swift`](boringNotch/managers/CodexAccountClient.swift), [`CodexQuotaMonitor.swift`](boringNotch/managers/CodexQuotaMonitor.swift), [`ClaudeQuotaMonitor.swift`](boringNotch/managers/ClaudeQuotaMonitor.swift), [`CodexUsageStatsService.swift`](boringNotch/managers/CodexUsageStatsService.swift), [`ClaudeUsageStatsService.swift`](boringNotch/managers/ClaudeUsageStatsService.swift), [`AgentApprovalMonitor.swift`](boringNotch/managers/AgentApprovalMonitor.swift), and [`AgentBreathingMonitor.swift`](boringNotch/managers/AgentBreathingMonitor.swift).
- **Downloads and network alerts:** Downloads-folder progress and reachability alerts in [`DownloadProgressMonitor.swift`](boringNotch/managers/DownloadProgressMonitor.swift), [`DownloadProgressDropdown.swift`](boringNotch/components/Live%20activities/DownloadProgressDropdown.swift), [`NetworkConnectivityMonitor.swift`](boringNotch/managers/NetworkConnectivityMonitor.swift), and [`NetworkAlertDropdown.swift`](boringNotch/components/Notch/NetworkAlertDropdown.swift).

The app entitlements are in [`Configuration/PublicRelease.entitlements`](Configuration/PublicRelease.entitlements), and the target and scheme are defined in [`project.pbxproj`](boringNotch.xcodeproj/project.pbxproj) and [`Public Release.xcscheme`](boringNotch.xcodeproj/xcshareddata/xcschemes/Public%20Release.xcscheme).

## Architecture

The app process renders SwiftUI and AppKit views, coordinates sampling with Swift Concurrency, and collects public system metrics. The `BoringNotchXPCHelper` XPC service handles Accessibility and hardware reads through IOKit, AppleSMC, and IOReport. The request and response types are defined in [`BoringNotchXPCHelperProtocol.swift`](BoringNotchXPCHelper/BoringNotchXPCHelperProtocol.swift) and [`SystemMonitorXPCModels.swift`](boringNotch/SystemMonitor/Models/SystemMonitorXPCModels.swift).

The system-monitor tests cover public metric providers, CPU and storage calculations, sampling policy, stale data, alert behavior, XPC schema/fixture decoding, and hardware fixtures. Start with [`SystemPublicMetricsProviderTests.swift`](boringNotchTests/SystemMonitor/SystemPublicMetricsProviderTests.swift), [`SamplerStoreAndAlertTests.swift`](boringNotchTests/SystemMonitor/SamplerStoreAndAlertTests.swift), and [`XPCContractAndFixtureTests.swift`](boringNotchTests/SystemMonitor/XPCContractAndFixtureTests.swift).

## Build

Build requirements: macOS 26 or later and Xcode 27. The pinned Swift Package Manager revisions are recorded in [`Package.resolved`](boringNotch.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved). Resolve the pinned dependencies, then build:

```sh
SOURCE_PACKAGES="$PWD/DerivedData/SourcePackages"

xcodebuild -resolvePackageDependencies \
  -project boringNotch.xcodeproj \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES"

xcodebuild \
  -project boringNotch.xcodeproj \
  -scheme "Public Release" \
  -configuration "Public Release" \
  -destination generic/platform=macOS \
  -derivedDataPath build/public-release/DerivedData \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
  -disableAutomaticPackageResolution \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build
```

Package an already-built app with:

```sh
./Configuration/package_public_release.sh --package-only
```

## Test

Run the system-monitor tests with the Debug configuration:

```sh
SOURCE_PACKAGES="$PWD/DerivedData/SourcePackages"

xcodebuild \
  -project boringNotch.xcodeproj \
  -scheme "Public Release" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build/public-release/DerivedData \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
  -disableAutomaticPackageResolution \
  test
```

The `Public Release` scheme runs the functional and fixture tests. Run the AGX readback and GPU-load diagnostics with:

```sh
xcodebuild -project boringNotch.xcodeproj \
  -scheme "M3 Hardware Diagnostics" -configuration Debug \
  -destination 'platform=macOS' test
```

## Runtime data and credentials

At launch, the Codex quota monitors read the user's local Codex login state and query the account usage endpoints. The Claude quota monitor uses an app-specific Keychain entry and queries `claude.ai`. Background Keychain reads run without authentication dialogs. Codex and Claude usage tabs scan the user's local session logs. AgentLight reads local agent state files. Music control, calendar, camera, Accessibility, clipboard, Shelf, AirDrop, and system-monitor features use the corresponding macOS permissions and local data.

Each installation uses the accounts and credentials on that Mac. Account requests go directly to the corresponding service.

## Dependencies and attributions

Swift Package pins and revisions are in `Package.resolved`; the main packages include AsyncXPCConnection, Defaults, KeyboardShortcuts, LaunchAtLogin-Modern, Lottie, MacroVisionKit, Pow, SkyLightWindow, Sparkle, swift-collections, swift-syntax, and SwiftUI-Introspect.

The app uses the bundled `MediaRemoteAdapter` framework and Perl wrapper in [`mediaremote-adapter`](mediaremote-adapter). The wrapper matches upstream revision `dc3ff1740e2035a2490ec67d3b33322449af780a` (v0.7.2); its upstream source is included in [`third_party/MediaRemoteAdapter-source`](third_party/MediaRemoteAdapter-source). Third-party license texts are in [`THIRD_PARTY_LICENSES`](THIRD_PARTY_LICENSES).

The code is based on Boring Notch and is licensed under [GNU GPLv3](LICENSE). The source and binary distribution must retain the license and third-party notices.
