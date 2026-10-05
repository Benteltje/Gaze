import Foundation

/// Dropped after idleness so Gaze doesn't pin Core ML weights forever.
protocol IdleUnloadable: AnyObject {
	func unloadIfIdle(for interval: TimeInterval)
}

/// One reloadable model. Two locks: `lock` guards only the stored reference and is
/// never held for more than a pointer swap, so `ifLoaded` on the main thread can
/// never wait behind a load; `loadLock` serialises loads, which can take seconds
/// while Core ML compiles for the Neural Engine. Predictions run unlocked against
/// a local strong reference.
final class ModelSlot<Model>: IdleUnloadable, @unchecked Sendable {
	private let lock = NSLock()
	private let loadLock = NSLock()
	private let load: () -> Model?
	private var value: Model?
	private var lastUse = Date()

	init(load: @escaping () -> Model?, initial: Model? = nil) {
		self.load = load
		self.value = initial
		ModelResidency.register(self)
	}

	private func current(stamp: Bool) -> Model? {
		lock.withLock {
			if stamp, value != nil { lastUse = Date() }
			return value
		}
	}

	/// The loaded model, loading it first if needed. Off the main thread only.
	private func loaded() -> Model? {
		if let model = current(stamp: true) { return model }
		return loadLock.withLock {
			// Someone else may have finished loading while this caller waited.
			if let model = current(stamp: true) { return model }
			guard let model = load() else { return nil }
			lock.withLock {
				value = model
				lastUse = Date()
			}
			return model
		}
	}

	/// Loads when needed, stamps use, runs the body unlocked. Nil when loading fails.
	func withModel<R>(_ body: (Model) throws -> R) rethrows -> R? {
		guard let model = loaded() else { return nil }
		return try body(model)
	}

	/// Runs the body only if the model is already loaded; never loads and never waits
	/// for a load. For callers on the main thread.
	func ifLoaded<R>(_ body: (Model) throws -> R) rethrows -> R? {
		guard let model = current(stamp: true) else { return nil }
		return try body(model)
	}

	/// Loads when unloaded (lock-screen path calls this at lock and wake).
	func preload() {
		_ = loaded()
	}

	func unloadIfIdle(for interval: TimeInterval) {
		lock.withLock {
			if Date().timeIntervalSince(lastUse) >= interval { value = nil }
		}
	}
}

/// One background sweep unloads every registered slot idle past the limit.
enum ModelResidency {
	/// 30 minutes. Shorter reloaded the models on nearly every lock, and each reload
	/// can make Core ML rebuild them for the Neural Engine and write to disk; longer
	/// kept about 80 MB of weights in memory for hours of not locking.
	static let idleLimit: TimeInterval = 30 * 60

	private static let lock = NSLock()
	private static var slots: [any IdleUnloadable] = []
	private static var timer: DispatchSourceTimer?

	static func register(_ slot: AnyObject & IdleUnloadable) {
		lock.withLock {
			slots.append(slot)
			guard timer == nil else { return }
			let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
			t.schedule(deadline: .now() + 300, repeating: 300)
			t.setEventHandler { reap() }
			t.resume()
			timer = t
		}
	}

	private static func reap() {
		let current = lock.withLock { slots }
		for slot in current { slot.unloadIfIdle(for: idleLimit) }
	}
}
