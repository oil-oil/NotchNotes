import AppKit
import Foundation
@testable import MarkdownEngine
import SwiftUI
import XCTest
@testable import NotchNotes

@MainActor
final class LocalizationTests: XCTestCase {
    func testDefaultLanguageMatchesPreferredLanguages() {
        XCTAssertEqual(AppLanguage.defaultLanguage(forPreferredLanguages: ["zh-Hans-CN", "en-US"]), .chinese)
        XCTAssertEqual(AppLanguage.defaultLanguage(forPreferredLanguages: ["zh-Hant-HK"]), .chinese)
        XCTAssertEqual(AppLanguage.defaultLanguage(forPreferredLanguages: ["en-US", "zh-Hans-CN"]), .english)
        XCTAssertEqual(AppLanguage.defaultLanguage(forPreferredLanguages: ["ja-JP"]), .english)
        XCTAssertEqual(AppLanguage.defaultLanguage(forPreferredLanguages: []), .english)
    }

    func testAppSettingsStorePersistsLanguageAndRespectsPreferredLanguagesWhenUnset() {
        let suiteName = "NotchNotesTests.Localization.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removeTestSuiteAndPlist(named: suiteName) }

        let chineseDefaultStore = AppSettingsStore(
            defaults: defaults,
            sleepDisabledState: { false },
            preferredLanguages: ["zh-Hans-CN"]
        )
        XCTAssertEqual(chineseDefaultStore.language, .chinese)

        chineseDefaultStore.language = .english
        let persistedEnglishStore = AppSettingsStore(
            defaults: defaults,
            sleepDisabledState: { false },
            preferredLanguages: ["zh-Hans-CN"]
        )
        XCTAssertEqual(persistedEnglishStore.language, .english)

        persistedEnglishStore.language = .chinese
        let persistedChineseStore = AppSettingsStore(
            defaults: defaults,
            sleepDisabledState: { false },
            preferredLanguages: ["en-US"]
        )
        XCTAssertEqual(persistedChineseStore.language, .chinese)
    }

    func testModelAndSlashTitlesSwitchBetweenEnglishAndChinese() throws {
        XCTAssertEqual(TriggerMode.hover.title(for: .english), "Hover")
        XCTAssertEqual(TriggerMode.hover.title(for: .chinese), "悬停")
        XCTAssertEqual(TriggerMode.click.title(for: .english), "Click")
        XCTAssertEqual(TriggerMode.click.title(for: .chinese), "点击")
        XCTAssertEqual(TriggerMode.menuBar.title(for: .english), "Menu Bar Only")
        XCTAssertEqual(TriggerMode.menuBar.title(for: .chinese), "仅菜单栏")

        let suiteName = "NotchNotesTests.LocalizedTitle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchNotesTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removeTestSuiteAndPlist(named: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        let store = NoteStore(
            defaults: defaults,
            archiveURL: directory.appendingPathComponent("notes.json")
        )
        XCTAssertEqual(store.title(for: store.activeTabID, language: .english), "Untitled 1")
        XCTAssertEqual(store.title(for: store.activeTabID, language: .chinese), "未命名 1")

        store.updateText("# Launch Plan\nBody")
        XCTAssertEqual(store.title(for: store.activeTabID, language: .english), "Launch Plan")
        XCTAssertEqual(store.title(for: store.activeTabID, language: .chinese), "Launch Plan")

        let todoItem = try XCTUnwrap(SlashCommandEngine.builtInItems.first { $0.id == "todo" })
        XCTAssertEqual(AppStrings(language: .english).slashItemTitle(todoItem), "Todo List")
        XCTAssertEqual(AppStrings(language: .chinese).slashItemTitle(todoItem), "待办清单")

