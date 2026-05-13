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
            rxChannel: runtimeRxChannel(runtimeId)
        )
        runtimes[runtimeId] = runtime
        registerByteChannel(runtimeId: runtimeId)

        let plainJs = stripModuleSyntax(mjsCode)
        let wasmBase64 = wasmBytes.base64EncodedString()

        let bootHtml = """
        <!DOCTYPE html><html><head><meta charset="utf-8"></head><body><script>
        var _rpcWasmOutbox = [];
        var _microtaskQueue = [];
        var _timerId = 0;
        var _timers = {};
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
          return id;
        }
        function setInterval(fn, ms) {
          var id = ++_timerId;
          _timers[id] = { fn: fn, interval: true, ms: ms || 16, next: Date.now() + (ms || 16) };
          return id;
        }
        function clearInterval(id) { delete _timers[id]; }
        function clearTimeout(id) { delete _timers[id]; }
        function _tickTimers() {
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
        }
        function _rpcWasmSendBytes(bytes) {
          window.webkit.messageHandlers.rpcBytes.postMessage(Array.from(bytes));
        }
        function _rpcWasmReceiveBytes(bytes) {
          if (typeof rpcWasmReceiveBytes === 'function') {
            rpcWasmReceiveBytes(bytes);
          } else if (typeof globalThis.rpcWasmReceiveBytes === 'function') {
            globalThis.rpcWasmReceiveBytes(bytes);
          }
          _flushMicrotasks();
        }
        \(jsBootPrefix)
        \(plainJs)
        (async function() {
          try {
            var b64 = '\(wasmBase64)';
            var binary = atob(b64);
            var wasmBytes = new Uint8Array(binary.length);
            for (var i = 0; i < binary.length; i++) wasmBytes[i] = binary.charCodeAt(i);
            var compiled = await compile(wasmBytes);
            var app = await compiled.instantiate({});
            app.invokeMain();
            _flushMicrotasks();
            window.webkit.messageHandlers.rpcBoot.postMessage('ok');
          } catch(e) {
            window.webkit.messageHandlers.rpcBoot.postMessage('error:' + e + (e && e.stack ? '\\n' + e.stack : ''));
          }
        })();
        </script></body></html>
        """

        runtime.boot(html: bootHtml) { bootResult in
            if let error = bootResult {
                result(["runtimeId": runtimeId, "error": error])
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
        let byteArray = [UInt8](bytes)
        runtime.callJS("_rpcWasmReceiveBytes(new Uint8Array(args.bytes));", arguments: ["bytes": byteArray])
    }

    private func sendRuntimeBytes(runtimeId: String, bytes: Data) {
        messenger?.send(onChannel: runtimeRxChannel(runtimeId), message: bytes)
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

// MARK: - WasmRuntime (WKWebView wrapper)

private class WasmRuntime: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let runtimeId: String
    let webView: WKWebView
    private let messenger: FlutterBinaryMessenger
    private let rxChannel: String
    private var bootCompletion: ((String?) -> Void)?
    private var bootTimeoutTimer: Timer?
    private var timerDriver: Timer?

    private static let bootTimeoutSeconds: TimeInterval = 30

    init(runtimeId: String, messenger: FlutterBinaryMessenger, rxChannel: String) {
        self.runtimeId = runtimeId
        self.messenger = messenger
        self.rxChannel = rxChannel

        let config = WKWebViewConfiguration()
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        webView.navigationDelegate = self
        webView.configuration.userContentController.add(self, name: "rpcBytes")
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

    func callJS(_ js: String, arguments: [String: Any] = [:]) {
        webView.callAsyncJavaScript(js, arguments: arguments, in: nil, in: .page, completionHandler: nil)
    }

    func close() {
        bootTimeoutTimer?.invalidate()
        bootTimeoutTimer = nil
        timerDriver?.invalidate()
        timerDriver = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "rpcBytes")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "rpcBoot")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "rpcConsole")
        webView.stopLoading()
    }

    private func finishBoot(_ error: String?) {
        bootTimeoutTimer?.invalidate()
        bootTimeoutTimer = nil
        let cb = bootCompletion
        bootCompletion = nil
        if error == nil {
            startTimerDriver()
        }
        cb?(error)
    }

    private func startTimerDriver() {
        timerDriver = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.webView.evaluateJavaScript("_tickTimers();", completionHandler: nil)
        }
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

        if message.name == "rpcBytes" {
            guard let array = message.body as? [NSNumber] else { return }
            var bytes = Data(count: array.count)
            for i in 0..<array.count {
                bytes[i] = array[i].uint8Value
            }
            messenger.send(onChannel: rxChannel, message: bytes)
        }
    }
}