import Foundation
import Network

class ServerManager: ObservableObject {
    @Published var isRunning = false
    @Published var connectedClients = 0
    @Published var localIPAddress: String?
    
    private let port: UInt16
    private var httpListener: NWListener?
    private var wsListener: NWListener?
    private var wsConnections: [NWConnection] = []
    private let clipboardStore: ClipboardStore
    private let queue = DispatchQueue(label: "com.clipsync.server")
    
    // Web 资源路径
    private var webResourcesURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Web")
    }
    
    init(port: UInt16 = 3737, clipboardStore: ClipboardStore) {
        self.port = port
        self.clipboardStore = clipboardStore
        self.localIPAddress = getLocalIPAddress()
    }
    
    func start() {
        startHTTPServer()
        startWebSocketServer()
        DispatchQueue.main.async {
            self.isRunning = true
        }
    }
    
    func stop() {
        httpListener?.cancel()
        wsListener?.cancel()
        wsConnections.forEach { $0.cancel() }
        wsConnections.removeAll()
        DispatchQueue.main.async {
            self.isRunning = false
            self.connectedClients = 0
        }
    }
    
    // MARK: - HTTP Server
    private func startHTTPServer() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            
            httpListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            
            httpListener?.newConnectionHandler = { [weak self] connection in
                self?.handleHTTPConnection(connection)
            }
            
            httpListener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("HTTP 服务器已启动，端口: \(self.port)")
                case .failed(let error):
                    print("HTTP 服务器启动失败: \(error)")
                default:
                    break
                }
            }
            
            httpListener?.start(queue: queue)
        } catch {
            print("创建 HTTP 服务器失败: \(error)")
        }
    }
    
    private func handleHTTPConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            
            // 解析请求路径
            let lines = request.components(separatedBy: "\r\n")
            guard let firstLine = lines.first else {
                connection.cancel()
                return
            }
            
            let parts = firstLine.components(separatedBy: " ")
            guard parts.count >= 2 else {
                connection.cancel()
                return
            }
            
            let method = parts[0]
            var path = parts[1]
            
            // 检查是否是 WebSocket 升级请求
            if request.contains("Upgrade: websocket") {
                self.handleWebSocketUpgrade(connection, request: request)
                return
            }
            
            // 处理 HTTP 请求
            if path == "/" {
                path = "/index.html"
            }
            
            self.serveFile(connection, path: path)
        }
    }
    
    private func serveFile(_ connection: NWConnection, path: String) {
        let fileName = String(path.dropFirst()) // 移除开头的 /
        
        // 从 Bundle 加载文件
        var fileContent: Data?
        var contentType = "text/html"
        
        if fileName == "index.html" {
            fileContent = getIndexHTML().data(using: .utf8)
        } else if fileName == "styles.css" {
            fileContent = getStylesCSS().data(using: .utf8)
            contentType = "text/css"
        } else if fileName == "app.js" {
            fileContent = getAppJS().data(using: .utf8)
            contentType = "application/javascript"
        }
        
        if let content = fileContent {
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: \(contentType); charset=utf-8\r
            Content-Length: \(content.count)\r
            Connection: close\r
            \r
            
            """
            
            var responseData = response.data(using: .utf8)!
            responseData.append(content)
            
            connection.send(content: responseData, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } else {
            let response = "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
    
    // MARK: - WebSocket Server
    private func startWebSocketServer() {
        // WebSocket 使用同一个端口，通过 HTTP Upgrade 处理
    }
    
    private func handleWebSocketUpgrade(_ connection: NWConnection, request: String) {
        // 解析 WebSocket 握手
        guard let keyLine = request.components(separatedBy: "\r\n").first(where: { $0.hasPrefix("Sec-WebSocket-Key:") }) else {
            connection.cancel()
            return
        }
        
        let key = keyLine.replacingOccurrences(of: "Sec-WebSocket-Key:", with: "").trimmingCharacters(in: .whitespaces)
        let acceptKey = generateWebSocketAcceptKey(key)
        
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(acceptKey)\r
        \r
        
        """
        
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] error in
            if error == nil {
                self?.wsConnections.append(connection)
                DispatchQueue.main.async {
                    self?.connectedClients = self?.wsConnections.count ?? 0
                }
                self?.receiveWebSocketMessage(connection)
            }
        })
    }
    
    private func receiveWebSocketMessage(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                print("WebSocket 接收错误: \(error)")
                self.removeConnection(connection)
                return
            }
            
            if isComplete {
                self.removeConnection(connection)
                return
            }
            
            if let data = data, let message = self.decodeWebSocketFrame(data) {
                print("收到消息: \(message)")
                self.clipboardStore.addItem(message)
                
                // 广播给所有客户端
                self.broadcast(message)
            }
            
            // 继续接收消息
            self.receiveWebSocketMessage(connection)
        }
    }
    
    private func broadcast(_ message: String) {
        let frame = encodeWebSocketFrame(message)
        for connection in wsConnections {
            connection.send(content: frame, completion: .contentProcessed { _ in })
        }
    }
    
    private func removeConnection(_ connection: NWConnection) {
        wsConnections.removeAll { $0 === connection }
        connection.cancel()
        DispatchQueue.main.async {
            self.connectedClients = self.wsConnections.count
        }
    }
    
    // MARK: - WebSocket 帧编解码
    private func decodeWebSocketFrame(_ data: Data) -> String? {
        guard data.count >= 2 else { return nil }
        
        let firstByte = data[0]
        let secondByte = data[1]
        
        let isMasked = (secondByte & 0x80) != 0
        var payloadLength = Int(secondByte & 0x7F)
        var offset = 2
        
        if payloadLength == 126 {
            guard data.count >= 4 else { return nil }
            payloadLength = Int(data[2]) << 8 | Int(data[3])
            offset = 4
        } else if payloadLength == 127 {
            guard data.count >= 10 else { return nil }
            payloadLength = 0
            for i in 0..<8 {
                payloadLength = payloadLength << 8 | Int(data[2 + i])
            }
            offset = 10
        }
        
        var maskKey: [UInt8] = []
        if isMasked {
            guard data.count >= offset + 4 else { return nil }
            maskKey = Array(data[offset..<offset+4])
            offset += 4
        }
        
        guard data.count >= offset + payloadLength else { return nil }
        
        var payload = Array(data[offset..<offset+payloadLength])
        
        if isMasked {
            for i in 0..<payload.count {
                payload[i] ^= maskKey[i % 4]
            }
        }
        
        return String(bytes: payload, encoding: .utf8)
    }
    
    private func encodeWebSocketFrame(_ message: String) -> Data {
        let payload = Array(message.utf8)
        var frame: [UInt8] = []
        
        frame.append(0x81) // FIN + Text frame
        
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count < 65536 {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() {
                frame.append(UInt8((payload.count >> (i * 8)) & 0xFF))
            }
        }
        
        frame.append(contentsOf: payload)
        return Data(frame)
    }
    
    private func generateWebSocketAcceptKey(_ key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = key + magic
        let sha1 = combined.data(using: .utf8)!.sha1()
        return sha1.base64EncodedString()
    }
    
    // MARK: - 获取本地 IP
    private func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return nil
        }
        
        defer { freeifaddrs(ifaddr) }
        
        // 优先级：en0 > en1 > bridge > 其他
        var candidates: [(name: String, ip: String)] = []
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                           &hostname, socklen_t(hostname.count),
                           nil, socklen_t(0), NI_NUMERICHOST)
                let ip = String(cString: hostname)
                
                // 排除 localhost 和自环地址
                if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") {
                    candidates.append((name: name, ip: ip))
                    print("发现网络接口: \(name) -> \(ip)")
                }
            }
        }
        
        // 按优先级选择
        let priority = ["en0", "en1", "bridge0", "bridge100"]
        for p in priority {
            if let found = candidates.first(where: { $0.name == p }) {
                address = found.ip
                break
            }
        }
        
        // 如果没找到优先的，就用第一个可用的
        if address == nil, let first = candidates.first {
            address = first.ip
        }
        
        print("选择的 IP 地址: \(address ?? "无")")
        return address
    }
}

