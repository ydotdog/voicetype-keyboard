import SwiftUI

enum AppTheme {
    static let background = Color(red: 0.965, green: 0.972, blue: 0.964)
    static let surface = Color.white
    static let ink = Color(red: 0.070, green: 0.085, blue: 0.100)
    static let secondary = Color(red: 0.360, green: 0.390, blue: 0.410)
    static let accent = Color(red: 0.080, green: 0.560, blue: 0.760)
    static let coral = Color(red: 0.940, green: 0.360, blue: 0.240)
    static let mint = Color(red: 0.060, green: 0.600, blue: 0.430)
    static let border = Color.black.opacity(0.08)

    static var appGradient: LinearGradient {
        LinearGradient(
            colors: [accent, mint],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension View {
    func panelStyle() -> some View {
        padding(18)
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            }
    }
}
