import Flutter
import WebKit

public class RpcDartWasmPlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel?
    private var messenger: FlutterBinaryMessenger?
    private var runtimes: [String: WasmRuntime] = [:]
    private var checkSupportWebView: WKWebView?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "rpc_dart_wasm",
            binaryMessenger: registrar.messenger()
        )
        let instance = RpcDartWasmPlugin()
        instance.channel = channel
        instance.messenger = registrar.messenger()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "checkSupport":
            checkSupport(result: result)
        case "loadRuntime":
            let args = call.arguments as? [String: Any]
            let wasmData = (args?["wasm"] as? FlutterStandardTypedData)?.data
            let mjsCode = args?["mjs"] as? String
            let prefix = args?["jsBootPrefix"] as? String ?? ""
            loadRuntime(wasmBytes: wasmData, mjsCode: mjsCode, jsBootPrefix: prefix, result: result)
        case "closeRuntime":
            let args = call.arguments as? [String: Any]
            closeRuntime(runtimeId: args?["runtimeId"] as? String ?? "")
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Check support

    private func checkSupport(result: @escaping FlutterResult) {
        let webView = WKWebView(frame: .zero)
        checkSupportWebView = webView
        webView.evaluateJavaScript("""
            (function() {
              var r = {};
              r.jsEngineAvailable = true;
              r.hasWebAssembly = (typeof WebAssembly !== 'undefined');
              if (r.hasWebAssembly) {
                try {
                  var bytes = new Uint8Array([
                    0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
                    0x01, 0x05, 0x01, 0x5F, 0x01, 0x7F, 0x01
                  ]);
                  r.wasmGC = WebAssembly.validate(bytes) ? 'GC_SUPPORTED' : 'GC_NOT_VALIDATED';
                } catch(e) { r.wasmGC = 'GC_ERROR: ' + e; }
              }
              return JSON.stringify(r);
            })()
        """) { [weak self] value, error in
            self?.checkSupportWebView = nil
            if let json = value as? String,
               let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result(dict)
            } else {
                result([
                    "jsEngineAvailable": true,
                    "hasWebAssembly": false,
                    "error": error?.localizedDescription ?? "unknown"
                ] as [String: Any])
            }
        }
    }

    // MARK: - Load runtime

    private func loadRuntime(
        wasmBytes: Data?,
        mjsCode: String?,
        jsBootPrefix: String,
        result: @escaping FlutterResult
    ) {
        guard let wasmBytes = wasmBytes, let mjsCode = mjsCode else {
            result(["error": "Missing wasm or mjs data"])
            return
        }
        guard let messenger = self.messenger else {
            result(["error": "No binary messenger"])
            return
        }

        let runtimeId = UUID().uuidString
        let runtime = WasmRuntime(
            runtimeId: runtimeId,
            messenger: messenger,
            rxChannel: runtimeRxChannel(runtimeId),
            wasmBytes: wasmBytes
        )
        runtimes[runtimeId] = runtime
        registerByteChannel(runtimeId: runtimeId)

        let plainJs = stripModuleSyntax(mjsCode)

        let bootHtml = """
        <!DOCTYPE html><html><head><meta charset="utf-8"></head><body><script>
        var _nativeSetTimeout = setTimeout;
        var _nativeClearTimeout = clearTimeout;
        var _microtaskQueue = [];
        var _timerId = 0;
        var _timers = {};
        var _nextTickHandle = 0;
        function queueMicrotask(fn) { _microtaskQueue.push(fn); }
        function _flushMicrotasks() {
          while (_microtaskQueue.length > 0) {
            var fn = _microtaskQueue.shift();
            try { fn(); } catch(e) { console.error(e); }
          }
        }
        var _origConsole = typeof console !== 'undefined' ? console : {};
        console = {
          log: function() { var m = Array.prototype.join.call(arguments, ' '); window.webkit.messageHandlers.rpcConsole.postMessage({level: 'info', message: m}); },
          warn: function() { var m = Array.prototype.join.call(arguments, ' '); window.webkit.messageHandlers.rpcConsole.postMessage({level: 'warn', message: m}); },
          error: function() { var m = Array.prototype.join.call(arguments, ' '); window.webkit.messageHandlers.rpcConsole.postMessage({level: 'error', message: m}); },
          info: function() { var m = Array.prototype.join.call(arguments, ' '); window.webkit.messageHandlers.rpcConsole.postMessage({level: 'info', message: m}); },
          debug: function() { var m = Array.prototype.join.call(arguments, ' '); window.webkit.messageHandlers.rpcConsole.postMessage({level: 'debug', message: m}); }
        };
        function setTimeout(fn, ms) {
          var id = ++_timerId;
          _timers[id] = { fn: fn, interval: false, ms: ms || 0, next: Date.now() + (ms || 0) };
          _scheduleNextTick();
          return id;
        }
        function setInterval(fn, ms) {
          var id = ++_timerId;
          _timers[id] = { fn: fn, interval: true, ms: ms || 16, next: Date.now() + (ms || 16) };
          _scheduleNextTick();
          return id;
        }
        function clearInterval(id) { delete _timers[id]; }
        function clearTimeout(id) { delete _timers[id]; }
        function _scheduleNextTick() {
          var now = Date.now();
          var minDelay = Infinity;
          var ids = Object.keys(_timers);
          for (var i = 0; i < ids.length; i++) {
            var t = _timers[ids[i]];
            if (t) {
              var d = t.next - now;
              if (d < minDelay) minDelay = d;
            }
          }
          if (_nextTickHandle) {
            _nativeClearTimeout(_nextTickHandle);
            _nextTickHandle = 0;
          }
          if (minDelay === Infinity) return;
          if (minDelay < 0) minDelay = 0;
          _nextTickHandle = _nativeSetTimeout(_runDueTimers, minDelay);
        }
        function _runDueTimers() {
          _nextTickHandle = 0;
          var now = Date.now();
          var ids = Object.keys(_timers);
          for (var i = 0; i < ids.length; i++) {
            var id = ids[i];
            var t = _timers[id];
            if (!t) continue;
            if (now >= t.next) {
              if (t.interval) {
                t.next = now + t.ms;
              } else {
                delete _timers[id];
              }
              try { t.fn(); } catch(e) { console.error(e); }
            }
          }
          _flushMicrotasks();
          _scheduleNextTick();
        }
        function _rpcWasmSendBytes(bytes) {
          fetch('rpc-wasm:///send', {method: 'POST', body: bytes});
        }
        var _recvRunning = false;
        function _rpcWasmReceiveBytes(bytes) {
          if (typeof rpcWasmReceiveBytes === 'function') {
            rpcWasmReceiveBytes(bytes);
          } else if (typeof globalThis.rpcWasmReceiveBytes === 'function') {
            globalThis.rpcWasmReceiveBytes(bytes);
          }
          _flushMicrotasks();
        }
        function _startRecvLoop() {
          if (_recvRunning) return;
          _recvRunning = true;
          (function poll() {
            fetch('rpc-wasm:///recv').then(function(r) {
              return r.arrayBuffer();
            }).then(function(buf) {
              _rpcWasmReceiveBytes(new Uint8Array(buf));
              poll();
            }).catch(function(e) {
              _recvRunning = false;
            });
          })();
        }
        \(jsBootPrefix)
        \(plainJs)
        (async function() {
          try {
            var resp = await fetch('rpc-wasm:///module.wasm');
            var compiled;
            if (typeof compileStreaming === 'function') {
              compiled = await compileStreaming(resp);
            } else {
              var wasmBytes = new Uint8Array(await resp.arrayBuffer());
              compiled = await compile(wasmBytes);
            }
            var app = await compiled.instantiate({});
            _startRecvLoop();
            app.invokeMain();
            _flushMicrotasks();
            window.webkit.messageHandlers.rpcBoot.postMessage('ok');
          } catch(e) {
            window.webkit.messageHandlers.rpcBoot.postMessage('error:' + e + (e && e.stack ? '\\n' + e.stack : ''));
          }
        })();
        </script></body></html>
        """

        runtime.boot(html: bootHtml) { [weak self] bootResult in
            if let error = bootResult {
                self?.messenger?.setMessageHandlerOnChannel(self?.runtimeTxChannel(runtimeId) ?? "", binaryMessageHandler: nil)
                self?.runtimes.removeValue(forKey: runtimeId)?.close()
                result(["runtimeId": nil, "error": error] as [String: Any?])
            } else {
                NSLog("[RpcDartWasm] Runtime %@ booted on WKWebView", runtimeId)
                result(["runtimeId": runtimeId, "error": nil] as [String: Any?])
            }
        }
    }

    // MARK: - Close / byte channels

    private func closeRuntime(runtimeId: String) {
        messenger?.setMessageHandlerOnChannel(runtimeTxChannel(runtimeId), binaryMessageHandler: nil)
        runtimes.removeValue(forKey: runtimeId)?.close()
    }

    private func registerByteChannel(runtimeId: String) {
        messenger?.setMessageHandlerOnChannel(runtimeTxChannel(runtimeId), binaryMessageHandler: { [weak self] message, reply in
            guard let self = self, let bytes = message else {
                reply(nil)
                return
            }
            self.receiveRuntimeBytes(runtimeId: runtimeId, bytes: bytes)
            reply(nil)
        })
    }

    private func receiveRuntimeBytes(runtimeId: String, bytes: Data) {
        guard let runtime = runtimes[runtimeId] else { return }
        runtime.enqueueForJS(bytes)
    }

    private func stripModuleSyntax(_ code: String) -> String {
        return code
            .replacingOccurrences(of: "export async function ", with: "async function ")
            .replacingOccurrences(of: "export const ", with: "const ")
            .replacingOccurrences(of: "export function ", with: "function ")
            .replacingOccurrences(of: "export class ", with: "class ")
    }

    private func runtimeTxChannel(_ runtimeId: String) -> String {
        return "rpc_dart_wasm/\(runtimeId)/outgoing"
    }

    private func runtimeRxChannel(_ runtimeId: String) -> String {
        return "rpc_dart_wasm/\(runtimeId)/incoming"
    }
}

