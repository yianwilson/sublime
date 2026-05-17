import SwiftUI
import UIKit

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.green)
            Text(title)
                .font(.headline)
        }
        .padding(.horizontal, 20)
    }
}

// MARK: - Confidence Badge

struct ConfidenceBadge: View {
    let label: String
    let confidence: Float

    private var color: Color {
        confidence >= 0.7 ? .green : confidence >= 0.4 ? .orange : .red
    }

    private var text: String {
        confidence >= 0.7 ? "High" : confidence >= 0.4 ? "Medium" : "Low"
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(text + " confidence")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(color)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Shot Shape Badge

struct ShotShapeBadge: View {
    let shape: ShotShape
    let confidence: Float

    var body: some View {
        VStack(spacing: 4) {
            Text("Shot Shape")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(confidence >= 0.45 ? shape.displayName : "Unknown")
                .font(.caption.weight(.semibold))
                .foregroundStyle(confidence > 0.4 ? .primary : .secondary)
            Text(confidence >= 0.45 ? "Tracked" : "Not enough track")
                .font(.caption2)
                .foregroundStyle(confidence >= 0.45 ? .green : .orange)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Low Confidence Banner

struct LowConfidenceBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.subheadline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.2), lineWidth: 1))
    }
}

// MARK: - Metric Card

struct MetricCard: View {
    let metric: AnalysisMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(metric.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(metric.displayValue)
                .font(.title3.weight(.bold))
                .foregroundStyle(metric.isLowConfidence ? .secondary : .primary)

            if metric.isLowConfidence {
                Text("Low confidence")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                ConfidenceBar(value: Double(metric.confidence))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct ConfidenceBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(.systemGray5))
                    .frame(height: 4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(value >= 0.7 ? Color.green : value >= 0.4 ? Color.orange : Color.red)
                    .frame(width: geo.size.width * value, height: 4)
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Feedback Card

struct FeedbackCard: View {
    let item: FeedbackItem

    private var borderColor: Color {
        switch item.severity {
        case .positive: return .green
        case .warning: return .orange
        case .info: return .blue
        }
    }

    private var icon: String {
        switch item.severity {
        case .positive: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(borderColor)
                .font(.title3)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if item.isLowConfidence {
                        Text("Low confidence")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(borderColor.opacity(0.3), lineWidth: 1.5))
    }
}

// MARK: - Session Thumbnail Card (home screen)

struct SessionThumbnailCard: View {
    let session: PracticeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnailImage
                .frame(width: 140, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(session.sportType.displayName)
                .font(.caption.weight(.semibold))
            Text(session.createdAt.formatted(date: .abbreviated, time: .omitted))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 140)
    }

    private var thumbnailImage: some View {
        Group {
            if let path = session.thumbnailLocalPath,
               let image = UIImage(contentsOfFile: path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(.systemGray5)
                    Image(systemName: session.sportType.iconName)
                        .font(.largeTitle)
                        .foregroundStyle(.green.opacity(0.6))
                }
            }
        }
    }
}
