import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

struct MenuBarView: View {
    @ObservedObject var clipboardStore: ClipboardStore
    @ObservedObject var serverManager: ServerManager
    @State private var copiedItemId: UUID?
    @State private var showQRCode = false
    
    var body: some View {
        VStack(spacing: 0) {
            // 头部信息
            headerSection
            
            Divider()
            
            // 二维码区域
            if showQRCode, let ip = serverManager.localIPAddress {
                qrCodeSection(ip: ip)
                Divider()
            }
            
            // 消息列表
            if clipboardStore.items.isEmpty {
                emptyState
            } else {
                messageList
            }
            
            Divider()
            
            // 底部操作
            footerSection
        }
        .frame(width: 360, height: 500)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - 头部信息
    private var headerSection: some View {
        VStack(spacing: 8) {
            HStack {
                Circle()
                    .fill(serverManager.isRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(serverManager.isRunning ? "服务运行中" : "服务已停止")
                    .font(.headline)
                Spacer()
                
                // 快捷键提示
                Text("⌥␣")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(4)
                
                if serverManager.connectedClients > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "iphone")
                        Text("\(serverManager.connectedClients)")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            
            if let ip = serverManager.localIPAddress {
                HStack {
                    Text("http://\(ip):3737")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.blue)
                    Spacer()
                    Button(action: copyAddress) {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("复制地址")
                    
                    Button(action: { withAnimation { showQRCode.toggle() } }) {
                        Image(systemName: showQRCode ? "qrcode" : "qrcode")
                            .foregroundColor(showQRCode ? .blue : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(showQRCode ? "隐藏二维码" : "显示二维码")
                }
                .font(.caption)
            }
        }
        .padding()
    }
    
    // MARK: - 二维码区域
    private func qrCodeSection(ip: String) -> some View {
        VStack(spacing: 8) {
            if let qrImage = generateQRCode(from: "http://\(ip):3737") {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .background(Color.white)
                    .cornerRadius(8)
            }
            Text("手机扫码访问")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.03))
    }
    
    // MARK: - 空状态
    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("暂无内容")
                .foregroundColor(.secondary)
            Text("在手机上发送文字即可同步")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - 消息列表
    private var messageList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(clipboardStore.items) { item in
                    MessageRow(
                        item: item,
                        isCopied: copiedItemId == item.id,
                        onCopy: { copyItem(item) },
                        onDelete: { clipboardStore.removeItem(item) }
                    )
                    Divider()
                }
            }
        }
    }
    
    // MARK: - 底部操作
    private var footerSection: some View {
        HStack {
            Button(action: { clipboardStore.clearAll() }) {
                Label("清空", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(clipboardStore.items.isEmpty)
            
            Spacer()
            
            Button(action: { NSApplication.shared.terminate(nil) }) {
                Label("退出", systemImage: "power")
            }
            .buttonStyle(.borderless)
        }
        .padding()
    }
    
    // MARK: - 操作方法
    private func copyAddress() {
        if let ip = serverManager.localIPAddress {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("http://\(ip):3737", forType: .string)
        }
    }
    
    private func copyItem(_ item: ClipboardItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.content, forType: .string)
        
        withAnimation {
            copiedItemId = item.id
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                if copiedItemId == item.id {
                    copiedItemId = nil
                }
            }
        }
    }
    
    // MARK: - 生成二维码
    private func generateQRCode(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        
        guard let outputImage = filter.outputImage else { return nil }
        
        // 放大二维码
        let scale = 10.0
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

// MARK: - 消息行组件
struct MessageRow: View {
    let item: ClipboardItem
    let isCopied: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.content)
                    .lineLimit(3)
                    .font(.body)
                
                HStack(spacing: 8) {
                    Text(item.source)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(4)
                    
                    Text(item.timeAgo)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            if isHovered || isCopied {
                HStack(spacing: 4) {
                    Button(action: onCopy) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .foregroundColor(isCopied ? .green : .primary)
                    }
                    .buttonStyle(.borderless)
                    
                    Button(action: onDelete) {
                        Image(systemName: "xmark")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            onCopy()
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
