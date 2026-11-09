import Foundation

/// Alpaca's free IEX trade stream. Reconnects on its own; calls back on the main queue.
public final class LiveStream: NSObject, URLSessionWebSocketDelegate {
    static let url = URL(string: "wss://stream.data.alpaca.markets/v2/iex")!
    let keys: Keys
    var symbols: [String]
    var task: URLSessionWebSocketTask?
    lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    var stopped = false
    var retryAfter: TimeInterval = 15
    public var onTrade: ((String, Double) -> Void)?
    public var onStatus: ((Bool, String?) -> Void)?   // connected, error

    public init(keys: Keys, symbols: [String]) {
        self.keys = keys; self.symbols = symbols
    }

    public func start() {
        stopped = false
        let t = session.webSocketTask(with: Self.url)
        task = t
        t.resume()
        send(["action": "auth", "key": keys.id, "secret": keys.secret])
        send(["action": "subscribe", "trades": symbols])
        receive()
    }

    public func stop() {
        stopped = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    public func update(symbols new: [String]) {
        let gone = Set(symbols).subtracting(new), added = Set(new).subtracting(symbols)
        symbols = new
        if !gone.isEmpty { send(["action": "unsubscribe", "trades": Array(gone)]) }
        if !added.isEmpty { send(["action": "subscribe", "trades": Array(added)]) }
    }

    func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }

    func receive() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let msg):
                let data: Data
                switch msg {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: data = Data()
                }
                let trades = Parse.streamTrades(data), errors = Parse.streamErrors(data), authed = Parse.streamAuthenticated(data)
                DispatchQueue.main.async {
                    if authed { self.onStatus?(true, nil) }   // live only once Alpaca accepted the keys, not when the socket opens
                    for (s, p) in trades { self.onTrade?(s, p) }
                    if let e = errors.first {
                        // 406: the free IEX plan allows one stream connection, someone else holds it; don't hammer, poll instead
                        let busy = e.hasPrefix("406")
                        self.retryAfter = busy ? 300 : 15
                        self.onStatus?(false, busy ? "another app is using the Alpaca live stream (free plan: one connection); prices update every minute meanwhile" : e)
                    }
                }
                self.receive()
            case .failure(let e):
                DispatchQueue.main.async { self.onStatus?(false, e.localizedDescription) }
                self.retry()
            }
        }
    }

    func retry() {
        guard !stopped else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + retryAfter) { [weak self] in
            guard let self = self, !self.stopped else { return }
            self.start()
        }
    }

    public func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol p: String?) {
        DispatchQueue.main.async { self.retryAfter = 15 }
    }
}
