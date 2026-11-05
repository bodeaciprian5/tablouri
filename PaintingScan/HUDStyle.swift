import SwiftUI

/// Shared look for the capture HUD: dark translucent panels, small caps labels, monospaced numbers.
extension View {
    func hudPanel(cornerRadius: CGFloat = 14) -> some View {
        self
            .padding(10)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(.white.opacity(0.12)))
    }
}

struct HUDLabel: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            Text(value).font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
        }
    }
}

struct RailButton: View {
    let systemImage: String
    var isOn: Bool = false
    var size: CGFloat = 44
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.41, weight: .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(isOn ? .black : .white)
                .background(isOn ? Color.yellow : Color.white.opacity(0.08), in: Circle())
        }
    }
}

struct Pill: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.black.opacity(0.5), in: Capsule())
        .foregroundStyle(.white)
    }
}
