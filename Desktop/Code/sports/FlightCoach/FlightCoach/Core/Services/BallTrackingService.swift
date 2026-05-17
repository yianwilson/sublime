import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics

final class BallTrackingService {
    static let shared = BallTrackingService()

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let workingScale: Float = 0.35

    private init() {}

    // MARK: - Public API

    func trackGolfBall(
        in frames: [VideoFrame],
        poseFrames: [PoseFrame],
        impactWindow: ImpactWindow,
        cameraAngle: CameraAngle,
        onProgress: ((Double) -> Void)? = nil
    ) async -> [BallTrackPoint] {
        guard frames.count > 3 else { return [] }

        let sortedFrames = frames.sorted { $0.index < $1.index }
        let bodyMask = buildBodyMask(from: poseFrames)
        let setupFrames = sortedFrames.filter { $0.index < impactWindow.startFrameIndex }
        let selectedAddress = findAddressBall(in: setupFrames.isEmpty ? Array(sortedFrames.prefix(max(2, sortedFrames.count / 4))) : setupFrames, bodyMask: bodyMask)

        guard let address = selectedAddress else {
            #if DEBUG
            print("BallTrackingService: no address ball found; suppressing golf trail")
            #endif
            onProgress?(1.0)
            return []
        }

        let launchFrames = sortedFrames.filter {
            $0.index >= impactWindow.startFrameIndex && $0.index <= impactWindow.endFrameIndex
        }

        let launchTrack = await trackLaunch(
            frames: launchFrames,
            address: address,
            bodyMask: bodyMask,
            cameraAngle: cameraAngle,
            onProgress: onProgress
        )

        guard hasRenderableLaunchTrack(launchTrack, address: address.centroid, cameraAngle: cameraAngle) else {
            #if DEBUG
            print("BallTrackingService: no reliable launch track; suppressing golf trail, impactReason=\(impactWindow.reason), addressScore=\(address.totalScore)")
            #endif
            onProgress?(1.0)
            return []
        }

        var trackPoints = preImpactAddressPoints(
            from: sortedFrames,
            address: address,
            before: impactWindow.estimatedFrameIndex
        )
        trackPoints.append(contentsOf: launchTrack)

        let filtered = filterPhysicallyPlausible(smooth(trackPoints.sorted { $0.frameIndex < $1.frameIndex }))
        let directionChecked = directionValidatedGolfTrack(filtered, address: address.centroid, cameraAngle: cameraAngle)

        #if DEBUG
        if directionChecked.count < 3 {
            print("BallTrackingService: weak golf track, points=\(directionChecked.count), impactReason=\(impactWindow.reason), addressScore=\(address.totalScore)")
        }
        #endif

        onProgress?(1.0)
        return directionChecked
    }

    func trackBall(
        in frames: [VideoFrame],
        poseFrames: [PoseFrame],
        contactFrameHint: Int?,
        onProgress: ((Double) -> Void)? = nil
    ) async -> [BallTrackPoint] {
        guard frames.count > 3 else { return [] }
        return await trackGenericBall(in: frames, poseFrames: poseFrames, onProgress: onProgress)
    }

