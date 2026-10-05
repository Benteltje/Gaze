import Foundation

struct UnlockChallengeGate {
	static let defaultRequiredActions = 2
	static let presentationDelay = Duration.milliseconds(350)
	static let responseTimeout = Duration.seconds(8)
	/// How long a presented movement may go without a verified face before it is
	/// withdrawn. A nod tips the face away from the camera, and for a few frames it can
	/// score low, blur or drop out of detection; that is the movement, not a new attempt.
	static let interruptionGrace = Duration.milliseconds(800)

	let requiredActions: Int
	private(set) var completedActions = 0
	private var presentedAt: ContinuousClock.Instant?
	private var presentationFrame: UInt64?
	private var lastFrame: UInt64?
	private var lastCapture: ContinuousClock.Instant?
	private var interruptedAt: ContinuousClock.Instant?

	init(requiredActions: Int = Self.defaultRequiredActions) {
		if requiredActions == 0 || requiredActions == 1 || requiredActions == 2 {
			self.requiredActions = requiredActions
		} else {
			self.requiredActions = Self.defaultRequiredActions
		}
	}

	var isPresented: Bool { presentedAt != nil }
	/// Zero required actions is already satisfied: no prompt is ever presented.
	var isVerified: Bool { completedActions == requiredActions }

	@discardableResult
	mutating func reset() -> Bool {
		let hadGuidance = isPresented || completedActions > 0
		let count = requiredActions
		self = Self(requiredActions: count)
		return hadGuidance
	}

	mutating func present(at now: ContinuousClock.Instant, frameID: UInt64) {
		guard !isPresented, !isVerified else { return }
		presentedAt = now
		presentationFrame = frameID
		lastFrame = frameID
		lastCapture = nil
		interruptedAt = nil
	}

	/// Whether the presented movement may ride out a frame with no verified face. The
	/// first such frame starts the grace; it holds until `resume()`, and anything past
	/// `interruptionGrace` is false, so the caller withdraws the prompt as before.
	/// Tolerating a frame admits no evidence: the caller still checks every frame it
	/// feeds to the challenge, and completion still needs a verified one.
	mutating func tolerates(interruptionAt now: ContinuousClock.Instant) -> Bool {
		guard isPresented, !isVerified, !expired(at: now) else { return false }
		let since = interruptedAt ?? now
		interruptedAt = since
		return now >= since && since.duration(to: now) < Self.interruptionGrace
	}

	/// A verified face is back; the next interruption gets a fresh grace.
	mutating func resume() {
		interruptedAt = nil
	}

	func expired(at now: ContinuousClock.Instant) -> Bool {
		guard let presentedAt else { return false }
		return now < presentedAt || presentedAt.duration(to: now) >= Self.responseTimeout
	}

	mutating func admits(frameID: UInt64, capturedAt: ContinuousClock.Instant,
		now: ContinuousClock.Instant) -> Bool {
		guard !isVerified, let presentedAt, !expired(at: now),
			capturedAt <= now,
			capturedAt.duration(to: now) <= CameraFrameLease.maximumAge,
			presentedAt.duration(to: capturedAt) >= Self.presentationDelay,
			frameID != presentationFrame, frameID != lastFrame,
			lastCapture.map({ capturedAt > $0 }) ?? true else { return false }
		lastFrame = frameID
		lastCapture = capturedAt
		return true
	}

	mutating func completeAction() {
		guard isPresented, lastCapture != nil, !isVerified else { return }
		completedActions += 1
		presentedAt = nil
		presentationFrame = nil
		lastFrame = nil
		lastCapture = nil
		interruptedAt = nil
	}
}
