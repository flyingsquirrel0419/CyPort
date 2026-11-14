// The first screen of a CyPort built without a game (GitHub Actions, build.sh NO_GAME=1): sign in to Steam, get the
// Mac game program onto the phone and turn it into an IPA to install over this app (GameInstaller.swift).
// Opened by the shim's starter (MacShimMain in MacShim.m) when the app has no Games/<version>/.
import SwiftUI
import UIKit

@objc(MSInstallerUI)
final class MSInstallerUI: NSObject {
    @MainActor @objc static func make() -> UIViewController {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let vc = UIHostingController(rootView: InstallerView(model: InstallerModel(GameInstaller(documents: docs))))
        vc.view.backgroundColor = .black
        return vc
    }
}

@MainActor
final class InstallerModel: ObservableObject {
    enum Phase { case start, working(String), ready(GameInstaller.Prepared), downloading, done(GameInstaller.Result), failed(String) }
    @Published var phase: Phase = .start
    @Published var progress: Downloader.Progress?
    @Published var refresh = 0
    let installer: GameInstaller
    private var task: Task<Void, Never>?
    init(_ i: GameInstaller) {
        installer = i
        // an IPA written earlier (the app was closed before installing it): offer it again
        if let ipa = Self.existingIPA(i.outDir) {
            let size = (try? FileManager.default.attributesOfItem(atPath: ipa.path)[.size] as? NSNumber)?.int64Value ?? 0
            phase = .done(.init(ipa: ipa, version: String(ipa.deletingPathExtension().lastPathComponent.dropFirst("CyPort-".count)), size: size, log: []))
        }
    }
    static func existingIPA(_ dir: URL) -> URL? {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .first { $0.lastPathComponent.hasPrefix("CyPort-") && $0.pathExtension == "ipa" }
    }

    func prepare() {
        phase = .working("Checking your Steam library…")
        task = Task {
            do {
                let p = try await installer.prepare { m in Task { @MainActor in self.phase = .working(m) } }
                phase = .ready(p)
            } catch is CancellationError { phase = .start }
            catch { phase = .failed(error.localizedDescription); storeLog("installer: \(error.localizedDescription)") }
        }
    }
    func start(_ p: GameInstaller.Prepared) {
        phase = .downloading; progress = nil
        UIApplication.shared.isIdleTimerDisabled = true
        var bg = UIBackgroundTaskIdentifier.invalid
        bg = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(bg) }
        let inst = installer
        task = Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false; UIApplication.shared.endBackgroundTask(bg) }
            do {
                try await inst.downloader(p).run { pr in Task { @MainActor in self.progress = pr } }
                phase = .working("Converting the game program for iOS…")
                let r = try await Task.detached(priority: .userInitiated) {
                    try inst.build(p) { m in Task { @MainActor in self.phase = .working(m) } }
                }.value
                phase = .done(r)
            } catch is CancellationError { phase = .ready(p) }
            catch { phase = .failed(error.localizedDescription + "\n\nTry again: the download continues where it stopped."); storeLog("installer: \(error.localizedDescription)") }
        }
    }
    func cancel() { task?.cancel() }
    func startOver() {
        if case .done(let r) = phase { try? FileManager.default.removeItem(at: r.ipa) }
        phase = .start
    }
}

