import SwiftUI
import AppKit
import Carbon.HIToolbox

@main
struct ClipSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var serverManager: ServerManager!
    private var clipboardStore: ClipboardStore!
    private var eventMonitor: Any?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 初始化剪贴板存储
        clipboardStore = ClipboardStore()
        
        // 初始化服务器
        serverManager = ServerManager(port: 3737, clipboardStore: clipboardStore)
        serverManager.start()
        
        // 创建状态栏图标
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipSync")
            button.action = #selector(togglePopover)
        }
        
        // 创建弹出窗口
        popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 500)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(
                clipboardStore: clipboardStore,
                serverManager: serverManager
            )
        )
        
        // 注册全局快捷键 (⌘ + Shift + V)
        registerHotKey()
    }
    
    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        serverManager.stop()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    // MARK: - 全局快捷键
    private func registerHotKey() {
        // 使用 NSEvent 监听全局快捷键 ⌘ + Shift + B
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 检查 ⌘ + Shift + B
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == [.command, .shift] && event.keyCode == 11 { // 11 是 B 键
                DispatchQueue.main.async {
                    self?.togglePopover()
                }
            }
        }
        
        // 同时监听本地事件（当应用激活时）
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == [.command, .shift] && event.keyCode == 11 {
                DispatchQueue.main.async {
                    self?.togglePopover()
                }
                return nil
            }
            return event
        }
    }
}