// MARK: - SchemeHandler (zero-copy byte transport + WASM serving)

private class SchemeHandler: NSObject, WKURLSchemeHandler {
    private var wasmBytes: Data?
    private var pendingRecvTask: WKURLSchemeTask?
    private var recvQueue: [Data] = []
    private var stopped = false
    var onSend: ((Data) -> Void)?

    init(wasmBytes: Data) {
        self.wasmBytes = wasmBytes
        super.init()
    }

    func enqueue(_ data: Data) {
        if let task = pendingRecvTask {
            pendingRecvTask = nil
            respond(task: task, data: data)
        } else {
            recvQueue.append(data)
        }
    }

    func stop() {
        stopped = true
        wasmBytes = nil
        if let task = pendingRecvTask {
            pendingRecvTask = nil
            let response = HTTPURLResponse(
                url: task.request.url!,
                statusCode: 499,
                httpVersion: nil,
                headerFields: nil
            )!
            task.didReceive(response)
            task.didFinish()
        }
        recvQueue.removeAll()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard !stopped else {
            urlSchemeTask.didFailWithError(NSError(domain: "rpc-wasm", code: -1))
            return
        }

        let path = urlSchemeTask.request.url?.path ?? ""

        if path == "/module.wasm" || path == "module.wasm" {
            guard let wasm = wasmBytes else {
                urlSchemeTask.didFailWithError(NSError(domain: "rpc-wasm", code: -2))
                return
            }
            let response = HTTPURLResponse(
                url: urlSchemeTask.request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/wasm",
                    "Content-Length": "\(wasm.count)"
                ]
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(wasm)
            urlSchemeTask.didFinish()
            self.wasmBytes = nil
            return
        }

        if path == "/send" || path == "send" {
            let bodyData = readBody(from: urlSchemeTask.request)
            if !bodyData.isEmpty {
                onSend?(bodyData)
            }
            let response = HTTPURLResponse(
                url: urlSchemeTask.request.url!,
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didFinish()
            return
        }

        if path == "/recv" || path == "recv" {
            if !recvQueue.isEmpty {
                let data = recvQueue.removeFirst()
                respond(task: urlSchemeTask, data: data)
            } else {
                if let prev = pendingRecvTask {
                    prev.didFailWithError(NSError(domain: "rpc-wasm", code: -5,
                        userInfo: [NSLocalizedDescriptionKey: "superseded by new recv"]))
                }
                pendingRecvTask = urlSchemeTask
            }
            return
        }

        urlSchemeTask.didFailWithError(NSError(domain: "rpc-wasm", code: -3))
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        if pendingRecvTask === urlSchemeTask {
            pendingRecvTask = nil
        }
    }

    private func readBody(from request: URLRequest) -> Data {
        if let body = request.httpBody, !body.isEmpty {
            return body
        }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        let bufferSize = 16384
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 {
                result.append(buffer, count: read)
            } else {
                break
            }
        }
        return result
    }

