// main.swift — програма «Станція» в рядку меню.
import Cocoa
import SwiftUI
import ServiceManagement
import WebKit
import CoreImage

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, NSWindowDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let engine = Engine.shared
    private var panelWeb: WKWebView!
    private var dashWindow: NSWindow?
    private var dashWeb: WKWebView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.start()
        buildMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = symbol("bolt.batteryblock")
            b.imagePosition = .imageLeading
            b.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            b.title = " …"
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        panelWeb = makeWeb(path: "/panel")
        panelWeb.frame = NSRect(x: 0, y: 0, width: 380, height: 878)
        let host = NSViewController()
        host.view = panelWeb
        host.preferredContentSize = NSSize(width: 380, height: 878)
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 380, height: 878)
        popover.behavior = .transient
        popover.delegate = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self = self, !self.popover.isShown else { return }
            self.panelWeb.evaluateJavaScript("window.PAUSED=true", completionHandler: nil)
        }
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)

        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.updateTitle() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.updateTitle() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.askLoginItemOnce() }
        // якщо іконку в рядку меню сховав «виріз» екрана (забагато іконок) — показуємо вікно, щоб програма не була «невидимою»
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self = self, let w = self.statusItem.button?.window else { return }
            if !w.occlusionState.contains(.visible) || !NSScreen.screens.contains(where: { $0.frame.intersects(w.frame) }) {
                log("іконку в рядку меню не видно — відкриваю вікно")
                self.openDashboard("/")
            }
        }
    }

    /// Повторний запуск (подвійний клік у «Програмах», Spotlight) уже запущеної програми — відкриваємо вікно.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openDashboard("/")
        return false
    }

    /// Меню програми: потрібне для ⌘C/⌘V у полях входу, ⌘W і ⌘Q у вікні дашборду.
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Сховати «Станцію»", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Вийти зі «Станції»", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Редагування")
        edit.addItem(withTitle: "Скасувати", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вирізати", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Скопіювати", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставити", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Виділити все", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Вікно")
        win.addItem(withTitle: "Закрити", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Згорнути", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        NSApp.mainMenu = main
    }

    private func symbol(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Станція") ?? NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Станція")
        img?.isTemplate = true
        return img
    }

    private func updateTitle() {
        engine.lock.lock(); let s = engine.state; engine.lock.unlock()
        var title = " —", icon = "bolt.slash"
        let live = (s["connected"] as? Bool) == true && Date().timeIntervalSince1970 - ((s["last_update"] as? Double) ?? 0) < 30
        if let soc = s["soc"] as? Double {
            let pct = Int(soc.rounded()), inW = (s["in_w"] as? Double) ?? 0, out = (s["out_w"] as? Double) ?? 0
            if !live { title = " \(pct)% · ?" }
            else if inW <= 5 { title = " \(pct)% · −\(Int(out)) Вт"; icon = batteryIcon(pct) }
            else if inW > out + 20 { title = " \(pct)% · +\(Int(inW - out)) Вт"; icon = "battery.100percent.bolt" }
            else { title = " \(pct)%"; icon = "powerplug" }
        }
        statusItem.button?.title = title
        statusItem.button?.image = symbol(icon)
    }

    private func batteryIcon(_ p: Int) -> String {
        p < 13 ? "battery.0percent" : p < 38 ? "battery.25percent" : p < 63 ? "battery.50percent" : p < 88 ? "battery.75percent" : "battery.100percent"
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let ev = NSApp.currentEvent
        if ev?.type == .rightMouseUp || ev?.modifierFlags.contains(.control) == true { showMenu(); return }
        if popover.isShown { popover.performClose(sender); return }
        panelWeb.evaluateJavaScript("window.refresh && refresh()", completionHandler: nil)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Повний дашборд", action: #selector(openFull), keyEquivalent: "d").target = self
        menu.addItem(withTitle: "Акаунт…", action: #selector(accountItem), keyEquivalent: "").target = self
        menu.addItem(.separator())
        if engine.bridge() != nil {
            menu.addItem(withTitle: "Telegram-сповіщення…", action: #selector(openTelegram), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Панель на телефоні…", action: #selector(showPhone), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Увійти в Wonderfree знову…", action: #selector(connectCloud), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "Підключити хмару й Telegram…", action: #selector(connectCloud), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Папка з даними", action: #selector(openData), keyEquivalent: "").target = self
        menu.addItem(.separator())
        if #available(macOS 13.0, *) {
            let it = NSMenuItem(title: "Запускати при вході в систему", action: #selector(toggleLogin), keyEquivalent: "")
            it.target = self
            it.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(it); menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Вийти з програми", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Веб-вигляд, що показує сторінки вбудованого сервера й передає команди назад у програму.
    private func makeWeb(path: String, macWindow: Bool = false) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "app")
        if macWindow {   // відступ під кнопки вікна (світлофор)
            cfg.userContentController.addUserScript(WKUserScript(source: "document.documentElement.classList.add('macwin')",
                                                                 injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        cfg.websiteDataStore = .nonPersistent()
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.setValue(false, forKey: "drawsBackground")
        load(w, path)
        return w
    }
    private func load(_ w: WKWebView, _ path: String) {
        if let u = URL(string: "http://localhost:\(engine.port)\(path)") { w.load(URLRequest(url: u)) }
        // сервер може стартувати на мить пізніше — повторюємо, якщо сторінка не відкрилась
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak w] in
            w?.evaluateJavaScript("document.body ? document.body.children.length : 0") { r, _ in
                if (r as? Int ?? 0) == 0, let u = URL(string: "http://localhost:\(self.engine.port)\(path)") { w?.load(URLRequest(url: u)) }
            }
        }
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        switch m.body as? String ?? "" {
        case "dashboard": openDashboard("/")
        case "settings": openDashboard("/?settings=1")
        case "health": openDashboard("/?tab=hl")
        case "account": showAccount()
        case "quit": NSApp.terminate(nil)
        default: break
        }
    }

    /// Повний дашборд — окреме вікно всередині програми (без браузера).
    func openDashboard(_ path: String) {
        popover.performClose(nil)
        if let win = dashWindow, let web = dashWeb {
            if path != "/" || web.url == nil { load(web, path) }
            win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let web = makeWeb(path: path, macWindow: true)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 860),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "Станція"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = NSColor(red: 0.02, green: 0.024, blue: 0.05, alpha: 1)
        win.minSize = NSSize(width: 720, height: 560)
        win.contentView = web
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.setFrameAutosaveName("StantsiyaDashboard")
        if !win.setFrameUsingName("StantsiyaDashboard") { win.center() }
        dashWindow = win; dashWeb = web
        NSApp.setActivationPolicy(.regular)   // на час відкритого вікна — іконка в Dock і ⌘-Tab
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === dashWindow {
            dashWeb?.load(URLRequest(url: URL(string: "about:blank")!))
            dashWindow = nil; dashWeb = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }
    @objc private func openFull() { openDashboard("/") }
    @objc private func accountItem() { showAccount() }
    @objc private func connectCloud() { openDashboard("/?login=1") }

    // панель опитує сервер лише коли відкрита — менше навантаження й батареї
    func popoverWillShow(_ notification: Notification) { panelWeb.evaluateJavaScript("window.PAUSED=false; window.refresh && refresh()", completionHandler: nil) }
    func popoverDidClose(_ notification: Notification) { panelWeb.evaluateJavaScript("window.PAUSED=true", completionHandler: nil) }

    @objc private func openTelegram() {
        DispatchQueue.global().async {
            let me = self.engine.serverMe()
            DispatchQueue.main.async {
                guard let me = me, let link = me["tg_link"] as? String, let u = URL(string: link) else { self.serverError(); return }
                if (me["tg_bound"] as? Bool) == true {
                    let a = NSAlert(); a.messageText = "Telegram уже підключено"
                    a.informativeText = "Сповіщення приходять у Telegram-бот вашого сервера. Щоб прив'язати інший акаунт Telegram — відкрийте бота з нього й натисніть «Start»."
                    a.addButton(withTitle: "Відкрити бота"); a.addButton(withTitle: "Готово")
                    NSApp.activate(ignoringOtherApps: true)
                    if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(u) }
                } else { NSWorkspace.shared.open(u) }
            }
        }
    }

    @objc private func showPhone() {
        DispatchQueue.global().async {
            let me = self.engine.serverMe()
            DispatchQueue.main.async {
                guard let link = me?["phone_link"] as? String else { self.serverError(); return }
                let a = NSAlert()
                a.messageText = "Панель «патужно» на телефоні"
                a.informativeText = "Наведіть камеру iPhone на код і відкрийте посилання. Потім у Safari: «Поділитися» → «На початковий екран». Не показуйте цей код іншим — він дає керування станцією."
                if let img = self.qr(link) { let v = NSImageView(frame: NSRect(x: 0, y: 0, width: 220, height: 220)); v.image = img; a.accessoryView = v }
                a.addButton(withTitle: "Готово"); a.addButton(withTitle: "Скопіювати посилання")
                NSApp.activate(ignoringOtherApps: true)
                if a.runModal() == .alertSecondButtonReturn { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link, forType: .string) }
            }
        }
    }

    private func serverError() {
        let a = NSAlert(); a.messageText = "Сервер не відповідає"
        a.informativeText = "Перевірте інтернет і спробуйте ще раз за хвилину."
        NSApp.activate(ignoringOtherApps: true); a.runModal()
    }

    private func qr(_ text: String) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage"); f.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: ci)
        let img = NSImage(size: NSSize(width: 220, height: 220)); img.addRepresentation(rep)
        return img
    }

    @objc private func openData() { NSWorkspace.shared.open(appSupport) }
    @objc private func quit() { NSApp.terminate(nil) }

    /// Вікно акаунта: що підключено, зміна групи, вихід з акаунта.
    func showAccount() {
        popover.performClose(nil)
        let info = engine.accountInfo()
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        if info.isEmpty {
            a.messageText = "Станцію не підключено"
            a.informativeText = "Увійдіть в акаунт Wonderfree, щоб програма знайшла вашу станцію."
            a.addButton(withTitle: "Підключити"); a.addButton(withTitle: "Закрити")
            if a.runModal() == .alertFirstButtonReturn { openDashboard("/") }
            return
        }
        a.messageText = info["name"].flatMap { $0.isEmpty ? nil : $0 } ?? "Станція"
        let key = info["device_key"] ?? ""
        a.informativeText = """
        Модель: \(info["model"].flatMap { $0.isEmpty ? nil : $0 } ?? "—")
        Пристрій: \(key.isEmpty ? "—" : "…" + key.suffix(4))
        Група відключень: \(info["group"].flatMap { $0.isEmpty ? nil : $0 } ?? "не вказано")
        Пароль Wonderfree ніде не зберігається. Якщо підключено хмару, сервер «патужно» має ключ сесії, щоб читати станцію; «Вийти з акаунта» видаляє ваші дані й з сервера.
        """
        a.addButton(withTitle: "Готово")
        a.addButton(withTitle: "Змінити групу…")
        a.addButton(withTitle: "Вийти з акаунта")
        switch a.runModal() {
        case .alertSecondButtonReturn: openDashboard("/?settings=1")
        case .alertThirdButtonReturn:
            let c = NSAlert()
            c.messageText = "Вийти з акаунта?"
            c.informativeText = "Ключ станції буде видалено з цього Mac. Історія й налаштування залишаться. Щоб знову бачити станцію, потрібно буде увійти ще раз."
            c.alertStyle = .warning
            c.addButton(withTitle: "Вийти"); c.addButton(withTitle: "Скасувати")
            if c.runModal() == .alertFirstButtonReturn { engine.logout(); panelWeb.evaluateJavaScript("window.refresh && refresh()", completionHandler: nil); updateTitle() }
        default: break
        }
    }

    @objc private func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert(); a.messageText = "Не вдалося змінити автозапуск"; a.informativeText = error.localizedDescription; a.runModal()
        }
    }

    private func askLoginItemOnce() {
        guard #available(macOS 13.0, *) else { return }
        let key = "askedLoginItem"
        if UserDefaults.standard.bool(forKey: key) || SMAppService.mainApp.status == .enabled { return }
        UserDefaults.standard.set(true, forKey: key)
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Запускати «Станцію» при вході в систему?"
        a.informativeText = "Тоді програма сама стежитиме за станцією, записуватиме історію й графік відключень. Змінити можна будь-коли правим кліком по іконці."
        a.addButton(withTitle: "Так, запускати"); a.addButton(withTitle: "Ні")
        if a.runModal() == .alertFirstButtonReturn { toggleLogin() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
