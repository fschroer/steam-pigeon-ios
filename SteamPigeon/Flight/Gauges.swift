import SwiftUI

/// Speed gauge, ported from Android's `drawVelocityGauge`.
///
/// A 120° arc from 210° (lower-left) to 330° (lower-right): 0 m/s at 210°, `maxSpeed`
/// at 330°. Ticks every 100 m/s, and the arc changes colour as the needle climbs so
/// the reading is legible without reading the number.
struct VelocityGauge: View {
    let speedMs: Double
    var maxSpeed: Double = 500

    private let startDeg = 210.0
    private let sweepDeg = 120.0
    private let tickSpeeds: [Double] = [0, 100, 200, 300, 400, 500]

    var body: some View {
        Canvas { ctx, size in
            let radius = min(size.width, size.height) / 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let stroke = max(radius * 0.02, 1)
            let frac = min(max(speedMs / maxSpeed, 0), 1)

            // Background wedge.
            var bg = Path()
            bg.move(to: c)
            bg.addArc(center: c, radius: radius,
                      startAngle: .degrees(startDeg), endAngle: .degrees(startDeg + sweepDeg),
                      clockwise: false)
            bg.closeSubpath()
            ctx.fill(bg, with: .color(SPColor.mapOverlay))

            // Ticks and their labels.
            for tick in tickSpeeds where tick <= maxSpeed {
                let a = Angle.degrees(startDeg + (tick / maxSpeed) * sweepDeg).radians
                var line = Path()
                line.move(to: CGPoint(x: c.x + cos(a) * radius * 0.75,
                                      y: c.y + sin(a) * radius * 0.75))
                line.addLine(to: CGPoint(x: c.x + cos(a) * radius * 0.95,
                                         y: c.y + sin(a) * radius * 0.95))
                ctx.stroke(line, with: .color(SPColor.primary), lineWidth: stroke * 1.5)

                ctx.draw(Text("\(Int(tick))")
                            .font(SPFont.labelSmall)
                            .foregroundColor(SPColor.primary),
                         at: CGPoint(x: c.x + cos(a) * radius * 0.62,
                                     y: c.y + sin(a) * radius * 0.62))
            }

            // The travelled arc, coloured by how much of the range is used.
            if frac > 0 {
                let colour: Color = frac < 0.5 ? SPColor.primary
                                  : (frac < 0.8 ? Color(hex: 0xFF9800) : Color(hex: 0xF44336))
                var arc = Path()
                arc.addArc(center: c, radius: radius * 0.88,
                           startAngle: .degrees(startDeg),
                           endAngle: .degrees(startDeg + frac * sweepDeg),
                           clockwise: false)
                ctx.stroke(arc, with: .color(colour), lineWidth: stroke * 3)
            }

            // Needle and hub.
            let na = Angle.degrees(startDeg + frac * sweepDeg).radians
            var needle = Path()
            needle.move(to: c)
            needle.addLine(to: CGPoint(x: c.x + cos(na) * radius * 0.7,
                                       y: c.y + sin(na) * radius * 0.7))
            ctx.stroke(needle, with: .color(.white), lineWidth: stroke * 1.5)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - stroke * 2.5, y: c.y - stroke * 2.5,
                                            width: stroke * 5, height: stroke * 5)),
                     with: .color(.white))

            ctx.draw(Text("\(Int(speedMs)) m/s")
                        .font(SPFont.telemetryEmphasis(size: 14))
                        .foregroundColor(.white),
                     at: CGPoint(x: c.x, y: c.y + radius * 0.35))
        }
        .accessibilityLabel("Speed \(Int(speedMs)) metres per second")
    }
}

/// Wireframe rocket showing live attitude, ported from Android's `drawRocket3D`.
///
/// The body-frame model is projected through the attitude quaternion into NED, then
/// isometrically to the screen: east goes right, north upper-left, down goes down.
/// Segments are depth-sorted and drawn back-to-front, which is what stops the far
/// side of the airframe drawing over the near side.
struct AttitudeView: View {
    let attitude: Quaternionf

