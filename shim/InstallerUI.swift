// The first screen of a CyPort built without a game (GitHub Actions, build.sh NO_GAME=1). Two ways to give it the game
// program, then the same conversion (GameInstaller.swift) into an IPA to install over this app:
//   - Steam: sign in, download the Mac game program (Apple Silicon) from the account that owns the game
//   - your own copy (CyPort's original way): pick the Mac game's Cyberpunk2077.app in Files
// Opened by the shim's starter (MacShimMain in MacShim.m) when the app has no Games/<version>/. Looks like the start
// screen (CyStyle.swift).
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@objc(MSInstallerUI)
final class MSInstallerUI: NSObject {
    @MainActor @objc static func make() -> UIViewController {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let vc = InstallerHostingController(rootView: InstallerView(model: InstallerModel(GameInstaller(documents: docs))))
        vc.view.backgroundColor = .black
        return vc
    }
}
private final class InstallerHostingController: UIHostingController<InstallerView> {
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}

@MainActor
final class InstallerModel: ObservableObject {
    enum Source { case steam, local }
    enum Phase {
        case start, working(String), ready(GameInstaller.Prepared), downloading
        case local(GameInstaller.Local, URL)            // a picked copy, checked; URL = the security-scoped pick
        case done(GameInstaller.Result), failed(String)
    }
    @Published var source: Source = .steam
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
    var busy: Bool { switch phase { case .working, .downloading: return true; default: return false } }

    // Steam
    func prepare() {
        phase = .working("Checking your Steam library…")
        task = Task {
            do {
                let p = try await installer.prepare { m in Task { @MainActor in self.phase = .working(m) } }
                phase = .ready(p)
            } catch is CancellationError { phase = .start }
            catch { fail(error) }
        }
    }
    func start(_ p: GameInstaller.Prepared) {
        phase = .downloading; progress = nil
        let inst = installer
        run {
            try await inst.downloader(p).run { pr in Task { @MainActor in self.progress = pr } }
            return try inst.build(p) { m in Task { @MainActor in self.phase = .working(m) } }
        } cancelled: { self.phase = .ready(p) }
    }

    // your own copy
    func picked(_ r: Result<[URL], Error>) {
        switch r {
        case .failure(let e): fail(e)
        case .success(let urls):
            guard let u = urls.first else { return }
            let scoped = u.startAccessingSecurityScopedResource()
            do { phase = .local(try GameInstaller.findLocal(u), u) }
            catch { if scoped { u.stopAccessingSecurityScopedResource() }; fail(error) }
        }
    }
    func convert(_ l: GameInstaller.Local, _ u: URL) {
        phase = .working("Converting the game program for iOS…")
        let inst = installer
        run {
            defer { u.stopAccessingSecurityScopedResource() }
            return try inst.build(l) { m in Task { @MainActor in self.phase = .working(m) } }
        } cancelled: { self.phase = .start }
    }
    func back() {
        if case .local(_, let u) = phase { u.stopAccessingSecurityScopedResource() }
        phase = .start
    }

