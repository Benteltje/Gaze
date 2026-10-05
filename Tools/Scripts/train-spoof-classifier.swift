// Trains the face-crop live/spoof classifier that `SpoofDetector` runs, and measures it
// against the bundled model on held-out data before anyone ships it.
//
// Inputs (either or both):
//   --frames <dir>    whole frames as <split>/<live|spoof>/*.jpg, split = train|valid|test.
//                     Faces are found with Vision and cropped the way the app crops them.
//                     Keep the splits grouped by person or session, never by random frame.
//   --sessions <dir>  DatasetCapture output (~/Documents/GazeDataset): one folder per
//                     session, already context crops, label in session.json. Held out by
//                     whole session: the last 20% of sessions per label (at least one).
//
// Output: the model (--out), a metrics JSON (--metrics), crops under --work.
// Labels are "0" live and "1" spoof, matching `SpoofDetector.spoofLabel`.
//
// Run:
//   DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
//     xcrun swift Tools/Scripts/train-spoof-classifier.swift \
//       --sessions ~/Documents/GazeDataset --work /tmp/spoof-work \
//       --out outputs/spoof-models/Spoof-classifier.mlmodel \
//       --metrics outputs/spoof-models/metrics.json --old Resources/Spoof.mlmodel

import CoreImage
import CoreML
import CreateML
import Foundation
import ImageIO
import Vision

// Same as `Liveness.cropMargin` and the side `DatasetCapture` writes.
let margin: CGFloat = 2.7
let side = 256

var options: [String: String] = [:]
var argv = CommandLine.arguments.dropFirst()
while let key = argv.popFirst() {
	guard key.hasPrefix("--"), let value = argv.popFirst() else {
		FileHandle.standardError.write(Data("bad argument \(key)\n".utf8))
		exit(2)
	}
	options[String(key.dropFirst(2))] = (value as NSString).expandingTildeInPath
}
guard options["frames"] != nil || options["sessions"] != nil, let work = options["work"] else {
	FileHandle.standardError.write(Data("usage: --frames <dir> and/or --sessions <dir>, --work <dir> [--out m.mlmodel] [--metrics m.json] [--old Spoof.mlmodel]\n".utf8))
	exit(2)
}
let fm = FileManager.default
let workURL = URL(fileURLWithPath: work, isDirectory: true)
let outURL = URL(fileURLWithPath: options["out"] ?? "Spoof-classifier.mlmodel")
let metricsURL = URL(fileURLWithPath: options["metrics"] ?? "spoof-metrics.json")
let ciContext = CIContext()

struct Item {
	let crop: URL
	/// Whole frame, when the item came from one: the shipped detector reads full frames.
	let frame: URL?
	let spoof: Bool
	let group: String
}

