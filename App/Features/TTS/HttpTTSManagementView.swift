import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class HttpTTSLibraryModel: ObservableObject {
    @Published private(set) var engines: [HttpTTS] = []
    @Published var errorMessage: String?

    private func repository() throws -> SQLiteConfigurationRepository {
        SQLiteConfigurationRepository(database: try LegadoDatabase(url: LegadoDatabase.defaultURL()))
    }

    func load() async {
        do {
            var values = try await repository().loadHttpTTS()
            if values.isEmpty { values = try bundledDefaults() }
            engines = sorted(values)
            if !values.isEmpty { try await repository().saveHttpTTS(engines) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save(_ value: HttpTTS) async {
        var value = value
        value.lastUpdateTime = Int64(Date().timeIntervalSince1970 * 1_000)
        var values = engines.filter { $0.id != value.id }
        values.append(value)
        await persist(values)
    }

    /// MiMo 密钥写入 Keychain，渠道配置保存成功后再更新列表。
    func saveMiMo(_ value: HttpTTS, apiKey: String) async throws {
        var value = value
        value.lastUpdateTime = Int64(Date().timeIntervalSince1970 * 1_000)
        try MiMoTTSKeychain.save(apiKey, engineID: value.id)
        let values = sorted(engines.filter { $0.id != value.id } + [value])
        try await repository().saveHttpTTS(values)
        engines = values
    }

    /// 删除配置成功后清理对应的 MiMo 密钥，失败时保留错误信息。
    func delete(at offsets: IndexSet) async {
        let removed = offsets.map { engines[$0] }
        var values = engines
        values.remove(atOffsets: offsets)
        do {
            try await repository().saveHttpTTS(values)
            engines = values
            for engine in removed where engine.mimo != nil {
                try MiMoTTSKeychain.delete(engineID: engine.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importData(_ data: Data) async {
        do {
            let decoder = JSONDecoder()
            let imported: [HttpTTS]
            if let array = try? decoder.decode([HttpTTS].self, from: data) {
                imported = array
            } else {
                imported = [try decoder.decode(HttpTTS.self, from: data)]
            }
            var byID = Dictionary(uniqueKeysWithValues: engines.map { ($0.id, $0) })
            for value in imported { byID[value.id] = value }
            await persist(Array(byID.values))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreDefaults() async {
        do {
            let defaults = try bundledDefaults()
            var byID = Dictionary(uniqueKeysWithValues: engines.filter { $0.id >= 0 }.map { ($0.id, $0) })
            for value in defaults { byID[value.id] = value }
            await persist(Array(byID.values))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(engines)
    }

    private func bundledDefaults() throws -> [HttpTTS] {
        guard let url = Bundle.main.url(forResource: "httpTTS", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([HttpTTS].self, from: Data(contentsOf: url))
    }

    private func persist(_ values: [HttpTTS]) async {
        do {
            let values = sorted(values)
            try await repository().saveHttpTTS(values)
            engines = values
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sorted(_ values: [HttpTTS]) -> [HttpTTS] {
        values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct HttpTTSManagementView: View {
    @StateObject private var model = HttpTTSLibraryModel()
    @State private var editing: HttpTTS?
    @State private var importsFile = false
    @State private var exportsFile = false
    @State private var showsFailoverSettings = false
    @State private var exportDocument = HttpTTSJSONDocument(data: Data("[]".utf8))

    var body: some View {
        List {
            ForEach(model.engines) { engine in
                Button {
                    editing = engine
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(engine.name).foregroundStyle(.primary)
                        Text(engine.url).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .onDelete { offsets in Task { await model.delete(at: offsets) } }
        }
        .overlay {
            if model.engines.isEmpty {
                ReadingUnavailableView("没有在线朗读引擎", systemImage: "waveform", description: Text("可恢复内置引擎或导入 HTTP TTS JSON。"))
            }
        }
        .navigationTitle("在线朗读引擎")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu("新建", systemImage: "plus") {
                    Button("小米 MiMo 渠道") { editing = .miMoEngine() }
                    Button("自定义 HTTP 引擎") { editing = HttpTTS() }
                }
                Menu("更多", systemImage: "ellipsis.circle") {
                    Button("渠道自动切换", systemImage: "arrow.triangle.swap") { showsFailoverSettings = true }
                    Button("导入", systemImage: "square.and.arrow.down") { importsFile = true }
                    Button("导出", systemImage: "square.and.arrow.up") {
                        do {
                            exportDocument = .init(data: try model.exportData())
                            exportsFile = true
                        } catch { model.errorMessage = error.localizedDescription }
                    }
                    Button("恢复内置引擎", systemImage: "arrow.counterclockwise") {
                        Task { await model.restoreDefaults() }
                    }
                    Button("清除朗读缓存", systemImage: "trash") {
                        Task { await HttpTTSAudioCache.shared.clear() }
                    }
                }
            }
        }
        .task { await model.load() }
        .sheet(isPresented: $showsFailoverSettings) {
            ReadingNavigationStack { HttpTTSFailoverSettingsView(engines: model.engines) }
        }
        .sheet(item: $editing) { engine in
            ReadingNavigationStack {
                if let configuration = engine.mimo {
                    MiMoTTSEditorView(engine: engine, configuration: configuration) { value, apiKey in
                        try await model.saveMiMo(value, apiKey: apiKey)
                    }
                } else {
                    HttpTTSEditorView(engine: engine) { value in
                        Task { await model.save(value) }
                    }
                }
            }
        }
        .fileImporter(isPresented: $importsFile, allowedContentTypes: [.json, .data]) { result in
            do {
                let url = try result.get()
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                Task { await model.importData(data) }
            } catch { model.errorMessage = error.localizedDescription }
        }
        .fileExporter(
            isPresented: $exportsFile,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "httpTTS"
        ) { result in
            if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
        }
        .alert("在线朗读引擎", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// 备用渠道必须由用户明确选择，排序决定失败后的切换与恢复优先级。
private struct HttpTTSFailoverSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let engines: [HttpTTS]
    @AppStorage("ttsFailoverEnabled") private var enabled = false
    @State private var order: [String] = []

    /// 按用户保存的顺序解析仍存在的备用渠道，不把内置引擎自动加入切换链。
    private var selected: [HttpTTS] {
        order.compactMap { id in engines.first { String($0.id) == id } }
    }

    var body: some View {
        List {
            Section {
                Toggle("失败后自动切换渠道", isOn: $enabled)
            } footer: {
                Text("先使用阅读页选中的渠道，失败后按下方顺序使用备用渠道。每 60 秒探测一次已失败的高优先级渠道，恢复后在下一段切回。所有渠道不可用时保留当前段落并等待重试。")
            }
            Section("备用顺序（拖动调整）") {
                ForEach(selected) { engine in Text(engine.name) }
                    .onMove { source, destination in
                        var ids = selected.map { String($0.id) }
                        ids.move(fromOffsets: source, toOffset: destination)
                        save(ids)
                    }
                    .onDelete { offsets in
                        var ids = selected.map { String($0.id) }
                        ids.remove(atOffsets: offsets)
                        save(ids)
                    }
            }
            Section("可用渠道") {
                ForEach(engines) { engine in
                    Toggle(engine.name, isOn: Binding(
                        get: { order.contains(String(engine.id)) },
                        set: { included in
                            let id = String(engine.id)
                            save(included ? order + [id] : order.filter { $0 != id })
                        }
                    ))
                }
            }
            Section {
                Text("恢复探测使用真实下一段正文，付费渠道可能计费。自动切换使用完整音频合成，每次请求最长等待 20 秒；试听不切换渠道。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("渠道自动切换")
        .environment(\.editMode, .constant(.active))
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .onAppear { order = UserDefaults.standard.stringArray(forKey: "ttsFailoverOrder") ?? [] }
    }

    /// 每次选择与排序立即持久化，避免关闭配置页后丢失备用链。
    private func save(_ ids: [String]) {
        order = ids
        UserDefaults.standard.set(ids, forKey: "ttsFailoverOrder")
    }
}

/// MiMo 渠道只开放密钥和音色，保存后可在现有听书引擎列表中使用。
@MainActor
private struct MiMoTTSEditorView: View {
    @Environment(\.dismiss) private var dismiss
    private let engine: HttpTTS
    private let onSave: @MainActor (HttpTTS, String) async throws -> Void
    @State private var apiKey = ""
    @State private var voice: MiMoTTSVoice
    @State private var isSaving = false
    @State private var errorMessage: String?
    @StateObject private var speech = ReaderSpeechController()

    /// 使用已保存的音色初始化表单，密钥在打开页面时从 Keychain 读取。
    init(engine: HttpTTS, configuration: MiMoTTSConfiguration, onSave: @escaping @MainActor (HttpTTS, String) async throws -> Void) {
        self.engine = engine
        self.onSave = onSave
        _voice = State(initialValue: configuration.voice)
    }

    var body: some View {
        Form {
            Section("小米 MiMo 渠道") {
                SecureField("API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                Picker("音色", selection: $voice) {
                    ForEach(MiMoTTSVoice.allCases, id: \.self) { voice in
                        Text(voice.displayName).tag(voice)
                    }
                }
            }
            .disabled(isSaving)
            Section {
                if speech.isSpeaking || speech.isPaused {
                    Button("停止试听", systemImage: "stop.fill") { speech.stop() }
                } else {
                    Button("保存并试听", systemImage: "play.fill") {
                        Task { await save(closesEditor: false) }
                    }
                    .disabled(apiKey.isEmpty || isSaving)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                if let error = speech.errorMessage { Text(error).foregroundStyle(.red) }
            } footer: {
                Text("密钥仅保存在本机，导出的配置不包含密钥。")
            }
        }
        .navigationTitle("小米 MiMo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }.disabled(isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "保存中…" : "保存") {
                    Task { await save(closesEditor: true) }
                }
                .disabled(apiKey.isEmpty || isSaving)
            }
        }
        .task {
            do { apiKey = try MiMoTTSKeychain.load(engineID: engine.id) ?? "" }
            catch { errorMessage = error.localizedDescription }
        }
        .onChange(of: apiKey) { _ in speech.stop() }
        .onChange(of: voice) { _ in speech.stop() }
        .onDisappear { speech.stop() }
        .interactiveDismissDisabled(isSaving)
    }

    /// 保存密钥和音色后关闭页面或朗读固定示例，失败时保留表单并展示原因。
    @MainActor
    private func save(closesEditor: Bool) async {
        isSaving = true
        errorMessage = nil
        speech.stop()
        defer { isSaving = false }
        var value = engine
        value.mimo = MiMoTTSConfiguration(voice: voice)
        do {
            try await onSave(value, apiKey)
            if closesEditor {
                dismiss()
            } else {
                speech.configure(followsSystemRate: false, speechRate: 5, readByPage: true, streamsHTTPAudio: false)
                speech.speakHTTP(engine: value, text: "你好，这是小米 MiMo 的听书声音。愿每一个故事，都能陪你度过美好的时光。", cachePolicy: .reload)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct HttpTTSEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var engine: HttpTTS
    let onSave: (HttpTTS) -> Void
    @StateObject private var speech = ReaderSpeechController()
    @State private var testText = "这是一段在线朗读引擎测试文本。"
    @State private var loginInfo: String
    @State private var showsLoginForm = false

    init(engine: HttpTTS, onSave: @escaping (HttpTTS) -> Void) {
        _engine = State(initialValue: engine)
        self.onSave = onSave
        _loginInfo = State(initialValue: BookSourceRuntimeStore.shared.get(sourceID: engine.sourceKey, key: "loginInfo"))
    }

    var body: some View {
        Form {
            Section("基本") {
                TextField("名称", text: $engine.name)
                TextEditor(text: $engine.url).frame(minHeight: 110)
                TextField("Content-Type 正则", text: optional(\.contentType))
                TextField("并发率", text: optional(\.concurrentRate))
                Toggle("启用 Cookie", isOn: optionalBool(\.enabledCookieJar))
            }
            Section("请求与脚本") {
                fieldLabel("Header")
                TextEditor(text: optional(\.header)).frame(minHeight: 80)
                fieldLabel("JS 库")
                TextEditor(text: optional(\.jsLib)).frame(minHeight: 100)
                fieldLabel("登录地址/脚本")
                TextEditor(text: optional(\.loginUrl)).frame(minHeight: 80)
                fieldLabel("登录 UI")
                TextEditor(text: optional(\.loginUi)).frame(minHeight: 80)
                fieldLabel("登录信息 JSON")
                TextEditor(text: $loginInfo).frame(minHeight: 80)
                if engine.loginUi?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    Button("打开登录表单", systemImage: "person.badge.key") { showsLoginForm = true }
                }
                fieldLabel("登录检查 JS")
                TextEditor(text: optional(\.loginCheckJs)).frame(minHeight: 100)
            }
            Section("测试") {
                TextField("测试文本", text: $testText)
                Button(speech.isSpeaking ? "停止测试" : "播放测试", systemImage: speech.isSpeaking ? "stop.fill" : "play.fill") {
                    speech.configure(followsSystemRate: false, speechRate: 5, readByPage: true, streamsHTTPAudio: true)
                    speech.toggleHTTP(engine: engine, text: testText)
                }
                if let error = speech.errorMessage { Text(error).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle(engine.name.isEmpty ? "新建在线朗读引擎" : engine.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    BookSourceRuntimeStore.shared.put(sourceID: engine.sourceKey, key: "loginInfo", value: loginInfo)
                    onSave(engine)
                    dismiss()
                }
                    .disabled(engine.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || engine.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .sheet(isPresented: $showsLoginForm) {
            ReadingNavigationStack {
                HttpTTSLoginView(engine: engine) { value in loginInfo = value }
            }
        }
        .onDisappear { speech.stop() }
    }

    private func fieldLabel(_ value: String) -> some View {
        Text(value).font(.subheadline.weight(.medium))
    }

    private func optional(_ keyPath: WritableKeyPath<HttpTTS, String?>) -> Binding<String> {
        Binding(get: { engine[keyPath: keyPath] ?? "" }, set: { engine[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    private func optionalBool(_ keyPath: WritableKeyPath<HttpTTS, Bool?>) -> Binding<Bool> {
        Binding(get: { engine[keyPath: keyPath] == true }, set: { engine[keyPath: keyPath] = $0 })
    }
}

private struct HttpTTSLoginRow: Decodable, Identifiable {
    var name = ""
    var type = "text"
    var action: String?
    var chars: [String?]?
    var `default`: String?
    var viewName: String?
    var id: String { "\(name)-\(type)" }

    private enum CodingKeys: String, CodingKey { case name, type, action, chars, `default`, viewName }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try values.decodeIfPresent(String.self, forKey: .type) ?? "text"
        action = try values.decodeIfPresent(String.self, forKey: .action)
        chars = try values.decodeIfPresent([String?].self, forKey: .chars)
        `default` = try values.decodeIfPresent(String.self, forKey: .default)
        viewName = try values.decodeIfPresent(String.self, forKey: .viewName)
    }
}

private struct HttpTTSLoginView: View {
    @Environment(\.dismiss) private var dismiss
    let engine: HttpTTS
    let onSave: (String) -> Void
    @State private var rows: [HttpTTSLoginRow] = []
    @State private var values: [String: String] = [:]
    @State private var errorMessage: String?
    @State private var isRunning = false
    @State private var pendingFieldAction: Task<Void, Never>?

    var body: some View {
        Form {
            if rows.isEmpty, errorMessage == nil {
                ProgressView("正在生成登录表单…")
            }
            ForEach(rows) { row in
                switch row.type {
                case "password":
                    SecureField(label(for: row), text: binding(for: row))
                        .onChange(of: values[row.name]) { _ in scheduleFieldAction(row.action) }
                case "select":
                    Picker(label(for: row), selection: binding(for: row)) {
                        ForEach(options(for: row), id: \.self) { Text($0).tag($0) }
                    }
                    .onChange(of: values[row.name]) { _ in runAction(row.action) }
                case "toggle":
                    Picker(label(for: row), selection: binding(for: row)) {
                        ForEach(options(for: row), id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: values[row.name]) { _ in runAction(row.action) }
                case "button":
                    Button(label(for: row)) { runAction(row.action) }
                default:
                    TextField(label(for: row), text: binding(for: row))
                        .onChange(of: values[row.name]) { _ in scheduleFieldAction(row.action) }
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.footnote) }
        }
        .navigationTitle("登录 · \(engine.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isRunning ? "执行中…" : "登录") { saveAndLogin() }.disabled(isRunning)
            }
        }
        .task { loadRows() }
        .onDisappear { pendingFieldAction?.cancel() }
    }

    private func loadRows() {
        do {
            values = decodeLoginInfo()
            let json = try renderedLoginUI()
            rows = try JSONDecoder().decode([HttpTTSLoginRow].self, from: Data(json.utf8))
            for row in rows where row.type != "button" && values[row.name] == nil {
                values[row.name] = row.default ?? options(for: row).first ?? ""
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func renderedLoginUI() throws -> String {
        guard var raw = engine.loginUi?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "[]"
        }
        let script: String?
        if raw.hasPrefix("@js:") {
            script = String(raw.dropFirst(4))
        } else if raw.hasPrefix("<js>"), raw.hasSuffix("</js>") {
            script = String(raw.dropFirst(4).dropLast(5))
        } else {
            script = nil
        }
        if let script {
            let result = try JavaScriptRuleEvaluator().evaluate(
                script: script,
                result: .object(values.mapValues(JSONValue.string)),
                executionContext: .init(source: engine.bookSourceAdapter)
            )
            raw = result.value.stringValue
        }
        return raw
    }

    private func decodeLoginInfo() -> [String: String] {
        let raw = BookSourceRuntimeStore.shared.get(sourceID: engine.sourceKey, key: "loginInfo")
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.mapValues { String(describing: $0) }
    }

    private func binding(for row: HttpTTSLoginRow) -> Binding<String> {
        Binding(get: { values[row.name] ?? row.default ?? "" }, set: { values[row.name] = $0 })
    }

    private func options(for row: HttpTTSLoginRow) -> [String] {
        let options = row.chars?.compactMap { $0 } ?? []
        return options.isEmpty ? [row.default ?? ""] : options
    }

    private func label(for row: HttpTTSLoginRow) -> String {
        guard let value = row.viewName, value.count >= 2,
              value.first == "'", value.last == "'" else { return row.name }
        return String(value.dropFirst().dropLast())
    }

    private func runAction(_ action: String?) {
        guard let action, !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isRunning = true
        errorMessage = nil
        let engine = engine
        let values = values
        Task { @MainActor in
            defer { isRunning = false }
            do {
                _ = try await Task.detached {
                    try JavaScriptRuleEvaluator().evaluate(
                        script: "\(engine.loginUrl ?? "")\n\(action)",
                        result: .object(values.mapValues(JSONValue.string)),
                        executionContext: .init(source: engine.bookSourceAdapter)
                    )
                }.value
                if engine.loginUi?.hasPrefix("@js:") == true { loadRows() }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func scheduleFieldAction(_ action: String?) {
        guard action?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
        pendingFieldAction?.cancel()
        pendingFieldAction = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 600_000_000)
                runAction(action)
            } catch { }
        }
    }

    private func saveAndLogin() {
        isRunning = true
        errorMessage = nil
        do {
            let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
            let raw = String(decoding: data, as: UTF8.self)
            BookSourceRuntimeStore.shared.put(sourceID: engine.sourceKey, key: "loginInfo", value: raw)
            let engine = engine
            let values = values
            Task { @MainActor in
                do {
                    if let login = engine.loginUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !login.isEmpty {
                        _ = try await Task.detached {
                            try JavaScriptRuleEvaluator().evaluate(
                                script: "\(login)\nif (typeof login === 'function') login.apply(this);",
                                result: .object(values.mapValues(JSONValue.string)),
                                executionContext: .init(source: engine.bookSourceAdapter)
                            )
                        }.value
                    }
                    onSave(raw)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                    isRunning = false
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            isRunning = false
        }
    }
}

private struct HttpTTSJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
