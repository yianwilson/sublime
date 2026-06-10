import Foundation
import UIKit

/// Captures labeled golf-ball examples from the user's manual ball taps, in Create ML
/// object-detection format (images + `annotations.json`). Over time this becomes the
/// dataset used to train `GolfBallDetector.mlmodel`, which `BallDetectorFactory` then
/// loads to power the CoreML detection path. The user's corrections *are* the labels.
final class TrainingDataService {
    static let shared = TrainingDataService()

    private let directory: URL
    private let queue = DispatchQueue(label: "training-data", qos: .utility)

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = docs.appendingPathComponent("TrainingData", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The folder to pull off-device (via the Files app / Finder) for training.
    var datasetURL: URL { directory }

    var exampleCount: Int {
        let imgs = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return imgs.filter { $0.pathExtension == "jpg" }.count
    }

    /// Zip the whole dataset to a temp file for sharing (AirDrop / Save to Files),
    /// so the folder can be pulled onto a Mac for training without navigating storage.
    func exportArchive() -> URL? {
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var result: URL?
        coordinator.coordinate(readingItemAt: directory, options: [.forUploading], error: &coordError) { zipURL in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("FlightCoachTrainingData.zip")
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: zipURL, to: dest)
                result = dest
            } catch {
                result = nil
            }
        }
        return result
    }

    /// Record one labeled example. `normalizedCenter` is in **top-left/y-down image
    /// space** (x, y ∈ [0,1]); convert from the app's y-up ball space before calling.
    func record(image: UIImage, normalizedCenter: CGPoint, boxFraction: CGFloat = 0.05) {
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { return }
        let w = image.size.width
        let h = image.size.height
        let id = UUID().uuidString
        let filename = "\(id).jpg"

        queue.async { [directory] in
            try? jpeg.write(to: directory.appendingPathComponent(filename))

            // Create ML annotation: pixel coords, centre-based, origin top-left.
            let side = boxFraction * w
            let coordinates: [String: Double] = [
                "x": Double(normalizedCenter.x) * Double(w),
                "y": Double(normalizedCenter.y) * Double(h),
                "width": Double(side),
                "height": Double(side)
            ]
            let entry: [String: Any] = [
                "image": filename,
                "annotations": [["label": "golf_ball", "coordinates": coordinates]]
            ]

            let annotationsURL = directory.appendingPathComponent("annotations.json")
            var all: [[String: Any]] = []
            if let data = try? Data(contentsOf: annotationsURL),
               let existing = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                all = existing
            }
            all.append(entry)
            if let out = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted]) {
                try? out.write(to: annotationsURL)
            }
            #if DEBUG
            print("TrainingDataService: saved example (\(all.count) total) → \(directory.path)")
            #endif
        }
    }
}
