import Foundation

/// A one-week roll-up shown at the top of Settings > Unlock Attempts.
///
/// Built from the raw log, so the view stays a thin reader: it keeps only the
/// last 7 days and counts what happened, plus one short tip saying what to
/// change when a pattern is clear enough to act on.
struct UnlockAttemptSummary {

	private static let week: TimeInterval = 7 * 24 * 60 * 60

	let total: Int
	let gazeUnlocked: Int
	let openedAnotherWay: Int
	let leftLocked: Int
	/// Median seconds from wake/lock to unlock across Gaze unlocks. Nil when none.
	let medianGazeDuration: TimeInterval?
	let tip: String?

	init(attempts: [UnlockAttempt], now: Date) {
		let cutoff = now.addingTimeInterval(-Self.week)
		let week = attempts.filter { $0.date >= cutoff && $0.date <= now }
		total = week.count
		gazeUnlocked = week.filter { $0.result == .unlocked }.count
		openedAnotherWay = week.filter {
			$0.result == .openedAnotherWay || $0.result == .closedWithoutUnlocking
		}.count
		leftLocked = week.filter { $0.result == .leftLocked }.count
		let durations = week.compactMap { $0.result == .unlocked ? $0.duration : nil }.sorted()
		if durations.isEmpty {
			medianGazeDuration = nil
		} else if durations.count.isMultiple(of: 2) {
			let mid = durations.count / 2
			medianGazeDuration = (durations[mid - 1] + durations[mid]) / 2
		} else {
			medianGazeDuration = durations[durations.count / 2]
		}
		tip = Self.tip(week: week, total: week.count, gazeUnlocked: gazeUnlocked)
	}

	/// First match wins, and only with enough attempts to mean something.
	private static func tip(week: [UnlockAttempt], total: Int, gazeUnlocked: Int) -> String? {
		guard total >= 5 else { return nil }
		let misses = week.filter { $0.result != .unlocked }
		guard !misses.isEmpty else { return nil }
		if misses.filter({ $0.reason == .tooDark }).count * 2 > misses.count {
			return "Most misses were in low light. Turn on Light up the screen when it’s dark."
		}
		let someoneElse = misses.filter {
			$0.reason == .differentPerson || $0.reason == .photoOrScreen
				|| $0.result == .unknownFace || $0.result == .spoofRejected
		}.count
		if someoneElse * 2 > misses.count {
			return "Most misses were someone else or a photo. Gaze blocked them as it should."
		}
		if gazeUnlocked * 2 < total,
			misses.mostCommon(\.result) == .notRecognised {
			return "Gaze often didn’t recognise you. Try adding your face again in better light."
		}
		return nil
	}
}

private extension Array where Element == UnlockAttempt {
	/// The value that shows up most often for the given key path, if any.
	func mostCommon<T: Hashable>(_ key: KeyPath<UnlockAttempt, T>) -> T? {
		var counts: [T: Int] = [:]
		for attempt in self { counts[attempt[keyPath: key], default: 0] += 1 }
		return counts.max(by: { $0.value < $1.value })?.key
	}
}
