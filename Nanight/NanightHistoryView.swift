import SwiftUI

struct NanightHistoryView: View {
    @ObservedObject var model: NanightAppModel
    var compact = false
    var openHistory: () -> Void = {}
    @State private var days: [NanightHistoryDay] = []
    @State private var earliest: Date?
    @State private var selected: Date?
    @State private var loadedCamera: String?
    @State private var loading = false
    @State private var loadError: String?
    @Environment(\.colorScheme) private var scheme

    private var camera: String? { model.activeCamera?.uid }
    private var moon: Color { scheme == .dark ? Color(red: 0.93, green: 0.90, blue: 0.84) : Color(red: 0.28, green: 0.38, blue: 0.51) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    if compact { Text("Recent activity").font(.headline) }
                    if !compact { Text(model.activeCamera?.name ?? "Select a camera").foregroundStyle(.secondary) }
                }
                Spacer()
                if compact { Button("View all history", action: openHistory).buttonStyle(.link) }
            }
            HStack(spacing: 12) {
                HStack(spacing: 5) {
                    Capsule().fill(moon).frame(width: 2, height: 10)
                    Text("Motion")
                }
                HStack(spacing: 5) {
                    Circle().fill(moon).frame(width: 4, height: 4)
                    Text("Sound")
                }
                Text("Shaded = observed").foregroundStyle(.secondary)
            }.font(.caption2)
            if let error = model.historyError ?? loadError {
                Text(error).font(.caption).foregroundStyle(.red)
                Button("Retry") { Task { await refresh() } }
            }
            if camera == nil {
                Text("Sign in and select a camera to view its history.").foregroundStyle(.secondary)
            } else {
                axis
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(days) { day in
                            Button {
                                if compact {
                                    model.selectedHistoryDay = day.id
                                    openHistory()
                                } else {
                                    selected = selected == day.id ? nil : day.id
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(day.date, format: .dateTime.month(.abbreviated).day())
                                        Text(Calendar.current.isDateInToday(day.date) ? "Today" : day.date.formatted(.dateTime.weekday(.abbreviated)))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }.frame(width: 55, alignment: .leading)
                                    NanightDayTrack(day: day, moon: moon)
                                        .frame(height: compact ? 22 : 28)
                                    Text("\(day.events.filter { $0.kind == "MOTION" }.count)")
                                        .monospacedDigit().frame(width: 32, alignment: .trailing)
                                }
                                .font(.caption)
                                .padding(.vertical, 24)
                                .padding(.horizontal, 4)
                                .background(selected == day.id ? moon.opacity(0.10) : .clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(day.date.formatted(date: .complete, time: .omitted)), \(day.events.count) activity markers, \(Int(day.observedSeconds / 60)) minutes observed")
                            Divider().opacity(0.4)
                        }
                        if !compact, let oldest = days.last?.date, let earliest, oldest > Calendar.current.startOfDay(for: earliest) {
                            Button(loading ? "Loading…" : "Load older days") { Task { await loadOlder() } }
                                .disabled(loading).padding()
                                .onAppear { Task { await loadOlder() } }
                        }
                    }
                }
                if !compact, let day = days.first(where: { $0.id == selected }) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(day.date, format: .dateTime.month().day().year()).font(.headline)
                            Spacer()
                            Text("\(Int(day.observedSeconds / 60)) min observed").foregroundStyle(.secondary)
                        }
                        if day.events.isEmpty { Text("No activity markers recorded.").foregroundStyle(.secondary) }
                        ScrollView(showsIndicators: false) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 128), spacing: 8)], alignment: .leading, spacing: 8) {
                                ForEach(day.events) { event in
                                    HStack(spacing: 6) {
                                        Image(systemName: event.kind == "MOTION" ? "figure.walk" : "waveform")
                                            .foregroundStyle(moon)
                                        Text(event.timestamp, format: .dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute().locale(Locale(identifier: "en_US")))
                                            .monospacedDigit()
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(moon.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 0.5))
                                    .help(event.kind == "MOTION" ? "Motion" : "Sound")
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel("\(event.kind == "MOTION" ? "Motion" : "Sound"), \(event.timestamp.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute().locale(Locale(identifier: "en_US"))))")
                                }
                            }
                        }.frame(maxHeight: 130)
                    }.font(.caption).padding(.top, 8)
                }
                Text(compact ? (earliest == nil ? "History starts as activity arrives." : "Gaps = not observed · Quiet ≠ asleep") : (earliest == nil ? "History begins as Nanight receives activity. Nothing is deleted automatically." : "Gaps are unobserved time. Quiet does not necessarily mean asleep."))
                    .font(.caption2).foregroundStyle(.secondary)
                if !compact { Text("Stored on this Mac indefinitely. Times use your current time zone.").font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .padding(compact ? 14 : 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if !compact { selected = model.selectedHistoryDay } }
        .onChange(of: model.selectedHistoryDay) { day in if !compact { selected = day } }
        .task(id: "\(camera ?? "")-\(model.historyRevision)") { await refresh() }
    }

    private var axis: some View {
        HStack(spacing: 10) {
            Text("Day").frame(width: 59, alignment: .leading)
            HStack {
                Text("00:00")
                Spacer()
                Text("12:00")
                Spacer()
                Text("24:00")
            }
            Text("Motion").frame(width: 36, alignment: .trailing)
        }.font(.system(size: 10)).foregroundStyle(.secondary)
    }

    private func refresh() async {
        guard let camera else { days = []; earliest = nil; selected = nil; loadedCamera = nil; return }
        if loadedCamera != camera { days = []; selected = nil; loadedCamera = camera }
        do {
            let first = try await model.activityStore.earliestDate(camera: camera)
            let recent = try await model.activityStore.days(camera: camera, endingAt: Date(), count: compact ? 3 : 30)
            guard !Task.isCancelled, self.camera == camera else { return }
            earliest = first
            let older = first == nil ? [] : days.filter { $0.date < (recent.last?.date ?? .distantPast) }
            let minimum = Calendar.current.date(byAdding: .day, value: -2, to: Calendar.current.startOfDay(for: Date())) ?? Date()
            let lowerBound = min(minimum, first.map { Calendar.current.startOfDay(for: $0) } ?? minimum)
            days = (recent + older).filter { compact || $0.date >= lowerBound }
            loadError = nil
        } catch { if !Task.isCancelled { loadError = "Could not load history: \(error.localizedDescription)" } }
    }

    private func loadOlder() async {
        guard !loading, let camera, let oldest = days.last?.date,
              let end = Calendar.current.date(byAdding: .day, value: -1, to: oldest) else { return }
        loading = true
        defer { loading = false }
        do {
            let older = try await model.activityStore.days(camera: camera, endingAt: end, count: 30)
            guard !Task.isCancelled, self.camera == camera, days.last?.date == oldest else { return }
            days += older.filter { $0.date >= (earliest.map { Calendar.current.startOfDay(for: $0) } ?? .distantPast) }
            loadError = nil
        } catch { loadError = "Could not load older history: \(error.localizedDescription)" }
    }
}