    private func trackGenericBall(
        in frames: [VideoFrame],
        poseFrames: [PoseFrame],
        onProgress: ((Double) -> Void)?
    ) async -> [BallTrackPoint] {
        let sortedFrames = frames.sorted { $0.index < $1.index }
        let bodyMask = buildBodyMask(from: poseFrames)
        var results: [BallTrackPoint] = []
        var current: CGPoint?
        var previousFrame: VideoFrame?
        var previousScaled: CIImage?

        for (idx, frame) in sortedFrames.enumerated() {
            guard let scaled = scaleImage(frame.image) else { continue }
            defer {
                previousFrame = frame
                previousScaled = scaled
            }

            let roi: CGRect?
            if let current {
                roi = CGRect(x: current.x - 0.24, y: current.y - 0.24, width: 0.48, height: 0.48)
            } else {
                roi = nil
            }

            var candidates = findBrightCandidates(in: scaled, frameIndex: frame.index, withinROI: roi)
            if let previousScaled {
                candidates.append(contentsOf: findMotionCandidates(current: scaled, previous: previousScaled, frameIndex: frame.index, withinROI: roi))
            }

            let scored = candidates.map { candidate -> BallCandidate in
                let bodyPenalty: Float = {
                    guard let bodyMask else { return 0 }
                    return bodyMask.contains(candidate.centroid) ? 0.25 : 0
                }()
                let continuity: Float = {
                    guard let current, let previousFrame else { return 0.15 }
                    let dt = max(1.0 / 240.0, frame.timestamp - previousFrame.timestamp)
                    let jump = Float(distance(current, candidate.centroid))
                    return max(0, 1 - jump / Float(max(0.12, 8.0 * dt)))
                }()
                let total = max(0, candidate.totalScore * 0.65 + candidate.motionScore * 0.2 + continuity * 0.15 - bodyPenalty)
                return BallCandidate(
                    frameIndex: candidate.frameIndex,
                    centroid: candidate.centroid,
                    boundingBox: candidate.boundingBox,
                    pixelCount: candidate.pixelCount,
                    whitenessScore: candidate.whitenessScore,
                    motionScore: candidate.motionScore,
                    shapeScore: candidate.shapeScore,
                    stabilityScore: candidate.stabilityScore,
                    totalScore: total,
                    rejectionReason: total < 0.24 ? "low-generic-score" : nil
                )
            }.sorted { $0.totalScore > $1.totalScore }

            if let best = scored.first, best.totalScore > 0.24 {
                current = best.centroid
                results.append(BallTrackPoint(
                    frameIndex: frame.index,
                    timestamp: frame.timestamp,
                    x: Float(best.centroid.x),
                    y: Float(best.centroid.y),
                    confidence: min(0.55, best.totalScore)
                ))
            }

            if idx % 8 == 0 { await Task.yield() }
            onProgress?(Double(idx + 1) / Double(sortedFrames.count))
        }

        return filterPhysicallyPlausible(smooth(results))
    }

    // MARK: - Address detection

    private func findAddressBall(in frames: [VideoFrame], bodyMask: CGRect?) -> BallCandidate? {
        var clusters: [[BallCandidate]] = []

        for frame in frames {
            guard let scaled = scaleImage(frame.image) else { continue }
            let candidates = findBrightCandidates(in: scaled, frameIndex: frame.index, withinROI: nil)
                .filter { $0.pixelCount >= 2 && $0.pixelCount <= 450 }

            for candidate in candidates {
                if let idx = clusters.firstIndex(where: { cluster in
                    guard let first = cluster.first else { return false }
                    return distance(first.centroid, candidate.centroid) < 0.035
                }) {
                    clusters[idx].append(candidate)
                } else {
                    clusters.append([candidate])
                }
            }
        }

        guard !clusters.isEmpty else { return nil }

        let minStableFrames = min(3, max(2, frames.count / 4))
        let ranked = clusters.compactMap { cluster -> BallCandidate? in
            let uniqueFrameCount = Set(cluster.map(\.frameIndex)).count
            guard uniqueFrameCount >= minStableFrames else { return nil }

            let centroid = averageCentroid(cluster)
            let avgPixels = Int(cluster.map(\.pixelCount).reduce(0, +) / max(1, cluster.count))
            let avgWhite = average(cluster.map(\.whitenessScore))
            let avgShape = average(cluster.map(\.shapeScore))
            let stability = min(1.0, Float(uniqueFrameCount) / Float(max(1, frames.count)))
            let bodyPenalty: Float = {
                guard let bodyMask else { return 0 }
                return bodyMask.contains(centroid) ? 0.18 : 0
            }()
            let lowerFrameBonus: Float = centroid.y < 0.65 ? 0.08 : 0
            let total = max(0, avgWhite * 0.35 + avgShape * 0.25 + stability * 0.40 + lowerFrameBonus - bodyPenalty)

            return BallCandidate(
                frameIndex: cluster.sorted { $0.frameIndex < $1.frameIndex }.last?.frameIndex ?? frames[0].index,
                centroid: centroid,
                boundingBox: unionBoundingBox(cluster),
                pixelCount: avgPixels,
                whitenessScore: avgWhite,
                motionScore: 0,
                shapeScore: avgShape,
                stabilityScore: stability,
                totalScore: total,
                rejectionReason: nil
            )
        }.sorted { $0.totalScore > $1.totalScore }

        guard let best = ranked.first, best.totalScore > 0.35 else { return nil }

        if ranked.count > 1, let second = ranked.dropFirst().first, best.totalScore - second.totalScore < 0.08 {
            return BallCandidate(
                frameIndex: best.frameIndex,
                centroid: best.centroid,
                boundingBox: best.boundingBox,
                pixelCount: best.pixelCount,
                whitenessScore: best.whitenessScore,
                motionScore: best.motionScore,
                shapeScore: best.shapeScore,
                stabilityScore: best.stabilityScore,
                totalScore: best.totalScore * 0.75,
                rejectionReason: "ambiguous-address"
            )
        }

        return best
    }

