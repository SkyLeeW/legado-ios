import SwiftUI
import UIKit

/// 每页使用独立的有限高度 TextKit 容器，跨页段落由同一排版器连续布局。
@MainActor
final class ReaderPagedChapterLayout {
    let storage: NSTextStorage
    let manager = NSLayoutManager()
    let text: String
    let title: String
    let origin: CGPoint
    private(set) var ranges: [NSRange] = []
    private(set) var glyphRanges: [NSRange] = []
    private(set) var errorMessage: String?

    /// 按实际可用视口排出完整行，标题占用第一页空间，正文范围保持连续且不重叠。
    init(text: String, title: String, configuration: ReaderTextView, size: CGSize) {
        self.text = text
        self.title = title
        origin = CGPoint(x: configuration.paddingLeft, y: configuration.paddingTop + configuration.headerInset)
        let typography = ReaderTypography(configuration: configuration)
        let rendered = NSMutableAttributedString(string: "")
        if configuration.titleMode != 2 || configuration.isVolume, !title.isEmpty {
            rendered.append(NSAttributedString(string: title + "\n", attributes: typography.headingAttributes))
        }
        let prefix = rendered.length
        rendered.append(NSAttributedString(string: text, attributes: typography.bodyAttributes))
        storage = NSTextStorage(attributedString: rendered)
        storage.addLayoutManager(manager)
        let containerSize = CGSize(
            width: size.width - CGFloat(configuration.paddingLeft + configuration.paddingRight),
            height: size.height - CGFloat(configuration.paddingTop + configuration.headerInset
                + configuration.paddingBottom + configuration.footerInset)
        )
        guard containerSize.width > 8, containerSize.height > 0 else {
            errorMessage = "页面没有可用的正文空间，请减小页边距。"
            return
        }
        var consumed = 0
        while consumed < manager.numberOfGlyphs {
            let container = NSTextContainer(size: containerSize)
            container.lineFragmentPadding = 4
            container.lineBreakMode = .byWordWrapping
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            let glyphs = manager.glyphRange(for: container)
            guard glyphs.length > 0 else {
                errorMessage = "当前页面无法容纳一整行文字，请减小字号或页边距。"
                return
            }
            let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let start = max(characters.location - prefix, 0)
            let end = min(max(NSMaxRange(characters) - prefix, 0), text.utf16.count)
            ranges.append(NSRange(location: start, length: end - start))
            glyphRanges.append(glyphs)
            consumed = NSMaxRange(glyphs)
        }
    }

    /// 章节开头固定返回第一页，其余位置定位到包含该正文字符的页面。
    func page(containing position: Int) -> Int {
        if position == 0 { return 0 }
        return ranges.firstIndex(where: { NSLocationInRange(position, $0) }) ?? max(ranges.count - 1, 0)
    }
}

/// 分页画布只绘制当前容器中的字形，不从长滚动视图截取半行文字。
@MainActor
final class ReaderPagedCanvas: UIView {
    var layout: ReaderPagedChapterLayout?
    var pageIndex = 0
    var viewportChanged: (() -> Void)?
    private var previousSize = CGSize.zero

    /// 设置静态文字的无障碍语义，并在翻页和视口变化时重新绘制。
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityIdentifier = "reader.text"
        contentMode = .redraw
        clipsToBounds = true
    }

    /// 阅读画布由代码创建，不使用归档初始化。
    required init?(coder: NSCoder) { fatalError("阅读画布不支持归档初始化") }

    /// 仅在真实视口大小变化时请求重新分页，菜单状态变化不会重排正文。
    override func layoutSubviews() {
        super.layoutSubviews()
        if previousSize != bounds.size {
            previousSize = bounds.size
            viewportChanged?()
        }
    }

    /// 当前页字形使用所属容器的坐标绘制，行高和段落间距由 TextKit 统一处理。
    override func draw(_ rect: CGRect) {
        guard let layout else { return }
        if let message = layout.errorMessage {
            (message as NSString).draw(in: bounds.insetBy(dx: 20, dy: 20), withAttributes: [
                .font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label
            ])
            return
        }
        guard layout.glyphRanges.indices.contains(pageIndex) else { return }
        let glyphs = layout.glyphRanges[pageIndex]
        layout.manager.drawBackground(forGlyphRange: glyphs, at: layout.origin)
        layout.manager.drawGlyphs(forGlyphRange: glyphs, at: layout.origin)
    }
}

/// 翻页、恢复进度和逐页听书共用同一份真实分页结果。
struct ReaderPagedView: UIViewRepresentable {
    let configuration: ReaderTextView
    let chapterID: Int
    let canGoPrevious: Bool
    let canGoNext: Bool

    /// 协调器持有当前页和章节状态，避免 SwiftUI 更新再次消费跨章手势。
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// 创建独立分页画布并安装一次点击、左右滑动与自动阅读时钟。
    func makeUIView(context: Context) -> ReaderPagedCanvas { context.coordinator.makeView() }

    /// 配置变化仅在排版或正文实际改变时重排，普通菜单更新保留当前页。
    func updateUIView(_ view: ReaderPagedCanvas, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(view)
    }

