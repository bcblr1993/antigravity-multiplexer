import AppKit
import SwiftUI
import Sparkle

private let accent = Color(red: 0.31, green: 0.38, blue: 0.94)
private let pane = Color(red: 0.965, green: 0.971, blue: 0.988)

struct ManagedInstance: Identifiable, Hashable {
    let id: String
    let name: String
    let path: URL
    let bundleID: String
    let version: String
    let index: Int
    let running: Bool
    let verified: Bool
    var isOriginal: Bool { bundleID == "com.google.antigravity" }
    var profile: String { isOriginal ? "~/.gemini" : "~/.gemini-\(max(index - 1, 1))" }
}

struct BackupBatch: Decodable, Identifiable {
    let name: String
    let archiveCount: Int
    let bytes: Int64
    let referenced: Bool
    let deletable: Bool
    var id: String { name }
    var dateLabel: String {
        let characters = Array(name)
        guard characters.count == 22 else { return name }
        return "\(String(characters[0..<4]))-\(String(characters[4..<6]))-\(String(characters[6..<8])) " +
               "\(String(characters[9..<11])):\(String(characters[11..<13])):\(String(characters[13..<15]))"
    }
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

@MainActor final class InstanceStore: ObservableObject {
    @Published var instances: [ManagedInstance] = []
    @Published var backups: [BackupBatch] = []
    @Published var busy = false
    @Published var output = ""
    @Published var error: String?
    @Published var sourceVersion = "—"
    @Published var compatibility = "检查中"
    private let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Antigravity Multiplexer")
    private let knownASAR = "0f81685e9836ddf5a382869bea348385650cfe1bfeecbd2e2d902a571ce57261"
    private let names = ["Second": 2, "Third": 3, "Fourth": 4, "Fifth": 5, "Sixth": 6, "Seventh": 7, "Eighth": 8]

    func refresh() {
        let fm = FileManager.default
        let roots = [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var found: [ManagedInstance] = []
        var seen = Set<String>()
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for app in entries where app.pathExtension == "app" && app.lastPathComponent.hasPrefix("Antigravity") {
                guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                      let bundle = info["CFBundleIdentifier"] as? String,
                      bundle == "com.google.antigravity" || bundle.hasPrefix("local.antigravity.") else { continue }
                guard seen.insert(bundle).inserted else { continue }
                let version = info["CFBundleShortVersionString"] as? String ?? "未知"
                let name = info["CFBundleDisplayName"] as? String ?? app.deletingPathExtension().lastPathComponent
                let index = number(for: app.deletingPathExtension().lastPathComponent, bundle: bundle)
                let manifest = manifestPath(index: index)
                let record = (try? Data(contentsOf: manifest)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let verified = record?["login_verified"] as? Bool ?? false
                let running = !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
                found.append(ManagedInstance(id: bundle, name: name, path: app, bundleID: bundle,
                                             version: version, index: index, running: running, verified: verified))
            }
        }
        instances = found.sorted { $0.index < $1.index }
        if let source = instances.first(where: { $0.isOriginal }) {
            sourceVersion = source.version
            compatibility = ["2.15.1", "2.16.0"].contains(source.version) ? "已支持本机版本" : "版本待适配"
        } else {
            sourceVersion = "未找到"
            compatibility = "需要官方原版"
        }
        refreshBackups()
    }

    private func number(for name: String, bundle: String) -> Int {
        if bundle == "com.google.antigravity" { return 1 }
        for (word, value) in names where name.contains(word) { return value }
        if let value = Int(name.replacingOccurrences(of: "Antigravity ", with: "")) { return value }
        if let digits = bundle.components(separatedBy: "instance").last, let value = Int(digits) { return value }
        return 10_000
    }

    private func manifestPath(index: Int) -> URL { support.appendingPathComponent("instance-\(index).json") }
    var nextIndex: Int { max(8, (instances.map(\.index).filter { $0 < 10_000 }.max() ?? 7) + 1) }
    var pendingUpgrades: [ManagedInstance] { instances.filter { !$0.isOriginal && $0.version.compare(sourceVersion, options: .numeric) == .orderedAscending } }
    func refreshBackups() {
        guard let script = Bundle.main.url(forResource: "manage_backups", withExtension: "py") else {
            backups = []; return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, "list"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                backups = try JSONDecoder().decode([BackupBatch].self, from: data)
            } else {
                backups = []
                if error == nil { error = "无法读取备份列表，请检查备份目录。" }
            }
        } catch { self.error = "无法读取备份列表：\(error.localizedDescription)" }
    }
    func showBackups() { NSWorkspace.shared.open(support.appendingPathComponent("Backups")) }
    func deleteBackup(_ batch: BackupBatch) {
        guard !busy && batch.deletable else { return }
        guard let script = Bundle.main.url(forResource: "manage_backups", withExtension: "py") else {
            error = "应用缺少备份管理组件。"; return
        }
        runScript(script, arguments: ["delete", batch.name], starting: "正在删除选定备份批次…\n")
    }