    private func preImpactAddressPoints(from frames: [VideoFrame], address: BallCandidate, before frameIndex: Int) -> [BallTrackPoint] {
        frames
            .filter { $0.index < frameIndex }
            .suffix(3)
            .map {
                BallTrackPoint(
                    frameIndex: $0.index,
                    timestamp: $0.timestamp,
                    x: Float(address.centroid.x),
                    y: Float(address.centroid.y),
                    confidence: min(0.75, address.totalScore)
                )
            }
    }

    // MARK: - Launch tracking

    private func trackLaunch(
        frames: [VideoFrame],
        address: BallCandidate,
        bodyMask: CGRect?,
        cameraAngle: CameraAngle,
        onProgress: ((Double) -> Void)?
    ) async -> [BallTrackPoint] {
        guard !frames.isEmpty else { return [] }

        var points: [BallTrackPoint] = []
        var current = address.centroid
        var velocity = CGPoint.zero
        var previousFrame: VideoFrame?
        var previousScaled: CIImage?
        var lostCount = 0
        var launched = false
        var launchCandidateCount = 0

        for (idx, frame) in frames.enumerated() {
            guard let scaled = scaleImage(frame.image) else { continue }
            let dt = max(1.0 / 240.0, frame.timestamp - (previousFrame?.timestamp ?? frame.timestamp))
            let prediction = CGPoint(x: current.x + velocity.x * dt, y: current.y + velocity.y * dt)
            let radius: CGFloat = launched
                ? min(0.22, max(0.055, 0.045 + CGFloat(lostCount) * 0.025 + CGFloat(idx) * 0.003))
                : 0.12
            let roi = CGRect(x: prediction.x - radius, y: prediction.y - radius, width: radius * 2, height: radius * 2)

            let brightCandidates = findBrightCandidates(in: scaled, frameIndex: frame.index, withinROI: roi)
            var motionCandidates: [BallCandidate] = []
            if let previousScaled {
                motionCandidates = findMotionCandidates(current: scaled, previous: previousScaled, frameIndex: frame.index, withinROI: roi)
            }
            let candidates = hybridLaunchCandidates(
                motionCandidates: motionCandidates,
                brightCandidates: brightCandidates,
                address: address.centroid,
                launched: launched
            )

            let selected = bestLaunchCandidate(
                candidates: candidates,
                address: address.centroid,
                prediction: prediction,
                velocity: velocity,
                bodyMask: bodyMask,
                launched: launched,
                cameraAngle: cameraAngle
            )

            if let selected {
                let movementFromAddress = distance(selected.centroid, address.centroid)
                guard isPlausibleGolfLaunch(candidate: selected.centroid, address: address.centroid, cameraAngle: cameraAngle, launched: launched),
                      launched || isValidLaunchStart(candidate: selected, address: address.centroid, cameraAngle: cameraAngle) else {
                    lostCount += 1
                    previousFrame = frame
                    previousScaled = scaled
                    continue
                }
                let newVelocity = CGPoint(
                    x: (selected.centroid.x - current.x) / dt,
                    y: (selected.centroid.y - current.y) / dt
                )

                if movementFromAddress > 0.012 || launched {
                    launched = true
                    launchCandidateCount += 1
                    velocity = CGPoint(
                        x: velocity.x * 0.35 + newVelocity.x * 0.65,
                        y: velocity.y * 0.35 + newVelocity.y * 0.65
                    )
                    current = selected.centroid
                    lostCount = 0

                    points.append(BallTrackPoint(
                        frameIndex: frame.index,
                        timestamp: frame.timestamp,
                        x: Float(selected.centroid.x),
                        y: Float(selected.centroid.y),
                        confidence: min(0.9, selected.totalScore)
                    ))
                } else {
                    current = selected.centroid
                    velocity = CGPoint.zero
                    lostCount = 0
                }
            } else {
                lostCount += 1
                if launched {
                    current = prediction
                }
                if lostCount > 7 || (!launched && idx > min(20, max(8, frames.count / 2))) { break }
            }

            previousFrame = frame
            previousScaled = scaled
            if idx % 8 == 0 { await Task.yield() }
            onProgress?(Double(idx + 1) / Double(frames.count))
        }

        guard launchCandidateCount >= 2 else { return [] }
        return points
    }