struct InstallerView: View {
    @ObservedObject var model: InstallerModel
    @State private var login = false
    @State private var share: SharedFile?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Set up CyPort").font(.largeTitle.bold()).foregroundColor(.white)
                    Text("This CyPort doesn't contain the game yet. Sign in to Steam with the account that owns Cyberpunk 2077: CyPort downloads the Mac version of the game program (Apple Silicon), prepares it for iOS on this phone and makes an app to install over this one. No Mac needed.")
                        .font(.subheadline).foregroundColor(.gray)
                    content
                }
                .padding(24).frame(maxWidth: 720).frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $login) { LoginSheet(store: .steam) { login = false; model.refresh += 1 } }
        .sheet(item: $share) { f in ShareSheet(url: f.url) }
    }

    @ViewBuilder var content: some View {
        switch model.phase {
        case .start: steamRow
        case .working(let m): HStack(spacing: 12) { ProgressView(); Text(m).foregroundColor(.white) }
        case .ready(let p): ready(p)
        case .downloading: downloading
        case .done(let r): done(r)
        case .failed(let m):
            Text(m).foregroundColor(.orange)
            Button("Back") { model.phase = .start }.foregroundColor(.yellow)
        }
    }

    var steamRow: some View {
        let _ = model.refresh
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Steam").font(.headline).foregroundColor(.white)
                Text(SteamStore.shared.signedIn ? "Signed in\(SteamStore.shared.account.map { " as \($0)" } ?? "")" : "Not signed in").font(.caption).foregroundColor(.gray)
            }
            Spacer()
            if SteamStore.shared.signedIn {
                Button("Sign out") { SteamStore.shared.signOut(); model.refresh += 1 }.font(.caption).foregroundColor(.gray)
                Button("Get the game") { model.prepare() }.buttonStyle(.borderedProminent).tint(.yellow).foregroundColor(.black)
            } else {
                Button("Sign in") { login = true }.buttonStyle(.bordered).tint(.yellow)
            }
        }
        .padding(14).background(Color.white.opacity(0.07)).cornerRadius(12)
    }

    func ready(_ p: GameInstaller.Prepared) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Steam: Cyberpunk 2077 for Mac").font(.headline).foregroundColor(.white)
            Text("\(p.buildName) · game program \(gb(p.plan.totalBytes, 2))").foregroundColor(.white)
            Text("Steam always has its newest version. CyPort is tested with Steam 2.5.0; a newer version may need a newer CyPort.")
                .font(.caption).foregroundColor(.orange)
            Text("The game data (about 65–90 GB) is downloaded after installing, on CyPort's first screen.")
                .font(.caption).foregroundColor(.gray)
            HStack {
                Button("Back") { model.phase = .start }
                Spacer()
                Button("Download") { model.start(p) }.buttonStyle(.borderedProminent).tint(.yellow).foregroundColor(.black)
            }
        }
    }

    var downloading: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Downloading the game program from Steam…").font(.headline).foregroundColor(.white)
            let pr = model.progress
            ProgressView(value: Double(pr?.done ?? 0), total: Double(max(pr?.total ?? 1, 1))).tint(.yellow)
            if let pr {
                Text("\(gb(pr.done, 2)) of \(gb(pr.total, 2)) · \(String(format: "%.1f", pr.bytesPerSecond / 1e6)) MB/s").font(.caption.monospacedDigit()).foregroundColor(.white)
            } else { Text("Starting…").font(.caption).foregroundColor(.gray) }
            Button("Pause") { model.cancel() }.foregroundColor(.yellow)
        }
    }

    func done(_ r: GameInstaller.Result) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ready to install").font(.title.bold()).foregroundColor(.green)
            Text("\(r.ipa.lastPathComponent) (\(gb(r.size, 2))) – CyPort with Cyberpunk \(r.version). It's also in Files → On My iPhone → CyPort.")
                .foregroundColor(.white)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Tap Install and choose SideStore (or LiveContainer, AltStore, TrollStore).")
                Text("2. Install it over this app (same app: your sign-ins and files stay).")
                Text("3. Open CyPort again: it asks for the game data next (Download from Steam).")
                Text("Free Apple ID: the app needs the Increased Memory Limit – see GetMoreRam in the README.").foregroundColor(.gray)
            }.font(.subheadline).foregroundColor(.white)
            HStack {
                Button("Start over", role: .destructive) { model.startOver() }.font(.caption)
                Spacer()
                Button("Install…") { share = SharedFile(url: r.ipa) }.buttonStyle(.borderedProminent).tint(.yellow).foregroundColor(.black)
            }
        }
    }
    func gb(_ b: Int64, _ decimals: Int = 1) -> String { String(format: "%.\(decimals)f GB", Double(b) / 1e9) }
}

struct SharedFile: Identifiable { let url: URL; var id: String { url.path } }

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ v: UIActivityViewController, context: Context) {}
}
