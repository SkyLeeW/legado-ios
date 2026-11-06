import SwiftUI
import UIKit
// Readium 的界面和出版物操作统一由主执行器管理，等待加载完成后再呈现。
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumStreamer
@preconcurrency import ReadiumNavigator

/// EPUB keeps its XHTML, CSS, SVG, images and navigation in Readium. The text
/// reader remains available for the app's existing speech and text tools.
@MainActor
final class EPUBReaderModel: ObservableObject, EPUBNavigatorDelegate {
    struct TOCEntry: Identifiable {
        let id: Int
        let link: ReadiumShared.Link
        let depth: Int
    }

    @Published private(set) var navigator: EPUBNavigatorViewController?
    @Published private(set) var location: Locator?
    @Published private(set) var tableOfContents: [TOCEntry] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    @Published var showsControls = true
    var onLocationChanged: ((Locator, BookChapter) -> Void)?
    let book: Book
    let chapters: [BookChapter]
    let initialIndex: Int
    private let httpClient = DefaultHTTPClient()
    private var navigationAdapter: DirectionalNavigationAdapter?
    private var textMaps: [Int: EPUBTextMap] = [:]

    init(book: Book, chapters: [BookChapter], initialIndex: Int) {
        self.book = book
        self.chapters = chapters
        self.initialIndex = initialIndex
    }

    var currentChapter: BookChapter? {
        guard let location else { return chapters.first { $0.index == initialIndex } ?? chapters.first }
        let path = Self.path(location.href.string)
        let matches = chapters.filter { $0.resourceUrl == path }
        if let exact = matches.first(where: { chapter in
            chapter.startFragmentId.map { location.locations.fragments.contains($0) } == true
        }) { return exact }
        if let titled = matches.first(where: { $0.title == location.title }) { return titled }
        return matches.first ?? chapters.first { $0.index == initialIndex } ?? chapters.first
    }

    var progress: Double { location?.locations.totalProgression ?? 0 }

    func open(preferences: EPUBPreferences) async {
        guard navigator == nil, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let url = try LocalBookService.fileURL(for: book)
            guard let file = FileURL(url: url) else { throw LocalBookError.missingFile }
            let retriever = AssetRetriever(httpClient: httpClient)
            let opener = PublicationOpener(parser: DefaultPublicationParser(
                httpClient: httpClient, assetRetriever: retriever, pdfFactory: DefaultPDFDocumentFactory()
            ))
            let asset = try await retriever.retrieve(url: file).get()
            let publication = try await opener.open(asset: asset, allowUserInteraction: false).get()
            try Task.checkCancellation()
            var initialLocation: Locator?
            if initialIndex == book.durChapterIndex, let saved = book.readConfig?.epubLocation {
                initialLocation = try? Locator(jsonString: saved)
            }
            if initialLocation == nil, initialIndex > 0,
               let chapter = chapters.first(where: { $0.index == initialIndex }), let link = link(for: chapter) {
                initialLocation = await publication.locate(link)
            }
            let controller = try EPUBNavigatorViewController(
                publication: publication, initialLocation: initialLocation,
                config: .init(preferences: preferences)
            )
            controller.delegate = self
            controller.view.accessibilityIdentifier = "reader.epub"
            let adapter = DirectionalNavigationAdapter(animatedTransition: true)
            adapter.bind(to: controller)
            navigationAdapter = adapter
            // 边缘翻页先消费点击，剩余的中央点击只切换菜单，不再经过旧委托回调。
            controller.addObserver(.activate { [weak self] _ in
                self?.showsControls.toggle()
                return true
            })
            var entries: [TOCEntry] = []
            func append(_ links: [ReadiumShared.Link], depth: Int) {
                for link in links {
                    entries.append(.init(id: entries.count, link: link, depth: depth))
                    append(link.children, depth: depth + 1)
                }
            }
            let toc = (try? await publication.tableOfContents().get()) ?? []
            append(toc.isEmpty ? publication.readingOrder : toc, depth: 0)
            tableOfContents = entries
            navigator = controller
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func apply(_ preferences: EPUBPreferences) { navigator?.submitPreferences(preferences) }

    func go(to link: ReadiumShared.Link) async {
        guard let navigator else { return }
        if !(await navigator.go(to: link)) { errorMessage = "无法跳转到这段内容" }
    }

    func go(to bookmark: Bookmark) async {
        if let json = bookmark.epubLocation, let locator = try? Locator(jsonString: json) {
            _ = await navigator?.go(to: locator)
        } else if let index = bookmark.resolvedChapterIndex(in: chapters), let link = link(for: chapters[index]) {
            await go(to: link)
        }
    }

    func go(toProgress progress: Double) async {
        guard let navigator, let locator = await navigator.publication.locate(progression: progress) else { return }
        _ = await navigator.go(to: locator)
    }

    /// 底部按钮和屏幕边缘使用相同的 Readium 动画导航，跨章由引擎保留首尾页位置。
    func turnPage(forward: Bool) async {
        guard let navigator else { return }
        let options = NavigatorGoOptions(animated: true)
        if forward { _ = await navigator.goForward(options: options) }
        else { _ = await navigator.goBackward(options: options) }
    }

    /// 返回原排版时使用听书刚保存的正文 Locator，恢复到章内实际位置。
    func resumeAfterTextReading(_ updated: Book) async {
        do {
            guard let locator = try Locator(jsonString: updated.readConfig!.epubLocation!) else {
                throw NSError(domain: "Legado.EPUBPosition", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "听书位置为空，无法恢复原排版"])
            }
            if !(await navigator!.go(to: locator)) { errorMessage = "无法恢复听书位置" }
        } catch { errorMessage = error.localizedDescription }
    }