    func open(_ item: ManagedInstance) {
        NSWorkspace.shared.open(item.path)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
    }
    func reveal(_ item: ManagedInstance) { NSWorkspace.shared.activateFileViewerSelecting([item.path]) }
    func showLogs(_ item: ManagedInstance) {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\(item.name)")
        NSWorkspace.shared.open(path)
    }
    func toggleVerified(_ item: ManagedInstance) {
        guard !item.isOriginal && item.index >= 8 else { return }
        let path = manifestPath(index: item.index)
        guard let data = try? Data(contentsOf: path),
              var record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        record["login_verified"] = !item.verified
        guard let encoded = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) else { return }
        do { try encoded.write(to: path, options: .atomic); refresh() }
        catch { self.error = "无法保存验证状态：\(error.localizedDescription)" }
    }

    func upgradeAll() {
        guard !busy else { return }
        guard let script = Bundle.main.url(forResource: "upgrade_all", withExtension: "py") else {
            error = "应用缺少升级组件。"; return
        }
        runScript(script, arguments: ["--source", "/Applications/Antigravity.app"],
                  starting: "正在检查本机主实例和全部副本；此操作不下载程序…\n")
    }

    func create(index: Int, destination: URL) {
        guard !busy else { return }
        guard let script = Bundle.main.url(forResource: "create_instance", withExtension: "py") else {
            error = "应用缺少创建组件。"; return
        }
        runScript(script, arguments: ["--index", String(index), "--source", "/Applications/Antigravity.app",
                                      "--destination", destination.path],
                  starting: "正在检查官方应用…\n")
    }

    private func runScript(_ script: URL, arguments: [String], starting: String) {
        busy = true
        error = nil
        output = starting
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let message = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.output += message }
        }
        process.terminationHandler = { [weak self] completed in
            pipe.fileHandleForReading.readabilityHandler = nil
            let remainder = pipe.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor in
                if let text = String(data: remainder, encoding: .utf8) { self?.output += text }
                self?.busy = false
                if completed.terminationStatus != 0 { self?.error = "操作未完成，请查看下方记录。" }
                self?.refresh()
            }
        }
        do { try process.run() }
        catch { busy = false; self.error = "无法启动组件：\(error.localizedDescription)" }
    }

}

