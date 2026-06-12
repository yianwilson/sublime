// Train the ball/not-ball patch classifier and report HELD-OUT accuracy on
// unseen videos (the only number that counts). Run on macOS:
//   swift VisionLab/scripts/train_patch_classifier.swift [dataset-root]
import Foundation
import CreateML
import CoreML
import Vision

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
               ? CommandLine.arguments[1] : "VisionLab/datasets/ball-patches-v1")
let trainDir = root.appendingPathComponent("train")
let evalDir = root.appendingPathComponent("eval")
let modelURL = root.appendingPathComponent("BallPatchClassifier.mlmodel")

print("Training MLImageClassifier on \(trainDir.path) …")
var params = MLImageClassifier.ModelParameters()
params.maxIterations = 30
params.augmentationOptions = [.exposure, .blur, .rotation, .noise]
let model = try MLImageClassifier(
    trainingData: .labeledDirectories(at: trainDir), parameters: params)
try model.write(to: modelURL)
print("Saved \(modelURL.lastPathComponent); training: \(model.trainingMetrics)")

let compiled = try MLModel.compileModel(at: modelURL)
let vnModel = try VNCoreMLModel(for: try MLModel(contentsOf: compiled))

var perVideo: [String: (hit: Int, total: Int)] = [:]
for cls in ["ball", "notball"] {
    let dir = evalDir.appendingPathComponent(cls)
    for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    where file.pathExtension == "png" {
        let req = VNCoreMLRequest(model: vnModel)
        try VNImageRequestHandler(url: file).perform([req])
        guard let top = (req.results as? [VNClassificationObservation])?.first else { continue }
        let video = String(file.lastPathComponent.split(separator: "_")[0...1].joined(separator: "_"))
        let key = "\(video)/\(cls)"
        var entry = perVideo[key] ?? (0, 0)
        entry.total += 1
        if top.identifier == cls { entry.hit += 1 }
        perVideo[key] = entry
    }
}
var hits = 0, total = 0
for (key, e) in perVideo.sorted(by: { $0.key < $1.key }) {
    print(String(format: "HELD-OUT %@: %d/%d (%.0f%%)", key, e.hit, e.total,
                 100 * Double(e.hit) / Double(max(1, e.total))))
    hits += e.hit
    total += e.total
}
print("HELD-OUT OVERALL: \(hits)/\(total)")
