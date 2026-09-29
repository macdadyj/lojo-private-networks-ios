import SwiftUI

/// Procedurally drawn camera frame for demo devices: time-of-day sky, terrain, a subject per
/// camera, a timestamp overlay and lens vignette. Night frames render as monochrome "IR".
struct DemoStillView: View {
    let deviceKey: String
    let title: String
    let capturedAt: Date

    private var hour: Int { Calendar.current.component(.hour, from: capturedAt) }
    private var isNight: Bool { hour < 6 || hour >= 20 }
    private var isDusk: Bool { hour == 6 || (18...19).contains(hour) }
    private var seed: UInt64 {
        deviceKey.unicodeScalars.reduce(UInt64(7)) { $0 &* 31 &+ UInt64($1.value) }
            &+ UInt64(capturedAt.timeIntervalSince1970 / 60)
    }

    var body: some View {
        Canvas { ctx, size in
            var rng = SeededRandom(seed: seed)
            drawSky(ctx, size)
            drawMesa(ctx, size)
            drawGround(ctx, size, &rng)
            switch deviceKey {
            case "north-gate": drawGate(ctx, size)
            case "hay-barn-cam": drawBarn(ctx, size)
            case "corral-cam": drawCorral(ctx, size, &rng)
            default: drawFencePosts(ctx, size)
            }
            drawGrain(ctx, size, &rng)
        }
        .saturation(isNight ? 0 : 1)
        .colorMultiply(isNight ? Color(red: 0.8, green: 0.95, blue: 0.85) : .white)
        .overlay(
            RadialGradient(colors: [.clear, .black.opacity(0.45)], center: .center, startRadius: 80, endRadius: 330)
        )
        .overlay(alignment: .topLeading) { osd }
        .aspectRatio(4 / 3, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Sample camera still from \(title), \(isNight ? "night infrared" : "daylight") view")
    }

    private var osd: some View {
        HStack {
            Text(title.uppercased())
            Spacer()
            Text(capturedAt.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)))
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white.opacity(0.92))
        .shadow(color: .black.opacity(0.8), radius: 1, x: 1, y: 1)
        .padding(8)
        .accessibilityHidden(true)
    }

    // MARK: - layers

    private func drawSky(_ ctx: GraphicsContext, _ size: CGSize) {
        let colors: [Color]
        if isNight {
            colors = [Color(white: 0.12), Color(white: 0.3)]
        } else if isDusk {
            colors = [Color(red: 0.32, green: 0.3, blue: 0.55), Color(red: 0.98, green: 0.62, blue: 0.38)]
        } else {
            colors = [Color(red: 0.36, green: 0.6, blue: 0.9), Color(red: 0.78, green: 0.88, blue: 0.97)]
        }
        let rect = CGRect(origin: .zero, size: size)
        ctx.fill(Path(rect), with: .linearGradient(Gradient(colors: colors), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.6)))
    }

    private func drawMesa(_ ctx: GraphicsContext, _ size: CGSize) {
        let h = size.height, w = size.width
        var p = Path()
        p.move(to: CGPoint(x: 0, y: h * 0.52))
        p.addLine(to: CGPoint(x: w * 0.12, y: h * 0.47))
        p.addLine(to: CGPoint(x: w * 0.18, y: h * 0.38))
        p.addLine(to: CGPoint(x: w * 0.46, y: h * 0.37))
        p.addLine(to: CGPoint(x: w * 0.52, y: h * 0.45))
        p.addLine(to: CGPoint(x: w * 0.7, y: h * 0.47))
        p.addLine(to: CGPoint(x: w * 0.78, y: h * 0.41))
        p.addLine(to: CGPoint(x: w * 0.9, y: h * 0.42))
        p.addLine(to: CGPoint(x: w, y: h * 0.5))
        p.addLine(to: CGPoint(x: w, y: h * 0.6))
        p.addLine(to: CGPoint(x: 0, y: h * 0.6))
        p.closeSubpath()
        let mesa = isDusk ? Color(red: 0.42, green: 0.28, blue: 0.3) : Color(red: 0.58, green: 0.45, blue: 0.4)
        ctx.fill(p, with: .color(mesa.opacity(0.9)))
    }

    private func drawGround(_ ctx: GraphicsContext, _ size: CGSize, _ rng: inout SeededRandom) {
        let h = size.height, w = size.width
        let ground = CGRect(x: 0, y: h * 0.55, width: w, height: h * 0.45)
        ctx.fill(Path(ground), with: .linearGradient(
            Gradient(colors: [Color(red: 0.72, green: 0.64, blue: 0.45), Color(red: 0.5, green: 0.43, blue: 0.3)]),
            startPoint: CGPoint(x: 0, y: h * 0.55), endPoint: CGPoint(x: 0, y: h)))
        for _ in 0..<38 {
            let x = rng.next() * w
            let y = h * 0.58 + rng.next() * h * 0.4
            let r = 3 + rng.next() * 9 * (y / h)
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2.2, height: r)),
                     with: .color(Color(red: 0.4, green: 0.48, blue: 0.3).opacity(0.75)))
        }
    }

    private func drawFencePosts(_ ctx: GraphicsContext, _ size: CGSize) {
        let h = size.height, w = size.width
        var wire = Path()
        wire.move(to: CGPoint(x: 0, y: h * 0.66))
        wire.addLine(to: CGPoint(x: w, y: h * 0.6))
        ctx.stroke(wire, with: .color(.black.opacity(0.45)), lineWidth: 1)
        for i in 0..<7 {
            let x = CGFloat(i) * w / 6
            let y = h * 0.66 - (x / w) * h * 0.06
            ctx.fill(Path(CGRect(x: x - 2, y: y - 6, width: 4, height: h * 0.1)), with: .color(Color(red: 0.3, green: 0.22, blue: 0.16)))
        }
    }

    private func drawGate(_ ctx: GraphicsContext, _ size: CGSize) {
        let h = size.height, w = size.width
        drawFencePosts(ctx, size)
        let post = Color(red: 0.28, green: 0.2, blue: 0.14)
        ctx.fill(Path(CGRect(x: w * 0.3, y: h * 0.5, width: w * 0.035, height: h * 0.38)), with: .color(post))
        ctx.fill(Path(CGRect(x: w * 0.68, y: h * 0.5, width: w * 0.035, height: h * 0.38)), with: .color(post))
        let steel = Color(white: 0.72)
        for k in 0..<5 {
            let y = h * (0.56 + CGFloat(k) * 0.06)
            ctx.fill(Path(CGRect(x: w * 0.335, y: y, width: w * 0.345, height: h * 0.012)), with: .color(steel))
        }
        var brace = Path()
        brace.move(to: CGPoint(x: w * 0.335, y: h * 0.8))
        brace.addLine(to: CGPoint(x: w * 0.68, y: h * 0.56))
        ctx.stroke(brace, with: .color(steel), lineWidth: 3)
        var road = Path()
        road.move(to: CGPoint(x: w * 0.42, y: h * 0.88))
        road.addLine(to: CGPoint(x: w * 0.58, y: h * 0.88))
        road.addLine(to: CGPoint(x: w * 0.9, y: h))
        road.addLine(to: CGPoint(x: w * 0.1, y: h))
        road.closeSubpath()
        ctx.fill(road, with: .color(Color(red: 0.62, green: 0.55, blue: 0.44)))
    }

    private func drawBarn(_ ctx: GraphicsContext, _ size: CGSize) {
        let h = size.height, w = size.width
        let body = CGRect(x: w * 0.18, y: h * 0.42, width: w * 0.42, height: h * 0.3)
        ctx.fill(Path(body), with: .color(Color(red: 0.62, green: 0.18, blue: 0.14)))
        var roof = Path()
        roof.move(to: CGPoint(x: w * 0.15, y: h * 0.43))
        roof.addLine(to: CGPoint(x: w * 0.39, y: h * 0.28))
        roof.addLine(to: CGPoint(x: w * 0.63, y: h * 0.43))
        roof.closeSubpath()
        ctx.fill(roof, with: .color(Color(white: 0.55)))
        ctx.fill(Path(CGRect(x: w * 0.33, y: h * 0.54, width: w * 0.12, height: h * 0.18)), with: .color(Color(red: 0.25, green: 0.1, blue: 0.08)))
        let hay = Color(red: 0.86, green: 0.74, blue: 0.42)
        for k in 0..<4 {
            let x = w * (0.64 + CGFloat(k % 2) * 0.1)
            let y = h * (0.64 - CGFloat(k / 2) * 0.08)
            ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: w * 0.1, height: h * 0.08), cornerRadius: 3), with: .color(hay))
            ctx.stroke(Path(roundedRect: CGRect(x: x, y: y, width: w * 0.1, height: h * 0.08), cornerRadius: 3), with: .color(.black.opacity(0.2)), lineWidth: 1)
        }
    }

    private func drawCorral(_ ctx: GraphicsContext, _ size: CGSize, _ rng: inout SeededRandom) {
        let h = size.height, w = size.width
        let rail = Color(red: 0.42, green: 0.32, blue: 0.22)
        for k in 0..<3 {
            let y = h * (0.66 + CGFloat(k) * 0.04)
            ctx.fill(Path(CGRect(x: 0, y: y, width: w, height: h * 0.012)), with: .color(rail))
        }
        for i in 0..<9 {
            ctx.fill(Path(CGRect(x: CGFloat(i) * w / 8 - 3, y: h * 0.63, width: 6, height: h * 0.16)), with: .color(rail))
        }
        let hides: [Color] = [Color(red: 0.2, green: 0.14, blue: 0.1), Color(red: 0.45, green: 0.26, blue: 0.14), Color(white: 0.12)]
        for k in 0..<3 {
            let x = w * (0.18 + CGFloat(k) * 0.24 + rng.next() * 0.05)
            let y = h * (0.54 + rng.next() * 0.05)
            let bw = w * 0.13, bh = h * 0.08
            let c = hides[k % hides.count]
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: bw, height: bh)), with: .color(c))
            ctx.fill(Path(ellipseIn: CGRect(x: x + bw * 0.85, y: y - bh * 0.25, width: bw * 0.32, height: bh * 0.55)), with: .color(c))
            for leg in 0..<4 {
                let lx = x + bw * (0.12 + CGFloat(leg) * 0.23)
                ctx.fill(Path(CGRect(x: lx, y: y + bh * 0.7, width: 3, height: bh * 0.7)), with: .color(c))
            }
        }
    }

    private func drawGrain(_ ctx: GraphicsContext, _ size: CGSize, _ rng: inout SeededRandom) {
        for _ in 0..<260 {
            let x = rng.next() * size.width
            let y = rng.next() * size.height
            ctx.fill(Path(CGRect(x: x, y: y, width: 1.2, height: 1.2)),
                     with: .color(.white.opacity(0.05 + rng.next() * 0.08)))
        }
    }
}

struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

    mutating func next() -> CGFloat {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return CGFloat(state % 10_000) / 10_000
    }
}