struct InstanceCard: View {
    let item: ManagedInstance
    let sourceVersion: String
    let open: () -> Void
    let reveal: () -> Void
    let logs: () -> Void
    let verify: () -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 15) {
            ZStack {
                RoundedRectangle(cornerRadius: 13).fill(accent.opacity(0.10)).frame(width: 46, height: 46)
                Image(systemName: item.isOriginal ? "sparkle" : "square.on.square")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.name).font(.system(size: 15, weight: .semibold))
                    Text(item.running ? "运行中" : "未运行")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(item.running ? Color.green : Color.secondary)
                }
                Text("v\(item.version)  ·  \(item.profile)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if !item.isOriginal && item.version.compare(sourceVersion, options: .numeric) == .orderedAscending {
                Text("待升级").font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
            }
            if item.verified { Label("已验证", systemImage: "checkmark.seal.fill").font(.system(size: 11)).foregroundStyle(.green) }
            Menu {
                Button("在访达中显示", action: reveal)
                Button("查看日志", action: logs)
                if item.index >= 8 && !item.isOriginal {
                    Divider()
                    Button(item.verified ? "取消登录验证标记" : "标记已完成登录验证", action: verify)
                }
            } label: { Image(systemName: "ellipsis").frame(width: 18, height: 18) }
                .menuStyle(.borderlessButton).frame(width: 28)
            Button("打开", action: open).buttonStyle(.borderedProminent).tint(accent)
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.black.opacity(0.045)))
    }
}