    private func hybridLaunchCandidates(
        motionCandidates: [BallCandidate],
        brightCandidates: [BallCandidate],
        address: CGPoint,
        launched: Bool
    ) -> [BallCandidate] {
        let usableMotion = motionCandidates.filter { candidate in
            let addressDistance = distance(candidate.centroid, address)
            if !launched && addressDistance > 0.13 { return false }
            return candidate.motionScore >= 0.10 && candidate.pixelCount <= 520 && candidate.shapeScore >= 0.04
        }

        guard !usableMotion.isEmpty else { return [] }

        return usableMotion.map { motion in
            let nearestBright = brightCandidates
                .filter { distance($0.centroid, motion.centroid) <= max(0.018, CGFloat(max($0.boundingBox.width, $0.boundingBox.height)) * 2.0) }
                .sorted { $0.totalScore > $1.totalScore }
                .first

            let brightSupport = nearestBright?.totalScore ?? 0
            let mergedPoint: CGPoint
            if let nearestBright {
                mergedPoint = CGPoint(
                    x: motion.centroid.x * 0.72 + nearestBright.centroid.x * 0.28,
                    y: motion.centroid.y * 0.72 + nearestBright.centroid.y * 0.28
                )
            } else {
                mergedPoint = motion.centroid
            }

            let total = max(
                0,
                min(1, motion.motionScore * 0.45 + motion.shapeScore * 0.25 + motion.totalScore * 0.20 + brightSupport * 0.10)
            )

            return BallCandidate(
                frameIndex: motion.frameIndex,
                centroid: mergedPoint,
                boundingBox: motion.boundingBox,
                pixelCount: motion.pixelCount,
                whitenessScore: nearestBright?.whitenessScore ?? motion.whitenessScore,
                motionScore: motion.motionScore,
                shapeScore: motion.shapeScore,
                stabilityScore: brightSupport,
                totalScore: total,
                rejectionReason: total < 0.18 ? "low-hybrid-score" : nil
            )
        }
    }

    private func bestLaunchCandidate(
        candidates: [BallCandidate],
        address: CGPoint,
        prediction: CGPoint,
        velocity: CGPoint,
        bodyMask: CGRect?,
        launched: Bool,
        cameraAngle: CameraAngle
    ) -> BallCandidate? {
        let scored = candidates.map { candidate -> BallCandidate in
            let predictionDistance = distance(candidate.centroid, prediction)
            let predictionScore = max(0, 1 - Float(predictionDistance / 0.18))
            let addressDistance = distance(candidate.centroid, address)
            let launchScore = launched ? 0.12 : max(0, 0.30 - Float(addressDistance / 0.13) * 0.30)
            let directionScore = directionContinuity(candidate: candidate.centroid, prediction: prediction, velocity: velocity, cameraAngle: cameraAngle)
            let bodyPenalty: Float = {
                guard let bodyMask else { return 0 }
                return bodyMask.contains(candidate.centroid) && addressDistance > 0.04 ? 0.25 : 0
            }()
            let total = max(0, candidate.totalScore * 0.34 + predictionScore * 0.22 + directionScore * 0.14 + launchScore + candidate.motionScore * 0.30 - bodyPenalty)

            return BallCandidate(
                frameIndex: candidate.frameIndex,
                centroid: candidate.centroid,
                boundingBox: candidate.boundingBox,
                pixelCount: candidate.pixelCount,
                whitenessScore: candidate.whitenessScore,
                motionScore: candidate.motionScore,
                shapeScore: candidate.shapeScore,
                stabilityScore: candidate.stabilityScore,
                totalScore: total,
                rejectionReason: total < 0.24 ? "low-launch-score" : nil
            )
        }.sorted { $0.totalScore > $1.totalScore }

        guard let best = scored.first, best.totalScore >= (launched ? 0.22 : 0.26) else { return nil }
        return best
    }