func images(in dir: URL) -> [URL] {
	((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
		.filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
		.sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// `FaceAligner.contextWindow`: square, face size times margin, slid back inside the frame.
func contextCrop(_ url: URL) -> CGImage? {
	guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
	let extent = image.extent
	let request = VNDetectFaceRectanglesRequest()
	try? VNImageRequestHandler(ciImage: image, options: [:]).perform([request])
	guard let face = (request.results ?? []).max(by: {
		$0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
	}) else { return nil }
	let box = face.boundingBox
	let rect = CGRect(
		x: box.minX * extent.width + extent.minX, y: box.minY * extent.height + extent.minY,
		width: box.width * extent.width, height: box.height * extent.height)
	guard rect.width > 1, rect.height > 1 else { return nil }
	let wanted = min(max(rect.width, rect.height) * margin, min(extent.width, extent.height))
	var crop = CGRect(x: rect.midX - wanted / 2, y: rect.midY - wanted / 2, width: wanted, height: wanted)
	crop.origin.x = min(max(crop.minX, extent.minX), extent.maxX - crop.width)
	crop.origin.y = min(max(crop.minY, extent.minY), extent.maxY - crop.height)
	crop = crop.intersection(extent)
	guard crop.width > 1, crop.height > 1 else { return nil }
	let scale = CGFloat(side) / crop.width
	let rendered = image.cropped(to: crop)
		.transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
		.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
	return ciContext.createCGImage(rendered, from: CGRect(x: 0, y: 0, width: side, height: side))
}

func writeJPEG(_ image: CGImage, to url: URL) {
	guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
	CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
	CGImageDestinationFinalize(dest)
}

/// Split -> items, with crops copied or rendered into work/<split>/<0|1>/.
var splits: [String: [Item]] = ["train": [], "valid": [], "test": []]
var skipped = 0

func place(_ crop: URL, split: String, spoof: Bool, name: String) -> URL {
	let dir = workURL.appending(path: "\(split)/\(spoof ? "1" : "0")", directoryHint: .isDirectory)
	try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
	return dir.appending(path: name)
}

if let frames = options["frames"] {
	let base = URL(fileURLWithPath: frames, isDirectory: true)
	for split in ["train", "valid", "test"] {
		for (folder, spoof) in [("live", false), ("spoof", true)] {
			let source = images(in: base.appending(path: "\(split)/\(folder)"))
			print("→ cropping \(source.count) \(split)/\(folder) frames")
			for url in source {
				let dest = place(url, split: split, spoof: spoof, name: "f-" + url.deletingPathExtension().lastPathComponent + ".jpg")
				if !fm.fileExists(atPath: dest.path) {
					guard let crop = contextCrop(url) else { skipped += 1; continue }
					writeJPEG(crop, to: dest)
				}
				splits[split]!.append(Item(crop: dest, frame: url, spoof: spoof, group: "frames"))
			}
		}
	}
}

if let sessions = options["sessions"] {
	let base = URL(fileURLWithPath: sessions, isDirectory: true)
	let dirs = ((try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [])
		.filter { fm.fileExists(atPath: $0.appending(path: "session.json").path) }
		.sorted { $0.lastPathComponent < $1.lastPathComponent }
	var byLabel: [Bool: [URL]] = [:]
	for dir in dirs {
		guard let data = try? Data(contentsOf: dir.appending(path: "session.json")),
			let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let label = json["label"] as? String else { continue }
		byLabel[label != "live", default: []].append(dir)
	}
	for (spoof, list) in byLabel {
		let held = list.count < 2 ? 0 : max(1, Int((Double(list.count) * 0.2).rounded()))
		for (index, dir) in list.enumerated() {
			let split = index >= list.count - held ? "test" : "train"
			for url in images(in: dir) {
				let dest = place(url, split: split, spoof: spoof, name: "s-\(dir.lastPathComponent)-\(url.lastPathComponent)")
				if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: url, to: dest) }
				splits[split]!.append(Item(crop: dest, frame: nil, spoof: spoof, group: dir.lastPathComponent))
			}
		}
	}
}

for (split, items) in splits.sorted(by: { $0.key < $1.key }) {
	print("  \(split): \(items.filter { !$0.spoof }.count) live, \(items.filter(\.spoof).count) spoof")
}
print("  no face found in \(skipped) frames (skipped)")
guard splits["train"]!.contains(where: \.spoof), splits["train"]!.contains(where: { !$0.spoof }),
	!splits["test"]!.isEmpty else {
	FileHandle.standardError.write(Data("not enough data: need both classes in train and a test split\n".utf8))
	exit(1)
}

print("→ training")
let validDir = workURL.appending(path: "valid")
let hasValid = !splits["valid"]!.isEmpty
// Flip, exposure and crop only: blur and noise erase the moiré and pixel-grid cues the
// classifier is meant to learn.
let parameters = MLImageClassifier.ModelParameters(
	validation: hasValid ? .dataSource(.labeledDirectories(at: validDir)) : .split(strategy: .automatic),
	maxIterations: Int(ProcessInfo.processInfo.environment["SPOOF_ITERS"] ?? "") ?? 50,
	augmentation: [.flip, .exposure, .crop],
	algorithm: .transferLearning(featureExtractor: .scenePrint(revision: 2), classifier: .logisticRegressor))
let classifier = try MLImageClassifier(
	trainingData: .labeledDirectories(at: workURL.appending(path: "train")), parameters: parameters)
try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try classifier.write(to: outURL, metadata: MLModelMetadata(
	author: "Gaze", shortDescription: "Face-crop live (0) / spoof (1) classifier.", version: "2.0"))
print("✓ wrote \(outURL.path)")

func vision(_ url: URL) throws -> VNCoreMLModel {
	let compiled = try MLModel.compileModel(at: url)
	return try VNCoreMLModel(for: MLModel(contentsOf: compiled))
}

/// Exactly what `SpoofDetector` returns: class "1" confidence for a classifier, the best
/// "1" detection for the old object detector. nil when the model gives nothing usable.
func score(_ model: VNCoreMLModel, _ url: URL) -> Float? {
	let request = VNCoreMLRequest(model: model)
	request.imageCropAndScaleOption = .scaleFill
	guard (try? VNImageRequestHandler(url: url, options: [:]).perform([request])) != nil else { return nil }
	if let classes = request.results as? [VNClassificationObservation] {
		return classes.first(where: { $0.identifier == "1" })?.confidence
	}
	if let objects = request.results as? [VNRecognizedObjectObservation] {
		return objects.compactMap { $0.labels.first }.filter { $0.identifier == "1" }.map(\.confidence).max() ?? 0
	}
	return nil
}

struct Rates: Codable {
	let threshold: Float
	let accuracy: Double
	let spoofRecall: Double
	let liveFalseReject: Double
}

func rates(_ scores: [(Float, Bool)], _ t: Float) -> Rates {
	let live = scores.filter { !$0.1 }, spoof = scores.filter(\.1)
	let caught = spoof.filter { $0.0 >= t }.count, rejected = live.filter { $0.0 >= t }.count
	return Rates(
		threshold: t,
		accuracy: Double(caught + live.count - rejected) / Double(max(scores.count, 1)),
		spoofRecall: Double(caught) / Double(max(spoof.count, 1)),
		liveFalseReject: Double(rejected) / Double(max(live.count, 1)))
}

struct Report: Codable {
	let model: String
	let input: String
	let live: Int
	let spoof: Int
	let unscored: Int
	let sweep: [Rates]
}

let thresholds: [Float] = stride(from: 0.05, through: 0.951, by: 0.05).map { Float($0) }

func report(_ name: String, _ model: VNCoreMLModel, _ items: [Item], input: String, url: (Item) -> URL) -> Report {
	var scored: [(Float, Bool)] = []
	var missing = 0
	for item in items {
		// No score fails closed in the app, so count it as a reject.
		if let s = score(model, url(item)) { scored.append((s, item.spoof)) } else { missing += 1; scored.append((1, item.spoof)) }
	}
	return Report(model: name, input: input, live: items.filter { !$0.spoof }.count,
		spoof: items.filter(\.spoof).count, unscored: missing, sweep: thresholds.map { rates(scored, $0) })
}

let test = splits["test"]!
let newModel = try vision(outURL)
var reports: [String: Report] = [:]
for group in Set(test.map { $0.frame == nil ? "sessions" : "frames" }) {
	let items = test.filter { ($0.frame == nil ? "sessions" : "frames") == group }
	reports["\(group)/new"] = report("new", newModel, items, input: "face crop") { $0.crop }
	if let old = options["old"], let oldModel = try? vision(URL(fileURLWithPath: old)) {
		// The shipped detector runs on the whole frame; session items only have the crop.
		reports["\(group)/old"] = report("old", oldModel, items, input: group == "frames" ? "whole frame" : "face crop") {
			$0.frame ?? $0.crop
		}
	}
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(reports).write(to: metricsURL)
for (key, r) in reports.sorted(by: { $0.key < $1.key }) {
	print("== \(key) (\(r.input), \(r.live) live / \(r.spoof) spoof, \(r.unscored) unscored)")
	for row in r.sweep where [0.5, 0.65].contains(where: { abs($0 - row.threshold) < 0.001 }) {
		print(String(format: "   t=%.2f  acc %.3f  spoof recall %.3f  live false-reject %.3f",
			row.threshold, row.accuracy, row.spoofRecall, row.liveFalseReject))
	}
}
print("✓ wrote \(metricsURL.path)")