        let englishStrings = AppStrings(language: .english)
        let chineseStrings = AppStrings(language: .chinese)
        XCTAssertEqual(englishStrings.accessibilityExternalOn, "On, managed by another app")
        XCTAssertEqual(chineseStrings.accessibilityExternalOn, "开启，由其他应用管理")
        XCTAssertEqual(
            englishStrings.externalKeepAwakeHelp,
            "Another app is keeping Mac awake. Turning this off leaves that app’s setting unchanged."
        )
        XCTAssertEqual(
            chineseStrings.externalKeepAwakeHelp,
            "其他应用正在阻止 Mac 休眠。关闭此开关不会改变该应用的设置。"
        )
    }

    func testAppDelegateMenusLiveSwitchBetweenEnglishAndChinese() throws {
        let suiteName = "NotchNotesTests.DelegateLocale.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removeTestSuiteAndPlist(named: suiteName) }

        let settingsStore = AppSettingsStore(
            defaults: defaults,
            sleepDisabledState: { false },
            preferredLanguages: ["en-US"]
        )
        let appDelegate = AppDelegate()
        appDelegate.settingsStoreOverrideForTesting = settingsStore

        let englishStatusMenu = appDelegate.makeStatusContextMenu()
        XCTAssertNotNil(englishStatusMenu.items.first { $0.title == "Launch at Login" })
        XCTAssertNotNil(englishStatusMenu.items.first { $0.title == "Install CLI Command…" })
        XCTAssertNotNil(englishStatusMenu.items.first { $0.title == "Copy Agent Skill Prompt" })
        let languageSubmenu = try XCTUnwrap(
            englishStatusMenu.items.first { $0.title == "Language" }?.submenu
        )
        let chineseMenuItem = try XCTUnwrap(
            languageSubmenu.items.first { $0.title == "简体中文" }
        )
        let englishEditMenu = appDelegate.makeEditMenu()
        XCTAssertNotNil(englishEditMenu.items.first { $0.title == "Heading" })
        XCTAssertNotNil(englishEditMenu.items.first { $0.title == "Todo List" })

        let englishPasteboard = NSPasteboard.withUniqueName()
        defer { englishPasteboard.releaseGlobally() }
        let copiedEnglish = appDelegate.copyAgentSkillPrompt(to: englishPasteboard)
        XCTAssertEqual(englishPasteboard.string(forType: .string), copiedEnglish)
        XCTAssertTrue(copiedEnglish.contains("Install and configure".lowercased()) || copiedEnglish.contains("Set up the `notch-notes` CLI command"))

        appDelegate.selectLanguageFromMenu(chineseMenuItem)
        XCTAssertEqual(settingsStore.language, .chinese)

        let chineseStatusMenu = appDelegate.makeStatusContextMenu()
        XCTAssertNotNil(chineseStatusMenu.items.first { $0.title == "开机自启" })
        XCTAssertNotNil(chineseStatusMenu.items.first { $0.title == "安装 CLI 命令…" })
        XCTAssertNotNil(chineseStatusMenu.items.first { $0.title == "复制 Agent Skill 安装提示词" })
        XCTAssertNotNil(chineseStatusMenu.items.first { $0.title == "新建笔记" })
        XCTAssertNotNil(chineseStatusMenu.items.first { $0.title == "语言" })
        XCTAssertNotNil(chineseStatusMenu.items.first { $0.title == "退出 NotchNotes" })

        let chinesePasteboard = NSPasteboard.withUniqueName()
        defer { chinesePasteboard.releaseGlobally() }
        let copiedChinese = appDelegate.copyAgentSkillPrompt(to: chinesePasteboard)
        XCTAssertEqual(chinesePasteboard.string(forType: .string), copiedChinese)
        XCTAssertTrue(copiedChinese.contains("配置 CLI 命令 `notch-notes`"))

        let chineseEditMenu = appDelegate.makeEditMenu()
        XCTAssertNotNil(chineseEditMenu.items.first { $0.title == "标题" })
        XCTAssertNotNil(chineseEditMenu.items.first { $0.title == "待办清单" })
        XCTAssertNotNil(chineseEditMenu.items.first { $0.title == "加粗" })
    }

    func testMarkdownEngineContextMenuFollowsEditorLocale() throws {
        let englishMenu = buildContextMenu(locale: .english, baseFontItemTitle: "Font")
        XCTAssertNotNil(englishMenu?.items.first { $0.title == "Format" })
        XCTAssertNotNil(englishMenu?.items.first { $0.title == "Heading" })
        XCTAssertNotNil(englishMenu?.items.first { $0.title == "Lists" })

        let chineseMenu = buildContextMenu(locale: .chinese, baseFontItemTitle: "字体")
        XCTAssertNotNil(chineseMenu?.items.first { $0.title == "格式" })
        XCTAssertNotNil(chineseMenu?.items.first { $0.title == "标题" })
        XCTAssertNotNil(chineseMenu?.items.first { $0.title == "列表" })
    }

    private func buildContextMenu(
        locale: MarkdownEditorLocale,
        baseFontItemTitle: String
    ) -> NSMenu? {
        let wrapper = NativeTextViewWrapper(
            text: .constant("Hello"),
            configuration: MarkdownEditorConfiguration(locale: locale)
        )
        let coordinator = wrapper.makeCoordinator()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        textView.string = "Hello"
        let baseMenu = NSMenu()
        baseMenu.addItem(NSMenuItem(title: baseFontItemTitle, action: nil, keyEquivalent: ""))
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!
        return coordinator.textView(textView, menu: baseMenu, for: event, at: 0)
    }

    func testChangingLanguageOnStoreRefreshesAppDelegateMenusAutomatically() throws {
        _ = NSApplication.shared
        let previousMainMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMainMenu }

        let suiteName = "NotchNotesTests.DelegateLiveObserver.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removeTestSuiteAndPlist(named: suiteName) }

        let settingsStore = AppSettingsStore(
            defaults: defaults,
            sleepDisabledState: { false },
            preferredLanguages: ["en-US"]
        )
        let appDelegate = AppDelegate()
        appDelegate.settingsStoreOverrideForTesting = settingsStore
        appDelegate.refreshLocalizedUI()

        XCTAssertEqual(NSApp.mainMenu?.items.last?.title, "Edit")
        XCTAssertEqual(
            NSApp.mainMenu?.items.first?.submenu?.items.first?.title,
            "New Note"
        )

        // Mutate settingsStore.language directly (simulating SwiftUI settings change, not selectLanguageFromMenu)
        settingsStore.language = .chinese

        XCTAssertEqual(NSApp.mainMenu?.items.last?.title, "编辑")
        XCTAssertEqual(
            NSApp.mainMenu?.items.first?.submenu?.items.first?.title,
            "新建笔记"
        )
        let chineseStatusMenu = appDelegate.makeStatusContextMenu()
        let chineseLangItem = try XCTUnwrap(chineseStatusMenu.items.first { $0.title == "语言" }?.submenu?.items.first { $0.title == "简体中文" })
        XCTAssertEqual(chineseLangItem.state, .on)
    }
}
