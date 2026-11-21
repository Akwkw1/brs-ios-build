import SwiftUI

enum Theme {
    static let gold = Color(red: 1.00, green: 0.77, blue: 0.00)
    static let goldDim = Color(red: 0.72, green: 0.56, blue: 0.10)
    static let bg = Color(red: 0.059, green: 0.059, blue: 0.063)
    static let card = Color(red: 0.090, green: 0.090, blue: 0.102)
    static let border = Color(red: 0.227, green: 0.204, blue: 0.094)
    static let text = Color(red: 0.941, green: 0.906, blue: 0.776)
    static let sub = Color(red: 0.553, green: 0.522, blue: 0.439)
    static let ok = Color(red: 0.32, green: 0.85, blue: 0.45)
    static let warn = Color(red: 1.00, green: 0.45, blue: 0.32)
}

struct Card<Content: View>: View {
    var content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }
}

struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.gold)
            .padding(.top, 6)
    }
}

struct Pill: View {
    let text: String
    var color: Color = Theme.sub

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

struct Bar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.border.opacity(0.5))
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.gold)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: 6)
    }
}
