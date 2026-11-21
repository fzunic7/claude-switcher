import AppKit
import SwiftUI

/// `ClaudeSwitcher --assets <dir>` draws the app icon (iconset PNGs) and the DMG background.
@MainActor
enum BrandAssets {
    static func renderIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--assets"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        let iconset = dir.appendingPathComponent("AppIcon.iconset")
        try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

        for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
            for scale in scales {
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                write(AppIconView().frame(width: 1024, height: 1024), size: CGFloat(points * scale) / 1024,
                      to: iconset.appendingPathComponent(name))
            }
        }
        for scale in [1, 2] {
            write(DMGBackground().frame(width: 660, height: 400), size: CGFloat(scale),
                  to: dir.appendingPathComponent(scale == 1 ? "dmg-background.png" : "dmg-background@2x.png"))
        }
        print("wrote assets to \(dir.path)")
        exit(0)
    }

    private static func write<V: View>(_ view: V, size scale: CGFloat, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}

/// A rounded square with two overlapping account badges and a swap arrow.
struct AppIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 230, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.62, blue: 0.36), Color(red: 0.85, green: 0.36, blue: 0.24)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
            ZStack {
                Circle().fill(.white.opacity(0.28)).frame(width: 360, height: 360).offset(x: -110, y: -60)
                Circle().fill(.white).frame(width: 360, height: 360).offset(x: 110, y: 60)
                Image(systemName: "person.fill").font(.system(size: 190, weight: .bold))
                    .foregroundStyle(Color(red: 0.85, green: 0.36, blue: 0.24)).offset(x: 110, y: 60)
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 150, weight: .heavy))
                    .foregroundStyle(.white).offset(x: -150, y: 200)
            }
        }
        .frame(width: 1024, height: 1024)
    }
}

/// Background for the DMG window: "Drag to Applications" with an arrow between the two icons.
struct DMGBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.93, green: 0.95, blue: 0.99), Color(red: 0.99, green: 0.93, blue: 0.90)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text("Drag to Applications to install")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color(white: 0.25))
                .position(x: 330, y: 70)
            Arrow()
                .stroke(Color(white: 0.2), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                .frame(width: 160, height: 60)
                .position(x: 330, y: 190)
        }
        .frame(width: 660, height: 400)
    }
}

struct Arrow: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY - 10))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - 10), control: CGPoint(x: r.midX, y: r.minY - 30))
        // Arrowhead along the curve's direction at its end (down and to the right).
        let tip = CGPoint(x: r.maxX, y: r.maxY - 10)
        p.move(to: CGPoint(x: tip.x - 24, y: tip.y - 6))
        p.addLine(to: tip)
        p.addLine(to: CGPoint(x: tip.x - 6, y: tip.y - 24))
        return p
    }
}