    /// 离开阅读页后释放时钟及视口回调。
    static func dismantleUIView(_ view: ReaderPagedCanvas, coordinator: Coordinator) {
        coordinator.displayLink?.invalidate()
        view.viewportChanged = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ReaderPagedView
        var displayLink: CADisplayLink?
        private weak var view: ReaderPagedCanvas?
        private var chapterID: Int?
        private var styleKey = ""
        private var viewport = CGSize.zero
        private var lastJump: Int?
        private var waitingForChapter = false
        private var turning = false
        private var revision = 0
        private var timestamp: CFTimeInterval = 0
        private var elapsed: CFTimeInterval = 0

        /// 绑定配置快照，章节加载前后由显式章节标识区分。
        init(parent: ReaderPagedView) { self.parent = parent }

        /// 安装自定义翻页手势，避免 UIScrollView 原生分页再次吸附到另一页。
        func makeView() -> ReaderPagedCanvas {
            let canvas = ReaderPagedCanvas(frame: .zero)
            view = canvas
            canvas.viewportChanged = { [weak self, weak canvas] in
                guard let self, let canvas else { return }
                self.update(canvas)
            }
            canvas.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
            for direction: UISwipeGestureRecognizer.Direction in [.left, .right] {
                let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
                swipe.direction = direction
                canvas.addGestureRecognizer(swipe)
            }
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            return canvas
        }

        /// 新章按请求位置恢复，重排保留当前正文锚点，只有明确跳转才改变所选页面。
        func update(_ view: ReaderPagedCanvas) {
            let config = parent.configuration
            view.backgroundColor = config.backgroundColor
            guard view.bounds.width > 0, view.bounds.height > 0 else { return }
            let newChapter = chapterID != parent.chapterID
            let key = config.scrollTypographyKey + "|\(config.isVolume)|\(config.headerInset)|\(config.footerInset)"
            let changed = newChapter || styleKey != key || viewport != view.bounds.size
                || view.layout?.text != config.text || view.layout?.title != config.title
            if changed {
                let anchor = newChapter || view.layout?.text.isEmpty != false
                    ? config.requestedPosition : config.readerPosition
                revision += 1
                view.layer.removeAllAnimations()
                turning = false
                if newChapter { waitingForChapter = false; lastJump = nil }
                chapterID = parent.chapterID
                styleKey = key
                viewport = view.bounds.size
                let layout = ReaderPagedChapterLayout(text: config.text, title: config.title, configuration: config, size: view.bounds.size)
                view.layout = layout
                view.pageIndex = layout.page(containing: anchor)
                elapsed = 0
            }
            if let position = config.jumpPosition, position != lastJump {
                lastJump = position
                view.pageIndex = view.layout!.page(containing: position)
                elapsed = 0
            } else if config.jumpPosition == nil { lastJump = nil }
            refresh(view)
        }

        /// 回传捕获时的页码和范围，异步旧章节回调不能覆盖新章第一页的进度。
        private func refresh(_ view: ReaderPagedCanvas) {
            view.setNeedsDisplay()
            let layout = view.layout!
            guard layout.ranges.indices.contains(view.pageIndex) else { return }
            let characters = layout.manager.characterRange(forGlyphRange: layout.glyphRanges[view.pageIndex], actualGlyphRange: nil)
            view.accessibilityLabel = (layout.storage.string as NSString).substring(with: characters)
            let config = parent.configuration
            let page = view.pageIndex
            let position = layout.ranges[page].location
            let generation = revision
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, self.revision == generation, view.pageIndex == page else { return }
                let moved = config.currentPage != page + 1 || config.readerPosition != position
                if config.currentPage != page + 1 { config.currentPage = page + 1 }
                if config.totalPages != layout.ranges.count { config.totalPages = layout.ranges.count }
                if config.pageRanges != layout.ranges { config.pageRanges = layout.ranges }
                if config.readerPosition != position { config.readerPosition = position }
                if moved { config.onPageChanged() }
            }
        }

        /// 一次翻页只消费一个页索引，跨章期间等待新正文，不重复执行同一个手势。
        private func turn(_ direction: Int) {
            guard !turning, !waitingForChapter, let view, let layout = view.layout,
                  !parent.configuration.text.isEmpty, layout.errorMessage == nil else { return }
            elapsed = 0
            let target = view.pageIndex + direction
            if target < 0 || target >= layout.ranges.count {
                waitingForChapter = direction < 0 ? parent.canGoPrevious : parent.canGoNext
                if direction < 0 { parent.configuration.onReachedStart(layout.ranges[view.pageIndex].location) }
                else { parent.configuration.onReachedEnd(parent.configuration.text.utf16.count) }
                return
            }
            let config = parent.configuration
            let mode = config.isEInkMode ? 4 : config.pageAnimation
            let generation = revision
            view.pageIndex = target
            turning = mode != 4
            let finish: (Bool) -> Void = { [weak self] _ in
                guard let self, self.revision == generation else { return }
                self.turning = false
            }
            if mode == 2 {
                UIView.transition(with: view, duration: 0.38, options: direction > 0 ? .transitionCurlUp : .transitionCurlDown,
                                  animations: { self.refresh(view) }, completion: finish)
            } else {
                if mode != 4 {
                    let animation = CATransition()
                    animation.duration = 0.3
                    animation.type = mode == 0 ? (direction > 0 ? .reveal : .moveIn) : .push
                    animation.subtype = direction > 0 ? .fromRight : .fromLeft
                    view.layer.add(animation, forKey: "reader-page")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { finish(true) }
                }
                refresh(view)
            }
        }

        /// 点击区域只产生一次动作，屏幕中央固定切换菜单。
        @objc private func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view, gesture.state == .ended else { return }
            let point = gesture.location(in: view)
            let column = min(max(Int(point.x / (view.bounds.width / 3)), 0), 2)
            let row = min(max(Int(point.y / (view.bounds.height / 3)), 0), 2)
            let index = row * 3 + column
            let action = index == 4 ? 0 : parent.configuration.clickActions[index]
            switch action {
            case 1: turn(1)
            case 2: turn(-1)
            case -1: break
            default: parent.configuration.onTapAction(action)
            }
        }

        /// 左右滑动与点击共用同一个页索引状态机。
        @objc private func swiped(_ gesture: UISwipeGestureRecognizer) { turn(gesture.direction == .left ? 1 : -1) }

        /// 自动阅读到期后按同一分页结果前进，不再对正文执行固定像素滚动。
        @objc private func step(_ link: CADisplayLink) {
            defer { timestamp = link.timestamp }
            let config = parent.configuration
            guard config.isAutoReading, !config.isAutoReadPaused, !turning, !waitingForChapter else { elapsed = 0; return }
            guard timestamp > 0 else { return }
            elapsed += link.timestamp - timestamp
            if elapsed >= config.secondsPerScreen { turn(1) }
        }
    }
}