    /// 将原排版中首个可见字符转换成听书使用的正文坐标，并生成可反向恢复的 Locator。
    func readingBook(_ current: Book, rules: [ReplaceRule]) async throws -> Book {
        let locator = location!
        let value = try await navigator!.evaluateJavaScript(Self.visibleTextPointScript).get()
        let point = try JSONDecoder().decode(EPUBTextPoint.self, from: Data((value as! String).utf8))
        let path = Self.path(locator.href.string)
        let candidates = chapters.filter { $0.resourceUrl == path }
        for chapter in candidates {
            let raw: EPUBTextMap
            if let cached = textMaps[chapter.index] { raw = cached }
            else {
                raw = try await Task.detached {
                    try LocalBookService().loadContent(book: current, chapter: chapter).epubTextMap!
                }.value
                textMaps[chapter.index] = raw
            }
            if let rawPosition = raw.position(of: point) {
                let processed = ContentSanitizer().process(book: current, chapter: chapter, content: raw.text,
                    rules: (current.readConfig?.useReplaceRule ?? true) ? rules : [], tracksSourceOffsets: true)
                let position = processed.sourceMap!.position(forSourceOffset: rawPosition)
                var result = current
                result.durChapterIndex = chapter.index
                result.durChapterTitle = chapter.title
                result.durChapterPos = position
                if result.readConfig == nil { result.readConfig = BookReadConfig() }
                result.readConfig!.epubLocation = try raw.processed(processed).locatorJSON(chapter: chapter, position: position)
                return result
            }
        }
        throw NSError(domain: "Legado.EPUBPosition", code: 1, userInfo: [NSLocalizedDescriptionKey: "当前页面没有可同步的正文位置"])
    }

