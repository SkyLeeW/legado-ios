import SwiftUI
import UIKit
import WebKit
import XCTest
import ReadiumNavigator
@testable import Legado

@MainActor
final class ReaderFontStoreTests: XCTestCase {
    func testInvalidFontDoesNotOverwriteExistingFileOrLeaveNewFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ReaderFontStore.directory, withIntermediateDirectories: true)
        let source = root.appendingPathComponent(UUID().uuidString + ".ttf")
        let target = ReaderFontStore.directory.appendingPathComponent(source.lastPathComponent)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: target)
        }
        let previous = Data("previous font bytes".utf8)
        try Data("invalid font".utf8).write(to: source)
        try previous.write(to: target)

        XCTAssertThrowsError(try ReaderFontStore.install(from: source))
        XCTAssertEqual(try Data(contentsOf: target), previous)

        try FileManager.default.removeItem(at: target)
        XCTAssertThrowsError(try ReaderFontStore.install(from: source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
}

@MainActor
final class AppearanceContrastTests: XCTestCase {
    /// 应用与阅读器使用相反明暗时，只覆盖阅读区域，不能把外部页面一起切换。
    func testReadingAppearanceStaysInsideReader() async throws {
        let cases: [(ColorScheme, String, ColorScheme)] = [
            (.dark, "wechat", .light), (.dark, "preset1", .light), (.light, "night", .dark)
        ]
        for (appScheme, theme, readerScheme) in cases {
            var observed: [String: ColorScheme] = [:]
            let reader = VStack {
                ReaderSchemeProbe { observed["app"] = $0 }
                ReaderSchemeProbe { observed["reader"] = $0 }
                    .readerAppearance(ReaderStylePreset.resolve(theme))
            }.preferredColorScheme(appScheme)
            let controller = UIHostingController(rootView: reader)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            for _ in 0..<20 {
                if observed.count == 2 { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(observed["app"], appScheme)
            XCTAssertEqual(observed["reader"], readerScheme)
            window.isHidden = true
        }
    }

    /// 微信读书和夜间主题向 EPUB 显式传入颜色，原书排版不能再因缺少配色退回白底。
    func testEPUBUsesTheSelectedReadingPalette() {
        let day = ReaderStylePreset.resolve("wechat").epubPreferences(fontScale: 1, publisherStyles: true, scroll: false)
        XCTAssertEqual(day.backgroundColor?.rawValue, 0xC0EDC6)
        XCTAssertEqual(day.textColor?.rawValue, 0x0B0B0B)
        XCTAssertEqual(day.theme, .light)
        XCTAssertEqual(day.publisherStyles, true)

        let night = ReaderStylePreset.resolve("night").epubPreferences(fontScale: 1, publisherStyles: true, scroll: false)
        XCTAssertEqual(night.backgroundColor?.rawValue, 0x000000)
        XCTAssertEqual(night.textColor?.rawValue, 0xADADAD)
        XCTAssertEqual(night.theme, .dark)
    }

    /// 墨水屏模式对两种阅读器统一使用黑字白底，不能因保存了夜间主题而显示成黑底。
    func testEInkAppearanceAppliesToBothReaders() {
        let style = ReaderStylePreset.resolve("night", themeMode: "3")
        let preferences = style.epubPreferences(fontScale: 1, publisherStyles: true, scroll: false)
        XCTAssertEqual(style.colorScheme, .light)
        XCTAssertEqual(preferences.backgroundColor?.rawValue, 0xFFFFFF)
        XCTAssertEqual(preferences.textColor?.rawValue, 0x000000)
        XCTAssertEqual(preferences.theme, .light)
    }

    func testLoginWebViewUsesAdaptiveBackgroundBeforeContentArrives() async throws {
        var source = BookSource(bookSourceUrl: "https://appearance.invalid", bookSourceName: "外观测试")
        source.loginUrl = "about:blank"
        let controller = UIHostingController(rootView: SourceLoginView(source: source))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func webView(in view: UIView) -> WKWebView? {
            if let view = view as? WKWebView { return view }
            return view.subviews.lazy.compactMap { webView(in: $0) }.first
        }
        window.layoutIfNeeded()
        for _ in 0..<20 {
            if webView(in: controller.view) != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let web = try XCTUnwrap(webView(in: controller.view))
        XCTAssertFalse(web.isOpaque)
        for style in [UIUserInterfaceStyle.dark, .light] {
            window.overrideUserInterfaceStyle = style
            window.layoutIfNeeded()
            let traits = UITraitCollection(userInterfaceStyle: style)
            let background = try XCTUnwrap(web.backgroundColor).resolvedColor(with: traits)
            let scroll = try XCTUnwrap(web.scrollView.backgroundColor).resolvedColor(with: traits)
            if style == .dark {
                XCTAssertLessThan(luminance(background), 0.15)
                XCTAssertLessThan(luminance(scroll), 0.15)
            } else {
                XCTAssertGreaterThan(luminance(background), 0.6)
                XCTAssertGreaterThan(luminance(scroll), 0.6)
            }
        }
    }

    func testSyntaxTokensHaveReadableContrastInBaseAndElevatedAppearances() {
        let samples: [(SyntaxCodeEditor.Language, String)] = [
            (.json, #"{"title":"正文","count":12,"enabled":true,"empty":null}"#),
            (.rule, "@css:div && $.title {{key}} ##"),
            (.regex, #"\d+.*(word){2,4}"#),
            (.javascript, "// comment\nconst value = 'text'; return 123; /* comment */")
        ]
        for style in [UIUserInterfaceStyle.light, .dark] {
            for level in [UIUserInterfaceLevel.base, .elevated] {
                let traits = UITraitCollection(traitsFrom: [
                    UITraitCollection(userInterfaceStyle: style),
                    UITraitCollection(userInterfaceLevel: level)
                ])
                for (language, text) in samples {
                    let editor = SyntaxCodeEditor(text: .constant(text), language: language)
                    let view = UITextView()
                    view.overrideUserInterfaceStyle = style
                    view.text = text
                    editor.makeCoordinator().highlight(view)
                    let background = UIColor.secondarySystemGroupedBackground.resolvedColor(with: traits)
                    view.textStorage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: view.textStorage.length)) { color, _, _ in
                        guard let color = color as? UIColor else { return XCTFail("Missing syntax color") }
                        let foreground = color.resolvedColor(with: traits)
                        let values = [luminance(foreground), luminance(background)].sorted()
                        XCTAssertGreaterThanOrEqual((values[1] + 0.05) / (values[0] + 0.05), 4.5,
                                                    "Low contrast for \(language), \(style), \(level)")
                    }
                }
            }
        }
    }

    private func luminance(_ color: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a))
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}

/// 读取 SwiftUI 实际传递给原生视图的明暗环境，验证页面作用域而非主题解析函数本身。
private struct ReaderSchemeProbe: UIViewRepresentable {
    let onUpdate: (ColorScheme) -> Void

    /// 创建最小原生容器，使探针参与真实的 SwiftUI 环境传递。
    func makeUIView(context: Context) -> UIView { UIView() }

    /// 在原生视图更新时记录当前阅读或应用环境的明暗值。
    func updateUIView(_ view: UIView, context: Context) { onUpdate(context.environment.colorScheme) }
}
