//
//  ContentView.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import SwiftUI
import SwiftUIIntrospect

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var webcamManager = WebcamManager.shared
    @ObservedObject var downloadMonitor = DownloadProgressMonitor.shared

    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var brightnessManager = BrightnessManager.shared
    @ObservedObject var volumeManager = VolumeManager.shared
    @ObservedObject var approvalMonitor = AgentApprovalMonitor.shared
#if !PUBLIC_RELEASE
    @ObservedObject var portfolioMonitor = StockPortfolioMonitor.shared
#endif
    @ObservedObject var networkMonitor = NetworkConnectivityMonitor.shared
    @ObservedObject var quotaMonitor = CodexQuotaMonitor.shared
    @ObservedObject var claudeQuotaMonitor = ClaudeQuotaMonitor.shared
    @ObservedObject var quotaDropPresenter = QuotaDropPresenter.shared
    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering: Bool = false
    @State private var anyDropDebounceTask: Task<Void, Never>?
    // Where to return once a Codex approval request is resolved: which tab
    // was showing (nil while idle/never interrupted), and whether the notch
    // was closed before the request forced it open (in which case it should
    // close again afterward instead of sitting open on some tab).
    @State private var preApprovalRequestView: NotchViews?
    @State private var wasClosedBeforeApprovalRequest: Bool = false

    @State private var gestureProgress: CGFloat = .zero

    @State private var haptics: Bool = false

    @Namespace var albumArtNamespace

    @Default(.useMusicVisualizer) var useMusicVisualizer

    @Default(.showNotHumanFace) var showNotHumanFace
    @Default(.openNotchOnHover) private var openNotchOnHover
    @Default(.systemMonitorEnabled) private var systemMonitorEnabled
    @Default(.systemMonitorShowCPUWhenClosed) private var systemMonitorShowCPUWhenClosed

    // Shared interactive spring for movement/resizing to avoid conflicting animations
    private let animationSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10

    private var topCornerRadius: CGFloat {
       ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.top
                : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
            ? cornerRadiusInsets.opened.bottom
            : cornerRadiusInsets.closed.bottom
    }

    private var currentNotchShape: NotchShape {
        NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
    }

    /// Full-pill takeover for ~6s after a weekly-quota drop (Codex or
    /// Claude): closed width, a bit taller, regardless of whether the notch
    /// is actually open or closed right now — hides the badges/tabs
    /// entirely so this is the only thing showing, then hands back to
    /// whatever was on screen before once QuotaDropPresenter clears
    /// `current` (or moves on to the other agent's queued drop). `.id(drop)`
    /// forces a fresh view (and a replayed slide) for every new drop, since
    /// otherwise SwiftUI would just re-render the same QuotaDropRevealView
    /// instance in place without re-triggering onAppear.
    private func quotaDropRevealPill(_ drop: QuotaDropPresenter.Drop) -> some View {
        QuotaDropRevealView(drop: drop, topInset: vm.closedNotchSize.height)
            .id(drop)
            .frame(width: closedPillWithBadgesWidth, height: vm.closedNotchSize.height + 84, alignment: .top)
            .background(Color.black)
            .clipShape(NotchShape(topCornerRadius: cornerRadiusInsets.closed.top, bottomCornerRadius: cornerRadiusInsets.closed.bottom))
    }

    // Where the alert/download dropdowns hang from: right below the closed
    // pill when closed, right below the actual expanded notch when open —
    // otherwise an open notch would sit underneath (and behind) the pill.
    private var alertDropdownYOffset: CGFloat {
        (vm.notchState == .open ? vm.notchSize.height : vm.effectiveClosedNotchHeight) + 8
    }

    private var shouldShowDownloadProgress: Bool {
        guard coordinator.systemMonitorAlert == nil,
              networkMonitor.activeAlert == nil,
              !coordinator.sneakPeek.show,
              !coordinator.expandingView.show,
              !SharingStateManager.shared.preventNotchClose else {
            return false
        }
#if !PUBLIC_RELEASE
        guard portfolioMonitor.activeNotification == nil else {
            return false
        }
#endif
        return true
    }

    private var computedChinWidth: CGFloat {
        var chinWidth: CGFloat = vm.closedNotchSize.width

        if coordinator.expandingView.type == .battery && coordinator.expandingView.show
            && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
        {
            chinWidth = 640
        } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        } else if !coordinator.expandingView.show && vm.notchState == .closed
            && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace]
            && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        }

        return chinWidth
    }

    /// Same album-art-sized slot the two quota badges occupy.
    private var codexBadgeSlotSize: CGFloat {
        max(0, vm.effectiveClosedNotchHeight - 12)
    }

    /// Distance from screen-center to the Codex/Claude quota badge pair,
    /// derived only from the physical notch's own width (constant
    /// regardless of open/closed state or which tab is showing) — not from
    /// whatever content currently happens to be laid out, so these two land
    /// at one fixed absolute position regardless of
    /// open/closed state, instead of drifting by the couple of points that
    /// open vs. closed's different outer padding otherwise introduces when
    /// each context centers them independently through normal layout flow.
    private var codexBadgeOffsetX: CGFloat {
        let cameraZoneWidth = vm.closedNotchSize.width - cornerRadiusInsets.closed.top
        return cameraZoneWidth / 2 + 4 + codexBadgeSlotSize / 2
    }

    /// Full width of the closed pill as it normally reads — camera cutout
    /// plus the Codex and Claude quota badges flanking it on either
    /// side — not just vm.closedNotchSize.width, which is only the bare
    /// camera-cutout span the badges sit outside of.
    private var closedPillWithBadgesWidth: CGFloat {
        2 * codexBadgeOffsetX + codexBadgeSlotSize
    }

    /// Vertical offset that centers the (non-zero-height) badge within the
    /// closed-notch row when applied from `.overlay(alignment: .top)` —
    /// half the *leftover* space (row height minus the badge's own
    /// height), not half the row height itself, which is what actually
    /// pushed the badges most of the way to the bottom edge before.
    private var codexBadgeOffsetY: CGFloat {
        max(0, (vm.effectiveClosedNotchHeight - codexBadgeSlotSize) / 2)
    }

    var body: some View {
        // Calculate scale based on gesture progress only
        let gestureScale: CGFloat = {
            guard gestureProgress != 0 else { return 1.0 }
            let scaleFactor = 1.0 + gestureProgress * 0.01
            return max(0.6, scaleFactor)
        }()
        
        ZStack(alignment: .top) {
            if let drop = quotaDropPresenter.current {
                quotaDropRevealPill(drop)
                    .transition(.opacity)
            } else {
            VStack(spacing: 0) {
                let mainLayout = NotchLayout()
                    .frame(alignment: .top)
                    .padding(
                        .horizontal,
                        vm.notchState == .open
                        ? Defaults[.cornerRadiusScaling]
                        ? (cornerRadiusInsets.opened.top) : (cornerRadiusInsets.opened.bottom)
                        : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], vm.notchState == .open ? 12 : 0)
                    // Closed stays flat opaque black — it has to fuse
                    // seamlessly with the real camera housing (see
                    // codexBadgeOffsetX / the notch-shape comments above).
                    // Open is a floating control surface over the desktop,
                    // so it fades from solid black near the camera to
                    // transparent at the bottom.
                    .background(
                        vm.notchState == .open
                        ? AnyShapeStyle(LinearGradient(
                            colors: [.black, .black.opacity(0.55)],
                            startPoint: .top,
                            endPoint: .bottom
                          ))
                        : AnyShapeStyle(Color.black)
                    )
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    // Codex (left) and Claude (right) weekly-quota badges:
                    // fixed at one absolute position hard against the
                    // camera on each side, identical in open and closed
                    // state — see codexBadgeOffsetX. MusicLiveActivity/
                    // CodexIdleActivity/BoringHeader each leave a same-size
                    // clear placeholder where these would otherwise sit, so
                    // nothing else ever renders under them.
                    .overlay(alignment: .top) {
                        QuotaBadgeView(provider: .codex, remainingPercent: quotaMonitor.remainingPercent)
                            .offset(x: -codexBadgeOffsetX, y: codexBadgeOffsetY)
                    }
                    .overlay(alignment: .top) {
                        QuotaBadgeView(provider: .claude, remainingPercent: claudeQuotaMonitor.weekly?.remainingPercent)
                            .offset(x: codexBadgeOffsetX, y: codexBadgeOffsetY)
                    }
                    // Ambient glow prototype: traces the same corner radii
                    // as currentNotchShape (closed pill or open panel), so
                    // it automatically follows the notch's edge in both
                    // states — minus the flush-with-the-screen top edge,
                    // which doesn't need a glow (see AmbientGlowView).
                    .overlay(alignment: .top) {
                        AmbientGlowView(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
                    }
                    .shadow(
                        color: ((vm.notchState == .open || isHovering) && Defaults[.enableShadow])
                            ? .black.opacity(0.7) : .clear, radius: Defaults[.cornerRadiusScaling] ? 6 : 4
                    )
                    .padding(
                        .bottom,
                        vm.effectiveClosedNotchHeight == 0 ? 10 : 0
                    )
                
                mainLayout
                    .frame(
                        height: vm.notchState == .open ? vm.notchSize.height : nil,
                        alignment: .top
                    )
                    .opacity(vm.isIdleVirtualNotchHidden ? 0 : 1)
                    .conditionalModifier(true) { view in
                        let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
                        let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
                        
                        return view
                            .animation(vm.notchState == .open ? openAnimation : closeAnimation, value: vm.notchState)
                            .animation(.smooth, value: gestureProgress)
                    }
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .onTapGesture {
                        doOpen()
                    }
                    .conditionalModifier(Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .down) { translation, phase in
                                handleDownGesture(translation: translation, phase: phase)
                            }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish)) { _ in
                        if vm.notchState == .open && !isHovering && !vm.isBatteryPopoverActive {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if self.vm.notchState == .open && !self.isHovering && !self.vm.isBatteryPopoverActive && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: vm.notchState) { _, newState in
                        if newState == .closed && isHovering {
                            withAnimation {
                                isHovering = false
                            }
                        }
                    }
                    .onChange(of: vm.isBatteryPopoverActive) {
                        if !vm.isBatteryPopoverActive && !isHovering && vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if !self.vm.isBatteryPopoverActive && !self.isHovering && self.vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    .contextMenu {
                        Button("Settings") {
                            DispatchQueue.main.async {
                                SettingsWindowController.shared.showWindow()
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
                    }
                if vm.chinHeight > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.01))
                        .frame(width: computedChinWidth, height: vm.chinHeight)
                }
            }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: quotaDropPresenter.current)
        // Memory/thermal/storage alert: a Dynamic-Island-style pill that
        // drops down from underneath the camera, fixed centered,
        // independent of whatever the closed pill itself is showing. Kept
        // as its own sibling overlay here — rather than nested inside
        // mainLayout — so its buttons aren't shadowed by mainLayout's own
        // .onHover/.onTapGesture(doOpen) gesture handling.
        .overlay(alignment: .top) {
#if !PUBLIC_RELEASE
            let alertItems = orderedNotchAlerts(
                systemMonitorAlert: coordinator.systemMonitorAlert,
                stockNotification: portfolioMonitor.activeNotification,
                stockPresentedAt: portfolioMonitor.notificationPresentedAt,
                networkAlert: networkMonitor.activeAlert
            )
#else
            let alertItems = orderedNotchAlerts(
                systemMonitorAlert: coordinator.systemMonitorAlert,
                networkAlert: networkMonitor.activeAlert
            )
#endif
            if !alertItems.isEmpty,
               !coordinator.sneakPeek.show,
               !coordinator.expandingView.show,
               !SharingStateManager.shared.preventNotchClose {
                VStack(spacing: 8) {
                    ForEach(alertItems) { item in
                        switch item.kind {
                        case .systemMonitor(let alert):
                            SystemMonitorAlertDropdown(alert: alert) {
                                vm.open()
                                SystemMonitorStore.shared.openAlert(alert)
                            } dismiss: {
                                SystemMonitorStore.shared.dismissAlert()
                            }
#if !PUBLIC_RELEASE
                        case .stockPortfolio(let snapshot):
                            PortfolioAlertCard(snapshot: snapshot) {
                                StockPortfolioMonitor.shared.dismissNotification()
                            }
#endif
                        case .network(let alert):
                            NetworkAlertDropdown(alert: alert) {
                                NetworkConnectivityMonitor.shared.dismissAlert()
                            }
                        }
                    }
                }
                .offset(y: alertDropdownYOffset)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    )
                )
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: coordinator.systemMonitorAlert?.id)
#if !PUBLIC_RELEASE
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: portfolioMonitor.activeNotification)
#endif
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: networkMonitor.activeAlert?.id)
        // Downloads-folder progress pill — same drop-down slot as the
        // alerts above, so it only shows when neither is already occupying
        // the spot (a real health alert takes priority over a
        // download-progress nicety).
        .overlay(alignment: .top) {
            if let download = downloadMonitor.activeDownload, shouldShowDownloadProgress {
                DownloadProgressDropdown(download: download)
                    .offset(y: alertDropdownYOffset)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        )
                    )
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: downloadMonitor.activeDownload)
        .padding(.bottom, 8)
        .frame(maxWidth: windowSize.width, maxHeight: windowSize.height, alignment: .top)
        .compositingGroup()
        .scaleEffect(
            x: gestureScale,
            y: gestureScale,
            anchor: .top
        )
        .animation(.smooth, value: gestureProgress)
        .background(dragDetector)
        // A pending Codex approval request takes over the same module slot
        // as home/shelf/monitor (see NotchLayout) — this just force-opens
        // the notch to reveal it when a request arrives.
        .onChange(of: approvalMonitor.pendingRequest?.id) { oldID, newID in
            if newID != nil {
                // A request just arrived: remember what to restore, jump to
                // the Agent tab, and open the notch if it wasn't already.
                wasClosedBeforeApprovalRequest = (vm.notchState == .closed)
                if coordinator.currentView != .agent {
                    preApprovalRequestView = coordinator.currentView
                }
                coordinator.currentView = .agent
                if vm.notchState == .closed {
                    doOpen()
                }
            } else if oldID != nil {
                // The request that was showing just got answered: restore
                // whatever tab the user had open before it interrupted
                // them, then close back up too if that's how we found the
                // notch (rather than leaving it sitting open).
                coordinator.currentView = preApprovalRequestView ?? .home
                preApprovalRequestView = nil
                if wasClosedBeforeApprovalRequest {
                    vm.close()
                }
            }
        }
        .preferredColorScheme(.dark)
        .environmentObject(vm)
        .onChange(of: vm.anyDropZoneTargeting) { _, isTargeted in
            anyDropDebounceTask?.cancel()

            if isTargeted {
                if vm.notchState == .closed {
                    coordinator.currentView = .shelf
                    doOpen()
                }
                return
            }

            anyDropDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }

                if vm.dropEvent {
                    vm.dropEvent = false
                    return
                }

                vm.dropEvent = false
                if !SharingStateManager.shared.preventNotchClose {
                    vm.close()
                }
            }
        }
        .onAppear { updateMonitorVisibility() }
        .onDisappear {
            SystemMonitorStore.shared.setMonitorVisible(false, windowID: ObjectIdentifier(vm))
        }
        .onChange(of: coordinator.currentView) { _, _ in updateMonitorVisibility() }
        .onChange(of: vm.notchState) { _, _ in updateMonitorVisibility() }
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading) {
                if coordinator.helloAnimationRunning {
                    Spacer()
                    HelloAnimation(onFinish: {
                        vm.closeHello()
                    }).frame(
                        width: getClosedNotchSize().width,
                        height: 80
                    )
                    .padding(.top, 40)
                    Spacer()
                } else {
                    if coordinator.expandingView.type == .battery && coordinator.expandingView.show
                        && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
                    {
                        HStack(spacing: 0) {
                            HStack {
                                Text(batteryModel.statusText)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                            }

                            Rectangle()
                                .fill(.black)
                                .frame(width: vm.closedNotchSize.width + 10)

                            HStack {
                                BoringBatteryView(
                                    batteryWidth: 30,
                                    isCharging: batteryModel.isCharging,
                                    isInLowPowerMode: batteryModel.isInLowPowerMode,
                                    isPluggedIn: batteryModel.isPluggedIn,
                                    levelBattery: batteryModel.levelBattery,
                                    isForNotification: true
                                )
                            }
                            .frame(width: 76, alignment: .trailing)
                        }
                        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
                      } else if coordinator.sneakPeek.show && Defaults[.inlineHUD] && (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && vm.notchState == .closed {
                          InlineHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon, hoverAnimation: $isHovering, gestureProgress: $gestureProgress)
                              .transition(.opacity)
                      } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music) && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle) && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed {
                          MusicLiveActivity()
                              .frame(alignment: .center)
                      } else if systemMonitorEnabled && systemMonitorShowCPUWhenClosed
                                  && !coordinator.expandingView.show && !coordinator.sneakPeek.show
                                  && vm.notchState == .closed && musicManager.isPlayerIdle
                                  && !vm.hideOnClosed && !SharingStateManager.shared.preventNotchClose {
                          SystemMonitorClosedActivity()
                              .frame(width: vm.closedNotchSize.width, height: vm.effectiveClosedNotchHeight)
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && !vm.hideOnClosed  {
                          CodexIdleActivity()
                       } else if vm.notchState == .open {
                           BoringHeader()
                               .frame(height: max(24, vm.effectiveClosedNotchHeight))
                               .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
                       } else {
                           Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
                       }

                      if coordinator.sneakPeek.show {
                          if (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && !Defaults[.inlineHUD] && vm.notchState == .closed {
                              SystemEventIndicatorModifier(
                                  eventType: $coordinator.sneakPeek.type,
                                  value: $coordinator.sneakPeek.value,
                                  icon: $coordinator.sneakPeek.icon,
                                  sendEventBack: { newVal in
                                      switch coordinator.sneakPeek.type {
                                      case .volume:
                                          VolumeManager.shared.setAbsolute(Float32(newVal))
                                      case .brightness:
                                          BrightnessManager.shared.setAbsolute(value: Float32(newVal))
                                      default:
                                          break
                                      }
                                  }
                              )
                              .padding(.bottom, 10)
                              .padding(.leading, 4)
                              .padding(.trailing, 8)
                          }
                          // Old sneak peek music
                          else if coordinator.sneakPeek.type == .music {
                              if vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard {
                                  HStack(alignment: .center) {
                                      Image(systemName: "music.note")
                                      GeometryReader { geo in
                                          MarqueeText(.constant(musicManager.songTitle + " - " + musicManager.artistName),  textColor: Defaults[.playerColorTinting] ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray, minDuration: 1, frameWidth: geo.size.width)
                                      }
                                  }
                                  .foregroundStyle(.gray)
                                  .padding(.bottom, 10)
                              }
                          }
                      }
                  }
              }
              .conditionalModifier((coordinator.sneakPeek.show && (coordinator.sneakPeek.type == .music) && vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard) || (coordinator.sneakPeek.show && (coordinator.sneakPeek.type != .music) && (vm.notchState == .closed))) { view in
                  view
                      .fixedSize()
              }
              .zIndex(2)
            if vm.notchState == .open {
                VStack {
                    switch coordinator.currentView {
                    case .home:
                        NotchHomeView(albumArtNamespace: albumArtNamespace)
                    case .shelf:
                        ShelfView()
                    case .monitor:
                        SystemMonitorView()
                    case .agent:
                        AgentTabView()
                    case .claude:
                        ClaudeTabView()
                    case .clipboard:
                        ClipboardHistoryView()
#if !PUBLIC_RELEASE
                    case .portfolio:
                        PortfolioView()
#endif
                    }
                }
                .id(coordinator.currentView)
                .transition(
                    .scale(scale: 0.8, anchor: .top)
                    .combined(with: .opacity)
                    .animation(.smooth(duration: 0.35))
                )
                .zIndex(1)
                .allowsHitTesting(vm.notchState == .open)
                .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
            }
        }
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], delegate: GeneralDropTargetDelegate(isTargeted: $vm.generalDropTargeting))
    }

    @ViewBuilder
    func BoringFaceAnimation() -> some View {
        HStack {
            HStack {
                Rectangle()
                    .fill(.clear)
                    .frame(
                        width: max(0, vm.effectiveClosedNotchHeight - 12),
                        height: max(0, vm.effectiveClosedNotchHeight - 12)
                    )
                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedNotchSize.width - 20)
                MinimalFaceFeatures()
            }
        }.frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    /// Same-size clear placeholders where the Codex/Claude quota badges would
    /// otherwise sit — the actual views are drawn once, fixed to mainLayout
    /// itself (see codexBadgeOffsetX), so their absolute position is
    /// identical in open and closed state. These just reserve the matching
    /// gap in the surrounding layout (album art / spectrum spacing) so
    /// nothing else renders underneath them.
    private var leftQuotaBadgeSlot: some View {
        Color.clear.frame(width: codexBadgeSlotSize, height: codexBadgeSlotSize)
    }

    private var rightQuotaBadgeSlot: some View {
        Color.clear.frame(width: codexBadgeSlotSize, height: codexBadgeSlotSize)
    }

    /// Idle closed-notch content: just the Codex quota badge, the
    /// camera-area spacer, and the Claude quota badge — same left/camera/right slot geometry
    /// as BoringFaceAnimation above, which this replaces in the idle state.
    @ViewBuilder
    func CodexIdleActivity() -> some View {
        HStack {
            HStack {
                leftQuotaBadgeSlot

                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedNotchSize.width - 20)

                rightQuotaBadgeSlot
            }
        }.frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    func MusicLiveActivity() -> some View {
        HStack(spacing: 4) {
            Image(nsImage: musicManager.albumArt)
                .resizable()
                .clipped()
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed)
                )
                .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                .frame(
                    width: max(0, vm.effectiveClosedNotchHeight - 12),
                    height: max(0, vm.effectiveClosedNotchHeight - 12)
                )

            leftQuotaBadgeSlot

            Rectangle()
                .fill(.black)
                .overlay(
                    HStack(alignment: .top) {
                        if coordinator.expandingView.show
                            && coordinator.expandingView.type == .music
                        {
                            MarqueeText(
                                .constant(musicManager.songTitle),
                                textColor: Defaults[.coloredSpectrogram]
                                    ? Color(nsColor: musicManager.avgColor) : Color.gray,
                                minDuration: 0.4,
                                frameWidth: 100
                            )
                            .opacity(
                                (coordinator.expandingView.show
                                    && Defaults[.sneakPeekStyles] == .inline)
                                    ? 1 : 0
                            )
                            Spacer(minLength: vm.closedNotchSize.width)
                            // Song Artist
                            Text(musicManager.artistName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(
                                    Defaults[.coloredSpectrogram]
                                        ? Color(nsColor: musicManager.avgColor)
                                        : Color.gray
                                )
                                .opacity(
                                    (coordinator.expandingView.show
                                        && coordinator.expandingView.type == .music
                                        && Defaults[.sneakPeekStyles] == .inline)
                                        ? 1 : 0
                                )
                        }
                    }
                )
                .frame(
                    width: (coordinator.expandingView.show
                        && coordinator.expandingView.type == .music
                        && Defaults[.sneakPeekStyles] == .inline)
                        ? 380
                        : vm.closedNotchSize.width
                            + -cornerRadiusInsets.closed.top
                )

            rightQuotaBadgeSlot

            HStack {
                if useMusicVisualizer {
                    Rectangle()
                        .fill(
                            Defaults[.coloredSpectrogram]
                                ? Color(nsColor: musicManager.avgColor).gradient
                                : Color.gray.gradient
                        )
                        .frame(width: 50, alignment: .center)
                        .matchedGeometryEffect(id: "spectrum", in: albumArtNamespace)
                        .mask {
                            AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                                .frame(width: 16, height: 12)
                        }
                } else {
                    LottieAnimationContainer()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(
                width: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                        + gestureProgress / 2
                ),
                height: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                ),
                alignment: .center
            )
        }
        .frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    var dragDetector: some View {
        if Defaults[.boringShelf] && vm.notchState == .closed {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
            vm.dropEvent = true
            ShelfStateViewModel.shared.load(providers)
            return true
        }
        } else {
            EmptyView()
        }
    }

    private func doOpen() {
        withAnimation(animationSpring) {
            vm.open()
        }
    }

    private func updateMonitorVisibility() {
        let visible = systemMonitorEnabled
            && vm.notchState == .open
            && coordinator.currentView == .monitor
        SystemMonitorStore.shared.setMonitorVisible(
            visible,
            windowID: ObjectIdentifier(vm)
        )
    }

    // MARK: - Hover Management

    private func handleHover(_ hovering: Bool) {
        if coordinator.firstLaunch { return }
        hoverTask?.cancel()
        
        if hovering {
            withAnimation(animationSpring) {
                isHovering = true
                vm.edgeAutoOpenActive = true
            }
            
            if vm.notchState == .closed && Defaults[.enableHaptics] {
                haptics.toggle()
            }
            
            guard vm.notchState == .closed,
                  !coordinator.sneakPeek.show,
                  openNotchOnHover else { return }
            
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration]))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          self.isHovering,
                          !self.coordinator.sneakPeek.show else { return }
                    
                    self.doOpen()
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    withAnimation(animationSpring) {
                        self.isHovering = false
                        self.vm.edgeAutoOpenActive = false
                    }
                    // Mouse leaving no longer closes an open notch — once
                    // opened (by hover or otherwise), it stays open until a
                    // click lands outside it. See
                    // BoringViewModel.startOutsideClickMonitor.
                }
            }
        }
    }

    // MARK: - Gesture Handling

    private func handleDownGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .closed else { return }

        if phase == .ended {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * 20
        }

        if translation > Defaults[.gestureSensitivity] {
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
            doOpen()
        }
    }

}

struct FullScreenDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: () -> Void

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        onDrop()
        return true
    }

}

struct GeneralDropTargetDelegate: DropDelegate {
    @Binding var isTargeted: Bool

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        return false
    }
}

#Preview {
    let vm = BoringViewModel()
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}
