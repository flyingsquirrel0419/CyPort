// The first screen of a CyPort built without a game (GitHub Actions, build.sh NO_GAME=1). Two ways to give it the game
// program, then the same conversion (GameInstaller.swift) into an IPA to install over this app:
//   - Steam: sign in, download the Mac game program (Apple Silicon) from the account that owns the game
//   - your own copy (CyPort's original way): pick the Mac game's Cyberpunk2077.app in Files
// Three steps: 1 game program -> 2 game data (the normal store download into Documents, which stays when the app is
// installed over) -> 3 install the IPA (iOS only runs code signed into an installed app, so that can't be skipped).
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
        case data(GameInstaller.Result)                // step 2: the game data
        case done(GameInstaller.Result), failed(String) // done = step 3: install
    }
    @Published var source: Source = .steam
    @Published var phase: Phase = .start
    @Published var progress: Downloader.Progress?
    @Published var refresh = 0
    /// the app has a game program but it didn't load (MacShimMain set CYPORT_LOAD_ERROR): make it again
    @Published var loadError: String?
    let installer: GameInstaller
    private var task: Task<Void, Never>?
    init(_ i: GameInstaller) {
        installer = i
        if let e = ProcessInfo.processInfo.environment["CYPORT_LOAD_ERROR"] {
            loadError = e.contains("code signature") ? "The game program in this app isn't signed correctly (made by an older CyPort). Make it again: it takes a minute." : "The game program in this app didn't load. Make it again."
            // the broken Games/ in this app (LiveContainer: writable) would be picked again on the next start
            if GameInstaller.inLiveContainer { try? FileManager.default.removeItem(at: Bundle.main.bundleURL.appendingPathComponent("Games")) }
            // the app made from it is the broken one: don't offer it again
            for f in (try? FileManager.default.contentsOfDirectory(at: i.outDir, includingPropertiesForKeys: nil)) ?? []
                where f.lastPathComponent.hasPrefix("CyPort-") && f.pathExtension == "ipa" { try? FileManager.default.removeItem(at: f) }
            storeLog("installer: opened because the game program didn't load - old IPAs removed")
            return
        }
        // an IPA written earlier (the app was closed before installing it): offer it again
        if let ipa = Self.existingIPA(i.outDir) {
            let size = (try? FileManager.default.attributesOfItem(atPath: ipa.path)[.size] as? NSNumber)?.int64Value ?? 0
            let r = GameInstaller.Result(ipa: ipa, version: String(ipa.deletingPathExtension().lastPathComponent.dropFirst("CyPort-".count)), size: size, log: [])
            phase = Self.hasData ? .done(r) : .data(r)
        }
    }
    static func existingIPA(_ dir: URL) -> URL? {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .first { $0.lastPathComponent.hasPrefix("CyPort-") && $0.pathExtension == "ipa" }
    }
    /// the game data where the game looks for it (MSDataRoot in MacShim.m): Documents/Cyberpunk 2077, or a folder picked on the
    /// store screen ("A folder (SSD)…")
    static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static let dataBookmarkKey = "MacShimDataBookmark2"
    static var hasData: Bool {
        let root = docs.appendingPathComponent("Cyberpunk 2077")
        let inDocs = ["archive", "engine", "r6"].allSatisfy { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path, isDirectory: &d) && d.boolValue }
        return inDocs || UserDefaults.standard.data(forKey: dataBookmarkKey) != nil
    }
    var step: Int {
        switch phase { case .data: return 2; case .done: return 3; default: return 1 }
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
        DownloadPiP.shared.begin("Downloading the game program")
        run {
            defer { Task { @MainActor in DownloadPiP.shared.end() } }
            try await inst.downloader(p).run { pr in Task { @MainActor in self.progress = pr; DownloadPiP.shared.update(pr) } }
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
            do {
                let r = try await Task.detached(priority: .userInitiated) { try await work() }.value
                phase = Self.hasData ? .done(r) : .data(r)
            }
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
        if case .done(let r) = phase, let ipa = r.ipa { try? FileManager.default.removeItem(at: ipa) }
        if case .data(let r) = phase, let ipa = r.ipa { try? FileManager.default.removeItem(at: ipa) }
        phase = .start
    }
}

struct InstallerView: View {
    @ObservedObject var model: InstallerModel
    @State private var login = false
    @State private var picking = false
    @State private var share: SharedFile?
    @State private var dataStore: StoreModel?

    var body: some View {
        ZStack {
            CyBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    CyTitle(subtitle: "Set up CyPort")
                    steps
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
        .fullScreenCover(item: $dataStore) { m in StoreView(model: m) }
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
        case .data(let r): data(r)
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
            if let e = model.loadError {
                VStack(alignment: .leading, spacing: 8) {
                    CyHeading(text: "Make the app again", icon: "exclamationmark.triangle")
                    Text(e).font(.subheadline).foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                    Text("Your downloaded game data stays.").cyNote()
                }.cyCard(selected: true)
            }
            Text("First the game program (the part that runs): choose where it comes from. CyPort prepares it for iOS on this phone. Then the game data, then you install the finished app.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            option(.steam, icon: "cloud", title: "Steam", detail: "Sign in with the account that owns Cyberpunk 2077. CyPort downloads the game program (a few hundred MB).")
            option(.local, icon: "folder", title: "Your own copy", detail: "CyPort's original way: the Mac version's Cyberpunk2077.app that you already have, in Files (on the phone, iCloud Drive or a drive).")
            Group {
                if model.source == .steam { steamPanel } else { localPanel }
            }
            .animation(.easeOut(duration: 0.15), value: model.source)
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
            Text("If it stops, it continues from where it was.").cyNote()
            Button("Pause") { model.cancel() }.buttonStyle(CySecondaryButtonStyle())
            DownloadPiPCard().padding(.top, 6)
        }.cyCard()
    }

    // MARK: your own copy

    func local(_ l: GameInstaller.Local, _ u: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            CyHeading(text: "Your own copy", icon: "folder")
            row("Found", l.app.deletingLastPathComponent().lastPathComponent + "/" + l.app.lastPathComponent)
            row("Version", l.short)
            if l.hasData {
                Text("The game data is in the same folder too: after installing, pick this folder on CyPort's first screen (Import or Play from a folder).").cyNote()
            }
            HStack(spacing: 12) {
                Button("Back") { model.back() }.buttonStyle(CySecondaryButtonStyle())
                Button { model.convert(l, u) } label: { Label("Convert", systemImage: "gearshape.2") }
                    .buttonStyle(CyPrimaryButtonStyle(fill: true))
            }
        }.cyCard()
    }

