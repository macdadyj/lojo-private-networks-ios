import SwiftUI

/// Drawn site plan for the demo network. The demo ranch is fictional, so it gets fictional
/// ground instead of real map tiles (which would show real roads and neighbours).
struct DemoSiteMap: View {
    let clusters: [MapCluster]
    @Binding var selected: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size).insetBy(dx: 80, dy: 80)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in draw(in: &ctx, size: size) }
                ForEach(clusters) { cluster in
                    ClusterPin(cluster: cluster, isSelected: selected == cluster.id)
                        .onTapGesture {
                            Haptics.selection()
                            withAnimation(.spring(duration: 0.3)) {
                                selected = selected == cluster.id ? nil : cluster.id
                            }
                        }
                        .position(project(cluster, into: rect))
                        .offset(y: -22)
                    Text(cluster.title)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                        .position(project(cluster, into: rect))
                        .offset(y: 14)
                        .accessibilityHidden(true)
                }
            }
        }
        .background(ground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Demo site plan")
    }

    private var ground: Color {
        scheme == .dark ? Color(red: 0.13, green: 0.17, blue: 0.13) : Color(red: 0.90, green: 0.92, blue: 0.84)
    }

    private func project(_ c: MapCluster, into rect: CGRect) -> CGPoint {
        let lats = clusters.map(\.coordinate.latitude)
        let lons = clusters.map(\.coordinate.longitude)
        let (minLat, maxLat) = (lats.min() ?? 0, lats.max() ?? 1)
        let (minLon, maxLon) = (lons.min() ?? 0, lons.max() ?? 1)
        let x = (c.coordinate.longitude - minLon) / max(maxLon - minLon, 1e-6)
        let y = (maxLat - c.coordinate.latitude) / max(maxLat - minLat, 1e-6)
        return CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        let dark = scheme == .dark
        let field = dark ? Color(red: 0.17, green: 0.23, blue: 0.16) : Color(red: 0.82, green: 0.87, blue: 0.72)
        let fieldAlt = dark ? Color(red: 0.20, green: 0.21, blue: 0.14) : Color(red: 0.88, green: 0.85, blue: 0.70)
        let fence = dark ? Color.white.opacity(0.18) : Color.black.opacity(0.18)
        let track = dark ? Color(red: 0.42, green: 0.36, blue: 0.27) : Color(red: 0.76, green: 0.66, blue: 0.50)
        let water = dark ? Color(red: 0.20, green: 0.38, blue: 0.52) : Color(red: 0.55, green: 0.74, blue: 0.86)
        let label = dark ? Color.white.opacity(0.45) : Color.black.opacity(0.40)

        let paddocks: [(CGRect, Color, String)] = [
            (CGRect(x: 0.04 * w, y: 0.05 * h, width: 0.50 * w, height: 0.34 * h), field, "NORTH PASTURE"),
            (CGRect(x: 0.58 * w, y: 0.05 * h, width: 0.38 * w, height: 0.26 * h), fieldAlt, "HEADQUARTERS"),
            (CGRect(x: 0.04 * w, y: 0.43 * h, width: 0.42 * w, height: 0.30 * h), fieldAlt, "EAST PASTURE"),
            (CGRect(x: 0.50 * w, y: 0.35 * h, width: 0.46 * w, height: 0.38 * h), field, "HAY FIELD"),
            (CGRect(x: 0.04 * w, y: 0.77 * h, width: 0.92 * w, height: 0.19 * h), field, "SOUTH SECTION"),
        ]
        for (r, color, name) in paddocks {
            let path = Path(roundedRect: r, cornerRadius: 10)
            ctx.fill(path, with: .color(color))
            ctx.stroke(path, with: .color(fence), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            ctx.draw(Text(name).font(.system(size: 10, weight: .bold)).foregroundStyle(label),
                     at: CGPoint(x: r.minX + 10, y: r.minY + 12), anchor: .leading)
        }

        var creek = Path()
        creek.move(to: CGPoint(x: 0.70 * w, y: -10))
        creek.addCurve(to: CGPoint(x: 0.30 * w, y: h + 10),
                       control1: CGPoint(x: 0.95 * w, y: 0.45 * h),
                       control2: CGPoint(x: 0.05 * w, y: 0.55 * h))
        ctx.stroke(creek, with: .color(water), style: StrokeStyle(lineWidth: 7, lineCap: .round))

        var lane = Path()
        lane.move(to: CGPoint(x: -10, y: 0.41 * h))
        lane.addLine(to: CGPoint(x: 0.56 * w, y: 0.41 * h))
        lane.addLine(to: CGPoint(x: 0.56 * w, y: 0.33 * h))
        lane.addLine(to: CGPoint(x: w + 10, y: 0.33 * h))
        lane.move(to: CGPoint(x: 0.48 * w, y: 0.41 * h))
        lane.addLine(to: CGPoint(x: 0.48 * w, y: 0.75 * h))
        lane.addLine(to: CGPoint(x: w + 10, y: 0.75 * h))
        ctx.stroke(lane, with: .color(track), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))

        ctx.draw(Text("Sample site plan — not a real place").font(.system(size: 10, weight: .medium)).foregroundStyle(label),
                 at: CGPoint(x: w - 10, y: h - 10), anchor: .bottomTrailing)
    }
}
