// Train a Create ML object detector on the auto-labeled ball dataset and
// evaluate on a held-out video. Run on macOS:
//   swift VisionLab/scripts/train_createml_ball.swift <dataset-root>
import Foundation
import CreateML
import CoreML
import Vision

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
               ? CommandLine.arguments[1] : "VisionLab/datasets/ball-v1")
let trainDir = root.appendingPathComponent("train")
let evalDir = root.appendingPathComponent("eval")
let modelURL = root.appendingPathComponent("GolfBallDetector.mlmodel")

print("Training MLObjectDetector on \(trainDir.path) …")
let data = MLObjectDetector.DataSource.directoryWithImagesAndJsonAnnotation(at: trainDir)

var params = MLObjectDetector.ModelParameters()
params.maxIterations = 600
let model = try MLObjectDetector(
    trainingData: data, parameters: params,
    annotationType: .boundingBox(units: .pixel, origin: .topLeft, anchor: .center))
try model.write(to: modelURL)
print("Saved \(modelURL.lastPathComponent)")
print("Training metrics: \(model.trainingMetrics)")

// Held-out evaluation: did the model find the ball near the labeled position?
struct Ann: Decodable {
    struct A: Decodable {
        struct C: Decodable { let x: Double; let y: Double; let width: Double; let height: Double }
        let label: String; let coordinates: C
    }
    let image: String; let annotations: [A]
}
let anns = try JSONDecoder().decode([Ann].self,
    from: Data(contentsOf: evalDir.appendingPathComponent("annotations.json")))

let compiled = try MLModel.compileModel(at: modelURL)
let vnModel = try VNCoreMLModel(for: try MLModel(contentsOf: compiled))

var hits = 0, total = 0
var falsePositives = 0, negatives = 0
for ann in anns {
    guard let gt = ann.annotations.first else {
        // Negative crop (bare tee, shoes, club head, turf): any confident
        // detection is a false positive — the seed validator's failure mode.
        negatives += 1
        let imgURL = evalDir.appendingPathComponent(ann.image)
        let handler = VNImageRequestHandler(url: imgURL)
        let req = VNCoreMLRequest(model: vnModel)
        req.imageCropAndScaleOption = .scaleFill
        try handler.perform([req])
        let dets = ((req.results as? [VNRecognizedObjectObservation]) ?? [])
            .filter { $0.confidence >= 0.5 }
        if !dets.isEmpty {
            falsePositives += 1
            print(String(format: "EVAL %@: FALSE POSITIVE conf %.2f", ann.image, dets[0].confidence))
        }
        continue
    }
    total += 1
    let imgURL = evalDir.appendingPathComponent(ann.image)
    let handler = VNImageRequestHandler(url: imgURL)
    let req = VNCoreMLRequest(model: vnModel)
    req.imageCropAndScaleOption = .scaleFill
    try handler.perform([req])
    let results = (req.results as? [VNRecognizedObjectObservation]) ?? []

    // Image dims for converting normalized Vision coords (bottom-left) to pixels.
    guard let src = CGImageSourceCreateWithURL(imgURL as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Double,
          let h = props[kCGImagePropertyPixelHeight] as? Double else { continue }

    var best: (Double, Double, Double)? = nil   // dist, px, py
    for r in results {
        let px = r.boundingBox.midX * w
        let py = (1 - r.boundingBox.midY) * h
        let d = ((px - gt.coordinates.x) * (px - gt.coordinates.x)
               + (py - gt.coordinates.y) * (py - gt.coordinates.y)).squareRoot()
        if best == nil || d < best!.0 { best = (d, px, py) }
    }
    let tol = max(w, h) * 0.05
    if let b = best {
        let ok = b.0 <= tol
        if ok { hits += 1 }
        print(String(format: "EVAL %@: gt(%.0f,%.0f) pred(%.0f,%.0f) d=%.0fpx %@ (top conf %.2f, %d dets)",
                     ann.image, gt.coordinates.x, gt.coordinates.y, b.1, b.2, b.0,
                     ok ? "HIT" : "MISS", results.first?.confidence ?? 0, results.count))
    } else {
        print("EVAL \(ann.image): gt(\(Int(gt.coordinates.x)),\(Int(gt.coordinates.y))) NO DETECTION")
    }
}
print("HELD-OUT ACCURACY: \(hits)/\(total) labeled frames within 5% tolerance")
print("HELD-OUT FALSE POSITIVES: \(falsePositives)/\(negatives) negative crops with a confident detection")