    /// keeps the screen on and the app running for the work, then shows the IPA
    private func run(_ work: @escaping @Sendable () async throws -> GameInstaller.Result, cancelled: @escaping () -> Void) {
        UIApplication.shared.isIdleTimerDisabled = true
        var bg = UIBackgroundTaskIdentifier.invalid
        bg = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(bg) }
        let id = bg
        task = Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false; UIApplication.shared.endBackgroundTask(id) }
            do { phase = .done(try await Task.detached(priority: .userInitiated) { try await work() }.value) }
            catch is CancellationError { cancelled() }
            catch { fail(error) }
        }
    }
    private func fail(_ e: Error) {
        phase = .failed(e.localizedDescription + (source == .steam ? "\n\nTry again: the download continues where it stopped." : ""))
        storeLog("installer: \(e.localizedDescription)")
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
    @State private var picking = false
    @State private var share: SharedFile?

    var body: some View {
        ZStack {
            CyBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    CyTitle(subtitle: "Set up · get the game program")
                    content
                }
                .padding(.horizontal, 24).padding(.vertical, 28)
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .tint(cyberYellow)
        .persistentSystemOverlays(.hidden)
        .statusBarHidden(true)
        .sheet(isPresented: $login) { LoginSheet(store: .steam) { login = false; model.refresh += 1 } }
        .sheet(item: $share) { f in ShareSheet(url: f.url) }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder, .applicationBundle], allowsMultipleSelection: false) { model.picked($0) }
    }

    @ViewBuilder var content: some View {
        switch model.phase {
        case .start: choose
        case .working(let m):
            HStack(spacing: 12) { ProgressView().tint(cyberYellow); Text(m).font(.subheadline).foregroundStyle(.white) }.cyCard()
        case .ready(let p): ready(p)
        case .downloading: downloading
        case .local(let l, let u): local(l, u)
        case .done(let r): done(r)
        case .failed(let m):
            VStack(alignment: .leading, spacing: 14) {
                CyHeading(text: "Didn't work", icon: "exclamationmark.triangle")
                Text(m).font(.subheadline).foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                Button("Back") { model.phase = .start }.buttonStyle(CySecondaryButtonStyle())
            }.cyCard()
        }
    }

    // MARK: start: pick the way

    var choose: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This CyPort doesn't have the game program yet. Choose where it comes from: CyPort prepares it for iOS on this phone and makes an app to install over this one.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            option(.steam, icon: "cloud", title: "Steam", detail: "Sign in with the account that owns Cyberpunk 2077. CyPort downloads the game program (a few hundred MB).")
            option(.local, icon: "folder", title: "Your own copy", detail: "CyPort's original way: the Mac version's Cyberpunk2077.app that you already have, in Files (on the phone, iCloud Drive or a drive).")
            Group {
                if model.source == .steam { steamPanel } else { localPanel }
            }
            .animation(.easeOut(duration: 0.15), value: model.source)
            Text("The game data (about 65–90 GB) comes after installing, on CyPort's next screen.").cyNote()
        }
    }
    func option(_ s: InstallerModel.Source, icon: String, title: String, detail: String) -> some View {
        Button { model.source = s } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.source == s ? "largecircle.fill.circle" : "circle")
                    .font(.title3).foregroundStyle(model.source == s ? cyberYellow : .white.opacity(0.4))
                VStack(alignment: .leading, spacing: 4) {
                    Label(title, systemImage: icon).font(.headline).foregroundStyle(.white)
                    Text(detail).font(.caption).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .cyCard(selected: model.source == s)
        }
        .buttonStyle(.plain)
    }

    var steamPanel: some View {
        let _ = model.refresh
        let s = SteamStore.shared
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: s.signedIn ? "checkmark.circle.fill" : "person.crop.circle")
                    .foregroundStyle(s.signedIn ? cyberYellow : .white.opacity(0.5))
                Text(s.signedIn ? "Signed in\(s.account.map { " as \($0)" } ?? "")" : "Not signed in to Steam")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.85))
                Spacer()
                if s.signedIn { Button("Sign out") { s.signOut(); model.refresh += 1 }.font(.caption).foregroundStyle(.white.opacity(0.5)) }
            }
            if s.signedIn {
                Button { model.prepare() } label: { Label("Get the game", systemImage: "arrow.down.circle") }
                    .buttonStyle(CyPrimaryButtonStyle(fill: true))
            } else {
                Button { login = true } label: { Label("Sign in to Steam", systemImage: "person.badge.key") }
                    .buttonStyle(CyPrimaryButtonStyle(fill: true))
            }
        }
    }
    var localPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Copy the game folder from your Steam or GOG library (the Mac version) to the phone, iCloud Drive or a USB drive first. Pick Cyberpunk2077.app or the folder that holds it.")
                .cyNote()
            Button { picking = true } label: { Label("Pick the game…", systemImage: "folder") }
                .buttonStyle(CyPrimaryButtonStyle(fill: true))
        }
    }

    // MARK: Steam

    func ready(_ p: GameInstaller.Prepared) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            CyHeading(text: "Steam · Cyberpunk 2077", icon: "cloud")
            row("Version", p.buildName)
            row("Game program", gb(p.plan.totalBytes, 2))
            Text("Steam always has its newest version. CyPort is tested with Steam 2.5.0; a newer one may need a newer CyPort.")
                .font(.caption).foregroundStyle(cyberYellow.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Back") { model.phase = .start }.buttonStyle(CySecondaryButtonStyle())
                Button { model.start(p) } label: { Label("Download", systemImage: "arrow.down.circle") }
                    .buttonStyle(CyPrimaryButtonStyle(fill: true))
            }
        }.cyCard()
    }

    var downloading: some View {
        VStack(alignment: .leading, spacing: 12) {
            CyHeading(text: "Downloading", icon: "arrow.down.circle")
            let pr = model.progress
            CyProgress(done: pr?.done ?? 0, total: pr?.total ?? 1)
            if let pr {
                Text("\(gb(pr.done, 2)) of \(gb(pr.total, 2)) · \(String(format: "%.1f", pr.bytesPerSecond / 1e6)) MB/s")
                    .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
            } else { Text("Starting…").cyNote() }
            Text("Keep the app open (the screen stays on). If it stops, it continues from where it was.").cyNote()
            Button("Pause") { model.cancel() }.buttonStyle(CySecondaryButtonStyle())
        }.cyCard()
    }

    // MARK: your own copy

    func local(_ l: GameInstaller.Local, _ u: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            CyHeading(text: "Your own copy", icon: "folder")
            row("Found", l.app.deletingLastPathComponent().lastPathComponent + "/" + l.app.lastPathComponent)
            row("Version", l.short)
            if l.hasData {
                Text("The game data is in the same folder: after installing, pick this folder again on CyPort's next screen.").cyNote()
            }
            HStack(spacing: 12) {
                Button("Back") { model.back() }.buttonStyle(CySecondaryButtonStyle())
                Button { model.convert(l, u) } label: { Label("Convert", systemImage: "gearshape.2") }
                    .buttonStyle(CyPrimaryButtonStyle(fill: true))
            }
        }.cyCard()
    }

    // MARK: done

    func done(_ r: GameInstaller.Result) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                CyHeading(text: "Ready to install", icon: "checkmark.seal")
                row("App", r.ipa.lastPathComponent)
                row("Size", gb(r.size, 2))
                Text("Also in Files → On My iPhone → CyPort.").cyNote()
            }.cyCard()
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Tap Install and choose SideStore (or LiveContainer, AltStore, TrollStore).")
                step(2, "Install it over this app – same app: your sign-ins and files stay.")
                step(3, "Open CyPort again: it asks for the game data next.")
                Text("Free Apple ID: the app needs the Increased Memory Limit – see GetMoreRam in the README.").cyNote()
            }
            Button { share = SharedFile(url: r.ipa) } label: { Label("Install…", systemImage: "square.and.arrow.up") }
                .buttonStyle(CyPrimaryButtonStyle(fill: true))
            Button("Start over", role: .destructive) { model.startOver() }.font(.caption).foregroundStyle(cyberRed)
        }
    }

    // MARK: bits

    func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.caption).foregroundStyle(.white.opacity(0.5)).frame(width: 96, alignment: .leading)
            Text(v).font(.subheadline.monospacedDigit()).foregroundStyle(.white).lineLimit(2)
        }
    }
    func step(_ n: Int, _ t: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.system(size: 13, weight: .heavy, design: .monospaced)).foregroundStyle(.black)
                .frame(width: 22, height: 22).background(cyberYellow, in: RoundedRectangle(cornerRadius: 5))
            Text(t).font(.subheadline).foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
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
