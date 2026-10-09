import AlibiKit
import Foundation

// Developer tool: replays the last N hours of the unified log through the real
// pipeline into a throwaway database and prints what AppAlibi would record.
// Run after every macOS update to check that Apple's log formats still parse.
//
//   swift run alibi-probe [hours]

let hours = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 6
let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("alibi-probe-\(UUID().uuidString)")
    .appendingPathComponent("alibi.sqlite")
let store = try EventStore(url: url)
let since = Date().addingTimeInterval(-hours * 3600)

print("Replaying the last \(hours)h of the unified log…")
var processor = EventProcessor()
var lines = 0
var events: [CollectedEvent] = []
let started = Date()
for try await batch in LogReader.run(LogReader.showArguments(predicate: LogPredicates.combined, start: since)) {
    lines += batch.count
    for entry in batch { events += processor.process(entry) }
}
try store.record(events, lastProcessed: Date())

let sensorEvents = events.filter { if case .sensor = $0 { true } else { false } }.count
print("Parsed \(lines) log lines in \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(sensorEvents) sensor events, \(events.count - sensorEvents) permission checks.\n")

let duration = DateComponentsFormatter()
duration.allowedUnits = [.hour, .minute, .second]
duration.unitsStyle = .abbreviated
let time = DateFormatter()
time.dateFormat = "MM-dd HH:mm:ss"

print("Camera, microphone and screen sessions:")
let sensitive = try store.sessions(SessionQuery(sensors: Set(Sensor.known.filter(\.isSensitive)), limit: 25))
if sensitive.isEmpty { print("  none in this window") }
for session in sensitive {
    let length = session.isActive ? "active" : duration.string(from: session.duration()) ?? "?"
    print("  \(time.string(from: session.startedAt))  \(session.sensor.displayName.padding(toLength: 16, withPad: " ", startingAt: 0)) \(session.app)  (\(length))")
}

let location = try store.sessions(SessionQuery(sensors: [.location], limit: 100_000))
let locationApps = Dictionary(grouping: location, by: \.app).mapValues(\.count)
    .sorted { $0.value > $1.value }.map { "\($0.key) x\($0.value)" }.joined(separator: ", ")
print("\nLocation: \(location.count) sessions\(locationApps.isEmpty ? "" : " (\(locationApps))")")

print("\nPermission checks (non-Apple, including preflight):")
for row in try store.tccAggregates(TCCQuery(includePreflight: true, limit: 25)) {
    let kind = row.preflight ? "preflight" : "request"
    print("  \(row.serviceName.padding(toLength: 22, withPad: " ", startingAt: 0)) \(row.resultName.padding(toLength: 8, withPad: " ", startingAt: 0)) \(kind.padding(toLength: 10, withPad: " ", startingAt: 0)) x\(row.count)  \(row.app)")
}

try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
