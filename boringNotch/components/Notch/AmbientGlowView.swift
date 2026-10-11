//
//  AmbientGlowView.swift
//  boringNotch
//
//  Prototype: replaces the small breathing dot's color signal with a
//  color chase that runs along the notch's own edge — see the "Codex
//  Ambient Light" design review. Mirrors NotchShape's corner geometry
//  (same topCornerRadius/bottomCornerRadius ContentView already uses for
//  currentNotchShape) so the glow traces the closed pill or the open
//  panel automatically, but as an *open* path that stops short of the
//  final top edge — that segment sits flush against the screen's own top
//  edge, nothing to glow into up there, and it would just double up with
//  the black divider line ContentView already draws in that exact spot.
//
//  "Completely cover" here means the edge, not the notch's interior, and
//  the colors split the edge's actual path length evenly (a running
//  cycle's yellow/green/blue each own exactly a third of the perimeter,
//  not a third of the angle around some center point — those aren't the
//  same thing on a shape this much wider than it is tall). Built from
//  Shape.trim(from:to:), which is already parameterized by fraction of
//  path length, with all the segments' start/end continuously offset
//  together to chase clockwise around the edge forever.
//
//  Off at idle; a slow three-color sweep while an agent is running — one
//  palette for Codex alone, one for Claude alone, and a third when both
//  are running at once — and a fast red flash whenever either agent is
//  waiting on an approval (that takes priority over any running sweep).
//  Driven by the two AgentBreathingMonitor channels. Positive rotation
//  degrees is clockwise in SwiftUI's screen coordinate space.
//
//  Driven by TimelineView(.animation), not a `@State` + `.animation(_,
//  value:)` pair: that combination only *replays the same one bounded
//  transition* forever (SwiftUI interpolates between whatever the
//  old/new values resolved to, then snaps back and repeats) — for a
//  seamlessly-looping value like this one, the "old" and "new" states are
//  numerically identical (offset 0 and offset 1 both wrap to the same
//  position), so there's nothing to interpolate and it sits still.
//  TimelineView sidesteps that: it re-renders continuously from the
//  actual clock, so every frame gets a freshly-computed, genuinely
//  advancing phase — no replay trick, no old/new collision.
//

import SwiftUI

// Brighter/more vivid again — full-saturation, high-luminance hues so
// they still read clearly once blurred.
// The three running palettes deliberately share no hue with each other,
// so which agent(s) are working reads at a glance.
private let codexPalette = [
    Color(red: 1.00, green: 0.78, blue: 0.05), // amber
    Color(red: 0.15, green: 0.95, blue: 0.35), // green
    Color(red: 0.15, green: 0.55, blue: 1.00)  // blue
]
private let claudePalette = [
    Color(red: 1.00, green: 0.45, blue: 0.25), // Claude coral
    Color(red: 1.00, green: 0.30, blue: 0.62), // pink
    Color(red: 0.62, green: 0.36, blue: 1.00)  // violet
]
private let bothRunningPalette = [
    Color(red: 0.05, green: 0.90, blue: 1.00), // cyan
    Color(red: 0.72, green: 1.00, blue: 0.10), // chartreuse
    Color(red: 1.00, green: 0.20, blue: 0.95)  // magenta
]
private let ambientRed = Color(red: 1.00, green: 0.20, blue: 0.12)
// Wide enough that blurring still leaves a bright, thick core — a thin
// stroke blurred by a wide radius just spreads its brightness thin over
// a big area instead of reading as a solid glow (gaussian blur conserves
// total light, it doesn't add any), which is why this kept looking faint
// even after the colors themselves got more vivid.
private let strokeWidth: CGFloat = 18
// Blurs just the seams between adjacent color segments (applied inside
// ChasingStroke, before the outer edge-fade mask/blur) — kept small
// enough that combined with glowBlur it still fits the window's margin
// (see glowBlur's own comment — going much higher than this re-triggers
// the edge-clipping bug that was just fixed).
private let segmentBlur: CGFloat = 16
// Kept small deliberately: the window around the notch only has ~14-36pt
// of margin outside the notch's own clipped shape (less when closed, more
// when open — see mainLayout's padding in ContentView), and blur bleeds
// roughly 2-3x its radius before fading to nothing. A wider radius here
// gets hard-clipped by the window's own edge before it finishes fading,
// which reads as a harsh cutoff rather than a soft one — widening the
// window instead isn't safe, since the open panel's own width isn't
// pinned and grows to fill however much the window proposes to it.
private let glowBlur: CGFloat = 9
/// Fraction of the outline's total path length each open end (top-left
/// and top-right, where the path starts/stops short of the top edge)
/// fades out over.
private let edgeFadeLength: Double = 0.16
private let edgeFadeSteps = 24

/// Smoothstep ease — stays darker for longer near 0, then ramps up, so
/// the edge fade reads as a gradual dimming rather than a linear ramp
/// that still looks like it "starts" abruptly.
private func easeInOut(_ t: Double) -> Double {
    t * t * (3 - 2 * t)
}

/// Same path as NotchShape, minus the final line back across the top —
/// left, bottom, and right edges (with their corners) only.
private struct NotchGlowOutline: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY)
        )
        // Deliberately no closing line back to (minX, minY) — that
        // segment is the flush-with-the-screen top edge.

        return path
    }
}