/// 屏幕分页和听书预排共同使用 TextKit 的真实字形范围，避免按字数估算页边界。
@MainActor
enum ReaderPageLayout {
    /// 按阅读器的滚动边界逐页提取正文范围，保留末页与前页重叠的可见内容。
    static func ranges(in view: UITextView, prefix: Int, bodyLength: Int, pageHeight: CGFloat,
                       minimum: CGFloat, maximum: CGFloat, total: Int) -> [NSRange] {
        var ranges: [NSRange] = []
        for page in 0..<total {
            let offset = page == total - 1 ? maximum : min(minimum + CGFloat(page) * pageHeight, maximum)
            let rect = CGRect(x: 0, y: max(0, offset + view.textContainerInset.top),
                              width: view.textContainer.size.width, height: pageHeight)
            let glyphs = view.layoutManager.glyphRange(forBoundingRect: rect, in: view.textContainer)
            guard glyphs.length > 0 else { continue }
            let characters = view.layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let start = max(characters.location - prefix, 0)
            let end = min(NSMaxRange(characters) - prefix, bodyLength)
            guard end > start else { continue }
            let range = NSRange(location: start, length: end - start)
            if ranges.last != range { ranges.append(range) }
        }
        return ranges
    }
}

extension ReaderTextView {
    /// 用当前视口及同一套字体样式预排后续章节，为没有文字时间轴的渠道生成逐页音频。
    @MainActor
    func speechPageRanges(chapter: ReaderScrollChapter, size: CGSize) -> [NSRange] {
        if pageAnimation == 3 {
            return ReaderScrollChapterLayout(chapter: chapter, configuration: self, width: size.width)
                .pageRanges(height: size.height)
        }
        return ReaderPagedChapterLayout(text: chapter.content, title: chapter.title, configuration: self, size: size).ranges
    }
}

private final class ReaderLayoutTextView: UITextView {
    var onLayout: ((UITextView) -> Void)?
    private var reportedSize = CGSize.zero
    private var reportedContentSize = CGSize.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0,
              bounds.size != reportedSize || contentSize != reportedContentSize else { return }
        reportedSize = bounds.size
        reportedContentSize = contentSize
        onLayout?(self)
    }
}

