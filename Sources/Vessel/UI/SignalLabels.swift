import SwiftUI

/// A band or signal type, as a label of white text on its own colour.
struct SignalLabel: Equatable, Identifiable {
    let text: String
    /// 0xRRGGBB, each dark enough for white text to read on.
    let color: UInt32
    var id: String { text }

    /// The usual radio band names.
    static func band(hz: Double) -> SignalLabel? {
        let table: [(limit: Double, text: String, color: UInt32)] = [
            (30e6, "HF", 0x15803D), (300e6, "VHF", 0x2563EB), (1e9, "UHF", 0x7C3AED), (2e9, "L", 0x0F766E),
            (4e9, "S", 0x0369A1), (8e9, "C", 0xB45309), (12e9, "X", 0xBE185D), (18e9, "Ku", 0x4338CA),
            (27e9, "K", 0x6D28D9), (40e9, "Ka", 0x7E22CE),
        ]
        guard hz > 0, let row = table.first(where: { hz < $0.limit }) else { return nil }
        return SignalLabel(text: row.text, color: row.color)
    }

    private static let modes: [(name: String, shown: String, color: UInt32)] = [
        ("DVB-S2", "DVB-S2", 0xB91C1C), ("BPSK", "BPSK", 0xBE123C), ("QPSK", "QPSK", 0x9D174D), ("QSPK", "QPSK", 0x9D174D),
        ("GMSK", "GMSK", 0x1D4ED8), ("GFSK", "GFSK", 0x1E40AF), ("AFSK", "AFSK", 0x047857), ("FSK", "FSK", 0x0E7490),
        ("MSK", "MSK", 0x3730A3), ("LORA", "LoRa", 0x86198F), ("SSTV", "SSTV", 0xA21CAF), ("SSDV", "SSDV", 0x701A75),
        ("APRS", "APRS", 0x065F46), ("OFDM", "OFDM", 0x7F1D1D), ("DUV", "DUV", 0x334155), ("JAS", "JAS", 0x57534E),
        ("SSB", "SSB", 0x166534), ("USB", "USB", 0x14532D), ("LSB", "LSB", 0x365314), ("CW", "CW", 0x4B5563),
        ("FM", "FM", 0xC2410C), ("AM", "AM", 0xA16207),
    ]

    /// Every signal type named in a listing like "9k6BPSK* QSPK FM* SSDV*", in the order they're given.
    static func modes(in text: String) -> [SignalLabel] {
        let upper = text.uppercased()
        var found: [(at: Int, label: SignalLabel)] = []
        for mode in modes {
            let pattern = "(?<![A-Z])" + NSRegularExpression.escapedPattern(for: mode.name) + "(?![A-Z])"
            guard let r = upper.range(of: pattern, options: .regularExpression) else { continue }
            let at = upper.distance(from: upper.startIndex, to: r.lowerBound)
            if !found.contains(where: { $0.label.text == mode.shown }) {
                found.append((at, SignalLabel(text: mode.shown, color: mode.color)))
            }
        }
        return found.sorted { $0.at < $1.at }.map(\.label)
    }

    static func all(hz: Double, mode: String?) -> [SignalLabel] {
        (band(hz: hz).map { [$0] } ?? []) + modes(in: mode ?? "")
    }

    /// WCAG's measure against white, which should be 4.5 or more for text this small.
    static func contrastWithWhite(_ rgb: UInt32) -> Double {
        func linear(_ v: UInt32) -> Double {
            let c = Double(v & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb >> 16) + 0.7152 * linear(rgb >> 8) + 0.0722 * linear(rgb)
        return 1.05 / (luminance + 0.05)
    }

    /// For checking the colours as a set.
    static var everyColor: [UInt32] {
        let bands = [1e6, 100e6, 500e6, 1.5e9, 3e9, 5e9, 10e9, 14e9, 20e9, 30e9].compactMap { band(hz: $0)?.color }
        return bands + modes.map(\.color)
    }
}

struct SignalLabels: View {
    let labels: [SignalLabel]

    var body: some View {
        WrappingRow(spacing: 3) {
            ForEach(labels) { label in
                Text(label.text)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Color(hex: label.color), in: RoundedRectangle(cornerRadius: 3))
            }
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Lays its items out in a line, continuing on the next when they don't fit.
struct WrappingRow: Layout {
    var spacing: CGFloat = 4

    private func rows(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, places: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        var places: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += line + spacing
                line = 0
            }
            places.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + line), places)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let places = rows(subviews, width: bounds.width).places
        for (view, at) in zip(subviews, places) {
            view.place(at: CGPoint(x: bounds.minX + at.x, y: bounds.minY + at.y), proposal: .unspecified)
        }
    }
}