    private func respond(task: WKURLSchemeTask, data: Data) {
        let response = HTTPURLResponse(
            url: task.request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "application/octet-stream",
                "Content-Length": "\(data.count)"
            ]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}

// MARK: - WasmRuntime (WKWebView wrapper)

private class WasmRuntime: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let runtimeId: String
    let webView: WKWebView
    private let messenger: FlutterBinaryMessenger
    private let rxChannel: String
    private let schemeHandler: SchemeHandler
    private var bootCompletion: ((String?) -> Void)?
    private var bootTimeoutTimer: Timer?

    private static let bootTimeoutSeconds: TimeInterval = 30

    init(runtimeId: String, messenger: FlutterBinaryMessenger, rxChannel: String, wasmBytes: Data) {
        self.runtimeId = runtimeId
        self.messenger = messenger
        self.rxChannel = rxChannel
        self.schemeHandler = SchemeHandler(wasmBytes: wasmBytes)

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "rpc-wasm")
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        schemeHandler.onSend = { [weak self] data in
            guard let self = self else { return }
            self.messenger.send(onChannel: self.rxChannel, message: data)
        }

        webView.navigationDelegate = self
        webView.configuration.userContentController.add(self, name: "rpcBoot")
        webView.configuration.userContentController.add(self, name: "rpcConsole")
    }

    func boot(html: String, completion: @escaping (String?) -> Void) {
        bootCompletion = completion
        webView.loadHTMLString(html, baseURL: nil)

        bootTimeoutTimer = Timer.scheduledTimer(withTimeInterval: Self.bootTimeoutSeconds, repeats: false) { [weak self] _ in
            guard let self = self, let cb = self.bootCompletion else { return }
            self.bootCompletion = nil
            self.bootTimeoutTimer = nil
            cb("boot_timeout: no response within \(Int(Self.bootTimeoutSeconds))s")
        }
    }

    func enqueueForJS(_ data: Data) {
        schemeHandler.enqueue(data)
    }

    func close() {
        bootTimeoutTimer?.invalidate()
        bootTimeoutTimer = nil
        schemeHandler.stop()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "rpcBoot")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "rpcConsole")
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    private func finishBoot(_ error: String?) {
        bootTimeoutTimer?.invalidate()
        bootTimeoutTimer = nil
        let cb = bootCompletion
        bootCompletion = nil
        cb?(error)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishBoot("navigation_failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishBoot("navigation_failed: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishBoot("content_process_terminated")
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "rpcBoot" {
            let body = message.body as? String ?? ""
            if body == "ok" {
                finishBoot(nil)
            } else {
                let error = body.hasPrefix("error:") ? String(body.dropFirst(6)) : body
                finishBoot(error)
            }
            return
        }

        if message.name == "rpcConsole" {
            if let dict = message.body as? [String: Any],
               let level = dict["level"] as? String,
               let msg = dict["message"] as? String {
                let prefix: String
                switch level {
                case "warn": prefix = "W"
                case "error": prefix = "E"
                case "debug": prefix = "D"
                default: prefix = "I"
                }
                let log = "\(prefix):\(msg)"
                let consoleChannel = "rpc_dart_wasm/\(runtimeId)/console"
                if let data = log.data(using: .utf8) {
                    messenger.send(onChannel: consoleChannel, message: data)
                }
            }
            return
        }

    }
}