struct ContentView: View {
    let updaterController: SPUStandardUpdaterController
    @StateObject private var store = InstanceStore()
    @State private var showCreate = false
    @State private var showUpgrade = false
    @State private var showBackupManager = false
    @State private var showUpdateSettings = false
    @State private var destination = URL(fileURLWithPath: "/Applications")
    var body: some View {
        ZStack { pane.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Antigravity 多开管理器").font(.system(size: 27, weight: .bold))
                            Text("在这台 Apple Silicon Mac 上管理独立实例。")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { updaterController.checkForUpdates(nil) } label: { Label("管理器更新", systemImage: "arrow.down.circle") }
                            .buttonStyle(.bordered)
                        Button { showUpdateSettings = true } label: { Image(systemName: "gearshape") }
                            .buttonStyle(.bordered).help("更新设置")
                        Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.bordered).help("刷新列表")
                        Button { store.refreshBackups(); showBackupManager = true } label: { Label("管理备份", systemImage: "externaldrive") }
                            .buttonStyle(.bordered)
                        Button { showUpgrade = true } label: { Label("升级全部副本", systemImage: "arrow.up.circle") }
                            .buttonStyle(.bordered).disabled(store.busy || store.pendingUpgrades.isEmpty || store.compatibility != "已支持本机版本")
                        Button { showCreate = true } label: { Label("创建实例", systemImage: "plus") }
                            .buttonStyle(.borderedProminent).tint(accent).disabled(store.busy)
                    }
                    HStack(spacing: 12) {
                        statusTile(title: "已发现实例", value: "\(store.instances.count)", symbol: "square.stack.3d.up")
                        statusTile(title: "本机主实例", value: store.sourceVersion, symbol: "checkmark.shield")
                        statusTile(title: "创建适配", value: store.compatibility, symbol: "wrench.adjustable")
                    }
                    HStack {
                        Text("本机实例").font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Text("凭据留在各自的数据目录中").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(store.instances) { item in
                        InstanceCard(item: item, sourceVersion: store.sourceVersion, open: { store.open(item) }, reveal: { store.reveal(item) },
                                     logs: { store.showLogs(item) }, verify: { store.toggleVerified(item) })
                    }
                    if store.instances.isEmpty {
                        VStack(spacing: 7) {
                            Image(systemName: "square.stack.3d.up").font(.system(size: 26)).foregroundStyle(accent)
                            Text("未发现 Antigravity").font(.system(size: 14, weight: .semibold))
                            Text("请先安装官方 Apple Silicon 版本。").font(.system(size: 12)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(28)
                            .background(.white, in: RoundedRectangle(cornerRadius: 17))
                    }
                    if store.busy || !store.output.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack { Text("操作记录").font(.system(size: 14, weight: .semibold)); Spacer()
                                if store.busy { ProgressView().controlSize(.small) } }
                            Text(store.output).font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 16))
                    }
                }.padding(26)
            }
        }
        .frame(minWidth: 760, minHeight: 590)
        .onAppear { store.refresh() }
        .sheet(isPresented: $showCreate) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("创建 Antigravity \(ordinalName(store.nextIndex))").font(.system(size: 21, weight: .bold))
                        Text("使用已安装的官方 Antigravity.app，新账号将在新窗口登录。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 10) {
                    detailRow("实例名称", "Antigravity \(ordinalName(store.nextIndex))")
                    detailRow("独立数据", "~/.gemini-\(store.nextIndex - 1)")
                    detailRow("专属回调", "antigravity-\(store.nextIndex)")
                    detailRow("源版本", store.sourceVersion)
                }.padding(16).background(pane, in: RoundedRectangle(cornerRadius: 13))
                HStack {
                    Text("安装位置").font(.system(size: 12)).foregroundStyle(.secondary)
                    Picker("", selection: $destination) {
                        Text("应用程序 /Applications").tag(URL(fileURLWithPath: "/Applications"))
                        Text("个人应用程序 ~/Applications").tag(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"))
                    }.labelsHidden().frame(width: 280)
                }
                Text("创建前会核对原版签名与文件哈希。未知版本会停止，已有实例不会被覆盖。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack { Spacer()
                    Button("取消") { showCreate = false }
                    Button("创建并打开") {
                        store.create(index: store.nextIndex, destination: destination)
                        showCreate = false
                    }.buttonStyle(.borderedProminent).tint(accent).disabled(store.compatibility != "已支持本机版本")
                }
            }.padding(24).frame(width: 510)
        }
        .sheet(isPresented: $showUpgrade) {
            VStack(alignment: .leading, spacing: 17) {
                Text("从本机主实例升级全部副本").font(.system(size: 21, weight: .bold))
                Text("/Applications/Antigravity.app · v\(store.sourceVersion) · 待升级 \(store.pendingUpgrades.count) 个")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(store.pendingUpgrades) { item in
                            HStack { Text(item.name); Spacer(); Text("v\(item.version) → v\(store.sourceVersion)")
                                .foregroundStyle(.secondary) }
                                .font(.system(size: 12))
                        }
                    }.padding(16)
                }.frame(maxHeight: 230).background(pane, in: RoundedRectangle(cornerRadius: 13))
                Text("直接复制本机主实例，不从网络下载安装包。请先保存这些副本中的工作。工具会备份每个应用、账号目录和窗口数据，再逐个安装适配后的副本；账号目录保持原路径。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack { Spacer()
                    Button("取消") { showUpgrade = false }
                    Button("从主实例复制并升级") { store.upgradeAll(); showUpgrade = false }
                        .buttonStyle(.borderedProminent).tint(accent)
                }
            }.padding(24).frame(width: 520)
        }
        .sheet(isPresented: $showUpdateSettings) {
            UpdateSettingsView(updater: updaterController.updater)
        }
        .sheet(isPresented: $showBackupManager) {
            BackupManagementView(store: store)
        }
        .alert("操作未完成", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("好") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
    private func ordinalName(_ number: Int) -> String {
        let units = [1: "First", 2: "Second", 3: "Third", 4: "Fourth", 5: "Fifth",
                     6: "Sixth", 7: "Seventh", 8: "Eighth", 9: "Ninth", 10: "Tenth",
                     11: "Eleventh", 12: "Twelfth", 13: "Thirteenth", 14: "Fourteenth",
                     15: "Fifteenth", 16: "Sixteenth", 17: "Seventeenth", 18: "Eighteenth",
                     19: "Nineteenth"]
        let tens = [20: "Twenty", 30: "Thirty", 40: "Forty", 50: "Fifty",
                    60: "Sixty", 70: "Seventy", 80: "Eighty", 90: "Ninety"]
        let tensOrdinal = [20: "Twentieth", 30: "Thirtieth", 40: "Fortieth", 50: "Fiftieth",
                           60: "Sixtieth", 70: "Seventieth", 80: "Eightieth", 90: "Ninetieth"]
        let cardinal = ["", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine"]
        if let word = units[number] { return word }
        if number < 100 {
            let remainder = number % 10
            return remainder == 0 ? (tensOrdinal[number] ?? String(number))
                : (tens[(number / 10) * 10] ?? "") + " " + (units[remainder] ?? "")
        }
        if number < 1000 {
            let remainder = number % 100
            return cardinal[number / 100] + " Hundred" + (remainder == 0 ? "th" : " " + ordinalName(remainder))
        }
        let remainder = number % 1000
        return cardinal[number / 1000] + " Thousand" + (remainder == 0 ? "th" : " " + ordinalName(remainder))
    }
    private func statusTile(title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol).foregroundStyle(accent).font(.system(size: 18))
                .frame(width: 34, height: 34).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }.padding(14).frame(maxWidth: .infinity)
            .background(.white, in: RoundedRectangle(cornerRadius: 15))
    }
    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).fontWeight(.medium) }
            .font(.system(size: 12))
    }
}

