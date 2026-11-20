import AppKit
import SwiftUI

/// A color taken from the screen, in sRGB.
struct PickedColor: Codable, Equatable, Identifiable {
    var red: Int
    var green: Int
    var blue: Int

    var id: String { hex }

    init(red: Int, green: Int, blue: Int) {
        self.red = min(255, max(0, red))
        self.green = min(255, max(0, green))
        self.blue = min(255, max(0, blue))
    }

    init?(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(red: Int((rgb.redComponent * 255).rounded()), green: Int((rgb.greenComponent * 255).rounded()),
                  blue: Int((rgb.blueComponent * 255).rounded()))
    }

    var color: Color { Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255) }
    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    var rgb: String { "rgb(\(red), \(green), \(blue))" }

    var hsl: String {
        let r = Double(red) / 255, g = Double(green) / 255, b = Double(blue) / 255
        let high = max(r, g, b), low = min(r, g, b), spread = high - low
        let light = (high + low) / 2
        var hue = 0.0, saturation = 0.0
        if spread > 0 {
            saturation = spread / (1 - abs(2 * light - 1))
            switch high {
            case r: hue = ((g - b) / spread).truncatingRemainder(dividingBy: 6)
            case g: hue = (b - r) / spread + 2
            default: hue = (r - g) / spread + 4
            }
            hue *= 60
            if hue < 0 { hue += 360 }
        }
        return "hsl(\(Int(hue.rounded())), \(Int((saturation * 100).rounded()))%, \(Int((light * 100).rounded()))%)"
    }

    func text(_ format: Preferences.ColorFormat) -> String {
        switch format {
        case .hex: hex
        case .rgb: rgb
        case .hsl: hsl
        }
    }

    /// Whether dark text reads better on it than light.
    var isLight: Bool { (0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue)) > 150 }
}

/// The last few colors picked, kept across restarts.
@Observable
final class ColorStore {
    private(set) var recent: [PickedColor] = []
    @ObservationIgnored private var previewing = false
    private static let key = "pickedColors"
    static let limit = 9

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([PickedColor].self, from: data) {
            recent = Array(saved.prefix(Self.limit))
        }
    }

    func add(_ color: PickedColor) {
        recent.removeAll { $0 == color }
        recent.insert(color, at: 0)
        recent = Array(recent.prefix(Self.limit))
        guard !previewing, let data = try? JSONEncoder().encode(recent) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    func copy(_ text: String) {
        guard !previewing else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// For snapshots.
    func setPreview(_ colors: [PickedColor]) {
        previewing = true
        recent = colors
    }
}

/// The picked color in the open island: a swatch, its value three ways (click
/// one to copy it), and the colors picked before.
struct ColorPanel: View {
    let model: IslandModel
    @State private var selected: PickedColor?
    @State private var copied: Preferences.ColorFormat?
    private var store: ColorStore { model.colors }

    static let bodyHeight: CGFloat = 132

    private var color: PickedColor? { selected ?? store.recent.first }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(color?.color ?? Color.white.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
                    .frame(width: 76, height: 76)
                    .animation(model.prefs.settle(growing: true), value: color)
                Button { model.pickColor() } label: {
                    Label("Pick", systemImage: "eyedropper")
                }
                .buttonStyle(PillButtonStyle(compact: true))
                .help("Pick a color from the screen")
            }
            VStack(alignment: .leading, spacing: 4) {
                if let color {
                    ForEach(Preferences.ColorFormat.allCases) { format in
                        valueRow(format, color.text(format))
                    }
                } else {
                    Text("Nothing picked yet")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(height: 24)
                }
                HStack(spacing: 5) {
                    ForEach(store.recent) { item in
                        Button { selected = item } label: {
                            Circle()
                                .fill(item.color)
                                .overlay(Circle().strokeBorder(.white.opacity(item == color ? 0.9 : 0.2), lineWidth: item == color ? 1.5 : 1))
                                .frame(width: 18, height: 18)
                                .contentShape(Circle())
                        }
                        .buttonStyle(PressStyle())
                        .help(item.hex)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.setTool(nil) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            .help("Close")
        }
        .padding(.top, model.contentTop - 2)
        .padding(.horizontal, Layout.sidePadding)
        .frame(height: model.contentTop + Self.bodyHeight, alignment: .top)
        .staggered(0)
    }

    private func valueRow(_ format: Preferences.ColorFormat, _ value: String) -> some View {
        Button {
            store.copy(value)
            copied = format
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                if copied == format { copied = nil }
            }
        } label: {
            HStack(spacing: 8) {
                Text(format.title)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 28, alignment: .leading)
                Text(value)
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                Spacer(minLength: 4)
                Image(systemName: copied == format ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(copied == format ? Color.chargeGreen : .white.opacity(0.35))
                    .contentTransition(.symbolEffect(.replace))
            }
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.07)))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .help("Copy \(value)")
    }
}
