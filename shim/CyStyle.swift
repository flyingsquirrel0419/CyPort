// CyStyle.swift - the look the start screen (Launcher.swift) set, shared by every CyPort screen: black-to-plum
// gradient with neon edges, the italic CYPORT title, 10 pt outlined cards, heavy upper-case yellow buttons.
import SwiftUI

let cyberYellow = Color(red: 0.99, green: 0.93, blue: 0.04)
let cyberRed = Color(red: 1.0, green: 0.0, blue: 0.24)

/// the start screen's background: gradient, a yellow line on top and a red one at the bottom
struct CyBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.black, Color(red: 0.08, green: 0.02, blue: 0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack { Rectangle().fill(cyberYellow).frame(height: 3); Spacer(); Rectangle().fill(cyberRed.opacity(0.8)).frame(height: 2) }
        }
        .ignoresSafeArea()
    }
}

/// CYPORT with a line under it, like the start screen's title
struct CyTitle: View {
    let subtitle: String
    var size: CGFloat = 52
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CYPORT")
                .font(.system(size: size, weight: .black)).italic()
                .foregroundStyle(cyberYellow)
                .shadow(color: cyberRed.opacity(0.6), radius: 0, x: 3, y: 2)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(subtitle.uppercased())
                .font(.system(size: 13, weight: .heavy, design: .monospaced)).tracking(3)
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

/// a section heading inside a screen ("STEAM", "DOWNLOADING")
struct CyHeading: View {
    let text: String
    var icon: String?
    var body: some View {
        Group {
            if let icon { Label(text.uppercased(), systemImage: icon) } else { Text(text.uppercased()) }
        }
        .font(.system(size: 13, weight: .heavy, design: .monospaced)).tracking(2)
        .foregroundStyle(cyberYellow)
    }
}

extension View {
    /// the start screen's boxed row; `selected` outlines it in yellow
    func cyCard(selected: Bool = false) -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(selected ? 0.1 : 0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? cyberYellow.opacity(0.8) : .white.opacity(0.15), lineWidth: selected ? 1.5 : 1))
    }
    /// small grey explanation text
    func cyNote() -> some View {
        font(.caption).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
    }
}

/// yellow, black heavy upper-case text (PLAY, UPDATE CYBERPUNK)
struct CyPrimaryButtonStyle: ButtonStyle {
    var fill = false
    func makeBody(configuration: Configuration) -> some View { Body(configuration: configuration, fill: fill) }
    private struct Body: View {
        let configuration: Configuration
        let fill: Bool
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.subheadline.weight(.heavy)).tracking(1).textCase(.uppercase)
                .foregroundStyle(.black)
                .padding(.horizontal, 18).frame(minHeight: 44)
                .frame(maxWidth: fill ? .infinity : nil)
                .background(cyberYellow.opacity(enabled ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 10))
                .shadow(color: cyberYellow.opacity(enabled ? 0.3 : 0), radius: 10)
                .opacity(configuration.isPressed ? 0.75 : 1)
        }
    }
}

/// outlined yellow (Sign in, Back)
struct CySecondaryButtonStyle: ButtonStyle {
    var fill = false
    func makeBody(configuration: Configuration) -> some View { Body(configuration: configuration, fill: fill) }
    private struct Body: View {
        let configuration: Configuration
        let fill: Bool
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(cyberYellow.opacity(enabled ? 1 : 0.4))
                .padding(.horizontal, 16).frame(minHeight: 40)
                .frame(maxWidth: fill ? .infinity : nil)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(cyberYellow.opacity(enabled ? 0.6 : 0.2)))
                .opacity(configuration.isPressed ? 0.7 : 1)
        }
    }
}

/// a yellow progress bar with the numbers under it
struct CyProgress: View {
    let done: Int64, total: Int64
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.1))
                RoundedRectangle(cornerRadius: 3).fill(cyberYellow)
                    .frame(width: g.size.width * CGFloat(total > 0 ? min(1, Double(done) / Double(total)) : 0))
                    .shadow(color: cyberYellow.opacity(0.5), radius: 6)
            }
        }
        .frame(height: 6)
    }
}