private struct BackupManagementView: View {
    @ObservedObject var store: InstanceStore
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDeletion: BackupBatch?
    private var totalSize: String {
        ByteCountFormatter.string(fromByteCount: store.backups.reduce(0) { $0 + $1.bytes }, countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("升级备份").font(.system(size: 21, weight: .bold))
                Spacer()
                Button { store.refreshBackups() } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新备份列表")
            }
            Text("\(store.backups.count) 个批次 · 共 \(totalSize)")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if store.backups.isEmpty {
                Text("还没有升级备份。")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.backups) { batch in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(batch.dateLabel).font(.system(size: 14, weight: .semibold))
                                    Text("\(batch.archiveCount) 个压缩包 · \(batch.sizeLabel)")
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                    if batch.referenced {
                                        Text("当前升级记录引用此备份").font(.system(size: 11)).foregroundStyle(.orange)
                                    }
                                    if !batch.deletable {
                                        Text("含非备份文件，请在访达检查").font(.system(size: 11)).foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                Button("永久删除", role: .destructive) { pendingDeletion = batch }
                                    .disabled(store.busy || !batch.deletable)
                            }
                            .padding(13).background(pane, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }.frame(maxHeight: 350)
            }
            Text("只删除你选定的备份批次。删除后无法恢复；请先确认各副本的登录和项目正常。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let error = store.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            }
            HStack {
                Button("在访达中查看") { store.showBackups() }.disabled(store.backups.isEmpty)
                Spacer()
                Button("完成") { dismiss() }
            }
        }
        .padding(24).frame(width: 570)
        .alert("永久删除此备份？", isPresented: Binding(get: { pendingDeletion != nil },
                                             set: { if !$0 { pendingDeletion = nil } })) {
            Button("永久删除", role: .destructive) {
                if let batch = pendingDeletion { store.deleteBackup(batch) }
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("将删除 \(pendingDeletion?.dateLabel ?? "") 的整个备份批次，约 \(pendingDeletion?.sizeLabel ?? "0 B")。此操作无法撤销。")
        }
    }
}

private struct UpdateSettingsView: View {
    let updater: SPUUpdater
    @Environment(\.dismiss) private var dismiss
    @State private var automatic = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("管理器更新").font(.system(size: 21, weight: .bold))
            Toggle("自动检查、下载并安装更新", isOn: $automatic)
                .onChange(of: automatic) { enabled in
                    updater.automaticallyChecksForUpdates = enabled
                    updater.automaticallyDownloadsUpdates = enabled
                }
            Text("开启后每天检查新版本。更新只替换多开管理器；实例和账号数据保留。需要授权时，macOS 会提示你。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Button("立即检查") { updater.checkForUpdates(); dismiss() }
                Spacer()
                Button("完成") { dismiss() }
            }
        }
        .padding(24).frame(width: 440)
        .onAppear { automatic = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates }
    }
}

@main struct AntigravityMultiplexerApp: App {
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    var body: some Scene {
        WindowGroup { ContentView(updaterController: updaterController).preferredColorScheme(.light) }
            .windowStyle(.titleBar).windowToolbarStyle(.unifiedCompact)
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("检查多开管理器更新…") { updaterController.checkForUpdates(nil) }
                }
            }
    }
}
