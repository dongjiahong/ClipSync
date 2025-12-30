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
    private var hotKeyRef: EventHotKeyRef?
    
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
        
        // 注册全局快捷键 (Option + 空格)
        registerCarbonHotKey()
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
        unregisterCarbonHotKey()
    }
    
    // MARK: - Carbon 全局快捷键
    private func registerCarbonHotKey() {
        // Option + 空格
        // 空格键的虚拟键码是 49
        let modifiers: UInt32 = UInt32(optionKey)
        let keyCode: UInt32 = 49 // 空格键
        
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x434C5053) // "CLPS" 的 ASCII
        hotKeyID.id = 1
        
        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)
        
        // 安装事件处理器
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    appDelegate.togglePopover()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
        
        if status != noErr {
            print("安装事件处理器失败: \(status)")
            return
        }
        
        // 注册热键
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        
        if registerStatus != noErr {
            print("注册热键失败: \(registerStatus)")
        } else {
            print("全局快捷键已注册: Option+空格")
        }
    }
    
    private func unregisterCarbonHotKey() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
    }
}
