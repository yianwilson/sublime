import Foundation

enum SportType: String, Codable, CaseIterable, Identifiable {
    case golf
    case tennis

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .golf: return "Golf"
        case .tennis: return "Tennis"
        }
    }

    var iconName: String {
        switch self {
        case .golf: return "figure.golf"
        case .tennis: return "figure.tennis"
        }
    }
}

enum GolfMode: String, Codable, CaseIterable, Identifiable {
    case range

    var id: String { rawValue }
    var displayName: String { "Range" }
}

enum TennisMode: String, Codable, CaseIterable, Identifiable {
    case serve
    case rally
    case forehand
    case backhand

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .serve: return "Serve"
        case .rally: return "Rally"
        case .forehand: return "Forehand"
        case .backhand: return "Backhand"
        }
    }
}

enum CameraAngle: String, Codable, CaseIterable, Identifiable {
    case downTheLine
    case faceOn
    case behindBallFlight
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .downTheLine: return "Down the Line"
        case .faceOn: return "Face On"
        case .behindBallFlight: return "Behind Ball Flight"
        case .unknown: return "Unknown"
        }
    }

    static var golfAngles: [CameraAngle] { [.downTheLine, .faceOn, .behindBallFlight] }
    static var tennisAngles: [CameraAngle] { [.faceOn, .downTheLine] }
}

enum ShotShape: String, Codable, Equatable {
    case straight
    case fadeOrSlice
    case drawOrHook
    case unknown

    var displayName: String {
        switch self {
        case .straight: return "Straight"
        case .fadeOrSlice: return "Fade / Slice"
        case .drawOrHook: return "Draw / Hook"
        case .unknown: return "Unknown"
        }
    }
}