    private func directionContinuity(candidate: CGPoint, prediction: CGPoint, velocity: CGPoint, cameraAngle: CameraAngle) -> Float {
        let speed = hypot(velocity.x, velocity.y)
        guard speed > 0.01 else {
            switch cameraAngle {
            case .behindBallFlight:
                return candidate.y >= prediction.y - 0.08 ? 0.7 : 0.45
            default:
                return 0.55
            }
        }

        let candidateVector = CGPoint(x: candidate.x - prediction.x, y: candidate.y - prediction.y)
        let candidateMagnitude = max(0.0001, hypot(candidateVector.x, candidateVector.y))
        let dot = (candidateVector.x * velocity.x + candidateVector.y * velocity.y) / (candidateMagnitude * speed)
        return Float(max(0, min(1, (dot + 1) / 2)))
    }

    private func isPlausibleGolfLaunch(candidate: CGPoint, address: CGPoint, cameraAngle: CameraAngle, launched: Bool) -> Bool {
        switch cameraAngle {
        case .behindBallFlight, .downTheLine:
            let dx = abs(candidate.x - address.x)
            let dy = candidate.y - address.y

            if !launched && dy < -0.015 {
                return false
            }

            guard dx > 0.025 || abs(dy) > 0.025 else { return true }
            return dy > -0.01 && abs(dy) >= dx * 0.45
        case .faceOn, .unknown:
            return true
        }
    }

    private func isValidLaunchStart(candidate: BallCandidate, address: CGPoint, cameraAngle: CameraAngle) -> Bool {
        let dx = abs(candidate.centroid.x - address.x)
        let dy = candidate.centroid.y - address.y
        let displacement = hypot(dx, dy)

        guard displacement <= 0.13, displacement >= 0.004 else { return false }
        guard candidate.motionScore >= 0.10 else { return false }

        switch cameraAngle {
        case .behindBallFlight, .downTheLine:
            return dy > 0.002 && dy >= dx * 0.25
        case .faceOn:
            return abs(dx) > 0.006 || abs(dy) > 0.006
        case .unknown:
            return dy > -0.012
        }
    }

    private func hasRenderableLaunchTrack(_ points: [BallTrackPoint], address: CGPoint, cameraAngle: CameraAngle) -> Bool {
        guard points.count >= 2 else { return false }
        guard let first = points.first, let last = points.last else { return false }

        let firstPoint = CGPoint(x: CGFloat(first.x), y: CGFloat(first.y))
        let lastPoint = CGPoint(x: CGFloat(last.x), y: CGFloat(last.y))
        let startDistance = distance(firstPoint, address)
        let totalDisplacement = distance(lastPoint, firstPoint)

        guard startDistance <= 0.14, totalDisplacement >= 0.012 else { return false }
        let averageConfidence = points.map(\.confidence).reduce(0, +) / Float(points.count)
        guard averageConfidence >= 0.16 else { return false }

        switch cameraAngle {
        case .behindBallFlight, .downTheLine:
            let dx = abs(Double(last.x - first.x))
            let dy = Double(last.y - first.y)
            return dy > 0.006 && abs(dy) >= dx * 0.25
        case .faceOn, .unknown:
            return true
        }
    }

    private func directionValidatedGolfTrack(_ points: [BallTrackPoint], address: CGPoint, cameraAngle: CameraAngle) -> [BallTrackPoint] {
        switch cameraAngle {
        case .behindBallFlight, .downTheLine:
            let launchPoints = points.filter {
                distance(CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)), address) > 0.018
            }
            guard launchPoints.count >= 2 else { return points }