    // MARK: step 2: game data

    func data(_ r: GameInstaller.Result) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                CyHeading(text: "Game program ready", icon: "checkmark.seal")
                row("Cyberpunk", r.version)
                Text("Now the game data: the maps, sounds and videos (about 65–90 GB). It goes into CyPort's files on this iPhone (or a drive you pick) and stays there when you install the finished app.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
            }.cyCard()
            Button {
                let m = StoreModel(downloadRoot: InstallerModel.docs.appendingPathComponent("Cyberpunk 2077 (downloading)"),
                                   internalRoot: InstallerModel.docs.appendingPathComponent("Cyberpunk 2077"),
                                   bookmarkKey: InstallerModel.dataBookmarkKey)
                m.afterDone = { dataStore = nil; model.phase = .done(r) }
                dataStore = m
            } label: { Label("Download the game data", systemImage: "arrow.down.circle") }
                .buttonStyle(CyPrimaryButtonStyle(fill: true))
            Button(r.ipa == nil ? "Later" : "Later – install the app first") { model.phase = .done(r) }
                .buttonStyle(CySecondaryButtonStyle(fill: true))
            Text("Already have the game data in Files or on a drive? Choose Later: after installing, CyPort's first screen imports it or plays from that folder.").cyNote()
        }
    }

    // MARK: step 3: install

    @ViewBuilder func done(_ r: GameInstaller.Result) -> some View {
        if let ipa = r.ipa { install(r, ipa) } else { restart(r) }
    }
    /// LiveContainer: the game program is already in this app
    func restart(_ r: GameInstaller.Result) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                CyHeading(text: "Last step: start again", icon: "arrow.clockwise")
                Text("The game program is in CyPort now – no second app. Close CyPort and start it again from LiveContainer: LiveContainer signs the new game files first (a few seconds).")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                row("Cyberpunk", r.version)
                row("Game data", InstallerModel.hasData ? "ready ✓" : "next, on CyPort's first screen")
            }.cyCard()
            Text("If it then says 'code signature invalid': in LiveContainer open CyPort's settings → Force Sign, then start it again.").cyNote()
            Button { exit(0) } label: { Label("Close CyPort", systemImage: "xmark.circle") }
                .buttonStyle(CyPrimaryButtonStyle(fill: true))
        }
    }
    func install(_ r: GameInstaller.Result, _ ipa: URL) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                CyHeading(text: "Last step: install", icon: "square.and.arrow.down")
                Text("iOS only runs game code that is inside an installed app. CyPort has put the game program into a new copy of itself – install it over this one.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                row("App", ipa.lastPathComponent)
                row("Size", gb(r.size, 2))
                row("Game data", InstallerModel.hasData ? "ready ✓" : "after installing")
            }.cyCard()
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Tap Install and choose SideStore (or LiveContainer, AltStore, TrollStore).")
                step(2, "Install it over this app – same app: your sign-ins and game data stay.")
                step(3, InstallerModel.hasData ? "Open CyPort again and play." : "Open CyPort again: it asks for the game data.")
                Text("The app file is also in Files → On My iPhone → CyPort; delete it after installing.").cyNote()
                Text("Free Apple ID: the app needs the Increased Memory Limit – see GetMoreRam in the README.").cyNote()
            }
            Button { share = SharedFile(url: ipa) } label: { Label("Install…", systemImage: "square.and.arrow.up") }
                .buttonStyle(CyPrimaryButtonStyle(fill: true))
            Button("Start over", role: .destructive) { model.startOver() }.font(.caption).foregroundStyle(cyberRed)
        }
    }

    // MARK: bits

    /// 1 GAME PROGRAM · 2 GAME DATA · 3 INSTALL
    var steps: some View {
        HStack(spacing: 6) {
            ForEach(Array(["Program", "Data", GameInstaller.inLiveContainer ? "Restart" : "Install"].enumerated()), id: \.offset) { i, t in
                let n = i + 1, cur = model.step
                HStack(spacing: 6) {
                    Text(n < cur ? "✓" : "\(n)").font(.system(size: 12, weight: .heavy, design: .monospaced))
                        .foregroundStyle(n <= cur ? .black : .white.opacity(0.5))
                        .frame(width: 20, height: 20)
                        .background(n <= cur ? cyberYellow : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    Text(t.uppercased()).font(.system(size: 11, weight: .heavy, design: .monospaced)).tracking(1)
                        .foregroundStyle(n == cur ? cyberYellow : .white.opacity(n < cur ? 0.7 : 0.35))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                if n < 3 { Rectangle().fill(n < cur ? cyberYellow.opacity(0.7) : .white.opacity(0.15)).frame(height: 1).frame(maxWidth: .infinity) }
            }
        }
    }

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

/// the setup screen opens the store screen with .fullScreenCover(item:)
extension StoreModel: Identifiable {}
