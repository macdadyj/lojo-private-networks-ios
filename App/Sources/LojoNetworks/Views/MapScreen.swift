import MapKit
import SwiftUI

struct MapCluster: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let devices: [Device]

    var anyOnline: Bool { devices.contains(where: \.online) }
    var approximate: Bool { devices.allSatisfy { $0.location?.isApproximate ?? false } }
    var title: String { devices.count == 1 ? devices[0].displayName : "\(devices.count) devices" }
}

struct MapScreen: View {
    @EnvironmentObject private var store: NetworkStore
    @State private var position: MapCameraPosition = .automatic
    @State private var selected: String?

    private var located: [Device] { store.devices.filter { $0.location != nil } }
    private var unlocated: [Device] { store.devices.filter { $0.location == nil } }

    /// Devices reporting the same point (e.g. approximate positions) share one pin.
    private var clusters: [MapCluster] {
        let groups = Dictionary(grouping: located) { d -> String in
            guard let l = d.location else { return "" }
            return String(format: "%.4f,%.4f", l.lat, l.lon)
        }
        return groups.keys.sorted().compactMap { key in
            guard let list = groups[key], let loc = list.first?.location else { return nil }
            return MapCluster(
                id: key,
                coordinate: CLLocationCoordinate2D(latitude: loc.lat, longitude: loc.lon),
                devices: list.sorted { $0.displayName < $1.displayName }
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if clusters.isEmpty {
                emptyMap
            } else if store.isDemo {
                DemoSiteMap(clusters: clusters, selected: $selected)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .bottom) { selectionCard }
            } else {
                map
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .bottom) { selectionCard }
            }
            if !unlocated.isEmpty || !clusters.isEmpty {
                footer
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.isDemo {
                ToolbarItem(placement: .topBarLeading) { DemoBadge() }
            }
            if !clusters.isEmpty && !store.isDemo {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation { position = .automatic }
                    } label: {
                        Image(systemName: "scope")
                    }
                    .accessibilityLabel("Fit all devices")
                }
            }
        }
    }

    private var map: some View {
        Map(position: $position) {
            ForEach(clusters) { cluster in
                Annotation(cluster.title, coordinate: cluster.coordinate, anchor: .bottom) {
                    ClusterPin(cluster: cluster, isSelected: selected == cluster.id)
                        .onTapGesture {
                            Haptics.selection()
                            withAnimation(.spring(duration: 0.3)) {
                                selected = selected == cluster.id ? nil : cluster.id
                            }
                        }
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
    }

    @ViewBuilder
    private var selectionCard: some View {
        if let id = selected, let cluster = clusters.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(cluster.devices.count == 1 ? "Device here" : "\(cluster.devices.count) devices here")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    Button {
                        withAnimation { selected = nil }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .accessibilityLabel("Close")
                }
                ForEach(cluster.devices) { device in
                    NavigationLink(value: device.key) {
                        HStack(spacing: 12) {
                            DeviceIcon(kind: device.kind, online: device.online, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.displayName).font(.subheadline.weight(.semibold))
                                Text(device.online ? "Online · \(device.siteName)" : "Offline · \(device.siteName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if cluster.approximate {
                    Label("Approximate position from the device's internet address.", systemImage: "location.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                legend(color: LojoTheme.online, filled: true, text: "Online")
                legend(color: .secondary, filled: false, text: "Offline")
                Spacer()
                Text("\(located.count) of \(store.devices.count) on map")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !unlocated.isEmpty {
                Text("No location reported: " + unlocated.map(\.displayName).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func legend(color: Color, filled: Bool, text: String) -> some View {
        HStack(spacing: 5) {
            StatusDot(style: filled ? .online : .offline, size: 8)
            Text(text).font(.caption)
        }
        .accessibilityElement(children: .combine)
    }

    private var emptyMap: some View {
        ContentUnavailableView {
            Label("No locations yet", systemImage: "map")
        } description: {
            Text(store.devices.isEmpty
                 ? "Devices that report a position will appear on the map once your network is reachable."
                 : "None of your devices has reported a position. Devices with GPS or a set location show up here.")
        }
        .frame(maxHeight: .infinity)
    }
}

struct ClusterPin: View {
    let cluster: MapCluster
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(cluster.anyOnline ? AnyShapeStyle(LojoTheme.brandGradient) : AnyShapeStyle(Color.gray))
                    .frame(width: isSelected ? 46 : 38, height: isSelected ? 46 : 38)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                if cluster.devices.count > 1 {
                    Text("\(cluster.devices.count)")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: cluster.devices[0].kind.systemImage)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            Image(systemName: "triangle.fill")
                .font(.system(size: 9))
                .rotationEffect(.degrees(180))
                .foregroundStyle(.white)
                .offset(y: -3)
        }
        .animation(.spring(duration: 0.25), value: isSelected)
        .accessibilityElement()
        .accessibilityLabel("\(cluster.title), \(cluster.anyOnline ? "online" : "offline")")
        .accessibilityAddTraits(.isButton)
    }
}
