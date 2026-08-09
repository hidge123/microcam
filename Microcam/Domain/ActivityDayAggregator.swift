import Foundation

enum ActivityDayAggregator {
    static func summarize(
        _ records: [ActivityIntervalRecord],
        calendar: Calendar = .autoupdatingCurrent,
        now: Date = Date()
    ) -> [ActivityDaySummary] {
        struct Accumulator {
            var startAt: Date
            var activeSeconds: TimeInterval = 0
            var segmentIDs = 0
            var applications: [String: (name: String, seconds: TimeInterval)] = [:]
        }

        var days: [String: Accumulator] = [:]

        for record in records where record.endAt > record.startAt {
            var cursor = record.startAt
            while cursor < record.endAt {
                guard let dayInterval = calendar.dateInterval(of: .day, for: cursor) else { break }
                let sliceEnd = min(record.endAt, dayInterval.end)
                let seconds = sliceEnd.timeIntervalSince(cursor)
                guard seconds > 0 else { break }

                let day = DateCoding.dayString(dayInterval.start, calendar: calendar)
                var accumulator = days[day] ?? Accumulator(startAt: dayInterval.start)
                accumulator.activeSeconds += seconds
                accumulator.segmentIDs += 1
                let app = accumulator.applications[record.bundleID]
                let displayName = record.appName.isEmpty ? (app?.name ?? record.bundleID) : record.appName
                accumulator.applications[record.bundleID] = (
                    displayName,
                    (app?.seconds ?? 0) + seconds
                )
                days[day] = accumulator
                cursor = sliceEnd
            }
        }

        let today = DateCoding.dayString(now, calendar: calendar)
        return days.compactMap { day, value in
            guard value.activeSeconds > 0 else { return nil }
            let applications = value.applications.map { bundleID, app in
                ApplicationUsageSummary(
                    bundleID: bundleID,
                    appName: app.name,
                    activeSeconds: app.seconds
                )
            }.sorted {
                if $0.activeSeconds == $1.activeSeconds {
                    return $0.appName.localizedStandardCompare($1.appName) == .orderedAscending
                }
                return $0.activeSeconds > $1.activeSeconds
            }
            return ActivityDaySummary(
                day: day,
                startAt: value.startAt,
                activeSeconds: value.activeSeconds,
                segmentCount: value.segmentIDs,
                applications: applications,
                isToday: day == today
            )
        }.sorted { $0.day > $1.day }
    }
}