// MARK: - SHA1 扩展
import CommonCrypto

extension Data {
    func sha1() -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        self.withUnsafeBytes { buffer in
            _ = CC_SHA1(buffer.baseAddress, CC_LONG(self.count), &digest)
        }
        return Data(digest)
    }
}

// MARK: - 内嵌 Web 资源
extension ServerManager {
    func getIndexHTML() -> String {
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <meta name="apple-mobile-web-app-capable" content="yes">
            <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
            <title>ClipSync</title>
            <link rel="stylesheet" href="styles.css">
        </head>
        <body>
            <div class="container">
                <header>
                    <h1>📋 ClipSync</h1>
                    <div class="status" id="status">
                        <span class="dot"></span>
                        <span class="text">连接中...</span>
                    </div>
                </header>
                
                <main>
                    <div class="input-section">
                        <textarea id="content" placeholder="输入要发送到 Mac 的内容..." rows="4"></textarea>
                        <button id="sendBtn" class="send-btn">
                            <span>发送到 Mac</span>
                            <svg viewBox="0 0 24 24" width="20" height="20">
                                <path fill="currentColor" d="M2.01 21L23 12 2.01 3 2 10l15 2-15 2z"/>
                            </svg>
                        </button>
                    </div>
                    
                    <div class="history-section">
                        <div class="history-header">
                            <h2>历史记录</h2>
                            <button id="clearBtn" class="clear-btn">清空</button>
                        </div>
                        <div class="history-list" id="historyList">
                            <div class="empty-state">暂无历史记录</div>
                        </div>
                    </div>
                </main>
            </div>
            <script src="app.js"></script>
        </body>
        </html>
        """
    }
    
    func getStylesCSS() -> String {
        return """
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        :root {
            --bg-primary: #0a0a0f;
            --bg-secondary: #12121a;
            --bg-tertiary: #1a1a25;
            --text-primary: #ffffff;
            --text-secondary: #8888aa;
            --accent: #6366f1;
            --accent-light: #818cf8;
            --success: #22c55e;
            --danger: #ef4444;
            --border: rgba(255, 255, 255, 0.08);
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', Roboto, sans-serif;
            background: var(--bg-primary);
            color: var(--text-primary);
            min-height: 100vh;
            min-height: 100dvh;
        }

        .container {
            max-width: 480px;
            margin: 0 auto;
            padding: 20px;
            min-height: 100vh;
            min-height: 100dvh;
            display: flex;
            flex-direction: column;
        }

        header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 16px 0;
            margin-bottom: 24px;
        }

