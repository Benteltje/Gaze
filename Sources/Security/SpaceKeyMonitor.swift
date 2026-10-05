// Adapted from Glance by Jonathan Zhou, MIT licence, https://github.com/jonnyoo/glance

import Foundation
import IOKit
import IOKit.hid
import os

/// Notices the spacebar on the lock screen, so pressing Space looks again.
///
/// Raw IOKit HID reads: Secure Event Input swallows every other keyboard tap there.
/// Only runs while the screen is locked — LockWatcher starts it with the lock and stops
/// it with the unlock. No key logging: the callback only asks whether the key is Space,
/// and a missing grant fails closed to a no-op rather than prompting.
@MainActor
final class SpaceKeyMonitor {
	private static let logger = Logger(subsystem: "com.gazeunlock.Gaze", category: "SpaceKeyMonitor")

	/// Spacebar key-down: usage page 0x07, usage 0x2C.
	private static let spaceUsagePage: UInt32 = 0x07
	private static let spaceUsage: UInt32 = 0x2C

	/// Fires on spacebar key-down only, not release.
	var onSpaceKeyDown: (() -> Void)?

	private var manager: IOHIDManager?

	/// Key presses other than Space seen while listening. Counted, never recorded:
	/// only the total, so LockWatcher can tell typing from pressing Space exactly.
	private(set) var otherKeyDowns = 0
	/// Every key-down this listener heard during one lock, Space included. Logged
	/// as a count when it stops, so a silent listener shows up in the log.
	private var keyDownsSeen = 0

	/// True between a successful `start()` and `stop()`.
	var isListening: Bool { manager != nil }

	/// Input Monitoring, which IOKit needs to see keys on the lock screen.
	nonisolated static var isAllowed: Bool {
		IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
	}

	/// Asks once with macOS's prompt; called from Settings, never the lock screen.
	/// Returns whether access is granted now.
	@discardableResult
	nonisolated static func requestAccess() -> Bool {
		IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
	}

	/// Idempotent. Fails closed when Input Monitoring isn't granted — never prompts.
	func start() {
		guard manager == nil else { return }
		guard Self.isAllowed else {
			Self.logger.notice("Input Monitoring is off; Space won't retry the scan.")
			return
		}

		let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
		// Physical keyboards only (Generic Desktop page, Keyboard usage), not every HID device.
		let match: [String: Int] = [
			kIOHIDDeviceUsagePageKey: 0x01,
			kIOHIDDeviceUsageKey: 0x06,
		]
		IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

		// Capture-less C callback; self rides the context pointer. passUnretained is safe:
		// LockWatcher owns this and always stops (unregistering) before it can go away.
		let context = Unmanaged.passUnretained(self).toOpaque()
		IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
			guard let context else { return }
			let element = IOHIDValueGetElement(value)
			guard IOHIDElementGetUsagePage(element) == SpaceKeyMonitor.spaceUsagePage,
				IOHIDValueGetIntegerValue(value) == 1
			else { return }
			let usage = IOHIDElementGetUsage(element)
			let monitor = Unmanaged<SpaceKeyMonitor>.fromOpaque(context).takeUnretainedValue()
			// Below 0x04 are rollover/error codes, not keys.
			MainActor.assumeIsolated { monitor.keyDownsSeen += 1 }
			guard usage == SpaceKeyMonitor.spaceUsage else {
				// Letters, digits and symbols only. Modifiers (0xE0...0xE7) are not
				// typing: a Shift or Command tap stopped the scan as if it were.
				if (0x04...0xDF).contains(usage) {
					MainActor.assumeIsolated { monitor.otherKeyDowns += 1 }
				}
				return
			}
			Logger(subsystem: "com.gazeunlock.Gaze", category: "SpaceKeyMonitor").notice("Space pressed.")
			MainActor.assumeIsolated { monitor.onSpaceKeyDown?() }
		}, context)

		IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
		guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
			Self.logger.error("Space monitor failed to open; Space won't retry the scan.")
			IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
			return
		}
		Self.logger.notice("Listening for Space on the lock screen.")
		self.manager = manager
	}

	/// Idempotent.
	func stop() {
		guard let manager else { return }
		Self.logger.notice("Space monitor stopping; heard \(self.keyDownsSeen) key press(es) this lock.")
		keyDownsSeen = 0
		otherKeyDowns = 0
		IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
		IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
		self.manager = nil
	}
}