            guard let first = launchPoints.first, let last = launchPoints.last else { return points }
            let dx = abs(Double(last.x - first.x))
            let dy = Double(last.y - first.y)

            guard dy > 0.015, abs(dy) >= dx * 0.55 else {
                #if DEBUG
                print("BallTrackingService: rejected horizontal golf trail dx=\(dx), dy=\(dy), cameraAngle=\(cameraAngle.rawValue)")
                #endif
                return points.filter {
                    distance(CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)), address) <= 0.018
                }
            }

            return points
        case .faceOn, .unknown:
            return points
        }
    }

    // MARK: - Motion fallback

    private func motionFallback(
        frames: [VideoFrame],
        bodyMask: CGRect?,
        onProgress: ((Double) -> Void)?
    ) async -> [BallTrackPoint] {
        var results: [BallTrackPoint] = []
        var previousScaled: CIImage?
        var current: CGPoint?

        for (idx, frame) in frames.enumerated() {
            guard let scaled = scaleImage(frame.image) else { continue }
            defer { previousScaled = scaled }
            guard let previousScaled else { continue }

            let roi: CGRect?
            if let current {
                roi = CGRect(x: current.x - 0.22, y: current.y - 0.22, width: 0.44, height: 0.44)
            } else {
                roi = nil
            }

            let candidates = findMotionCandidates(current: scaled, previous: previousScaled, frameIndex: frame.index, withinROI: roi)
                .filter { candidate in
                    guard let bodyMask else { return true }
                    return !bodyMask.contains(candidate.centroid)
                }
                .sorted { $0.totalScore > $1.totalScore }

            if let best = candidates.first, best.totalScore > 0.3 {
                current = best.centroid
                results.append(BallTrackPoint(
                    frameIndex: frame.index,
                    timestamp: frame.timestamp,
                    x: Float(best.centroid.x),
                    y: Float(best.centroid.y),
                    confidence: min(0.45, best.totalScore)
                ))
            }

            if idx % 8 == 0 { await Task.yield() }
            onProgress?(Double(idx + 1) / Double(max(1, frames.count)))
        }

        return results
    }

    // MARK: - Candidate detection

    private struct PixelComponent {
        let pixels: [(Int, Int)]
        let whiteness: Float
    }

    private func findBrightCandidates(in ciImage: CIImage, frameIndex: Int, withinROI: CGRect?) -> [BallCandidate] {
        guard let cg = ciContext.createCGImage(ciImage, from: ciImage.extent),
              let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return [] }

        let w = cg.width
        let h = cg.height
        let bpp = max(1, cg.bitsPerPixel / 8)
        let bpr = cg.bytesPerRow
        let dataLen = CFDataGetLength(data)

        var bright = [Bool](repeating: false, count: w * h)
        var whiteness = [Float](repeating: 0, count: w * h)

        for py in 0..<h {
            for px in 0..<w {
                let offset = py * bpr + px * bpp
                guard offset + 2 < dataLen else { continue }

                let c0 = Double(ptr[offset])
                let c1 = Double(ptr[offset + 1])
                let c2 = Double(ptr[offset + 2])
                let brightness = (c0 + c1 + c2) / 765.0
                let balance = 1.0 - min(1.0, (abs(c0 - c1) + abs(c1 - c2) + abs(c0 - c2)) / 210.0)
                let score = Float(brightness * 0.7 + balance * 0.3)

                if brightness > 0.68 && balance > 0.45 {
                    let nx = Double(px) / Double(max(1, w - 1))
                    let ny = 1.0 - Double(py) / Double(max(1, h - 1))
                    if let withinROI, !withinROI.contains(CGPoint(x: nx, y: ny)) { continue }
                    let idx = py * w + px
                    bright[idx] = true
                    whiteness[idx] = score
                }
            }
        }

        return connectedComponents(mask: bright, values: whiteness, width: w, height: h)
            .compactMap { makeCandidate(from: $0, width: w, height: h, frameIndex: frameIndex, motionScore: 0) }
            .filter { $0.pixelCount >= 2 && $0.pixelCount <= 700 }
            .sorted { $0.totalScore > $1.totalScore }
    }

    private func findMotionCandidates(current: CIImage, previous: CIImage, frameIndex: Int, withinROI: CGRect?) -> [BallCandidate] {
        let diff = CIFilter.colorAbsoluteDifference()
        diff.inputImage = current
        diff.inputImage2 = previous
        guard let diffImage = diff.outputImage,
              let cg = ciContext.createCGImage(diffImage, from: diffImage.extent),
              let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return [] }

        let w = cg.width
        let h = cg.height
        let bpp = max(1, cg.bitsPerPixel / 8)
        let bpr = cg.bytesPerRow
        let dataLen = CFDataGetLength(data)

        var moving = [Bool](repeating: false, count: w * h)
        var magnitude = [Float](repeating: 0, count: w * h)

        for py in 0..<h {
            for px in 0..<w {
                let offset = py * bpr + px * bpp
                guard offset + 2 < dataLen else { continue }
                let motion = Float(ptr[offset]) + Float(ptr[offset + 1]) + Float(ptr[offset + 2])
                guard motion > 45 else { continue }

                let nx = Double(px) / Double(max(1, w - 1))
                let ny = 1.0 - Double(py) / Double(max(1, h - 1))
                if let withinROI, !withinROI.contains(CGPoint(x: nx, y: ny)) { continue }

                let idx = py * w + px
                moving[idx] = true
                magnitude[idx] = min(1, motion / 255.0)
            }
        }

        return connectedComponents(mask: moving, values: magnitude, width: w, height: h)
            .compactMap { makeCandidate(from: $0, width: w, height: h, frameIndex: frameIndex, motionScore: min(1, $0.whiteness)) }
            .filter { $0.pixelCount >= 2 && $0.pixelCount <= 500 }
            .sorted { $0.totalScore > $1.totalScore }
    }

    private func connectedComponents(mask: [Bool], values: [Float], width: Int, height: Int) -> [PixelComponent] {
        var visited = [Bool](repeating: false, count: width * height)
        var components: [PixelComponent] = []

        for startY in 0..<height {
            for startX in 0..<width {
                let startIdx = startY * width + startX
                guard mask[startIdx], !visited[startIdx] else { continue }

                var queue = [(startX, startY)]
                var pixels: [(Int, Int)] = []
                var valueSum: Float = 0
                visited[startIdx] = true

                var qi = 0
                while qi < queue.count {
                    let (cx, cy) = queue[qi]
                    qi += 1
                    pixels.append((cx, cy))
                    valueSum += values[cy * width + cx]

                    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let nx = cx + dx
                        let ny = cy + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let idx = ny * width + nx
                        guard mask[idx], !visited[idx] else { continue }
                        visited[idx] = true
                        queue.append((nx, ny))
                    }
                }

                guard !pixels.isEmpty else { continue }
                components.append(PixelComponent(pixels: pixels, whiteness: valueSum / Float(pixels.count)))
            }
        }

        return components
    }

    private func makeCandidate(
        from component: PixelComponent,
        width: Int,
        height: Int,
        frameIndex: Int,
        motionScore: Float
    ) -> BallCandidate? {
        let pixels = component.pixels
        guard pixels.count >= 2 else { return nil }

        let xs = pixels.map(\.0)
        let ys = pixels.map(\.1)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }

        let sumX = pixels.reduce(0.0) { $0 + Double($1.0) }
        let sumY = pixels.reduce(0.0) { $0 + Double($1.1) }
        let centroid = CGPoint(
            x: sumX / Double(pixels.count) / Double(max(1, width - 1)),
            y: 1.0 - sumY / Double(pixels.count) / Double(max(1, height - 1))
        )

        let boxWidthPixels = max(1, maxX - minX + 1)
        let boxHeightPixels = max(1, maxY - minY + 1)
        let aspect = Float(min(boxWidthPixels, boxHeightPixels)) / Float(max(boxWidthPixels, boxHeightPixels))
        let fill = Float(pixels.count) / Float(boxWidthPixels * boxHeightPixels)
        let sizeScore = max(0, 1 - abs(Float(pixels.count) - 28) / 120)
        let shapeScore = max(0, min(1, aspect * 0.55 + fill * 0.25 + sizeScore * 0.20))
        let total = max(0, min(1, component.whiteness * 0.45 + shapeScore * 0.35 + motionScore * 0.20))

        let boundingBox = CGRect(
            x: Double(minX) / Double(max(1, width - 1)),
            y: 1.0 - Double(maxY) / Double(max(1, height - 1)),
            width: Double(boxWidthPixels) / Double(max(1, width)),
            height: Double(boxHeightPixels) / Double(max(1, height))
        )

        return BallCandidate(
            frameIndex: frameIndex,
            centroid: centroid,
            boundingBox: boundingBox,
            pixelCount: pixels.count,
            whitenessScore: component.whiteness,
            motionScore: motionScore,
            shapeScore: shapeScore,
            stabilityScore: 0,
            totalScore: total,
            rejectionReason: nil
        )
    }

    // MARK: - Body mask

    private func buildBodyMask(from poseFrames: [PoseFrame]) -> CGRect? {
        var allX: [Float] = []
        var allY: [Float] = []

        for frame in poseFrames {
            for lm in frame.landmarks where lm.confidence > 0.35 {
                allX.append(lm.x)
                allY.append(lm.y)
            }
        }

        guard !allX.isEmpty else { return nil }

        let pad: Float = 0.035
        let minX = max(0, (allX.min() ?? 0) - pad)
        let maxX = min(1, (allX.max() ?? 1) + pad)
        let minY = max(0, (allY.min() ?? 0) - pad)
        let maxY = min(1, (allY.max() ?? 1) + pad)

        return CGRect(
            x: Double(minX),
            y: Double(minY),
            width: Double(maxX - minX),
            height: Double(maxY - minY)
        )
    }

    // MARK: - Helpers

    private func scaleImage(_ image: CIImage) -> CIImage? {
        let scaleFilter = CIFilter.lanczosScaleTransform()
        scaleFilter.inputImage = image
        scaleFilter.scale = workingScale
        scaleFilter.aspectRatio = 1.0
        return scaleFilter.outputImage
    }

    private func smooth(_ points: [BallTrackPoint]) -> [BallTrackPoint] {
        guard points.count > 2 else { return points }
        return points.enumerated().map { i, curr in
            let prev = points[max(0, i - 1)]
            let next = points[min(points.count - 1, i + 1)]
            return BallTrackPoint(
                frameIndex: curr.frameIndex,
                timestamp: curr.timestamp,
                x: prev.x * 0.18 + curr.x * 0.64 + next.x * 0.18,
                y: prev.y * 0.18 + curr.y * 0.64 + next.y * 0.18,
                confidence: curr.confidence
            )
        }
    }

    private func filterPhysicallyPlausible(_ points: [BallTrackPoint]) -> [BallTrackPoint] {
        guard points.count > 1 else { return points }
        var filtered: [BallTrackPoint] = [points[0]]

        for point in points.dropFirst() {
            guard let previous = filtered.last else { continue }
            let dt = max(1.0 / 240.0, point.timestamp - previous.timestamp)
            let dist = hypot(Double(point.x - previous.x), Double(point.y - previous.y))
            let allowedJump = max(0.12, min(0.42, 18.0 * dt))
            if dist <= allowedJump {
                filtered.append(point)
            }
        }

        return filtered
    }

    private func typicalFrameStep(_ indices: [Int]) -> Int {
        guard indices.count > 1 else { return 1 }
        let deltas = zip(indices.dropFirst(), indices).map { max(1, $0 - $1) }.sorted()
        return deltas[deltas.count / 2]
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func average(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Float(values.count)
    }

    private func averageCentroid(_ candidates: [BallCandidate]) -> CGPoint {
        guard !candidates.isEmpty else { return .zero }
        let x = candidates.map(\.centroid.x).reduce(0, +) / CGFloat(candidates.count)
        let y = candidates.map(\.centroid.y).reduce(0, +) / CGFloat(candidates.count)
        return CGPoint(x: x, y: y)
    }

    private func unionBoundingBox(_ candidates: [BallCandidate]) -> CGRect {
        guard let first = candidates.first else { return .zero }
        return candidates.dropFirst().reduce(first.boundingBox) { $0.union($1.boundingBox) }
    }
}
