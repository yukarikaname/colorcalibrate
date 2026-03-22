import SwiftUI

struct CalibrationHeroCard: View {
    let title: String
    let subtitle: String
    let color: RGBColor
    let profile: CalibrationProfile?

    var body: some View {
        let visibleColor = color.applying(profile: profile)

        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title.bold())
            Text(subtitle)
                .foregroundStyle(.secondary)

            RoundedRectangle(cornerRadius: 28)
                .fill(visibleColor.swiftUIColor)
                .frame(maxWidth: .infinity, minHeight: 280)
                .overlay(alignment: .bottomLeading) {
                    Text(visibleColor.description)
                        .font(.headline.monospacedDigit())
                        .padding(18)
                        .foregroundStyle(
                            visibleColor.red + visibleColor.green + visibleColor.blue > 1.5
                                ? .black : .white)
                }
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32))
    }
}

struct ComparisonSwatchGrid: View {
    let profile: CalibrationProfile?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
            ForEach(SwatchExample.examples) { swatch in
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 22)
                        .fill(swatch.color.applying(profile: profile).swiftUIColor)
                        .frame(height: 112)

                    Text(swatch.title)
                        .font(.headline)
                    Text(swatch.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
            }
        }
    }
}

struct StatusPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(.thinMaterial, in: Capsule())
    }
}
