import Flutter
import WebKit

public class RpcDartWasmPlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel?
    private var messenger: FlutterBinaryMessenger?
    private var runtimes: [String: WasmRuntime] = [:]

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
        """) { value, error in
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
          log: function() { var m = Array.prototype.join.call(arguments, ' '); window.webkit.messageHandlers.rpcConsole.postMessage('I:' + m); },
          warn: function() { var m = Array.prototype.join.call(arguments, ' '); window.webkit.messageHandlers.rpcConsole.postMessage('W:' + m); },
          error: function() { var m = Array.prototype.join.call(arguments, ' '); window.webkit.messageHandlers.rpcConsole.postMessage('E:' + m); },
          info: function() { var m = Array.prototype.join.call(arguments, ' '); window.webkit.messageHandlers.rpcConsole.postMessage('I:' + m); },
          debug: function() { var m = Array.prototype.join.call(arguments, ' '); window.webkit.messageHandlers.rpcConsole.postMessage('D:' + m); }
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
        function _bytesToBase64(bytes) {
          var s = '';
          for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
          return btoa(s);
        }
        function _base64ToBytes(b64) {
          var s = atob(b64);
          var bytes = new Uint8Array(s.length);
          for (var i = 0; i < s.length; i++) bytes[i] = s.charCodeAt(i);
          return bytes;
        }
        function _rpcWasmSendBytes(bytes) {
          window.webkit.messageHandlers.rpcBytes.postMessage(_bytesToBase64(bytes));
        }
        function _rpcWasmReceiveBytesB64(b64) {
          _rpcWasmReceiveBytes(_base64ToBytes(b64));
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
        let b64 = bytes.base64EncodedString()
        runtime.evaluate("_rpcWasmReceiveBytesB64('\(b64)');")
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

private class WasmRuntime: NSObject, WKScriptMessageHandler {
    let runtimeId: String
    let webView: WKWebView
    private let messenger: FlutterBinaryMessenger
    private let rxChannel: String
    private var bootCompletion: ((String?) -> Void)?

    init(runtimeId: String, messenger: FlutterBinaryMessenger, rxChannel: String) {
        self.runtimeId = runtimeId
        self.messenger = messenger
        self.rxChannel = rxChannel

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        webView.configuration.userContentController.add(self, name: "rpcBytes")
        webView.configuration.userContentController.add(self, name: "rpcBoot")
        webView.configuration.userContentController.add(self, name: "rpcConsole")
    }

    func boot(html: String, completion: @escaping (String?) -> Void) {
        bootCompletion = completion
        webView.loadHTMLString(html, baseURL: nil)
    }

    func evaluate(_ js: String) {
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func close() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "rpcBytes")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "rpcBoot")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "rpcConsole")
        webView.stopLoading()
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "rpcBoot" {
            let body = message.body as? String ?? ""
            if body == "ok" {
                bootCompletion?(nil)
            } else {
                let error = body.hasPrefix("error:") ? String(body.dropFirst(6)) : body
                bootCompletion?(error)
            }
            bootCompletion = nil
            return
        }

        if message.name == "rpcConsole" {
            if let log = message.body as? String {
                let consoleChannel = "rpc_dart_wasm/\(runtimeId)/console"
                if let data = log.data(using: .utf8) {
                    messenger.send(onChannel: consoleChannel, message: data)
                }
            }
            return
        }

        if message.name == "rpcBytes" {
            guard let b64 = message.body as? String,
                  let bytes = Data(base64Encoded: b64) else {
                return
            }
            messenger.send(onChannel: rxChannel, message: bytes)
        }
    }
}