    /// 通过实际字符矩形寻找当前可见正文，不使用页码比例或文本搜索猜测位置。
    private static let visibleTextPointScript = #"""
    (() => {
        // 元素路径与原始 DOM 的子元素顺序一致，不依赖书籍是否为段落设置 id。
        function selector(element) {
            if (element === document.body) return 'body';
            return selector(element.parentElement) + ' > :nth-child(' +
                (Array.from(element.parentElement.children).indexOf(element) + 1) + ')';
        }
        // 多栏和滚动排版均以字形矩形与视口相交作为可见条件。
        function visible(rect) {
            return rect.width > 0 && rect.height > 0 && rect.right > 0 && rect.left < innerWidth &&
                rect.bottom > 0 && rect.top < innerHeight;
        }
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
        const range = document.createRange();
        while (walker.nextNode()) {
            const node = walker.currentNode;
            if (node.nodeType === Node.ELEMENT_NODE && ['img', 'image'].includes(node.localName) &&
                Array.from(node.getClientRects()).some(visible)) {
                return JSON.stringify({cssSelector: selector(node), textNodeIndex: -1, offset: 0});
            }
            if (node.nodeType !== Node.TEXT_NODE || node.parentElement.closest('script,style,noscript,rt,rp,title,[hidden]')) continue;
            if (getComputedStyle(node.parentElement).visibility !== 'visible') continue;
            range.selectNodeContents(node);
            if (!Array.from(range.getClientRects()).some(visible)) continue;
            for (let offset = 0; offset < node.length;) {
                const character = String.fromCodePoint(node.textContent.codePointAt(offset));
                range.setStart(node, offset);
                range.setEnd(node, offset + character.length);
                if (!/\s/u.test(character) && Array.from(range.getClientRects()).some(visible)) {
                    return JSON.stringify({cssSelector: selector(node.parentElement),
                        textNodeIndex: Array.from(node.parentElement.childNodes).indexOf(node), offset});
                }
                offset += character.length;
            }
        }
        throw new Error('当前 EPUB 页面没有可见正文或插图');
    })()
    """#

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        location = locator
        if let chapter = currentChapter { onLocationChanged?(locator, chapter) }
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        errorMessage = error.localizedDescription
    }

    func clearError() { errorMessage = nil }

    /// 位置同步失败直接显示原因，保留当前阅读画面供用户重试。
    func reportPositionError(_ error: Error) { errorMessage = error.localizedDescription }

    private func link(for chapter: BookChapter) -> ReadiumShared.Link? {
        guard let path = chapter.resourceUrl else { return nil }
        var parts = URLComponents()
        parts.path = path
        parts.fragment = chapter.startFragmentId
        guard let href = parts.string, let url = AnyURL(string: href) else { return nil }
        return ReadiumShared.Link(href: url.string, mediaType: .xhtml, title: chapter.title)
    }

    static func path(_ href: String) -> String {
        (URLComponents(string: href)?.path ?? href).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

struct EPUBReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var activity: ReadingActivityModel
    @EnvironmentObject private var replaceRules: ReplaceRuleLibraryModel
    @StateObject private var model: EPUBReaderModel
    @State private var showsTOC = false
    @State private var showsSettings = false
    @State private var showsBookmarks = false
    @State private var showsTextReader = false
    @State private var textReaderBook: Book?
    @State private var startsListening = false
    @State private var isOpeningTextReader = false
    @State private var isRestoringTextPosition = false
    @State private var sliderProgress = 0.0
    @State private var isScrubbing = false
    @State private var saveTask: Task<Void, Never>?
    @AppStorage("epubFontScale") private var fontScale = 1.0
    @AppStorage("epubScroll") private var scroll = false
    @AppStorage("epubPublisherStyles") private var publisherStyles = true
    @AppStorage("epubTheme") private var theme = "system"

    /// 使用书籍信息创建原排版阅读模型。
    init(book: Book, chapters: [BookChapter], initialIndex: Int) {
        self.init(model: EPUBReaderModel(book: book, chapters: chapters, initialIndex: initialIndex))
    }

    /// 接收已有阅读模型，让页面与布局回归共享同一份导航状态。
    init(model: EPUBReaderModel) {
        _model = StateObject(wrappedValue: model)
    }

    private var preferences: EPUBPreferences {
        EPUBPreferences(fontSize: fontScale, publisherStyles: publisherStyles, scroll: scroll,
                        theme: theme == "sepia" ? .sepia : (theme == "dark" || (theme == "system" && colorScheme == .dark) ? .dark : .light))
    }

    var body: some View {
        Group {
            if let navigator = model.navigator {
                EPUBNavigatorHost(navigator: navigator)
            } else if let error = model.errorMessage {
                VStack(spacing: 16) {
                    Text("无法打开 EPUB").font(.headline)
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button("重试") { Task { await model.open(preferences: preferences) } }
                    Button("返回书架") { dismiss() }
                }.padding()
            } else {
                ProgressView("正在打开 EPUB…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 工具栏叠加在正文上，不改变视口尺寸，避免开关菜单时触发 EPUB 重新分页。
        .overlay(alignment: .top) {
            if model.showsControls { topBar.background(Color(uiColor: .systemBackground)) }
        }
        .overlay(alignment: .bottom) {
            if model.showsControls, model.navigator != nil {
                bottomBar.background(Color(uiColor: .systemBackground))
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationBarHidden(true)
        .readingTabBarHidden()
        .task {
            model.onLocationChanged = { locator, chapter in
                guard !showsTextReader, !isOpeningTextReader, !isRestoringTextPosition else { return }
                if !isScrubbing { sliderProgress = locator.locations.totalProgression ?? 0 }
                saveTask?.cancel()
                saveTask = Task {
                    do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
                    await persistVisibleProgress()
                }
            }
            activity.beginReading(model.book)
            await model.open(preferences: preferences)
        }
        .onChange(of: preferences) { model.apply($0) }
        .onChange(of: scenePhase) { phase in
            if phase != .active { saveProgress(); Task { await activity.endReading(model.book) } }
            else { activity.beginReading(model.book) }
        }
        .onDisappear {
            saveProgress()
            if !showsTextReader {
                model.onLocationChanged = nil
                Task { await activity.endReading(model.book) }
            }
        }
        .sheet(isPresented: $showsTOC) { tocSheet }
        .sheet(isPresented: $showsSettings) { settingsSheet }
        .sheet(isPresented: $showsBookmarks) { bookmarksSheet }
        .fullScreenCover(isPresented: $showsTextReader, onDismiss: {
            if let book = library.books.first(where: { $0.bookUrl == model.book.bookUrl }) {
                isRestoringTextPosition = true
                Task {
                    await model.resumeAfterTextReading(book)
                    isRestoringTextPosition = false
                }
            }
            activity.beginReading(model.book)
        }) {
            ReadingNavigationStack {
                if let book = textReaderBook {
                    ReaderView(book: book, chapters: model.chapters, initialIndex: book.durChapterIndex,
                               usesEPUBLayout: false, startsListening: startsListening)
                }
            }
        }
        .alert("EPUB 阅读", isPresented: Binding(get: { model.navigator != nil && model.errorMessage != nil }, set: { if !$0 { model.clearError() } })) {
            Button("好") { model.clearError() }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Button {
                saveProgress()
                Task {
                    await saveTask?.value
                    if model.errorMessage == nil { dismiss() }
                }
            } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("返回书架")
            VStack(alignment: .leading, spacing: 2) {
                Text(model.book.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(model.location?.title ?? model.currentChapter?.title ?? "EPUB")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu {
                Button("添加书签", systemImage: "bookmark") {
                    guard let locator = model.location, let chapter = model.currentChapter else { return }
                    Task {
                        do {
                            let json = try locator.jsonString()
                            await activity.addBookmark(book: model.book, chapter: chapter, position: 0,
                                                       content: locator.text.highlight ?? chapter.title, epubLocation: json)
                        } catch { model.reportPositionError(error) }
                    }
                }
                Button("我的书签", systemImage: "bookmark.fill") { showsBookmarks = true }
                Button("文字阅读与朗读", systemImage: "speaker.wave.2") { openTextReader(autoplay: false) }
                    .disabled(isOpeningTextReader || model.location == nil)
            } label: { Image(systemName: "ellipsis.circle").font(.title3) }
            .accessibilityLabel("EPUB 更多")
        }.padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack {
                Slider(value: $sliderProgress, in: 0...1) { editing in
                    isScrubbing = editing
                    if !editing { Task { await model.go(toProgress: sliderProgress) } }
                }.accessibilityLabel("阅读进度")
                Text("\(Int(sliderProgress * 100))%")
                    .font(.caption.monospacedDigit()).frame(width: 42)
            }
            HStack {
                Button { Task { await model.turnPage(forward: false) } } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("上一页")
                Spacer()
                Button("目录", systemImage: "list.bullet") { showsTOC = true }
                Spacer()
                Button("听书", systemImage: "headphones") { openTextReader(autoplay: true) }
                    .disabled(isOpeningTextReader || model.location == nil)
                    .accessibilityIdentifier("reader.epub.listen")
                Spacer()
                Button("排版", systemImage: "textformat.size") { showsSettings = true }
                Spacer()
                Button { Task { await model.turnPage(forward: true) } } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("下一页")
            }.font(.subheadline)
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var tocSheet: some View {
        ReadingNavigationStack {
            List(model.tableOfContents) { entry in
                Button {
                    showsTOC = false
                    Task { await model.go(to: entry.link) }
                } label: {
                    Text(entry.link.title ?? "未命名章节")
                        .foregroundStyle(.primary).padding(.leading, CGFloat(min(entry.depth, 6)) * 14)
                }
            }
            .navigationTitle("目录").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { showsTOC = false } } }
        }
    }

    private var settingsSheet: some View {
        ReadingNavigationStack {
            Form {
                Section("阅读方式") {
                    Toggle("滚动阅读", isOn: $scroll)
                    Toggle("使用原书排版", isOn: $publisherStyles)
                }
                Section("字号") {
                    Slider(value: $fontScale, in: 0.7...2.0, step: 0.1)
                    Text("\(Int(fontScale * 100))%")
                }
                Section("背景") {
                    Picker("主题", selection: $theme) {
                        Text("跟随系统").tag("system")
                        Text("白色").tag("light")
                        Text("纸色").tag("sepia")
                        Text("夜间").tag("dark")
                    }
                }
            }
            .navigationTitle("EPUB 排版").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showsSettings = false } } }
        }
    }

    private var bookmarksSheet: some View {
        ReadingNavigationStack {
            List {
                if activity.bookmarks(for: model.book).isEmpty { Text("还没有书签").foregroundStyle(.secondary) }
                ForEach(activity.bookmarks(for: model.book)) { bookmark in
                    Button {
                        showsBookmarks = false
                        Task { await model.go(to: bookmark) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bookmark.chapterName)
                            Text(bookmark.bookText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .swipeActions { Button("删除", role: .destructive) { Task { await activity.removeBookmark(bookmark) } } }
                }
            }
            .navigationTitle("书签").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showsBookmarks = false } } }
        }
    }

    /// 等待当前位置写入后再创建听书页面，避免旧书籍快照覆盖刚读到的位置。
    private func openTextReader(autoplay: Bool) {
        isOpeningTextReader = true
        saveTask?.cancel()
        Task {
            defer { isOpeningTextReader = false }
            do {
                let current = library.books.first { $0.bookUrl == model.book.bookUrl } ?? model.book
                let book = try await model.readingBook(current, rules: replaceRules.rules)
                await library.updateProgress(for: book, chapter: model.chapters[book.durChapterIndex],
                    position: book.durChapterPos, epubLocation: book.readConfig!.epubLocation)
                textReaderBook = book
                startsListening = autoplay
                showsTextReader = true
            } catch { model.reportPositionError(error) }
        }
    }

    /// 将可见正文位置和 EPUB Locator 一起保存，取消的旧页面任务不得覆盖新进度。
    private func persistVisibleProgress() async {
        guard !showsTextReader, !isOpeningTextReader, !isRestoringTextPosition else { return }
        do {
            let current = library.books.first { $0.bookUrl == model.book.bookUrl } ?? model.book
            let book = try await model.readingBook(current, rules: replaceRules.rules)
            try Task.checkCancellation()
            await library.updateProgress(for: book, chapter: model.chapters[book.durChapterIndex],
                position: book.durChapterPos, epubLocation: book.readConfig!.epubLocation)
        } catch is CancellationError {
        } catch { model.reportPositionError(error) }
    }

    /// 立即提交当前画面的进度任务，返回或切换阅读方式时可等待同一个写入完成。
    private func saveProgress() {
        saveTask?.cancel()
        guard !showsTextReader, !isRestoringTextPosition, model.location != nil else { return }
        saveTask = Task { await persistVisibleProgress() }
    }
}

private struct EPUBNavigatorHost: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController
    func makeUIViewController(context: Context) -> EPUBNavigatorViewController { navigator }
    func updateUIViewController(_ controller: EPUBNavigatorViewController, context: Context) {}
}