private struct NanightDayTrack: View {
    let day: NanightHistoryDay
    let moon: Color
    @State private var hoverLocation: CGPoint?

    var body: some View {
        Canvas { context, size in
            let duration = day.end.timeIntervalSince(day.date)
            let x: (Date) -> CGFloat = { min(size.width, max(0, $0.timeIntervalSince(day.date) / duration * size.width)) }
            let availableWidth = x(min(Date(), day.end))
            let bounds = CGRect(x: 0, y: 0, width: availableWidth, height: size.height)
            context.fill(Path(bounds), with: .color(.secondary.opacity(0.06)))
            context.clip(to: Path(CGRect(origin: .zero, size: size)))
            // Hatching distinguishes unavailable observations from a quiet interval.
            for offset in stride(from: -size.height, to: availableWidth, by: 6) {
                var line = Path()
                line.move(to: CGPoint(x: offset, y: size.height))
                line.addLine(to: CGPoint(x: min(offset + size.height, availableWidth), y: max(0, offset + size.height - availableWidth)))
                context.stroke(line, with: .color(.secondary.opacity(0.17)), lineWidth: 1)
            }
            for interval in day.observations {
                let rect = CGRect(x: x(interval.start), y: 0, width: x(interval.end) - x(interval.start), height: size.height)
                context.fill(Path(rect), with: .color(Color(nsColor: .windowBackgroundColor)))
                context.fill(Path(rect), with: .color(moon.opacity(0.25)))
            }
            for event in day.events {
                let rect = CGRect(x: min(size.width - 2, x(event.timestamp)), y: event.kind == "MOTION" ? 3 : size.height / 2 - 2,
                                  width: event.kind == "MOTION" ? 2 : 4, height: event.kind == "MOTION" ? size.height - 6 : 4)
                context.fill(event.kind == "MOTION" ? Path(rect) : Path(ellipseIn: rect), with: .color(moon))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay {
            GeometryReader { geometry in
                if let hoverLocation, geometry.size.width > 0 {
                    let x = min(geometry.size.width, max(0, hoverLocation.x))
                    let timestamp = day.date.addingTimeInterval(
                        Double(x / geometry.size.width) * day.end.timeIntervalSince(day.date)
                    )
                    Rectangle()
                        .fill(moon)
                        .frame(width: 1, height: geometry.size.height)
                        .position(x: x, y: geometry.size.height / 2)
                    hoverLabel(timestamp.formatted(.dateTime.hour().minute().second()),
                               x: x, y: geometry.size.height + 12, width: geometry.size.width)
                    if let event = hoveredEvent(at: hoverLocation, size: geometry.size) {
                        hoverLabel("\(event.kind == "MOTION" ? "Motion" : "Sound") · \(event.timestamp.formatted(.dateTime.hour().minute().second()))",
                                   x: x, y: -12, width: geometry.size.width, labelWidth: 140)
                    }
                }
            }
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): hoverLocation = location
            case .ended: hoverLocation = nil
            }
        }
        .onDisappear { hoverLocation = nil }
        .accessibilityHidden(true)
    }

    private func hoverLabel(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, labelWidth: CGFloat = 88) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 5)
            .frame(width: min(width, labelWidth), height: 20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            .position(x: min(max(x, min(width, labelWidth) / 2), width - min(width, labelWidth) / 2), y: y)
    }

    private func hoveredEvent(at location: CGPoint, size: CGSize) -> NanightHistoryEvent? {
        let duration = day.end.timeIntervalSince(day.date)
        return day.events.compactMap { event -> (event: NanightHistoryEvent, distance: CGFloat)? in
            let x = min(size.width - 2, max(0, event.timestamp.timeIntervalSince(day.date) / duration * size.width))
            let isMotion = event.kind == "MOTION"
            let rect = CGRect(x: x, y: isMotion ? 3 : size.height / 2 - 2,
                              width: isMotion ? 2 : 4, height: isMotion ? size.height - 6 : 4)
            guard rect.insetBy(dx: -3, dy: -2).contains(location) else { return nil }
            return (event, hypot(location.x - rect.midX, location.y - rect.midY))
        }.min { $0.distance < $1.distance }?.event
    }
}
