import NIO
import NIOHTTP1
import NIOWebSocket
import Foundation
import RxSwift

public class WebSocket: NSObject {
    public weak var delegate: IWebSocketDelegate?

    private var disposeBag = DisposeBag()
    private var logger: Logger?

    private let queue = DispatchQueue(label: "websocket-delegate-queue", qos: .background)
    private let reachabilityManager: IReachabilityManager

    private let url: URL
    private let auth: String?
    private let maxFrameSize: Int

    private var eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var nioWebSocket: INIOWebSocket?
    private var isStarted = false

    public var state: WebSocketState = .disconnected(error: WebSocketState.DisconnectError.notStarted) {
        didSet {
            queue.async { [weak self] in
                self.flatMap {
                    $0.delegate?.didUpdate(state: $0.state)
                }
            }
        }
    }

    public init(url: URL, reachabilityManager: IReachabilityManager, auth: String?, sessionRequestTimeout: TimeInterval = 20,
                maxFrameSize: Int = 1 << 27, logger: Logger? = nil) {
        self.url = url
        self.reachabilityManager = reachabilityManager
        self.auth = auth
        self.maxFrameSize = maxFrameSize
        self.logger = logger

        super.init()

        reachabilityManager.reachabilityObservable
            .observeOn(ConcurrentDispatchQueueScheduler(qos: .userInitiated))
            .subscribe(onNext: { [weak self] _ in
                if reachabilityManager.isReachable {
                    self?.connect()
                } else {
                    self?.disconnect(code: .normalClosure, error: WebSocketState.DisconnectError.socketDisconnected(reason: "Network not reachable"))
                }
            })
            .disposed(by: disposeBag)

        reachabilityManager.connectionTypeUpdatedObservable
            .observeOn(ConcurrentDispatchQueueScheduler(qos: .userInitiated))
            .subscribe(onNext: { [weak self] _ in
                guard case .connected = self?.state else {
                    return
                }

                self?.disconnect(code: .normalClosure, error: WebSocketState.DisconnectError.socketDisconnected(reason: "Network not reachable"))
                self?.connect()
            })
            .disposed(by: disposeBag)

        BackgroundModeObserver.shared
            .foregroundFromExpiredBackgroundObservable
            .subscribe(onNext: { [weak self] _ in
                self?.disconnect(code: .normalClosure, error: WebSocketState.DisconnectError.socketDisconnected(reason: "App in background mode"))
                self?.connect()
            })
            .disposed(by: disposeBag)
    }

    deinit {
        eventLoopGroup.shutdownGracefully { _ in }
    }

    private func connect() {
        guard case .disconnected = state, isStarted else {
            return
        }
        state = .connecting
        logger?.debug("Connecting to \(url)")

        if let socket = nioWebSocket {
            try? socket.close(code: .normalClosure).wait()
        }

        var headers = HTTPHeaders()
        
        if let auth = auth {
            let basicAuth = Data(":\(auth)".utf8).base64EncodedString()
            headers.add(name: "Authorization", value: "Basic \(basicAuth)")
        }

        let configuration = WebSocketClient.Configuration(maxFrameSize: maxFrameSize)
        let nioWebSocket = NIOWebSocket.connect(to: url, headers: headers, configuration: configuration, on: eventLoopGroup) { [weak self] webSocket in
            self?.onConnected(webSocket: webSocket)
        }

        nioWebSocket.whenFailure { [weak self] error in
            self?.logger?.debug("WebSocket connection error: \(error)")
            self?.state = .disconnected(error: error)
        }
    }

    private func disconnect(code: WebSocketErrorCode, error: Error = WebSocketState.DisconnectError.notStarted) {
        logger?.debug("Disconnecting from websocket with code: \(code); error: \(error)")
        nioWebSocket?.close(code: code)
        state = .disconnected(error: error)
    }

    private func onConnected(webSocket: INIOWebSocket) {
        nioWebSocket = webSocket

        webSocket.onClose.whenSuccess { [weak self, weak webSocket] _ in
            self?.nioWebSocket = nil

            guard let lastSocket = webSocket, !lastSocket.waitingForClose else {
                self?.logger?.debug("WebSocket disconnected by client")
                return
            }

            self?.logger?.debug("WebSocket disconnected by server")
            self?.disconnect(code: .unexpectedServerError, error: WebSocketState.DisconnectError.socketDisconnected(reason: "Unexpected Server Error"))
            self?.connect()
        }

        webSocket.onText { [weak self] _, text in
            self?.logger?.debug("WebSocket Received text: \(text)")
            self?.delegate?.didReceive(text: text)
        }

        webSocket.onBinary { [weak self] _, _ in
            self?.logger?.debug("WebSocket Received data")
        }

        webSocket.onError { [weak self] error in
            self?.logger?.debug("WebSocket Received error: \(error)")
            self?.disconnect(code: .protocolError, error: error)
        }

        logger?.debug("WebSocket connected \(webSocket)")
        state = .connected
    }

}

extension WebSocket: IWebSocket {

    public var source: String {
        url.host ?? ""
    }

    public func start() {
        isStarted = true
        connect()
    }

    public func stop() {
        isStarted = false
        disconnect(code: .goingAway)
    }

    public func send(data: Data, completionHandler: ((Error?) -> ())?) throws {
        guard case .connected = state else {
            throw WebSocketState.StateError.notConnected
        }

        nioWebSocket?.send(raw: data, opcode: .binary, fin: true, completionHandler: completionHandler)
    }

    public func send(ping: Data) throws {
        guard case .connected = state else {
            throw WebSocketState.StateError.notConnected
        }

        nioWebSocket?.sendPing(promise: nil)
    }

    public func send(pong: Data) throws {
        // URLSessionWebSocketTask has no method to send "pong" message
    }

}