        header h1 {
            font-size: 24px;
            font-weight: 700;
            background: linear-gradient(135deg, var(--accent-light), var(--accent));
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }

        .status {
            display: flex;
            align-items: center;
            gap: 8px;
            padding: 8px 16px;
            background: var(--bg-secondary);
            border-radius: 20px;
            font-size: 14px;
        }

        .status .dot {
            width: 8px;
            height: 8px;
            border-radius: 50%;
            background: var(--danger);
            animation: pulse 2s infinite;
        }

        .status.connected .dot {
            background: var(--success);
        }

        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.5; }
        }

        main {
            flex: 1;
            display: flex;
            flex-direction: column;
            gap: 24px;
        }

        .input-section {
            display: flex;
            flex-direction: column;
            gap: 16px;
        }

        textarea {
            width: 100%;
            padding: 16px;
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            border-radius: 16px;
            color: var(--text-primary);
            font-size: 16px;
            resize: none;
            transition: all 0.3s ease;
        }

        textarea:focus {
            outline: none;
            border-color: var(--accent);
            box-shadow: 0 0 0 3px rgba(99, 102, 241, 0.2);
        }

        textarea::placeholder {
            color: var(--text-secondary);
        }

        .send-btn {
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 8px;
            padding: 16px 24px;
            background: linear-gradient(135deg, var(--accent), var(--accent-light));
            border: none;
            border-radius: 12px;
            color: white;
            font-size: 16px;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.3s ease;
        }

        .send-btn:hover {
            transform: translateY(-2px);
            box-shadow: 0 8px 24px rgba(99, 102, 241, 0.4);
        }

        .send-btn:active {
            transform: translateY(0);
        }

        .send-btn:disabled {
            opacity: 0.5;
            cursor: not-allowed;
            transform: none;
        }

        .history-section {
            flex: 1;
            display: flex;
            flex-direction: column;
            min-height: 0;
        }

        .history-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 16px;
        }

        .history-header h2 {
            font-size: 18px;
            font-weight: 600;
            color: var(--text-secondary);
        }

        .clear-btn {
            padding: 8px 16px;
            background: transparent;
            border: 1px solid var(--border);
            border-radius: 8px;
            color: var(--text-secondary);
            font-size: 14px;
            cursor: pointer;
            transition: all 0.3s ease;
        }

        .clear-btn:hover {
            border-color: var(--danger);
            color: var(--danger);
        }

        .history-list {
            flex: 1;
            overflow-y: auto;
            display: flex;
            flex-direction: column;
            gap: 12px;
        }

        .history-item {
            padding: 16px;
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            border-radius: 12px;
            cursor: pointer;
            transition: all 0.3s ease;
            animation: slideIn 0.3s ease;
        }

        @keyframes slideIn {
            from {
                opacity: 0;
                transform: translateY(-10px);
            }
            to {
                opacity: 1;
                transform: translateY(0);
            }
        }

        .history-item:hover {
            border-color: var(--accent);
            background: var(--bg-tertiary);
        }

        .history-item .content {
            font-size: 15px;
            line-height: 1.5;
            word-break: break-all;
            margin-bottom: 8px;
        }

        .history-item .meta {
            display: flex;
            justify-content: space-between;
            align-items: center;
            font-size: 12px;
            color: var(--text-secondary);
        }

        .history-item .time {
            opacity: 0.7;
        }

        .history-item.copied {
            border-color: var(--success);
        }

        .history-item.copied::after {
            content: '已复制';
            position: absolute;
            right: 16px;
            top: 50%;
            transform: translateY(-50%);
            color: var(--success);
            font-size: 12px;
        }

        .empty-state {
            text-align: center;
            padding: 40px 20px;
            color: var(--text-secondary);
        }

        .toast {
            position: fixed;
            bottom: 100px;
            left: 50%;
            transform: translateX(-50%) translateY(100px);
            padding: 12px 24px;
            background: var(--success);
            color: white;
            border-radius: 8px;
            font-size: 14px;
            font-weight: 500;
            opacity: 0;
            transition: all 0.3s ease;
            z-index: 1000;
        }

        .toast.show {
            opacity: 1;
            transform: translateX(-50%) translateY(0);
        }
        """
    }
    
    func getAppJS() -> String {
        return """
        class ClipSync {
            constructor() {
                this.ws = null;
                this.history = JSON.parse(localStorage.getItem('clipHistory') || '[]');
                this.init();
            }

            init() {
                this.bindElements();
                this.renderHistory();
                this.connect();
            }

            bindElements() {
                this.statusEl = document.getElementById('status');
                this.contentEl = document.getElementById('content');
                this.sendBtn = document.getElementById('sendBtn');
                this.clearBtn = document.getElementById('clearBtn');
                this.historyList = document.getElementById('historyList');

                this.sendBtn.addEventListener('click', () => this.send());
                this.clearBtn.addEventListener('click', () => this.clearHistory());
                
                this.contentEl.addEventListener('keydown', (e) => {
                    if (e.key === 'Enter' && !e.shiftKey) {
                        e.preventDefault();
                        this.send();
                    }
                });
            }

            connect() {
                const host = window.location.host;
                this.ws = new WebSocket(`ws://${host}`);

                this.ws.onopen = () => {
                    this.statusEl.classList.add('connected');
                    this.statusEl.querySelector('.text').textContent = '已连接';
                    this.sendBtn.disabled = false;
                };

                this.ws.onclose = () => {
                    this.statusEl.classList.remove('connected');
                    this.statusEl.querySelector('.text').textContent = '已断开';
                    this.sendBtn.disabled = true;
                    setTimeout(() => this.connect(), 3000);
                };

                this.ws.onerror = () => {
                    this.statusEl.classList.remove('connected');
                    this.statusEl.querySelector('.text').textContent = '连接错误';
                };

                this.ws.onmessage = (e) => {
                    // 收到其他设备的消息
                    console.log('收到消息:', e.data);
                };
            }

            send() {
                const content = this.contentEl.value.trim();
                if (!content || !this.ws || this.ws.readyState !== WebSocket.OPEN) return;

                this.ws.send(content);
                this.addToHistory(content);
                this.contentEl.value = '';
                this.showToast('已发送到 Mac');
            }

            addToHistory(content) {
                const item = {
                    id: Date.now(),
                    content,
                    time: new Date().toLocaleString('zh-CN')
                };
                this.history.unshift(item);
                if (this.history.length > 50) {
                    this.history = this.history.slice(0, 50);
                }
                localStorage.setItem('clipHistory', JSON.stringify(this.history));
                this.renderHistory();
            }

            renderHistory() {
                if (this.history.length === 0) {
                    this.historyList.innerHTML = '<div class="empty-state">暂无历史记录</div>';
                    return;
                }

                this.historyList.innerHTML = this.history.map(item => `
                    <div class="history-item" data-id="${item.id}" data-content="${this.escapeHtml(item.content)}">
                        <div class="content">${this.escapeHtml(item.content)}</div>
                        <div class="meta">
                            <span class="time">${item.time}</span>
                        </div>
                    </div>
                `).join('');

                this.historyList.querySelectorAll('.history-item').forEach(el => {
                    el.addEventListener('click', () => {
                        const content = el.dataset.content;
                        this.contentEl.value = content;
                        this.contentEl.focus();
                    });
                });
            }

            clearHistory() {
                this.history = [];
                localStorage.removeItem('clipHistory');
                this.renderHistory();
            }

            showToast(message) {
                let toast = document.querySelector('.toast');
                if (!toast) {
                    toast = document.createElement('div');
                    toast.className = 'toast';
                    document.body.appendChild(toast);
                }
                toast.textContent = message;
                toast.classList.add('show');
                setTimeout(() => toast.classList.remove('show'), 2000);
            }

            escapeHtml(text) {
                const div = document.createElement('div');
                div.textContent = text;
                return div.innerHTML;
            }
        }

        new ClipSync();
        """
    }
}
