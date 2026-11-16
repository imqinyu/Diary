import MapKit
import SwiftUI

/// 把当前筛选结果里有坐标的条目撒到地图上，点一下就能跳回那天。
struct DiaryMapView: View {
    let entries: [DiaryEntry]

    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var position: MapCameraPosition = .automatic

    private struct Pin: Identifiable {
        let id: String
        let title: String
        let dayKey: String
        let mood: Mood?
        let coordinate: CLLocationCoordinate2D
    }

    private var pins: [Pin] {
        entries.compactMap { entry in
            guard let location = entry.location,
                  let latitude = location.latitude,
                  let longitude = location.longitude else { return nil }
            return Pin(
                id: entry.id,
                title: store.displayTitle(for: entry),
                dayKey: entry.dayKey,
                mood: entry.mood,
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            )
        }
    }

    var body: some View {
        Group {
            if pins.isEmpty {
                ContentUnavailableView(
                    "地图上还没有点",
                    systemImage: "map",
                    description: Text("在日记里记录位置后，那一天就会出现在这里。")
                )
            } else {
                Map(position: $position) {
                    ForEach(pins) { pin in
                        Annotation(pin.title, coordinate: pin.coordinate) {
                            Button {
                                store.requestedEntryID = pin.id
                                dismiss()
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(pin.mood?.tint ?? Color.accentColor)
                                        .frame(width: 24, height: 24)
                                        .shadow(radius: 2, y: 1)
                                    Image(systemName: pin.mood?.symbolName ?? "book.fill")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(pin.title)
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                Text("地图")
                    .font(.headline)
                Text(verbatim: "\(pins.count) 个地点")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .frame(minWidth: 660, minHeight: 480)
        .onAppear { fitCamera() }
        .onChange(of: pins.count) { _, _ in fitCamera() }
    }

    private func fitCamera() {
        let coordinates = pins.map(\.coordinate)
        guard let first = coordinates.first else { return }

        var minLatitude = first.latitude, maxLatitude = first.latitude
        var minLongitude = first.longitude, maxLongitude = first.longitude
        for coordinate in coordinates {
            minLatitude = min(minLatitude, coordinate.latitude)
            maxLatitude = max(maxLatitude, coordinate.latitude)
            minLongitude = min(minLongitude, coordinate.longitude)
            maxLongitude = max(maxLongitude, coordinate.longitude)
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLatitude + maxLatitude) / 2,
            longitude: (minLongitude + maxLongitude) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLatitude - minLatitude) * 1.4, 0.02),
            longitudeDelta: max((maxLongitude - minLongitude) * 1.4, 0.02)
        )
        position = .region(MKCoordinateRegion(center: center, span: span))
    }
}
