//
//  CodexLogoShape.swift
//  boringNotch
//
//  Codex's product mark as a SwiftUI Shape, traced from the same 24x24
//  SVG path data as Macos_breathing_light/Sources/AgentLight/LogoPaths.swift
//  (fill-rule evenodd — apply with `.fill(_, style: FillStyle(eoFill: true))`).
//  Unlike that AppKit version, no y-flip is needed here: SwiftUI's Path
//  coordinate space is already y-down, matching the source SVG directly.
//

import SwiftUI

struct CodexLogoShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let maxExtent = min(rect.width, rect.height) / 2
        let bboxCenter = CGPoint(x: 12.105, y: 11.965)
        let bboxHalf: CGFloat = 12.14
        let scale = maxExtent / bboxHalf

        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: center.x + (x - bboxCenter.x) * scale, y: center.y + (y - bboxCenter.y) * scale)
        }

        var path = Path()

        path.move(to: p(8.086, 0.457))
        path.addCurve(to: p(11.132, 0.042), control1: p(9.049, 0.061), control2: p(10.098, -0.082))
        path.addCurve(to: p(14.696, 1.742), control1: p(12.465, 0.195), control2: p(13.653, 0.762))
        path.addCurve(to: p(14.803, 1.771), control1: p(14.725, 1.769), control2: p(14.765, 1.780))
        path.addCurve(to: p(18.864, 2.137), control1: p(16.211, 1.425), control2: p(17.565, 1.547))
        path.addLine(to: p(18.927, 2.167))
        path.addLine(to: p(19.081, 2.243))
        path.addCurve(to: p(21.999, 5.441), control1: p(20.438, 2.946), control2: p(21.411, 4.013))
        path.addCurve(to: p(22.420, 7.567), control1: p(22.277, 6.120), control2: p(22.417, 6.829))
        path.addCurve(to: p(22.240, 9.198), control1: p(22.440, 8.117), control2: p(22.379, 8.666))
        path.addCurve(to: p(22.280, 9.353), control1: p(22.226, 9.253), control2: p(22.241, 9.312))
        path.addCurve(to: p(23.858, 12.244), control1: p(23.066, 10.150), control2: p(23.613, 11.152))
        path.addCurve(to: p(22.675, 17.384), control1: p(24.243, 14.145), control2: p(23.848, 15.859))
        path.addLine(to: p(22.493, 17.604))
        path.addCurve(to: p(19.559, 19.455), control1: p(21.716, 18.494), control2: p(20.696, 19.137))
        path.addCurve(to: p(19.451, 19.557), control1: p(19.509, 19.470), control2: p(19.468, 19.508))
        path.addCurve(to: p(18.464, 21.549), control1: p(19.196, 20.293), control2: p(18.940, 20.921))
        path.addCurve(to: p(13.516, 24.000), control1: p(17.265, 23.131), control2: p(15.502, 24.011))
        path.addCurve(to: p(9.306, 22.264), control1: p(11.933, 23.992), control2: p(10.530, 23.413))
        path.addCurve(to: p(9.166, 22.232), control1: p(9.268, 22.229), control2: p(9.215, 22.217))
        path.addCurve(to: p(7.562, 22.417), control1: p(8.648, 22.399), control2: p(8.126, 22.423))
        path.addCurve(to: p(4.967, 21.795), control1: p(6.661, 22.410), control2: p(5.773, 22.197))
        path.addCurve(to: p(2.821, 20.014), control1: p(4.123, 21.376), control2: p(3.388, 20.766))
        path.addCurve(to: p(2.270, 19.193), control1: p(2.618, 19.745), control2: p(2.417, 19.492))
        path.addCurve(to: p(1.775, 17.910), control1: p(2.067, 18.781), control2: p(1.902, 18.352))
        path.addCurve(to: p(1.758, 14.846), control1: p(1.509, 16.907), control2: p(1.503, 15.852))
        path.addCurve(to: p(1.766, 14.772), control1: p(1.766, 14.822), control2: p(1.769, 14.797))
        path.addCurve(to: p(1.729, 14.708), control1: p(1.761, 14.747), control2: p(1.748, 14.725))
        path.addCurve(to: p(0.349, 12.506), control1: p(1.113, 14.084), control2: p(0.641, 13.333))
        path.addCurve(to: p(0.016, 10.917), control1: p(0.155, 11.997), control2: p(0.043, 11.461))
        path.addCurve(to: p(0.204, 8.785), control1: p(-0.032, 10.201), control2: p(0.031, 9.482))
        path.addCurve(to: p(2.781, 5.292), control1: p(0.654, 7.301), control2: p(1.513, 6.137))
        path.addCurve(to: p(3.583, 4.854), control1: p(3.063, 5.104), control2: p(3.331, 4.958))
        path.addCurve(to: p(4.444, 4.550), control1: p(3.869, 4.734), control2: p(4.156, 4.634))
        path.addCurve(to: p(4.531, 4.463), control1: p(4.486, 4.538), control2: p(4.519, 4.505))
        path.addCurve(to: p(5.635, 2.310), control1: p(4.749, 3.678), control2: p(5.125, 2.945))
        path.addCurve(to: p(8.086, 0.457), control1: p(6.315, 1.464), control2: p(7.132, 0.846))
        path.closeSubpath()

        path.move(to: p(7.282, 8.307))
        path.addCurve(to: p(6.125, 7.992), control1: p(7.049, 7.900), control2: p(6.531, 7.759))
        path.addCurve(to: p(5.809, 9.149), control1: p(5.718, 8.224), control2: p(5.576, 8.742))
        path.addLine(to: p(7.503, 12.114))
        path.addLine(to: p(5.815, 14.962))
        path.addCurve(to: p(6.131, 16.094), control1: p(5.600, 15.363), control2: p(5.739, 15.862))
        path.addCurve(to: p(7.275, 15.826), control1: p(6.522, 16.326), control2: p(7.027, 16.207))
        path.addLine(to: p(9.215, 12.554))
        path.addCurve(to: p(9.222, 11.700), control1: p(9.371, 12.291), control2: p(9.373, 11.965))
        path.addLine(to: p(7.282, 8.307))
        path.closeSubpath()

        path.move(to: p(12.728, 14.547))
        path.addCurve(to: p(11.929, 15.395), control1: p(12.279, 14.574), control2: p(11.929, 14.945))
        path.addCurve(to: p(12.728, 16.242), control1: p(11.929, 15.844), control2: p(12.279, 16.215))
        path.addLine(to: p(17.576, 16.242))
        path.addCurve(to: p(18.384, 15.394), control1: p(18.028, 16.220), control2: p(18.384, 15.847))
        path.addCurve(to: p(17.576, 14.546), control1: p(18.384, 14.941), control2: p(18.028, 14.568))
        path.addLine(to: p(12.728, 14.546))
        path.closeSubpath()

        return path
    }
}