    // Body-frame geometry, x along the nose.
    private let ringCount = 6
    private let bodyR: Double = 0.08
    private let noseX: Double = 1.0
    private let noseBaseX: Double = 0.65
    private let tailX: Double = -0.5

    var body: some View {
        Canvas { ctx, size in
            let scale = min(size.width, size.height) / 2 * 0.9
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let stroke = max(scale * 0.02, 1)

            ctx.fill(Path(ellipseIn: CGRect(x: c.x - scale * 1.1, y: c.y - scale * 1.1,
                                            width: scale * 2.2, height: scale * 2.2)),
                     with: .color(SPColor.mapOverlay))

            // Rotation matrix from q_bn (body → NED). Each column is where a body axis
            // lands in NED.
            let w = Double(attitude.w), qx = Double(attitude.x)
            let qy = Double(attitude.y), qz = Double(attitude.z)
            let r00 = 1 - 2 * (qy * qy + qz * qz), r01 = 2 * (qx * qy - w * qz), r02 = 2 * (qx * qz + w * qy)
            let r10 = 2 * (qx * qy + w * qz), r11 = 1 - 2 * (qx * qx + qz * qz), r12 = 2 * (qy * qz - w * qx)
            let r20 = 2 * (qx * qz - w * qy), r21 = 2 * (qy * qz + w * qx), r22 = 1 - 2 * (qx * qx + qy * qy)

            let cos30 = cos(Double.pi / 6), sin30 = sin(Double.pi / 6)

            func depth(_ b: (Double, Double, Double)) -> Double {
                r20 * b.0 + r21 * b.1 + r22 * b.2
            }
            func project(_ b: (Double, Double, Double)) -> CGPoint {
                let pN = r00 * b.0 + r01 * b.1 + r02 * b.2
                let pE = r10 * b.0 + r11 * b.1 + r12 * b.2
                let pD = depth(b)
                return CGPoint(x: c.x + (pE - pN) * cos30 * scale,
                               y: c.y + ((pN + pE) * sin30 + pD) * scale)
            }
            func ring(_ x: Double, _ r: Double) -> [(Double, Double, Double)] {
                (0..<ringCount).map { i in
                    let a = 2 * Double.pi * Double(i) / Double(ringCount)
                    return (x, r * cos(a), r * sin(a))
                }
            }

            let noseRing = ring(noseBaseX, bodyR)
            let tailRing = ring(tailX, bodyR)
            let noseTip = (noseX, 0.0, 0.0)

            let bodyColour = Color(hex: 0xB0C8E8)
            let noseColour = Color(hex: 0xFF6060)

            var segments: [(CGPoint, CGPoint, Color, Double, Double)] = []
            func add(_ a: (Double, Double, Double), _ b: (Double, Double, Double),
                     _ colour: Color, _ width: Double) {
                segments.append((project(a), project(b), colour, width,
                                 (depth(a) + depth(b)) * 0.5))
            }

            for i in 0..<ringCount { add(noseRing[i], noseTip, noseColour, stroke * 1.5) }
            for i in 0..<ringCount { add(noseRing[i], noseRing[(i + 1) % ringCount], bodyColour, stroke) }
            for i in 0..<ringCount { add(noseRing[i], tailRing[i], bodyColour, stroke) }
            for i in 0..<ringCount { add(tailRing[i], tailRing[(i + 1) % ringCount], bodyColour, stroke) }

            // Back-to-front: larger NED down is further from the eye in this
            // projection, so it is drawn first.
            for seg in segments.sorted(by: { $0.4 > $1.4 }) {
                var path = Path()
                path.move(to: seg.0)
                path.addLine(to: seg.1)
                ctx.stroke(path, with: .color(seg.2), lineWidth: seg.3)
            }
        }
        .accessibilityLabel(String(format: "Attitude: inclination %.0f degrees, heading %.0f degrees",
                                   attitude.inclinationDeg, attitude.headingDeg))
    }
}