/// `colors.count` equal-length bands, each a solid color, splitting the
/// outline's total path length evenly and chasing clockwise around it
/// forever — `phase` (0..<1, one full lap per `period` seconds of real
/// time) shifts every band's start/end together.
private struct ChasingStroke: View {
    let outline: NotchGlowOutline
    let colors: [Color]
    let period: Double

    private var segmentLength: Double { 1.0 / Double(colors.count) }

    private func phase(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period) / period
        return t < 0 ? t + 1 : t
    }

    /// One color's segment can wrap past the path's end back to its
    /// start, in which case it's really two trimmed ranges, not one.
    private func trimRanges(start: Double, phase: Double) -> [(Double, Double)] {
        var s = (start + phase).truncatingRemainder(dividingBy: 1)
        if s < 0 { s += 1 }
        let e = s + segmentLength
        return e <= 1 ? [(s, e)] : [(s, 1), (0, e - 1)]
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = phase(at: timeline.date)
            ZStack {
                ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                    ForEach(
                        Array(trimRanges(start: Double(index) * segmentLength, phase: phase).enumerated()),
                        id: \.offset
                    ) { _, range in
                        outline
                            .trim(from: range.0, to: range.1)
                            .stroke(color, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .butt))
                    }
                }
            }
            .blur(radius: segmentBlur)
        }
    }
}

/// A single solid color that flashes on and off around the whole outline
/// at once — same shape/width/blur treatment as the running chase, just
/// one color blinking instead of several chasing each other.
private struct FlashingStroke: View {
    let outline: NotchGlowOutline
    let color: Color
    let period: Double

    private func opacity(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period) / period
        let phase = t < 0 ? t + 1 : t
        // Triangle wave through the smoothstep ease: dim -> bright in the
        // first half, bright -> dim in the second — a fast `period`
        // (see attentionFlashPeriod) is what makes this read as a flash
        // rather than a slow breathing pulse.
        let half = phase < 0.5 ? phase / 0.5 : (1 - phase) / 0.5
        return 0.15 + 0.85 * easeInOut(half)
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            outline
                .stroke(color, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .butt))
                .opacity(opacity(at: timeline.date))
        }
    }
}

/// A stepped opacity ramp that fades to nothing right at the outline's
/// two open ends (top-left and top-right, where the path stops short of
/// the top edge — see NotchGlowOutline) and stays fully solid in
/// between. Applied as a `.mask()`, independent of whichever color the
/// chase currently has at each position, so the fade holds steady even
/// as colors rotate underneath it.
private struct EdgeFadeMask: View {
    let outline: NotchGlowOutline

    var body: some View {
        ZStack {
            outline
                .trim(from: edgeFadeLength, to: 1 - edgeFadeLength)
                .stroke(Color.black, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .butt))
            ForEach(0..<edgeFadeSteps, id: \.self) { step in
                let fraction = Double(step) / Double(edgeFadeSteps)
                let nextFraction = Double(step + 1) / Double(edgeFadeSteps)
                let opacity = easeInOut(nextFraction)

                outline
                    .trim(from: edgeFadeLength * fraction, to: edgeFadeLength * nextFraction)
                    .stroke(Color.black.opacity(opacity), style: StrokeStyle(lineWidth: strokeWidth, lineCap: .butt))

                outline
                    .trim(from: 1 - edgeFadeLength * nextFraction, to: 1 - edgeFadeLength * fraction)
                    .stroke(Color.black.opacity(opacity), style: StrokeStyle(lineWidth: strokeWidth, lineCap: .butt))
            }
        }
    }
}

struct AmbientGlowView: View {
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat

    @ObservedObject private var codexMonitor = AgentBreathingMonitor.codex
    @ObservedObject private var claudeMonitor = AgentBreathingMonitor.claude

    // Full trip around the edge while running; a fast on/off flash cycle
    // while waiting on your approval.
    private static var runningChasePeriod: Double { 6 }
    private static var attentionFlashPeriod: Double { 0.35 }

    private var outline: NotchGlowOutline {
        NotchGlowOutline(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
    }

    var body: some View {
        pulseLayer
            .mask(EdgeFadeMask(outline: outline))
            .blur(radius: glowBlur)
            .opacity(isShowing ? 1 : 0)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.6), value: isShowing)
    }

    @ViewBuilder
    private var pulseLayer: some View {
        if codexMonitor.state == .attention || claudeMonitor.state == .attention {
            FlashingStroke(outline: outline, color: ambientRed, period: Self.attentionFlashPeriod)
        } else if let runningPalette {
            // Keyed by palette so the other agent starting/stopping
            // crossfades between palettes instead of snapping. The chase
            // phase comes from the wall clock, so the sweep position stays
            // continuous across the swap.
            ZStack {
                ChasingStroke(outline: outline, colors: runningPalette, period: Self.runningChasePeriod)
                    .id(runningPalette)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.6), value: runningPalette)
        }
    }

    private var runningPalette: [Color]? {
        switch (codexMonitor.state == .running, claudeMonitor.state == .running) {
        case (true, true): return bothRunningPalette
        case (true, false): return codexPalette
        case (false, true): return claudePalette
        case (false, false): return nil
        }
    }

    private var isShowing: Bool { codexMonitor.state != .idle || claudeMonitor.state != .idle }
}