struct ReaderTextView: UIViewRepresentable {
    let text: String
    let title: String
    let previousTitle: String?
    let previousText: String
    let isPreviousReady: Bool
    let continuationTitle: String?
    let continuationText: String
    let isContinuationReady: Bool
    let isVolume: Bool
    let fontSize: Double
    let fontPath: String
    let letterSpacing: Double
    let lineSpacing: Double
    let paragraphSpacing: Double
    let paragraphIndent: String
    let paddingLeft: Double
    let paddingRight: Double
    let paddingTop: Double
    let paddingBottom: Double
    let headerInset: Double
    let footerInset: Double
    let fontWeight: Int
    let titleMode: Int
    let titleSize: Double
    let titleTopSpacing: Double
    let titleBottomSpacing: Double
    let underlineMode: Int
    let isSelectable: Bool
    let fullJustify: Bool
    let pageAnimation: Int
    let isEInkMode: Bool
    let clickActions: [Int]
    let backgroundColor: UIColor
    let foregroundColor: UIColor
    let requestedPosition: Int
    let jumpPosition: Int?
    let renderRevision: Int
    @Binding var readerPosition: Int
    @Binding var pageRanges: [NSRange]
    @Binding var currentPage: Int
    @Binding var totalPages: Int
    let isAutoReading: Bool
    let isAutoReadPaused: Bool
    let isLoadingNextChapter: Bool
    let secondsPerScreen: Double
    let onReachedEnd: (Int) -> Void
    let onReachedStart: (Int) -> Void
    let onEnteredPrevious: (Int) -> Void
    let onEnteredContinuation: (Int) -> Void
    let onDeferredRender: () -> Void
    let onCancelNextLoading: () -> Void
    let onPageChanged: () -> Void
    let onTapAction: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextView {
        // Pagination uses NSLayoutManager. Start in TextKit 1 rather than
        // switching a TextKit 2 view after its content size has been computed.
        let view: ReaderLayoutTextView
        if #available(iOS 16.0, *) {
            view = ReaderLayoutTextView(usingTextLayoutManager: false)
        } else {
            view = ReaderLayoutTextView(frame: .zero)
        }
        view.onLayout = { [weak coordinator = context.coordinator] view in
            coordinator?.reportPage(in: view)
            coordinator?.reportPageRanges(in: view)
        }
        view.accessibilityIdentifier = "reader.text"
        let effectivePageAnimation = isEInkMode ? 4 : pageAnimation
        view.backgroundColor = backgroundColor
        view.isOpaque = backgroundColor != .clear
        view.delegate = context.coordinator
        view.isEditable = false
        view.isSelectable = false
        view.alwaysBounceVertical = effectivePageAnimation == 3
        view.isScrollEnabled = true
        view.panGestureRecognizer.isEnabled = effectivePageAnimation == 3
        view.textContainer.lineFragmentPadding = 4
        view.showsVerticalScrollIndicator = false
        view.isPagingEnabled = effectivePageAnimation != 3
        view.decelerationRate = effectivePageAnimation == 3 ? .normal : .fast
        context.coordinator.installDisplayLink(for: view)
        context.coordinator.installGestures(on: view)
        context.coordinator.updateInteractionMode(on: view, isScrollMode: effectivePageAnimation == 3)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        let viewportSizeChanged = view.bounds.size != .zero
            && context.coordinator.lastViewportSize != view.bounds.size
        if viewportSizeChanged {
            context.coordinator.lastViewportSize = view.bounds.size
        }
        let effectivePageAnimation = isEInkMode ? 4 : pageAnimation
        view.isSelectable = false
        view.alwaysBounceVertical = effectivePageAnimation == 3
        view.isScrollEnabled = true
        view.panGestureRecognizer.isEnabled = effectivePageAnimation == 3
        view.showsVerticalScrollIndicator = false
        view.isPagingEnabled = effectivePageAnimation != 3
        view.decelerationRate = effectivePageAnimation == 3 ? .normal : .fast
        context.coordinator.updateInteractionMode(on: view, isScrollMode: effectivePageAnimation == 3)
        view.backgroundColor = backgroundColor
        view.isOpaque = backgroundColor != .clear
        view.isSelectable = false
        view.selectedRange = NSRange(location: 0, length: 0)
        view.resignFirstResponder()
        view.textContainerInset = .init(
            top: CGFloat(paddingTop + headerInset),
            left: CGFloat(paddingLeft),
            bottom: CGFloat(paddingBottom + footerInset),
            right: CGFloat(paddingRight)
        )
        let contentKey = text.hashValue
        let primaryContentKey = "\(title)|\(text)".hashValue
        let showsContinuation = effectivePageAnimation == 3 && isContinuationReady && continuationTitle != nil
        let showsPrevious = showsContinuation && isPreviousReady && previousTitle != nil
        let adjacentContentKey = "\(showsPrevious)|\(previousTitle ?? "")|\(previousText)|\(showsContinuation)|\(continuationTitle ?? "")|\(continuationText)".hashValue
        let displaysTitle = titleMode != 2 || isVolume
        let titlePrefix = displaysTitle && !title.isEmpty ? title + "\n" : ""
        let styleKey = "\(contentKey)|\(adjacentContentKey)|\(title)|\(isVolume)|\(fontSize)|\(fontPath)|\(letterSpacing)|\(lineSpacing)|\(paragraphSpacing)|\(paragraphIndent)|\(paddingLeft)|\(paddingRight)|\(paddingTop)|\(paddingBottom)|\(headerInset)|\(footerInset)|\(fontWeight)|\(titleMode)|\(titleSize)|\(titleTopSpacing)|\(titleBottomSpacing)|\(underlineMode)|\(isSelectable)|\(fullJustify)|\(effectivePageAnimation)|\(foregroundColor.hash)"
        if context.coordinator.styleKey != styleKey {
            if context.coordinator.shouldDeferRender(in: view) {
                context.coordinator.needsDeferredRender = true
                return
            }
            let primaryContentChanged = context.coordinator.primaryContentKey != primaryContentKey
            let visiblePosition = context.coordinator.contentCharacter(at: view.contentOffset, in: view)
            context.coordinator.resetAutoReadForPageChange()
            context.coordinator.resetPageRangeRetry()
            context.coordinator.contentKey = contentKey
            context.coordinator.primaryContentKey = primaryContentKey
            context.coordinator.styleKey = styleKey
            let typography = ReaderTypography(configuration: self)
            let bodyAttributes = typography.bodyAttributes
            let rendered = NSMutableAttributedString(string: "")
            context.coordinator.previousBodyStart = nil
            context.coordinator.previousBodyEnd = nil
            context.coordinator.continuationSectionStart = nil
            context.coordinator.continuationBodyStart = nil
            if showsPrevious {
                let previousHeading = displaysTitle ? (previousTitle ?? "") + "\n" : ""
                rendered.append(NSAttributedString(string: previousHeading, attributes: typography.headingAttributes))
                context.coordinator.previousBodyStart = rendered.length
                rendered.append(NSAttributedString(
                    string: previousText.isEmpty ? String(repeating: "\n", count: 80) : previousText,
                    attributes: bodyAttributes
                ))
                context.coordinator.previousBodyEnd = rendered.length
                rendered.append(NSAttributedString(string: "\n\n", attributes: bodyAttributes))
            }
            context.coordinator.currentSectionStart = rendered.length
            if !titlePrefix.isEmpty {
                rendered.append(NSAttributedString(string: titlePrefix, attributes: typography.headingAttributes))
            }
            context.coordinator.renderedPrefixLength = rendered.length
            rendered.append(NSAttributedString(string: text, attributes: bodyAttributes))
            context.coordinator.currentBodyEnd = rendered.length
            if showsContinuation {
                rendered.append(NSAttributedString(string: "\n\n", attributes: bodyAttributes))
                context.coordinator.continuationSectionStart = rendered.length
                let continuationHeading = displaysTitle ? (continuationTitle ?? "") + "\n" : ""
                rendered.append(NSAttributedString(string: continuationHeading, attributes: typography.headingAttributes))
                context.coordinator.continuationBodyStart = rendered.length
                rendered.append(NSAttributedString(
                    string: continuationText.isEmpty ? String(repeating: "\n", count: 80) : continuationText,
                    attributes: bodyAttributes
                ))
            }
            context.coordinator.isApplyingContent = true
            view.attributedText = rendered
            context.coordinator.isApplyingContent = false
            context.coordinator.scroll(
                to: primaryContentChanged ? requestedPosition : visiblePosition,
                in: view
            )
            let generation = context.coordinator.layoutGeneration
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                guard coordinator?.layoutGeneration == generation else { return }
                coordinator?.reportPage(in: view)
                coordinator?.reportPageRanges(in: view)
            }
        } else if viewportSizeChanged {
            context.coordinator.scroll(to: readerPosition, in: view)
            let generation = context.coordinator.layoutGeneration
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                guard coordinator?.layoutGeneration == generation else { return }
                coordinator?.reportPage(in: view)
                coordinator?.reportPageRanges(in: view)
            }
        }
        if let jumpPosition, context.coordinator.lastJumpPosition != jumpPosition {
            context.coordinator.lastJumpPosition = jumpPosition
            context.coordinator.scroll(to: jumpPosition, in: view)
        } else if jumpPosition == nil {
            context.coordinator.lastJumpPosition = nil
        }
        context.coordinator.updateLoadingFooter(in: view, visible: isLoadingNextChapter)
        context.coordinator.updateAutoRead(
            isRunning: isAutoReading,
            isPaused: isAutoReadPaused,
            secondsPerScreen: secondsPerScreen
        )
        // SwiftUI can reset the bindings after the chapter's TextKit layout has
        // already completed. Reconcile them even when the text/style is unchanged.
        if view.bounds.width > 0, view.bounds.height > 0 {
            context.coordinator.reportPage(in: view)
            if pageRanges.isEmpty { context.coordinator.reportPageRanges(in: view) }
        }
    }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: ReaderTextView
        var contentKey = 0
        var primaryContentKey = 0
        var styleKey = ""
        var renderedPrefixLength = 0
        var currentSectionStart = 0
        var currentBodyEnd = 0
        var previousBodyStart: Int?
        var previousBodyEnd: Int?
        var continuationSectionStart: Int?
        var continuationBodyStart: Int?
        var lastJumpPosition: Int?
        private(set) var layoutGeneration = 0
        var lastViewportSize = CGSize.zero
        private var isAutoReading = false
        private var isAutoReadPaused = false
        private var secondsPerScreen = 10.0
        private weak var textView: UITextView?
        private var displayLink: CADisplayLink?
        private var lastTimestamp: CFTimeInterval = 0
        private var isUserDragging = false
        private var lastDragOffsetY: CGFloat = 0
        private var dragDirection = 0
        private var didReachEnd = false
        private var didReachStart = false
        private var didEnterPrevious = false
        private var didEnterContinuation = false
        private var pendingPreviousPosition: Int?
        private var pendingContinuationPosition: Int?
        var needsDeferredRender = false
        var isApplyingContent = false
        private var isTurningPage = false
        private var isRenderingAutoPage = false
        private var lastReportedPage: Int?
        private var autoPageProgress: CGFloat = 0
        private var eInkElapsed: CFTimeInterval = 0
        private var eInkPageInterval: CFTimeInterval = 10
        private var autoPageTarget: CGFloat?
        private weak var autoPageOverlay: UIImageView?
        private var pageRangeRetryCount = 0
        private weak var nextSwipe: UISwipeGestureRecognizer?
        private weak var previousSwipe: UISwipeGestureRecognizer?
        private weak var readerTap: UITapGestureRecognizer?
        private weak var loadingFooter: UIView?
        private var didRequestLoadingCancellation = false

        init(parent: ReaderTextView) { self.parent = parent }

        func installDisplayLink(for view: UITextView) {
            textView = view
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func installGestures(on view: UITextView) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.delaysTouchesBegan = false
            tap.cancelsTouchesInView = false
            tap.delegate = self
            view.addGestureRecognizer(tap)
            readerTap = tap
            let next = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            next.direction = .left
            view.addGestureRecognizer(next)
            let previous = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            previous.direction = .right
            view.addGestureRecognizer(previous)
            nextSwipe = next
            previousSwipe = previous
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer === readerTap || otherGestureRecognizer === readerTap
        }

        func updateInteractionMode(on view: UITextView, isScrollMode: Bool) {
            // The scroll reader owns the vertical pan gesture. Horizontal
            // swipe recognizers must be disabled there or UIKit can cancel the
            // pan before the user reaches the end of a long chapter.
            nextSwipe?.isEnabled = !isScrollMode
            previousSwipe?.isEnabled = !isScrollMode
            view.panGestureRecognizer.isEnabled = isScrollMode
            view.alwaysBounceVertical = isScrollMode
            view.isPagingEnabled = !isScrollMode
            view.showsVerticalScrollIndicator = false
        }

        func updateLoadingFooter(in view: UITextView, visible: Bool) {
            if !visible {
                loadingFooter?.removeFromSuperview()
                loadingFooter = nil
                view.contentInset.bottom = 0
                didRequestLoadingCancellation = false
                return
            }
            let footer: UIView
            if let loadingFooter {
                footer = loadingFooter
            } else {
                let container = UIView()
                container.isUserInteractionEnabled = false
                let indicator = UIActivityIndicatorView(style: .medium)
                indicator.color = parent.foregroundColor.withAlphaComponent(0.65)
                indicator.startAnimating()
                let label = UILabel()
                label.text = "正在加载下一章…"
                label.textColor = parent.foregroundColor.withAlphaComponent(0.65)
                label.font = .systemFont(ofSize: 13)
                let stack = UIStackView(arrangedSubviews: [indicator, label])
                stack.axis = .horizontal
                stack.spacing = 8
                stack.alignment = .center
                stack.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                    stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
                ])
                view.addSubview(container)
                loadingFooter = container
                footer = container
            }
            view.contentInset.bottom = 64
            footer.frame = CGRect(x: 0, y: view.contentSize.height, width: view.bounds.width, height: 52)
        }

        func shouldDeferRender(in view: UITextView) -> Bool {
            parent.pageAnimation == 3 && (isUserDragging || view.isDragging || view.isDecelerating)
        }

        func invalidate() {
            layoutGeneration &+= 1
            resetAutoPage()
            displayLink?.invalidate()
            displayLink = nil
        }

        func updateAutoRead(isRunning: Bool, isPaused: Bool, secondsPerScreen: Double) {
            let wasRunning = isAutoReading
            let wasPaused = isAutoReadPaused
            self.isAutoReading = isRunning
            isAutoReadPaused = isPaused
            self.secondsPerScreen = max(1, secondsPerScreen)
            if wasRunning && !isRunning {
                resetAutoPage()
            } else if !wasRunning && isRunning {
                didReachEnd = false
                lastTimestamp = 0
                eInkPageInterval = self.secondsPerScreen
            } else if isPaused || wasPaused != isPaused {
                lastTimestamp = 0
            }
        }

        func resetAutoReadForPageChange() {
            didReachEnd = false
            didReachStart = false
            lastReportedPage = nil
            didEnterPrevious = false
            didEnterContinuation = false
            pendingPreviousPosition = nil
            pendingContinuationPosition = nil
            resetAutoPage()
        }

        func scroll(to characterPosition: Int, in view: UITextView) {
            guard !view.text.isEmpty else { return }
            layoutGeneration &+= 1
            let generation = layoutGeneration
            let prefix = characterPosition == 0 && parent.pageAnimation == 3
                ? currentSectionStart
                : renderedPrefixLength
            let location = ReaderPositionResolver.renderedLocation(
                position: characterPosition,
                prefixLength: prefix,
                renderedLength: view.text.utf16.count
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                view.layoutManager.ensureLayout(for: view.textContainer)
                let glyph = view.layoutManager.glyphIndexForCharacter(at: location)
                var point = view.layoutManager.boundingRect(
                    forGlyphRange: NSRange(location: glyph, length: 1),
                    in: view.textContainer
                ).origin
                point.y += view.textContainerInset.top
                let limits = self.scrollLimits(for: view)
                let target = min(
                    max(point.y - view.adjustedContentInset.top, limits.minimum),
                    limits.maximum
                )
                view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            }
        }

        private func readingViewportHeight(for view: UITextView) -> CGFloat {
            max(
                view.bounds.height
                    - view.adjustedContentInset.top
                    - view.adjustedContentInset.bottom
                    - view.textContainerInset.top
                    - view.textContainerInset.bottom,
                1
            )
        }

        private func scrollLimits(for view: UITextView) -> (minimum: CGFloat, maximum: CGFloat) {
            let minimum = -view.adjustedContentInset.top
            let maximum = max(
                view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom,
                minimum
            )
            return (minimum, maximum)
        }

        private func pageMetrics(for view: UITextView) -> (current: Int, total: Int) {
            let pageHeight = readingViewportHeight(for: view)
            if parent.pageAnimation == 3, currentBodyEnd > currentSectionStart {
                view.layoutManager.ensureLayout(for: view.textContainer)
                let glyphCount = view.layoutManager.numberOfGlyphs
                if glyphCount > 0 {
                    let first = min(view.layoutManager.glyphIndexForCharacter(at: currentSectionStart), glyphCount - 1)
                    let last = min(view.layoutManager.glyphIndexForCharacter(at: currentBodyEnd - 1), glyphCount - 1)
                    let start = view.layoutManager.boundingRect(
                        forGlyphRange: NSRange(location: first, length: 1), in: view.textContainer
                    ).minY + view.textContainerInset.top - view.adjustedContentInset.top
                    let end = view.layoutManager.boundingRect(
                        forGlyphRange: NSRange(location: last, length: 1), in: view.textContainer
                    ).maxY + view.textContainerInset.top - view.adjustedContentInset.top
                    let total = max(Int(ceil((end - start) / pageHeight)), 1)
                    let position = max(view.contentOffset.y - start, 0)
                    return (min(Int(floor(position / pageHeight)) + 1, total), total)
                }
            }
            let limits = scrollLimits(for: view)
            let scrollRange = max(limits.maximum - limits.minimum, 0)
            let total = max(Int(ceil(scrollRange / pageHeight)) + 1, 1)
            guard total > 1 else { return (1, 1) }
            let position = min(max(view.contentOffset.y - limits.minimum, 0), scrollRange)
            let current = position >= scrollRange - 0.5
                ? total
                : min(Int(floor(position / pageHeight)) + 1, total)
            return (current, total)
        }

        private func renderedCharacter(at offset: CGPoint, in view: UITextView) -> Int {
            guard !view.text.isEmpty else { return 0 }
            let point = CGPoint(
                x: view.textContainerInset.left + 1,
                y: offset.y + view.textContainerInset.top + 1
            )
            let glyphCount = view.layoutManager.numberOfGlyphs
            guard glyphCount > 0 else { return 0 }
            let glyph = min(view.layoutManager.glyphIndex(for: point, in: view.textContainer), glyphCount - 1)
            let character = view.layoutManager.characterIndexForGlyph(at: glyph)
            return min(max(character, 0), view.text.utf16.count)
        }

        func contentCharacter(at offset: CGPoint, in view: UITextView) -> Int {
            let character = renderedCharacter(at: offset, in: view)
            return min(max(character - renderedPrefixLength, 0), parent.text.utf16.count)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isRenderingAutoPage, !isApplyingContent else { return }
            guard let view = scrollView as? UITextView, !view.text.isEmpty else { return }
            if parent.isLoadingNextChapter, !didRequestLoadingCancellation {
                let textBottom = max(
                    view.contentSize.height - view.bounds.height
                        + view.adjustedContentInset.bottom - view.contentInset.bottom,
                    -view.adjustedContentInset.top
                )
                if view.contentOffset.y < textBottom - 44 {
                    didRequestLoadingCancellation = true
                    DispatchQueue.main.async { [weak self] in self?.parent.onCancelNextLoading() }
                }
            }
            if isUserDragging {
                let delta = scrollView.contentOffset.y - lastDragOffsetY
                if abs(delta) > 0.5 { dragDirection = delta > 0 ? 1 : -1 }
                lastDragOffsetY = scrollView.contentOffset.y
            }
            let metrics = pageMetrics(for: view)
            reportPage(in: view)
            if let lastReportedPage, lastReportedPage != metrics.current {
                self.lastReportedPage = metrics.current
                let generation = layoutGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onPageChanged()
                }
            } else if lastReportedPage == nil {
                lastReportedPage = metrics.current
            }
            let contentCharacter = contentCharacter(at: scrollView.contentOffset, in: view)
            let renderedCharacter = renderedCharacter(at: scrollView.contentOffset, in: view)
            if let previousBodyStart,
               let previousBodyEnd,
               renderedCharacter < currentSectionStart {
                pendingContinuationPosition = nil
                let position = min(max(renderedCharacter - previousBodyStart, 0), max(previousBodyEnd - previousBodyStart - 1, 0))
                if isUserDragging || view.isDecelerating {
                    pendingPreviousPosition = position
                    return
                }
                guard !didEnterPrevious else { return }
                didEnterPrevious = true
                let generation = layoutGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onEnteredPrevious(position)
                }
                return
            }
            if let continuationSectionStart,
               let continuationBodyStart,
               renderedCharacter >= continuationSectionStart {
                pendingPreviousPosition = nil
                let position = max(renderedCharacter - continuationBodyStart, 0)
                if isUserDragging || view.isDecelerating {
                    pendingContinuationPosition = position
                    return
                }
                guard !didEnterContinuation else { return }
                didEnterContinuation = true
                let generation = layoutGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onEnteredContinuation(position)
                }
                return
            }
            pendingPreviousPosition = nil
            pendingContinuationPosition = nil
            guard contentCharacter != parent.readerPosition else { return }
            let generation = layoutGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                self.parent.readerPosition = contentCharacter
            }
        }

        func reportPage(in view: UITextView) {
            guard view.bounds.width > 0, view.bounds.height > 0 else { return }
            let metrics = pageMetrics(for: view)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uiPagingDiagnostics") {
                view.accessibilityLabel = "bounds=\(view.bounds.size) content=\(view.contentSize) used=\(view.layoutManager.usedRect(for: view.textContainer)) mode=\(parent.pageAnimation) pages=\(metrics.total)"
            }
            #endif
            guard metrics.current != parent.currentPage || metrics.total != parent.totalPages else { return }
            let generation = layoutGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                self.parent.currentPage = metrics.current
                self.parent.totalPages = metrics.total
            }
        }

        /// 将显示分页使用的真实字形范围回传给阅读进度和逐页听书计划。
        func reportPageRanges(in view: UITextView) {
            guard view.bounds.width > 0, view.bounds.height > 0 else { return }
            if parent.pageAnimation == 3 {
                let ranges = parent.text.isEmpty
                    ? []
                    : [NSRange(location: 0, length: parent.text.utf16.count)]
                guard ranges != parent.pageRanges else { return }
                DispatchQueue.main.async { [weak self] in self?.parent.pageRanges = ranges }
                return
            }
            guard !view.text.isEmpty else { return }
            view.layoutManager.ensureLayout(for: view.textContainer)
            let pageHeight = readingViewportHeight(for: view)
            let limits = scrollLimits(for: view)
            let metrics = pageMetrics(for: view)
            let ranges = ReaderPageLayout.ranges(in: view, prefix: renderedPrefixLength,
                                               bodyLength: parent.text.utf16.count,
                                               pageHeight: pageHeight, minimum: limits.minimum,
                                               maximum: limits.maximum, total: metrics.total)
            if ranges.isEmpty {
                guard pageRangeRetryCount < 10 else { return }
                pageRangeRetryCount += 1
                let generation = layoutGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.reportPageRanges(in: view)
                }
                return
            }
            pageRangeRetryCount = 0
            guard ranges != parent.pageRanges else { return }
            let generation = layoutGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                self.parent.pageRanges = ranges
            }
        }

        func resetPageRangeRetry() {
            pageRangeRetryCount = 0
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isUserDragging = true
            lastDragOffsetY = scrollView.contentOffset.y
            dragDirection = 0
            didReachEnd = false
            didReachStart = false
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if parent.pageAnimation == 3, let view = scrollView as? UITextView {
                triggerChapterBoundaryIfNeeded(in: view)
            }
            if !decelerate {
                isUserDragging = false
                flushPendingChapterTransition()
                requestDeferredRenderIfNeeded()
            }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            if parent.pageAnimation == 3, let view = scrollView as? UITextView {
                triggerChapterBoundaryIfNeeded(in: view)
            }
            isUserDragging = false
            flushPendingChapterTransition()
            requestDeferredRenderIfNeeded()
        }

        private func requestDeferredRenderIfNeeded() {
            guard needsDeferredRender else { return }
            needsDeferredRender = false
            DispatchQueue.main.async { [weak self] in self?.parent.onDeferredRender() }
        }

        private func flushPendingChapterTransition() {
            let previous = pendingPreviousPosition
            let continuation = pendingContinuationPosition
            pendingPreviousPosition = nil
            pendingContinuationPosition = nil
            let generation = layoutGeneration
            if let previous, !didEnterPrevious {
                didEnterPrevious = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onEnteredPrevious(previous)
                }
            } else if let continuation, !didEnterContinuation {
                didEnterContinuation = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onEnteredContinuation(continuation)
                }
            }
        }

        private func triggerChapterBoundaryIfNeeded(in view: UITextView) {
            let (minimum, maximum) = scrollLimits(for: view)
            let atEnd = view.contentOffset.y >= maximum - 0.5
            let atStart = view.contentOffset.y <= minimum + 0.5
            if atEnd, dragDirection > 0, continuationSectionStart == nil, !didReachEnd {
                didReachEnd = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
            } else if atStart, dragDirection < 0, previousBodyStart == nil, !didReachStart {
                didReachStart = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                parent.onReachedStart(contentCharacter(at: view.contentOffset, in: view))
            }
        }

        @objc private func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = textView, gesture.state == .ended else { return }
            let point = gesture.location(in: view)
            // UIScrollView changes its bounds origin as content scrolls, and
            // gesture locations use that content coordinate space. Convert
            // back to viewport coordinates before dividing the visible screen
            // into the 3×3 tap grid.
            let viewportX = point.x - view.bounds.minX
            let viewportY = point.y - view.bounds.minY
            let column = min(max(Int(viewportX / max(view.bounds.width / 3, 1)), 0), 2)
            let row = min(max(Int(viewportY / max(view.bounds.height / 3, 1)), 0), 2)
            let index = row * 3 + column
            let action = index == 4
                ? 0
                : (parent.clickActions.indices.contains(index) ? parent.clickActions[index] : 0)

            if parent.pageAnimation == 3, action == 1 || action == 2 {
                return
            }
            switch action {
            case 1: turnPage(1)
            case 2: turnPage(-1)
            case -1: break
            default: parent.onTapAction(action)
            }
        }

        @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
            turnPage(gesture.direction == .left ? 1 : -1)
        }

        private func turnPage(_ direction: Int) {
            guard !isTurningPage, let view = textView else { return }
            if isAutoReading { resetAutoReadForPageChange() }
            let pageHeight = readingViewportHeight(for: view)
            let (minimum, maximum) = scrollLimits(for: view)
            let target = min(max(view.contentOffset.y + CGFloat(direction) * pageHeight, minimum), maximum)
            if direction < 0, view.contentOffset.y <= minimum + 0.5 {
                parent.onReachedStart(contentCharacter(at: view.contentOffset, in: view))
                return
            }
            if direction > 0, view.contentOffset.y >= maximum - 0.5 {
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
                return
            }
            isTurningPage = true
            let completion: (Bool) -> Void = { [weak self] _ in self?.isTurningPage = false }
            switch parent.isEInkMode ? 4 : parent.pageAnimation {
            case 4:
                view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                isTurningPage = false
            case 0:
                let transition = CATransition()
                transition.duration = 0.3
                transition.type = direction > 0 ? .reveal : .moveIn
                transition.subtype = direction > 0 ? .fromRight : .fromLeft
                view.layer.add(transition, forKey: "reader-cover")
                view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.31) { [weak self] in self?.isTurningPage = false }
            case 1:
                let transition = CATransition()
                transition.duration = 0.3
                transition.type = .push
                transition.subtype = direction > 0 ? .fromRight : .fromLeft
                view.layer.add(transition, forKey: "reader-slide")
                view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.31) { [weak self] in self?.isTurningPage = false }
            case 2:
                UIView.transition(
                    with: view,
                    duration: 0.38,
                    options: direction > 0 ? .transitionCurlUp : .transitionCurlDown,
                    animations: { view.setContentOffset(CGPoint(x: 0, y: target), animated: false) },
                    completion: completion
                )
            default:
                view.setContentOffset(CGPoint(x: 0, y: target), animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in self?.isTurningPage = false }
            }
        }

        private func resetAutoPage() {
            autoPageProgress = 0
            eInkElapsed = 0
            eInkPageInterval = secondsPerScreen
            autoPageTarget = nil
            autoPageOverlay?.removeFromSuperview()
            autoPageOverlay = nil
            lastTimestamp = 0
        }

        private func prepareAutoPage(in view: UITextView) -> Bool {
            let pageHeight = readingViewportHeight(for: view)
            let maximum = scrollLimits(for: view).maximum
            guard view.contentOffset.y < maximum - 0.5 else { return false }
            let target = min(view.contentOffset.y + pageHeight, maximum)
            let originalOffset = view.contentOffset
            isRenderingAutoPage = true
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            view.layoutIfNeeded()
            let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
            let image = renderer.image { context in view.layer.render(in: context.cgContext) }
            view.setContentOffset(originalOffset, animated: false)
            isRenderingAutoPage = false

            let overlay = UIImageView(image: image)
            overlay.isUserInteractionEnabled = false
            overlay.contentMode = .top
            overlay.clipsToBounds = true
            overlay.layer.borderColor = view.tintColor.cgColor
            overlay.layer.borderWidth = 0
            overlay.frame = CGRect(x: 0, y: originalOffset.y, width: view.bounds.width, height: 0)
            view.addSubview(overlay)
            autoPageOverlay = overlay
            autoPageTarget = target
            return true
        }

        private func advancePagedAutoRead(in view: UITextView, elapsed: CFTimeInterval) {
            if autoPageOverlay == nil, !prepareAutoPage(in: view) {
                guard !didReachEnd else { return }
                didReachEnd = true
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
                return
            }
            didReachEnd = false
            let pageHeight = readingViewportHeight(for: view)
            autoPageProgress += pageHeight / CGFloat(secondsPerScreen) * CGFloat(elapsed)
            let revealedHeight = min(autoPageProgress, pageHeight)
            if let overlay = autoPageOverlay {
                overlay.frame = CGRect(
                    x: 0,
                    y: view.contentOffset.y,
                    width: view.bounds.width,
                    height: revealedHeight
                )
                overlay.layer.borderWidth = revealedHeight > 0 ? 0.5 : 0
            }
            guard autoPageProgress >= pageHeight, let target = autoPageTarget else { return }
            autoPageOverlay?.removeFromSuperview()
            autoPageOverlay = nil
            autoPageTarget = nil
            autoPageProgress = 0
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        }

        private func advanceEInkAutoRead(in view: UITextView, elapsed: CFTimeInterval) {
            eInkElapsed += elapsed
            guard eInkElapsed >= eInkPageInterval else { return }
            eInkElapsed = 0
            eInkPageInterval = secondsPerScreen
            let pageHeight = readingViewportHeight(for: view)
            let maximum = scrollLimits(for: view).maximum
            guard view.contentOffset.y < maximum - 0.5 else {
                guard !didReachEnd else { return }
                didReachEnd = true
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
                return
            }
            didReachEnd = false
            let target = min(view.contentOffset.y + pageHeight, maximum)
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        }

        @objc private func step(_ link: CADisplayLink) {
            guard isAutoReading, !isAutoReadPaused, !isUserDragging, let view = textView else {
                lastTimestamp = link.timestamp
                return
            }
            guard lastTimestamp > 0 else {
                lastTimestamp = link.timestamp
                return
            }
            let elapsed = link.timestamp - lastTimestamp
            lastTimestamp = link.timestamp
            if parent.isEInkMode {
                advanceEInkAutoRead(in: view, elapsed: elapsed)
                return
            }
            if parent.pageAnimation != 3 {
                advancePagedAutoRead(in: view, elapsed: elapsed)
                return
            }
            let maximum = scrollLimits(for: view).maximum
            let next = view.contentOffset.y
                + readingViewportHeight(for: view) / CGFloat(secondsPerScreen) * CGFloat(elapsed)
            if next >= maximum - 0.5 {
                view.setContentOffset(CGPoint(x: 0, y: maximum), animated: false)
                guard !didReachEnd else { return }
                didReachEnd = true
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
            } else {
                didReachEnd = false
                view.setContentOffset(CGPoint(x: 0, y: next), animated: false)
            }
        }
    }
}
