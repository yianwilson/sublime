import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics

final class BallTrackingService {
    static let shared = BallTrackingService()

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let workingScale: Float = 0.35
    private let detector: BallDetector

    private init(detector: BallDetector = BallDetectorFactory.productionDetector()) {
        self.detector = detector
    }

    // MARK: - Public API

    func trackGolfBall(
        in frames: [VideoFrame],
        poseFrames: [PoseFrame],
        impactWindow: ImpactWindow,
        cameraAngle: CameraAngle,
        handedness: Handedness = .rightHanded,
        onProgress: ((Double) -> Void)? = nil
    ) async -> [BallTrackPoint] {
        let result = await detectAddressBall(
            in: frames,
            poseFrames: poseFrames,
            impactWindow: impactWindow,
            cameraAngle: cameraAngle,
            handedness: handedness,
            onProgress: onProgress
        )
        return result.trackPoints
    }

    /// Full address detection + launch tracking, returning both the track and the
    /// structured address result (calibrated confidence + failure reason) so the
    /// caller/UI can decide between auto-accept and a one-tap fallback.
    func detectAddressBall(
        in frames: [VideoFrame],
        poseFrames: [PoseFrame],
        impactWindow: ImpactWindow,
        cameraAngle: CameraAngle,
        handedness: Handedness = .rightHanded,
        onProgress: ((Double) -> Void)? = nil
    ) async -> (trackPoints: [BallTrackPoint], address: AddressBallResult) {
        guard frames.count > 3 else {
            onProgress?(1.0)
            return ([], .failure(.noCandidatesInROI))
        }

        let sortedFrames = frames.sorted { $0.index < $1.index }
        let bodyMask = buildBodyMask(from: poseFrames)
        let setupFrames = sortedFrames.filter { $0.index < impactWindow.startFrameIndex }
        let addressResult = await findAddressBall(
            in: setupFrames.isEmpty ? Array(sortedFrames.prefix(max(2, sortedFrames.count / 4))) : setupFrames,
            poseFrames: poseFrames,
            bodyMask: bodyMask,
            impactFrames: sortedFrames,
            impactWindow: impactWindow,
            cameraAngle: cameraAngle,
            handedness: handedness
        )

        guard let address = addressResult.selected else {
            #if DEBUG
            print("BallTrackingService: no address ball found (\(addressResult.failureReason?.rawValue ?? "unknown")); suppressing automatic tracer")
            #endif
            onProgress?(1.0)
            return ([], addressResult)
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

        let addressPoint = BallTrackPoint(
            frameIndex: impactWindow.estimatedFrameIndex,
            timestamp: sortedFrames.first(where: { $0.index >= impactWindow.estimatedFrameIndex })?.timestamp ?? 0,
            x: Float(address.centroid.x),
            y: Float(address.centroid.y),
            confidence: min(0.95, max(0.20, addressResult.confidence))
        )

        guard hasRenderableLaunchTrack(launchTrack, address: address.centroid, cameraAngle: cameraAngle) else {
            #if DEBUG
            print("BallTrackingService: no reliable launch track; returning address ball only, impactReason=\(impactWindow.reason), addressConfidence=\(addressResult.confidence)")
            #endif
            onProgress?(1.0)
            return ([addressPoint], addressResult)
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
        print("BallTrackingService: AUTO raw flight track → \(directionChecked.count) points (impactReason=\(impactWindow.reason), addressConfidence=\(String(format: "%.2f", addressResult.confidence)))")
        #endif

        // Hand the raw launch points to the ballistic fitter (in the pipeline); it
        // decides whether they form a real arc. No gate here — gating before the fit
        // just starves it of data.
        onProgress?(1.0)
        return (directionChecked, addressResult)
    }

    /// Detect just the address ball (normalised, y-up) without running launch tracking —
    /// used to seed the spec-v3 GolfTracerPipeline in the auto path.
    func detectAddressOnly(in frames: [VideoFrame], poseFrames: [PoseFrame], impactWindow: ImpactWindow,
                           cameraAngle: CameraAngle, handedness: Handedness) async -> CGPoint? {
        guard frames.count > 1 else { return nil }
        let sortedFrames = frames.sorted { $0.index < $1.index }
        let bodyMask = buildBodyMask(from: poseFrames)
        let setupFrames = sortedFrames.filter { $0.index < impactWindow.startFrameIndex }
        let result = await findAddressBall(
            in: setupFrames.isEmpty ? Array(sortedFrames.prefix(max(2, sortedFrames.count / 4))) : setupFrames,
            poseFrames: poseFrames, bodyMask: bodyMask, impactFrames: sortedFrames,
            impactWindow: impactWindow, cameraAngle: cameraAngle, handedness: handedness)
        // Spec §8.4: never seed tracking on a low-confidence / ambiguous address. Better to
        // draw nothing and ask for a manual tap than place a wrong ball (e.g. an 8px corner
        // blob when pose is unavailable on the simulator).
        guard let selected = result.selected,
              Double(result.confidence) >= GolfTracerConfig().minimumAddressConfidence else {
            #if DEBUG
            print("BallTrackingService: address confidence \(result.confidence) < \(GolfTracerConfig().minimumAddressConfidence) — refusing auto address, manual tap needed")
            #endif
            return nil
        }
        return selected.centroid
    }

    /// A real ball flight is ballistic: one consistent horizontal direction and at
    /// most one vertical apex. A track that reverses direction repeatedly is noise
    /// (club/body/background at low fps) — suppress it to just the address ball
    /// rather than drawing a zig-zag.
    private func ballisticPlausibleTrack(_ points: [BallTrackPoint], address: CGPoint) -> [BallTrackPoint] {
        let sorted = points.sorted { $0.timestamp < $1.timestamp }
        let addressOnly = sorted.filter {
            distance(CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)), address) <= 0.02
        }
        let launch = sorted.filter {
            distance(CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)), address) > 0.02
        }
        guard launch.count >= 3 else { return sorted }

        func reversals(_ values: [Float], deadzone: Float) -> Int {
            var count = 0
            var lastSign = 0
            for i in 1..<values.count {
                let d = values[i] - values[i - 1]
                guard abs(d) >= deadzone else { continue }
                let sign = d > 0 ? 1 : -1
                if lastSign != 0 && sign != lastSign { count += 1 }
                lastSign = sign
            }
            return count
        }

        let vReversals = reversals(launch.map(\.y), deadzone: 0.01)
        let hReversals = reversals(launch.map(\.x), deadzone: 0.01)

        if vReversals >= 2 || hReversals >= 2 {
            #if DEBUG
            print("BallTrackingService: non-ballistic track rejected (vRev=\(vReversals), hRev=\(hReversals)) — trail suppressed")
            #endif
            return addressOnly.isEmpty ? Array(sorted.prefix(1)) : addressOnly
        }
        return sorted
    }

    func trackGolfBallFromSeed(
        in frames: [VideoFrame],
        seed: BallTrackPoint,
        cameraAngle: CameraAngle,
        onProgress: ((Double) -> Void)? = nil
    ) async -> [BallTrackPoint] {
        let sortedFrames = frames
            .filter { $0.timestamp >= max(0, seed.timestamp - 0.05) }
            .sorted { $0.timestamp < $1.timestamp }
        guard sortedFrames.count > 2 else {
            onProgress?(1.0)
            return [seed]
        }

        let seededTrack = await trackSeededLaunch(
            frames: sortedFrames,
            seed: seed,
            cameraAngle: cameraAngle,
            onProgress: onProgress
        )
        let smoothed = filterPhysicallyPlausible(smooth(seededTrack.sorted { $0.timestamp < $1.timestamp }))
        guard smoothed.count >= 3 else {
            return [seed]
        }
        return smoothed
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

            var candidates = await detectBallCandidates(in: frame, previousFrame: previousFrame, withinROI: roi)
            candidates.append(contentsOf: findBrightCandidates(in: scaled, frameIndex: frame.index, withinROI: roi))
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

    private func findAddressBall(
        in frames: [VideoFrame],
        poseFrames: [PoseFrame],
        bodyMask: CGRect?,
        impactFrames: [VideoFrame],
        impactWindow: ImpactWindow,
        cameraAngle: CameraAngle,
        handedness: Handedness
    ) async -> AddressBallResult {
        // Setup-phase poses (at/around address), used to anchor the search region.
        let sortedPoses = poseFrames.sorted { $0.frameIndex < $1.frameIndex }
        let setupPoseSubset = sortedPoses.filter { $0.frameIndex < impactWindow.startFrameIndex }
        let setupPoses = setupPoseSubset.isEmpty
            ? Array(sortedPoses.prefix(max(2, sortedPoses.count * 35 / 100)))
            : setupPoseSubset

        // 1. Narrow the search to the estimated club-head / address area using pose.
        let roi = clubHeadAddressROI(
            poseFrames: setupPoses,
            bodyMask: bodyMask,
            cameraAngle: cameraAngle,
            handedness: handedness
        )
        let wristMidpoint = addressWristMidpoint(poseFrames: setupPoses)

        // 2. Pre-compute golf-context temporal signals (launch origin near impact).
        let impactMotionCandidates = await addressImpactMotionCandidates(
            frames: impactFrames,
            impactWindow: impactWindow,
            withinROI: roi
        )

        // 3. Lenient candidate generation inside the ROI (strictness moves to ranking).
        var clusters: [[BallCandidate]] = []
        var previousScaled: CIImage?
        var previousFrame: VideoFrame?

        for frame in frames {
            guard let scaled = scaleImage(frame.image) else { continue }

            var candidates = await detectBallCandidates(in: frame, previousFrame: previousFrame, withinROI: roi)
            candidates.append(contentsOf: findBrightCandidates(in: scaled, frameIndex: frame.index, withinROI: roi))
            candidates.append(contentsOf: findContrastCandidates(in: scaled, frameIndex: frame.index, withinROI: roi))
            if let previousScaled {
                candidates.append(contentsOf: findStableObjectCandidates(
                    current: scaled,
                    previous: previousScaled,
                    frameIndex: frame.index,
                    withinROI: roi
                ))
            }
            // Lenient size gate only — a golf ball is small; reject only obvious blobs.
            candidates = candidates.filter { $0.pixelCount >= 1 && $0.pixelCount <= 500 }

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

            previousScaled = scaled
            previousFrame = frame
        }

        guard !clusters.isEmpty else {
            return .failure(.noCandidatesInROI, roi: roi, wristMidpoint: wristMidpoint)
        }

        // 4. Score each stable cluster with golf-context-dominant weights.
        // When the ROI is pose-anchored (club head), club-head proximity is a strong
        // signal. Without pose the ROI is the broad ground band, so proximity to its
        // centre is misleading — lean instead on the temporal signals (launch origin,
        // disappearance) which don't need pose.
        let poseAnchored = wristMidpoint != nil
        // Circularity (a round, well-filled disc) is the most direct ball signal and
        // needs no pose. Club-head proximity only means something with a pose-anchored
        // ROI; without pose the ROI is the whole ground band, so drop that bias.
        let wRound: Float = poseAnchored ? 0.18 : 0.30
        let wClub: Float = poseAnchored ? 0.24 : 0.0
        let wLaunch: Float = poseAnchored ? 0.14 : 0.18
        let wGround: Float = poseAnchored ? 0.08 : 0.12
        let wDisappear: Float = poseAnchored ? 0.14 : 0.20
        let roiCenter = CGPoint(x: roi.midX, y: roi.midY)
        let roiHalfDiag = max(0.05, hypot(roi.width, roi.height) / 2)
        // Pre-scale a bounded set of post-impact frames once (disappearance check).
        let scaledPostImpact: [(index: Int, image: CIImage)] = impactFrames
            .filter { $0.index > impactWindow.estimatedFrameIndex }
            .prefix(10)
            .compactMap { frame in scaleImage(frame.image).map { (frame.index, $0) } }
        let minStableFrames = min(3, max(2, frames.count / 4))

        // Stage 1 — cheap golf-context score (no post-impact validation yet).
        struct ScoredCluster {
            let candidate: BallCandidate
            let centroid: CGPoint
            let launchOrigin: Float
            let baseTotal: Float
        }

        let stage1: [ScoredCluster] = clusters.compactMap { cluster in
            let uniqueFrameCount = Set(cluster.map(\.frameIndex)).count
            guard uniqueFrameCount >= max(2, minStableFrames) else { return nil }

            let centroid = averageCentroid(cluster)
            let avgPixels = Int(cluster.map(\.pixelCount).reduce(0, +) / max(1, cluster.count))
            let avgWhite = average(cluster.map(\.whitenessScore))
            let avgShape = average(cluster.map(\.shapeScore))
            let stability = min(1.0, Float(uniqueFrameCount) / Float(max(1, frames.count)))

            let clubHeadProximity = max(0, 1 - Float(distance(centroid, roiCenter) / roiHalfDiag))
            let launchOrigin = nearestImpactMotionScore(to: centroid, candidates: impactMotionCandidates)
            let ground = addressGroundScore(centroid)
            // Roundness only counts once a blob is big enough to assess its shape — a
            // 2px speck is "round" trivially. Large round discs are NOT penalised.
            let sizeConfidence: Float = avgPixels >= 8 ? 1 : Float(avgPixels) / 8
            let roundScore = avgShape * sizeConfidence

            let insideBody: Float = {
                guard let bodyMask else { return 0 }
                return bodyMask.contains(centroid) ? 1 : 0
            }()
            let nearShoes = shoeProximityPenalty(centroid: centroid, poseFrames: setupPoses)
            let tooHigh: Float = centroid.y > 0.45 ? 1 : 0
            // Penalise large blobs only when they are NOT round (irregular bright
            // regions like turf glare), so a genuinely large ball survives.
            let tooLarge: Float = (avgPixels > 450 && avgShape < 0.5) ? 1 : 0

            let baseTotal = roundScore * wRound
                + clubHeadProximity * wClub
                + stability * 0.12
                + launchOrigin * wLaunch
                + ground * wGround
                + avgWhite * 0.03
                - insideBody * 0.30
                - nearShoes * 0.15
                - tooHigh * 0.12
                - tooLarge * 0.10

            let candidate = BallCandidate(
                frameIndex: cluster.sorted { $0.frameIndex < $1.frameIndex }.last?.frameIndex ?? frames[0].index,
                centroid: centroid,
                boundingBox: unionBoundingBox(cluster),
                pixelCount: avgPixels,
                whitenessScore: avgWhite,
                motionScore: launchOrigin,
                shapeScore: avgShape,
                stabilityScore: stability,
                totalScore: max(0, baseTotal),
                rejectionReason: nil
            )
            return ScoredCluster(candidate: candidate, centroid: centroid, launchOrigin: launchOrigin, baseTotal: baseTotal)
        }.sorted { $0.baseTotal > $1.baseTotal }

        guard !stage1.isEmpty else {
            return .failure(.noCandidatesInROI, candidates: [], roi: roi, wristMidpoint: wristMidpoint)
        }

        // Stage 2 — run the expensive post-impact disappearance check only on the
        // top contenders, then re-score. The struck ball leaves its address spot; a
        // tee marker / shoe logo / sign stays put.
        let refineCount = min(6, stage1.count)
        let refined: [BallCandidate] = stage1.enumerated().map { index, scored in
            let disappearance: Float
            if index < refineCount {
                disappearance = addressDisappearanceScore(centroid: scored.centroid, scaledPostImpact: scaledPostImpact)
            } else {
                disappearance = 0.5 // neutral for un-refined tail
            }
            let staticPersist: Float = (disappearance < 0.35 && scored.launchOrigin < 0.15) ? 1 : 0
            let total = max(0, scored.baseTotal + disappearance * wDisappear - staticPersist * 0.22)
            let c = scored.candidate
            return BallCandidate(
                frameIndex: c.frameIndex, centroid: c.centroid, boundingBox: c.boundingBox,
                pixelCount: c.pixelCount, whitenessScore: c.whitenessScore, motionScore: c.motionScore,
                shapeScore: c.shapeScore, stabilityScore: disappearance, totalScore: total,
                rejectionReason: nil
            )
        }

        let ranked = refined.sorted { $0.totalScore > $1.totalScore }

        guard let best = ranked.first else {
            return .failure(.noCandidatesInROI, candidates: [], roi: roi, wristMidpoint: wristMidpoint)
        }

        let secondScore = ranked.dropFirst().first?.totalScore
        let separation = secondScore.map { max(0, best.totalScore - $0) } ?? 0.20
        let launchOrigin = best.motionScore
        let disappearance = best.stabilityScore // stored disappearance for the winner
        let validationBonus: Float = (disappearance > 0.5 && launchOrigin > 0.18) ? 0.12 : 0

        // Calibrated confidence: blends absolute score, separation from runner-up,
        // and temporal validation.
        let confidence = min(0.97, max(0, best.totalScore * 0.68 + min(0.25, separation) * 1.2 + validationBonus))

        #if DEBUG
        print(String(format: "BallTrackingService: SELECTED ball x=%.3f y=%.3f (score=%.2f sep=%.2f disappear=%.2f launch=%.2f conf=%.2f pixels=%d) poseAnchored=%@ roi=[x %.2f y %.2f w %.2f h %.2f]",
                     best.centroid.x, best.centroid.y, best.totalScore, separation, disappearance, launchOrigin, confidence, best.pixelCount,
                     poseAnchored ? "YES" : "NO", roi.minX, roi.minY, roi.width, roi.height))
        for (i, c) in ranked.prefix(5).enumerated() {
            print(String(format: "  cand[%d] x=%.3f y=%.3f score=%.2f pixels=%d round=%.2f launch=%.2f disappear=%.2f", i, c.centroid.x, c.centroid.y, c.totalScore, c.pixelCount, c.shapeScore, c.motionScore, c.stabilityScore))
        }
        print("  (coords are normalised, origin BOTTOM-LEFT, y up; impactReason=\(impactWindow.reason))")
        #endif

        // Reject only when there is genuinely nothing usable.
        guard best.totalScore >= 0.20 else {
            return .failure(.lowConfidence, candidates: ranked, roi: roi, wristMidpoint: wristMidpoint)
        }

        // Refine: nudge the address position toward the launch-motion origin only when
        // the pick is NOT already a clean round disc. A high-circularity candidate is
        // trusted as-is; refining it would drag a good pick toward club/launch motion.
        let refinedCentroid = best.shapeScore >= 0.6
            ? best.centroid
            : refineToLaunchOrigin(candidate: best.centroid, motionCandidates: impactMotionCandidates)
        let selectedBall = refinedCentroid == best.centroid ? best : BallCandidate(
            frameIndex: best.frameIndex, centroid: refinedCentroid, boundingBox: best.boundingBox,
            pixelCount: best.pixelCount, whitenessScore: best.whitenessScore, motionScore: best.motionScore,
            shapeScore: best.shapeScore, stabilityScore: best.stabilityScore, totalScore: best.totalScore,
            rejectionReason: best.rejectionReason
        )
        #if DEBUG
        if refinedCentroid != best.centroid {
            print(String(format: "  REFINED toward launch origin → x=%.3f y=%.3f", refinedCentroid.x, refinedCentroid.y))
        }
        #endif

        // Ambiguous: near-tied candidates the temporal signals can't separate. A very
        // small gap is a coin-flip even with a validation bonus, so treat it as
        // ambiguous regardless. Still surface the best guess (so it's pointed out
        // automatically), but flag low confidence so the UI invites a confirming tap.
        let gap = secondScore.map { best.totalScore - $0 } ?? 1
        if (gap < 0.05 && validationBonus == 0) || gap < 0.03 {
            let ambiguousConfidence = min(confidence, 0.32)
            return AddressBallResult(
                selected: selectedBall,
                confidence: ambiguousConfidence,
                candidates: ranked,
                roi: roi,
                wristMidpoint: wristMidpoint,
                failureReason: .ambiguous
            )
        }

        return AddressBallResult(
            selected: selectedBall,
            confidence: confidence,
            candidates: ranked,
            roi: roi,
            wristMidpoint: wristMidpoint,
            failureReason: confidence < 0.35 ? .lowConfidence : nil
        )
    }

    // MARK: - Pose-anchored address ROI

    /// Median wrist midpoint across setup frames, in Vision-normalised space
    /// (origin bottom-left, y up). Hands are roughly above the ball at address.
    private func addressWristMidpoint(poseFrames: [PoseFrame]) -> CGPoint? {
        var points: [CGPoint] = []
        for frame in poseFrames {
            let wrists = [frame.leftWrist, frame.rightWrist].compactMap { $0 }.filter { $0.confidence > 0.30 }
            guard !wrists.isEmpty else { continue }
            let x = wrists.map { CGFloat($0.x) }.reduce(0, +) / CGFloat(wrists.count)
            let y = wrists.map { CGFloat($0.y) }.reduce(0, +) / CGFloat(wrists.count)
            points.append(CGPoint(x: x, y: y))
        }
        guard !points.isEmpty else { return nil }
        let xs = points.map(\.x).sorted()
        let ys = points.map(\.y).sorted()
        return CGPoint(x: xs[xs.count / 2], y: ys[ys.count / 2])
    }

    /// Approximate ground line (lowest body landmark y) from ankles, else knees.
    private func addressGroundLine(poseFrames: [PoseFrame]) -> CGFloat? {
        var ys: [CGFloat] = []
        for frame in poseFrames {
            let ankles = [frame.leftAnkle, frame.rightAnkle].compactMap { $0 }.filter { $0.confidence > 0.25 }
            if let lowest = ankles.map({ CGFloat($0.y) }).min() {
                ys.append(lowest)
            } else {
                let knees = [frame.leftKnee, frame.rightKnee].compactMap { $0 }.filter { $0.confidence > 0.25 }
                if let lowestKnee = knees.map({ CGFloat($0.y) }).min() {
                    // Ground is below the knees; nudge downward in (y-up) space.
                    ys.append(max(0, lowestKnee - 0.12))
                }
            }
        }
        guard !ys.isEmpty else { return nil }
        let sorted = ys.sorted()
        return sorted[sorted.count / 2]
    }

    /// Tight ROI around where the club head / ball should be at address: a box
    /// dropped from the wrist midpoint down to the ground band, nudged laterally
    /// by camera angle and handedness. Falls back to the lower-body ground band
    /// when wrists are unreliable (hands often occluded by the club at address).
    private func clubHeadAddressROI(
        poseFrames: [PoseFrame],
        bodyMask: CGRect?,
        cameraAngle: CameraAngle,
        handedness: Handedness
    ) -> CGRect {
        let fallback = addressSearchROI(bodyMask: bodyMask)
        guard let wristMid = addressWristMidpoint(poseFrames: poseFrames) else {
            return fallback
        }

        // Ground band: ball sits at/near ground, i.e. low y in Vision space.
        let groundY = addressGroundLine(poseFrames: poseFrames) ?? max(0.04, wristMid.y - 0.30)

        // Lateral nudge: ball sits slightly toward the target relative to the hands.
        // Down-the-line: RH golfer faces left→right target; ball is toward the
        // camera-right of the hands for RH, camera-left for LH (mirror for face-on
        // is weaker, so keep it small).
        let lateral: CGFloat
        switch cameraAngle {
        case .downTheLine, .behindBallFlight:
            lateral = handedness == .rightHanded ? 0.03 : -0.03
        case .faceOn:
            lateral = handedness == .rightHanded ? -0.02 : 0.02
        case .unknown:
            lateral = 0
        }

        let centerX = min(0.92, max(0.08, wristMid.x + lateral))
        // Centre the box on the ground band, biased just above the ground line.
        let bandHeight: CGFloat = 0.20
        let centerY = min(0.46, max(0.04, groundY + 0.04))

        let width: CGFloat = 0.36
        let height = bandHeight
        var rect = CGRect(
            x: centerX - width / 2,
            y: centerY - height / 2,
            width: width,
            height: height
        )
        // Clamp into frame.
        rect.origin.x = min(max(0, rect.origin.x), 1 - rect.width)
        rect.origin.y = min(max(0, rect.origin.y), 1 - rect.height)

        // Guard against a degenerate region drifting up into the torso.
        if rect.maxY > 0.6 {
            return fallback
        }
        return rect
    }

    /// Penalty (0…1) for being on/near the golfer's shoes, a common false positive.
    private func shoeProximityPenalty(centroid: CGPoint, poseFrames: [PoseFrame]) -> Float {
        var nearest: CGFloat = .greatestFiniteMagnitude
        for frame in poseFrames {
            for ankle in [frame.leftAnkle, frame.rightAnkle].compactMap({ $0 }) where ankle.confidence > 0.30 {
                let d = distance(centroid, CGPoint(x: CGFloat(ankle.x), y: CGFloat(ankle.y)))
                nearest = min(nearest, d)
            }
        }
        guard nearest != .greatestFiniteMagnitude else { return 0 }
        let radius: CGFloat = 0.05
        return nearest >= radius ? 0 : Float(1 - nearest / radius)
    }

    /// Score (0…1) for the address blob *disappearing* from its location after
    /// impact. A struck ball leaves; a tee marker / shoe logo / sign stays. Returns
    /// high when no stable bright object remains near `centroid` post-impact.
    private func addressDisappearanceScore(centroid: CGPoint, scaledPostImpact: [(index: Int, image: CIImage)]) -> Float {
        guard scaledPostImpact.count >= 2 else { return 0.5 } // unknown → neutral
        let roi = CGRect(x: centroid.x - 0.05, y: centroid.y - 0.05, width: 0.10, height: 0.10)
        var presentCount = 0
        for (index, image) in scaledPostImpact {
            let stationary = findBrightCandidates(in: image, frameIndex: index, withinROI: roi)
                .filter { distance($0.centroid, centroid) < 0.035 && $0.pixelCount <= 250 }
            if !stationary.isEmpty { presentCount += 1 }
        }
        let presenceRatio = Float(presentCount) / Float(scaledPostImpact.count)
        // Disappears (low presence) → high score.
        return max(0, 1 - presenceRatio)
    }

    /// Impact time in the extractor's clock, found by when the address ball
    /// *leaves* its spot — the one impact signal that needs no pose, no swing
    /// model, and no club detection.
    ///
    /// Signal (validated against ground truth on both GT fixtures): the count
    /// of white-outlier pixels (luma > local median + 0.2) in a tight window
    /// around the address. The ball keeps that count high even under the
    /// golfer's shadow; after impact it collapses. Absolute counts vary with
    /// resolution and leftover tee/divot brightness, so presence is relative
    /// to the clip's own peak, and impact is the end of the LAST sustained
    /// presence run. Returns nil when no ball signal exists or it never leaves.
    func impactTimeByDisappearance(address: CGPoint, frames: [VideoFrame]) async -> TimeInterval? {
        let sorted = frames.sorted { $0.index < $1.index }
        guard sorted.count >= 8 else { return nil }

        var samples: [(time: TimeInterval, whitePixels: Int)] = []
        for (idx, frame) in sorted.enumerated() {
            if let count = whiteOutlierCount(in: frame.image, at: address) {
                samples.append((frame.timestamp, count))
            }
            if idx % 8 == 0 { await Task.yield() }
        }
        guard samples.count >= 8, let peak = samples.map(\.whitePixels).max(), peak >= 8 else {
            #if DEBUG
            print("impactTimeByDisappearance: no ball signal at address (peak \(samples.map(\.whitePixels).max() ?? 0))")
            #endif
            return nil
        }

        // Longest sustained presence run = the ball sitting at address; the
        // last run can be the golfer retrieving the tee. Require sustained
        // absence right after the run (club-crossing transients are shorter).
        let threshold = max(4, Int(Double(peak) * 0.35))
        let present = samples.map { $0.whitePixels >= threshold }
        var bestRun: (start: Int, end: Int)?
        var i = 0
        while i < present.count {
            if present[i] {
                var j = i
                while j + 1 < present.count && present[j + 1] { j += 1 }
                if j > i, j - i >= (bestRun.map { $0.end - $0.start } ?? -1) {
                    bestRun = (i, j)
                }
                i = j + 1
            } else {
                i += 1
            }
        }
        guard let run = bestRun, run.end + 3 < samples.count,
              !present[run.end + 1], !present[run.end + 2], !present[run.end + 3] else {
            #if DEBUG
            print("impactTimeByDisappearance: no clean disappearance (peak \(peak))")
            #endif
            return nil
        }
        let impact = (samples[run.end].time + samples[run.end + 1].time) / 2
        #if DEBUG
        print(String(format: "impactTimeByDisappearance: t=%.2fs (peak %d, threshold %d, %d samples)",
                     impact, peak, threshold, samples.count))
        #endif
        return impact
    }

    /// White-outlier pixel count in a tight full-resolution window around a
    /// normalized (vision y-up) point. nil when the window can't be read.
    private func whiteOutlierCount(in image: CIImage, at point: CGPoint) -> Int? {
        let extent = image.extent
        let longEdge = max(extent.width, extent.height)
        let r = max(8, Int(0.011 * longEdge))
        let ro = r * 4
        let px = extent.origin.x + point.x * extent.width
        let py = extent.origin.y + point.y * extent.height
        let crop = CGRect(x: px - CGFloat(ro), y: py - CGFloat(ro),
                          width: CGFloat(ro * 2), height: CGFloat(ro * 2))
            .intersection(extent)
        guard !crop.isEmpty, crop.width >= CGFloat(r), crop.height >= CGFloat(r),
              let cg = ciContext.createCGImage(image.cropped(to: crop), from: crop),
              let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }

        let w = cg.width
        let h = cg.height
        let bpp = max(1, cg.bitsPerPixel / 8)
        let bpr = cg.bytesPerRow
        let dataLen = CFDataGetLength(data)

        // CGImage rows are top-down; the crop's CIImage origin is bottom-left.
        let centerX = Int(px - crop.minX)
        let centerY = Int(crop.maxY - py)

        var histogram = [Int](repeating: 0, count: 256)
        var lumas = [Int](repeating: 0, count: w * h)
        for row in 0..<h {
            for col in 0..<w {
                let offset = row * bpr + col * bpp
                guard offset + 2 < dataLen else { continue }
                let luma = (Int(ptr[offset]) + Int(ptr[offset + 1]) + Int(ptr[offset + 2])) / 3
                histogram[luma] += 1
                lumas[row * w + col] = luma
            }
        }
        var cumulative = 0
        var median = 0
        let half = (w * h) / 2
        for (value, count) in histogram.enumerated() {
            cumulative += count
            if cumulative >= half { median = value; break }
        }

        let cutoff = median + 51
        var count = 0
        for row in max(0, centerY - r)..<min(h, centerY + r) {
            for col in max(0, centerX - r)..<min(w, centerX + r) where lumas[row * w + col] > cutoff {
                count += 1
            }
        }
        return count
    }

    /// Nudge the address position toward the nearest strong, small, near-ground
    /// launch-motion blob — the ball is what moves at impact, so that motion is the
    /// most precise locator. Capped so a near-miss is corrected without the centroid
    /// jumping onto the (large, fast) club head.
    private func refineToLaunchOrigin(candidate: CGPoint, motionCandidates: [BallCandidate]) -> CGPoint {
        let searchRadius: CGFloat = 0.14
        let nearby = motionCandidates.filter {
            distance($0.centroid, candidate) <= searchRadius
            && $0.pixelCount <= 160
            && $0.centroid.y <= candidate.y + 0.06   // not above the ball
        }
        // Prefer strong motion close to the ground.
        guard let origin = nearby.max(by: { a, b in
            (a.motionScore + Float(1 - a.centroid.y)) < (b.motionScore + Float(1 - b.centroid.y))
        }), origin.motionScore > 0.10 else {
            return candidate
        }

        let dx = origin.centroid.x - candidate.x
        let dy = origin.centroid.y - candidate.y
        let dist = hypot(dx, dy)
        guard dist > 0.005 else { return candidate }
        let maxMove: CGFloat = 0.07
        let factor = min(1, maxMove / dist)
        return CGPoint(x: candidate.x + dx * factor, y: candidate.y + dy * factor)
    }

    /// Local-contrast candidate generation: a golf ball is usually *locally*
    /// brighter than the surrounding turf/mat even when not pure white. More robust
    /// than an absolute brightness threshold under shade/exposure changes.
    private func findContrastCandidates(in ciImage: CIImage, frameIndex: Int, withinROI: CGRect?) -> [BallCandidate] {
        guard let cg = ciContext.createCGImage(ciImage, from: ciImage.extent),
              let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return [] }

        let w = cg.width
        let h = cg.height
        let bpp = max(1, cg.bitsPerPixel / 8)
        let bpr = cg.bytesPerRow
        let dataLen = CFDataGetLength(data)

        func luma(_ px: Int, _ py: Int) -> Float? {
            guard px >= 0, px < w, py >= 0, py < h else { return nil }
            let offset = py * bpr + px * bpp
            guard offset + 2 < dataLen else { return nil }
            return (Float(ptr[offset]) + Float(ptr[offset + 1]) + Float(ptr[offset + 2])) / 3.0
        }

        var mask = [Bool](repeating: false, count: w * h)
        var values = [Float](repeating: 0, count: w * h)
        let step = 5 // local background sampling radius (in scaled pixels)

        for py in 0..<h {
            for px in 0..<w {
                guard let centerLuma = luma(px, py) else { continue }
                // Local background = ring samples around the pixel.
                var surround: Float = 0
                var n: Float = 0
                for (dx, dy) in [(-step, 0), (step, 0), (0, -step), (0, step), (-step, -step), (step, step), (-step, step), (step, -step)] {
                    if let l = luma(px + dx, py + dy) { surround += l; n += 1 }
                }
                guard n > 0 else { continue }
                let background = surround / n
                let contrast = (centerLuma - background) / 255.0
                guard contrast > 0.10, centerLuma > 110 else { continue }

                let nx = Double(px) / Double(max(1, w - 1))
                let ny = 1.0 - Double(py) / Double(max(1, h - 1))
                if let withinROI, !withinROI.contains(CGPoint(x: nx, y: ny)) { continue }

                let idx = py * w + px
                mask[idx] = true
                values[idx] = min(1, contrast * 3.0)
            }
        }

        return connectedComponents(mask: mask, values: values, width: w, height: h)
            .compactMap { makeCandidate(from: $0, width: w, height: h, frameIndex: frameIndex, motionScore: 0) }
            .filter { $0.pixelCount >= 1 && $0.pixelCount <= 300 }
            .sorted { $0.totalScore > $1.totalScore }
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

    private func trackSeededLaunch(
        frames: [VideoFrame],
        seed: BallTrackPoint,
        cameraAngle: CameraAngle,
        onProgress: ((Double) -> Void)?
    ) async -> [BallTrackPoint] {
        let seedPoint = CGPoint(x: CGFloat(seed.x), y: CGFloat(seed.y))
        var points: [BallTrackPoint] = [seed]
        var current = seedPoint
        var velocity = CGPoint.zero
        var previousFrame: VideoFrame?
        var previousScaled: CIImage?
        var lostCount = 0
        var acceptedCount = 0
        var lastSeedDistance: CGFloat = 0

        for (idx, frame) in frames.enumerated() {
            guard let scaled = scaleImage(frame.image) else { continue }
            defer {
                previousFrame = frame
                previousScaled = scaled
            }

            if abs(frame.timestamp - seed.timestamp) < 0.0001 { continue }

            let dt = max(1.0 / 240.0, frame.timestamp - (previousFrame?.timestamp ?? seed.timestamp))
            let prediction = CGPoint(x: current.x + velocity.x * dt, y: current.y + velocity.y * dt)
            // Before the ball clearly leaves the seed, search WIDE so the launch jump
            // (rest → fast flight, a large step especially at low fps) is caught. Once
            // launched, tighten to a predictive ROI. The dt term auto-widens for low fps.
            let launched = lastSeedDistance > 0.05
            let baseRadius: CGFloat = launched ? 0.055 : 0.16
            let radius = min(0.34, baseRadius + CGFloat(lostCount) * 0.04 + CGFloat(acceptedCount) * 0.006 + CGFloat(dt) * 1.5)
            let roi = CGRect(x: prediction.x - radius, y: prediction.y - radius, width: radius * 2, height: radius * 2)

            var candidates = await detectBallCandidates(in: frame, previousFrame: previousFrame, withinROI: roi)
            candidates.append(contentsOf: findBrightCandidates(in: scaled, frameIndex: frame.index, withinROI: roi))
            if let previousScaled {
                candidates.append(contentsOf: findMotionCandidates(current: scaled, previous: previousScaled, frameIndex: frame.index, withinROI: roi))
            }

            let selected = bestSeededCandidate(
                candidates: candidates,
                seed: seedPoint,
                prediction: prediction,
                velocity: velocity,
                acceptedCount: acceptedCount,
                lastSeedDistance: lastSeedDistance,
                cameraAngle: cameraAngle
            )

            guard let selected else {
                // Before launch the ball is still sitting at the seed (no flight motion);
                // those frames must NOT count as "lost" or the tracker breaks before the
                // ball ever launches. Only penalise/break once it has launched.
                if launched {
                    lostCount += 1
                    current = prediction
                    if lostCount > 8 { break }
                }
                if idx % 8 == 0 { await Task.yield() }
                onProgress?(Double(idx + 1) / Double(frames.count))
                continue
            }

            let newVelocity = CGPoint(
                x: (selected.centroid.x - current.x) / dt,
                y: (selected.centroid.y - current.y) / dt
            )
            velocity = CGPoint(
                x: velocity.x * 0.45 + newVelocity.x * 0.55,
                y: velocity.y * 0.45 + newVelocity.y * 0.55
            )
            current = selected.centroid
            lastSeedDistance = max(lastSeedDistance, distance(current, seedPoint))
            lostCount = 0
            acceptedCount += 1

            points.append(BallTrackPoint(
                frameIndex: frame.index,
                timestamp: frame.timestamp,
                x: Float(selected.centroid.x),
                y: Float(selected.centroid.y),
                confidence: min(0.88, max(0.35, selected.totalScore))
            ))

            if acceptedCount >= 24 { break }
            if idx % 8 == 0 { await Task.yield() }
            onProgress?(Double(idx + 1) / Double(frames.count))
        }

        #if DEBUG
        print(String(format: "BallTrackingService: SEEDED flight → %d points (accepted=%d, lastSeedDist=%.3f, cameraAngle=%@)",
                     points.count, acceptedCount, lastSeedDistance, cameraAngle.rawValue))
        #endif
        onProgress?(1.0)
        return points
    }

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

            let detectorCandidates = await detectBallCandidates(in: frame, previousFrame: previousFrame, withinROI: roi)
            let brightCandidates = findBrightCandidates(in: scaled, frameIndex: frame.index, withinROI: roi)
            var motionCandidates: [BallCandidate] = []
            if let previousScaled {
                motionCandidates = findMotionCandidates(current: scaled, previous: previousScaled, frameIndex: frame.index, withinROI: roi)
            }
            let candidates = hybridLaunchCandidates(
                motionCandidates: motionCandidates + detectorCandidates.filter { $0.motionScore > 0 || $0.totalScore >= 0.15 },
                brightCandidates: brightCandidates + detectorCandidates,
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

            let brightSupport = nearestBright?.totalScore ?? min(0.18, motion.totalScore * 0.35)
            let mergedPoint: CGPoint
            if let nearestBright {
                mergedPoint = CGPoint(
                    x: motion.centroid.x * 0.72 + nearestBright.centroid.x * 0.28,
                    y: motion.centroid.y * 0.72 + nearestBright.centroid.y * 0.28
                )
            } else {
                mergedPoint = motion.centroid
            }

            let total = max(0, min(1, motion.motionScore * 0.50 + motion.shapeScore * 0.24 + motion.totalScore * 0.18 + brightSupport * 0.08))

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

    private func bestSeededCandidate(
        candidates: [BallCandidate],
        seed: CGPoint,
        prediction: CGPoint,
        velocity: CGPoint,
        acceptedCount: Int,
        lastSeedDistance: CGFloat,
        cameraAngle: CameraAngle
    ) -> BallCandidate? {
        let scored = candidates
            .filter {
                $0.pixelCount <= 160
                && $0.shapeScore >= 0.10
                && isPlausibleSeededFlight(
                    candidate: $0.centroid,
                    seed: seed,
                    acceptedCount: acceptedCount,
                    lastSeedDistance: lastSeedDistance,
                    cameraAngle: cameraAngle
                )
            }
            .map { candidate -> BallCandidate in
                let predictionDistance = distance(candidate.centroid, prediction)
                let predictionScore = max(0, 1 - Float(predictionDistance / 0.16))
                let directionScore = directionContinuity(candidate: candidate.centroid, prediction: prediction, velocity: velocity, cameraAngle: cameraAngle)
                let seedDistance = distance(candidate.centroid, seed)
                let seedPenalty = seedDistance < 0.003 ? Float(0.08) : 0
                let total = max(
                    0,
                    candidate.totalScore * 0.30
                    + candidate.motionScore * 0.34
                    + candidate.shapeScore * 0.14
                    + predictionScore * 0.16
                    + directionScore * 0.10
                    - seedPenalty
                )

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
                    rejectionReason: total < 0.22 ? "low-seeded-score" : nil
                )
            }
            .sorted { $0.totalScore > $1.totalScore }

        guard let best = scored.first, best.totalScore >= 0.22 else { return nil }
        return best
    }

    private func isPlausibleSeededFlight(
        candidate: CGPoint,
        seed: CGPoint,
        acceptedCount: Int,
        lastSeedDistance: CGFloat,
        cameraAngle: CameraAngle
    ) -> Bool {
        let dx = abs(candidate.x - seed.x)
        let dy = candidate.y - seed.y
        let distanceFromSeed = distance(candidate, seed)

        guard distanceFromSeed >= 0.003 else { return false }
        if acceptedCount > 0, distanceFromSeed + 0.025 < lastSeedDistance {
            return false
        }

        switch cameraAngle {
        case .behindBallFlight, .downTheLine:
            guard dy >= -0.012 else { return false }
            if distanceFromSeed > 0.025 {
                guard dy >= dx * 0.18 else { return false }
            }
            return true
        case .faceOn, .unknown:
            return true
        }
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

            // A real ball flight rises and moves out — accept diagonal trajectories,
            // only reject trails that are essentially flat or going downward (likely a
            // club sweep or noise). The previous 0.55 ratio wrongly discarded normal
            // up-and-out shots (e.g. dx=0.38, dy=0.20 ≈ 28°).
            guard dy > 0.01, abs(dy) >= dx * 0.15 else {
                #if DEBUG
                print("BallTrackingService: rejected flat/descending golf trail dx=\(dx), dy=\(dy), cameraAngle=\(cameraAngle.rawValue)")
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

    private func detectBallCandidates(
        in frame: VideoFrame,
        previousFrame: VideoFrame?,
        withinROI roi: CGRect?
    ) async -> [BallCandidate] {
        let detections = await detector.detectCandidates(
            in: frame,
            region: BallDetectionRegion(normalizedRect: normalizedSearchRect(roi)),
            context: BallDetectorContext(previousFrame: previousFrame)
        )

        return detections.map { ballCandidate(from: $0) }
    }

    private func ballCandidate(from detection: BallDetectionCandidate) -> BallCandidate {
        let inferredPixelCount = Float(max(2, detection.boundingBox.width * detection.boundingBox.height * 20_000))
        let pixelCount = Int(detection.features["pixel_count"] ?? inferredPixelCount)
        let motionScore = detection.features["motion_score"] ?? (detection.source == .heuristic ? detection.confidence : 0)
        let shapeScore = detection.features["shape_score"] ?? detection.confidence
        let detectorScore = detection.features["class_confidence"] ?? detection.features["detector_score"] ?? detection.confidence
        let totalScore: Float

        switch detection.source {
        case .coreML:
            totalScore = min(1, detection.confidence * 0.78 + shapeScore * 0.12 + motionScore * 0.10)
        case .hybrid:
            totalScore = min(1, detection.confidence * 0.72 + detectorScore * 0.18 + motionScore * 0.10)
        case .heuristic:
            totalScore = min(1, detection.confidence)
        }

        return BallCandidate(
            frameIndex: detection.frameIndex,
            centroid: detection.center,
            boundingBox: detection.boundingBox,
            pixelCount: max(2, pixelCount),
            whitenessScore: detectorScore,
            motionScore: motionScore,
            shapeScore: shapeScore,
            stabilityScore: detection.source == .coreML ? detection.confidence : (detection.features["candidate_count"] ?? 0),
            totalScore: totalScore,
            rejectionReason: totalScore < 0.15 ? "low-detector-score" : nil
        )
    }

    private func normalizedSearchRect(_ roi: CGRect?) -> CGRect {
        guard let roi else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        let x = max(0, roi.minX)
        let y = max(0, roi.minY)
        let maxX = min(1, roi.maxX)
        let maxY = min(1, roi.maxY)

        guard maxX > x, maxY > y else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        return CGRect(x: x, y: y, width: maxX - x, height: maxY - y)
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

    private func findStableObjectCandidates(current: CIImage, previous: CIImage, frameIndex: Int, withinROI: CGRect?) -> [BallCandidate] {
        guard let currentCG = ciContext.createCGImage(current, from: current.extent),
              let previousCG = ciContext.createCGImage(previous, from: previous.extent),
              currentCG.width == previousCG.width,
              currentCG.height == previousCG.height,
              let currentData = currentCG.dataProvider?.data,
              let previousData = previousCG.dataProvider?.data,
              let currentPtr = CFDataGetBytePtr(currentData),
              let previousPtr = CFDataGetBytePtr(previousData) else { return [] }

        let w = currentCG.width
        let h = currentCG.height
        let bpp = max(1, currentCG.bitsPerPixel / 8)
        let bpr = currentCG.bytesPerRow
        let dataLen = min(CFDataGetLength(currentData), CFDataGetLength(previousData))

        var stable = [Bool](repeating: false, count: w * h)
        var values = [Float](repeating: 0, count: w * h)

        for py in 0..<h {
            for px in 0..<w {
                let offset = py * bpr + px * bpp
                guard offset + 2 < dataLen else { continue }

                let c0 = Double(currentPtr[offset])
                let c1 = Double(currentPtr[offset + 1])
                let c2 = Double(currentPtr[offset + 2])
                let p0 = Double(previousPtr[offset])
                let p1 = Double(previousPtr[offset + 1])
                let p2 = Double(previousPtr[offset + 2])

                let brightness = (c0 + c1 + c2) / 765.0
                let balance = 1.0 - min(1.0, (abs(c0 - c1) + abs(c1 - c2) + abs(c0 - c2)) / 255.0)
                let frameDelta = (abs(c0 - p0) + abs(c1 - p1) + abs(c2 - p2)) / 765.0

                guard brightness > 0.44, balance > 0.28, frameDelta < 0.12 else { continue }

                let nx = Double(px) / Double(max(1, w - 1))
                let ny = 1.0 - Double(py) / Double(max(1, h - 1))
                if let withinROI, !withinROI.contains(CGPoint(x: nx, y: ny)) { continue }

                let idx = py * w + px
                stable[idx] = true
                values[idx] = Float(brightness * 0.58 + balance * 0.22 + (1.0 - frameDelta) * 0.20)
            }
        }

        return connectedComponents(mask: stable, values: values, width: w, height: h)
            .compactMap { makeCandidate(from: $0, width: w, height: h, frameIndex: frameIndex, motionScore: 0) }
            .filter { $0.pixelCount >= 2 && $0.pixelCount <= 320 }
            .sorted { $0.totalScore > $1.totalScore }
    }

    private func addressSearchROI(bodyMask: CGRect?) -> CGRect {
        let lowerBand = CGRect(x: 0.06, y: 0.04, width: 0.88, height: 0.34)
        guard let bodyMask else { return lowerBand }

        let feetRegion = CGRect(
            x: max(0.04, bodyMask.minX - 0.32),
            y: 0.04,
            width: min(0.92, bodyMask.width + 0.64),
            height: min(0.34, max(0.18, bodyMask.minY + 0.18))
        )
        let intersection = lowerBand.intersection(feetRegion)
        return intersection.isNull ? lowerBand : intersection
    }

    private func addressGroundScore(_ point: CGPoint) -> Float {
        guard point.y >= 0.04, point.y <= 0.38 else { return 0 }
        let preferredY: CGFloat = 0.16
        return max(0, 1 - Float(abs(point.y - preferredY) / 0.18))
    }

    private func addressHorizontalScore(_ point: CGPoint) -> Float {
        guard point.x >= 0.08, point.x <= 0.92 else { return 0 }
        return max(0, 1 - Float(abs(point.x - 0.5) / 0.55))
    }

    private func addressSizeScore(_ pixelCount: Int) -> Float {
        max(0, 1 - abs(Float(pixelCount) - 24) / 90)
    }

    private func addressImpactMotionCandidates(
        frames: [VideoFrame],
        impactWindow: ImpactWindow,
        withinROI roi: CGRect?
    ) async -> [BallCandidate] {
        let radius = max(10, typicalFrameStep(frames.map(\.index)) * 5)
        let lower = impactWindow.estimatedFrameIndex - radius
        let upper = impactWindow.estimatedFrameIndex + radius
        let windowFrames = frames
            .filter { $0.index >= lower && $0.index <= upper }
            .sorted { $0.index < $1.index }

        guard windowFrames.count >= 2 else { return [] }

        var candidates: [BallCandidate] = []
        var previousScaled: CIImage?
        var previousFrame: VideoFrame?
        for frame in windowFrames {
            guard let scaled = scaleImage(frame.image) else { continue }
            candidates.append(contentsOf: await detectBallCandidates(in: frame, previousFrame: previousFrame, withinROI: roi))
            if let previousScaled {
                candidates.append(contentsOf: findMotionCandidates(
                    current: scaled,
                    previous: previousScaled,
                    frameIndex: frame.index,
                    withinROI: roi
                ))
            }
            previousScaled = scaled
            previousFrame = frame
        }

        return candidates
            .filter { $0.pixelCount >= 2 && $0.pixelCount <= 700 }
            .sorted { $0.totalScore > $1.totalScore }
    }

    private func nearestImpactMotionScore(to point: CGPoint, candidates: [BallCandidate]) -> Float {
        guard !candidates.isEmpty else { return 0 }
        let searchRadius: CGFloat = 0.060
        return candidates.reduce(Float(0)) { best, candidate in
            let d = distance(point, candidate.centroid)
            guard d <= searchRadius else { return best }
            let proximity = Float(1 - d / searchRadius)
            let score = min(1, candidate.totalScore * 0.65 + candidate.motionScore * 0.35) * proximity
            return max(best, score)
        }
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
        // Circularity: a round disc has aspect ≈ 1 and fill ≈ π/4 ≈ 0.785. Independent
        // of absolute size so a large clean ball is not penalised.
        let fillError = min(1, abs(fill - 0.785) / 0.5)
        let shapeScore = max(0, min(1, aspect * 0.6 + (1 - fillError) * 0.4))
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
