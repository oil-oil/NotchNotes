import AppKit
import Combine
import NotchNotesCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var panelController: NotchPanelController?
    private var statusItem: NSStatusItem?
    private var statusContextMenu: NSMenu?
    private var launchAtLoginMenuItem: NSMenuItem?
    private var languageMenuItems: [NSMenuItem] = []
    private var languageCancellable: AnyCancellable?
    var settingsStoreOverrideForTesting: AppSettingsStore? {
        didSet {
            observeLanguageChanges()
        }
    }

    private var currentLanguage: AppLanguage {
        activeSettingsStore?.language ?? .english
    }

    private var strings: AppStrings {
        AppStrings(language: currentLanguage)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelController = NotchPanelController()
        panelController?.showDocked()
        buildStatusItem()
        buildMenu()
        observeLanguageChanges()
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController?.flush()
    }

    private func observeLanguageChanges() {
        languageCancellable = nil
        guard let settingsStore = activeSettingsStore else { return }
        languageCancellable = settingsStore.$language
            .dropFirst()
            .sink { [weak self] newLanguage in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self?.refreshLocalizedUI(for: newLanguage)
                    }
                } else {
                    Task { @MainActor [weak self] in
                        self?.refreshLocalizedUI(for: newLanguage)
                    }
                }
            }
    }

    func refreshLocalizedUI(for language: AppLanguage? = nil) {
        let resolvedLanguage = language ?? currentLanguage
        let resolvedStrings = AppStrings(language: resolvedLanguage)
        statusItem?.button?.toolTip = resolvedStrings.openNotchNotes
        statusContextMenu = makeStatusContextMenu(language: resolvedLanguage)
        buildMenu(for: resolvedLanguage)
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }

        button.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "NotchNotes")
        button.imagePosition = .imageOnly
        button.action = #selector(statusItemButtonClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = strings.openNotchNotes

        statusContextMenu = makeStatusContextMenu()
        statusItem = item
    }

    private func buildMenu(for language: AppLanguage? = nil) {
        let resolvedStrings = AppStrings(language: language ?? currentLanguage)
        let rootItem = NSMenuItem(title: "NotchNotes", action: nil, keyEquivalent: "")
        rootItem.submenu = makeAppMenu(strings: resolvedStrings)

        let editItem = NSMenuItem(title: resolvedStrings.editMenu, action: nil, keyEquivalent: "")
        editItem.submenu = makeEditMenu(language: language ?? currentLanguage)

        let mainMenu = NSMenu()
        mainMenu.addItem(rootItem)
        mainMenu.addItem(editItem)
        let app: NSApplication? = NSApp
        app?.mainMenu = mainMenu
    }

    private func makeAppMenu(strings: AppStrings) -> NSMenu {
        let appMenu = NSMenu()
        let newItem = NSMenuItem(title: strings.newNoteMenu, action: #selector(newNote), keyEquivalent: "n")
        newItem.target = self
        appMenu.addItem(newItem)

        let showItem = NSMenuItem(title: strings.showNotes, action: #selector(showNotes), keyEquivalent: "")
        showItem.target = self
        appMenu.addItem(showItem)

        let hideItem = NSMenuItem(title: strings.hideNotes, action: #selector(hideNotes), keyEquivalent: "w")
        hideItem.target = self
        appMenu.addItem(hideItem)

        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: strings.quitNotchNotes, action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)

        return appMenu
    }

    func makeStatusContextMenu(language: AppLanguage? = nil) -> NSMenu {
        let resolvedLanguage = language ?? currentLanguage
        let resolvedStrings = AppStrings(language: resolvedLanguage)
        let menu = NSMenu()
        menu.delegate = self

        let newItem = NSMenuItem(title: resolvedStrings.newNoteMenu, action: #selector(newNote), keyEquivalent: "n")
        newItem.target = self
        menu.addItem(newItem)

        menu.addItem(.separator())

        let launchItem = NSMenuItem(
            title: resolvedStrings.launchAtLogin,
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = (activeSettingsStore?.isLaunchAtLoginEnabled == true) ? .on : .off
        menu.addItem(launchItem)
        launchAtLoginMenuItem = launchItem

        let installCLIItem = NSMenuItem(
            title: resolvedStrings.installCLICommand,
            action: #selector(installCLICommandFromMenu),
            keyEquivalent: ""
        )
        installCLIItem.target = self
        menu.addItem(installCLIItem)

        let copySkillPromptItem = NSMenuItem(
            title: resolvedStrings.copyAgentSkillPrompt,
            action: #selector(copyAgentSkillPromptFromMenu),
            keyEquivalent: ""
        )
        copySkillPromptItem.target = self
        menu.addItem(copySkillPromptItem)

        let languageItem = NSMenuItem(title: resolvedStrings.languageMenuTitle, action: nil, keyEquivalent: "")
        let languageSubmenu = NSMenu(title: resolvedStrings.languageMenuTitle)
        var builtLanguageItems: [NSMenuItem] = []
        for option in AppLanguage.allCases {
            let item = NSMenuItem(
                title: option.nativeDisplayName,
                action: #selector(selectLanguageFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option.rawValue
            item.state = (option == resolvedLanguage) ? .on : .off
            languageSubmenu.addItem(item)
            builtLanguageItems.append(item)
        }
        languageMenuItems = builtLanguageItems
        languageItem.submenu = languageSubmenu
        menu.addItem(languageItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: resolvedStrings.quitNotchNotes,
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let launchAtLoginMenuItem,
           menu === statusContextMenu || menu.items.contains(where: { $0 === launchAtLoginMenuItem }) {
            activeSettingsStore?.refreshLaunchAtLoginState()
            launchAtLoginMenuItem.state = (activeSettingsStore?.isLaunchAtLoginEnabled == true) ? .on : .off
        }

        for item in languageMenuItems {
            if let rawValue = item.representedObject as? String,
               let itemLanguage = AppLanguage(rawValue: rawValue) {
                item.state = (itemLanguage == currentLanguage) ? .on : .off
            }
        }
    }

    private var activeSettingsStore: AppSettingsStore? {
        settingsStoreOverrideForTesting ?? panelController?.appSettingsStore
    }

    func makeEditMenu(language: AppLanguage? = nil) -> NSMenu {
        let resolvedStrings = AppStrings(language: language ?? currentLanguage)
        let editMenu = NSMenu(title: resolvedStrings.editMenu)

        let undoItem = NSMenuItem(title: resolvedStrings.undo, action: Selector(("undo:")), keyEquivalent: "z")
        undoItem.target = nil
        editMenu.addItem(undoItem)

        let redoItem = NSMenuItem(title: resolvedStrings.redo, action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        redoItem.target = nil
        editMenu.addItem(redoItem)

        editMenu.addItem(.separator())

        let cutItem = NSMenuItem(title: resolvedStrings.cut, action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        cutItem.target = nil
        editMenu.addItem(cutItem)

        let copyItem = NSMenuItem(title: resolvedStrings.copy, action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copyItem.target = nil
        editMenu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: resolvedStrings.paste, action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        pasteItem.target = nil
        editMenu.addItem(pasteItem)

        editMenu.addItem(.separator())

        let selectAllItem = NSMenuItem(title: resolvedStrings.selectAll, action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        selectAllItem.target = nil
        editMenu.addItem(selectAllItem)

        editMenu.addItem(.separator())

        editMenu.addItem(markdownCommandItem(command: .bold, keyEquivalent: "b", strings: resolvedStrings))
        editMenu.addItem(markdownCommandItem(command: .italic, keyEquivalent: "i", strings: resolvedStrings))
        editMenu.addItem(markdownCommandItem(
            command: .strikethrough,
            keyEquivalent: "x",
            modifiers: [.command, .shift],
            strings: resolvedStrings
        ))
        editMenu.addItem(markdownCommandItem(command: .inlineCode, keyEquivalent: "e", strings: resolvedStrings))
        editMenu.addItem(markdownCommandItem(command: .link, keyEquivalent: "k", strings: resolvedStrings))
        editMenu.addItem(markdownCommandItem(
            command: .quote,
            keyEquivalent: "'",
            modifiers: [.command, .shift],
            strings: resolvedStrings
        ))
        editMenu.addItem(markdownCommandItem(
            command: .unorderedList,
            keyEquivalent: "u",
            modifiers: [.command, .shift],
            strings: resolvedStrings
        ))
        editMenu.addItem(markdownCommandItem(
            command: .orderedList,
            keyEquivalent: "o",
            modifiers: [.command, .shift],
            strings: resolvedStrings
        ))
        editMenu.addItem(markdownCommandItem(
            command: .todoList,
            keyEquivalent: "l",
            modifiers: [.command, .shift],
            strings: resolvedStrings
        ))

        let headingMenuItem = NSMenuItem(title: resolvedStrings.headingMenu, action: nil, keyEquivalent: "")
        let headingMenu = NSMenu(title: resolvedStrings.headingMenu)
        for level in 1...3 {
            let item = NSMenuItem(
                title: resolvedStrings.headingLevel(level),
                action: #selector(performMarkdownHeadingShortcut(_:)),
                keyEquivalent: "\(level)"
            )
            item.keyEquivalentModifierMask = [.command, .option]
            item.tag = level
            item.target = self
            headingMenu.addItem(item)
        }
        headingMenuItem.submenu = headingMenu
        editMenu.addItem(headingMenuItem)

        editMenu.addItem(.separator())

        let findMenuItem = NSMenuItem(title: resolvedStrings.findMenu, action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: resolvedStrings.findMenu)
        findMenu.addItem(findCommand(
            title: resolvedStrings.findEllipsis,
            action: .showFindInterface,
            keyEquivalent: "f"
        ))
        findMenu.addItem(findCommand(
            title: resolvedStrings.findNext,
            action: .nextMatch,
            keyEquivalent: "g"
        ))
        let previousItem = findCommand(
            title: resolvedStrings.findPrevious,
            action: .previousMatch,
            keyEquivalent: "g"
        )
        previousItem.keyEquivalentModifierMask = [.command, .shift]
        findMenu.addItem(previousItem)
        findMenuItem.submenu = findMenu
        editMenu.addItem(findMenuItem)

        return editMenu
    }

    private func markdownCommandItem(
        command: MarkdownCommand,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = [.command],
        strings: AppStrings
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: strings.markdownCommandTitle(command),
            action: #selector(performMarkdownCommandShortcut(_:)),
            keyEquivalent: keyEquivalent
        )
        item.keyEquivalentModifierMask = modifiers
        item.representedObject = command.id
        item.target = self
        return item
    }

    @objc private func performMarkdownCommandShortcut(_ sender: NSMenuItem) {
        guard let commandID = sender.representedObject as? String else { return }
        NotificationCenter.default.post(
            name: .notchNotesMarkdownShortcut,
            object: activeShortcutTarget,
            userInfo: [MarkdownShortcutUserInfoKey.commandID: commandID]
        )
    }

    @objc private func performMarkdownHeadingShortcut(_ sender: NSMenuItem) {
        NotificationCenter.default.post(
            name: .notchNotesMarkdownShortcut,
            object: activeShortcutTarget,
            userInfo: [MarkdownShortcutUserInfoKey.headingLevel: sender.tag]
        )
    }

    private var activeShortcutTarget: Any? {
        if let responder = NSApp.keyWindow?.firstResponder as? NSTextView {
            return responder
        }
        return NSApp.keyWindow
    }

    private func findCommand(
        title: String,
        action: NSTextFinder.Action,
        keyEquivalent: String
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: keyEquivalent
        )
        item.tag = action.rawValue
        item.target = nil
        return item
    }

    @objc private func statusItemButtonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isContextClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if isContextClick {
            statusContextMenu?.popUp(
                positioning: nil,
                at: NSPoint(x: sender.bounds.midX, y: sender.bounds.minY),
                in: sender
            )
        } else {
            panelController?.expand(animated: true)
        }
    }

    @objc private func newNote() {
        panelController?.createNote()
    }

    @objc private func showNotes() {
        panelController?.expand(animated: true)
    }

    @objc private func hideNotes() {
        panelController?.collapse(animated: true)
    }

    @objc func selectLanguageFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let language = AppLanguage(rawValue: rawValue),
              let settingsStore = activeSettingsStore else {
            return
        }
        settingsStore.language = language
        refreshLocalizedUI()
    }

    @objc func toggleLaunchAtLogin() {
        guard let settingsStore = activeSettingsStore else { return }
        settingsStore.toggleLaunchAtLogin()
        launchAtLoginMenuItem?.state = settingsStore.isLaunchAtLoginEnabled ? .on : .off

        if panelController?.isExpanded != true,
           settingsStoreOverrideForTesting == nil,
           let errorMessage = settingsStore.launchAtLoginErrorMessage {
            let needsApproval = settingsStore.launchAtLoginNeedsApproval
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = strings.couldNotUpdateLaunchAtLoginTitle
            alert.informativeText = errorMessage
            if needsApproval {
                alert.addButton(withTitle: strings.openSystemSettings)
            }
            alert.addButton(withTitle: strings.ok)
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if needsApproval, response == .alertFirstButtonReturn {
                settingsStore.openLaunchAtLoginApprovalSettings()
            } else {
                settingsStore.dismissLaunchAtLoginError()
            }
        }
    }

    @discardableResult
    func copyAgentSkillPrompt(to pasteboard: NSPasteboard = .general) -> String {
        let prompt = AgentSkillSetup.installPrompt(isChinese: currentLanguage == .chinese)
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
        return prompt
    }

    @objc func copyAgentSkillPromptFromMenu() {
        copyAgentSkillPrompt(to: .general)
        guard settingsStoreOverrideForTesting == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = strings.agentSkillPromptCopiedTitle
        alert.informativeText = strings.agentSkillPromptCopiedMessage
        alert.addButton(withTitle: strings.ok)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc func installCLICommandFromMenu() {
        let title: String
        let message: String
        let style: NSAlert.Style
        do {
            let result = try CLIInstaller.install()
            style = .informational
            title = strings.cliInstalledTitle
            message = strings.cliInstallSuccessMessage(for: result)
        } catch {
            style = .warning
            title = strings.couldNotInstallCLITitle
            message = strings.cliInstallErrorMessage(for: error)
        }
        guard settingsStoreOverrideForTesting == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: strings.ok)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
