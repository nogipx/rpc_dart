// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import FlutterMacOS
import Foundation
import JavaScriptCore
import Security

/// The macOS backend: a guest compiled to JavaScript (`dart compile js`), each
/// in a JavaScriptCore context of its own, on a queue of its own.
///
/// The byte channels are the iOS and Android backends' own, so the Dart bridge
/// is the same: `rpc_dart_wasm/<id>/outgoing` (host to guest, a send answered
/// once the guest has room), `incoming` (guest to host), `console` (`L:text`)
/// and `died`. A context lives in this process and does not die on its own, so
/// nothing is ever sent on `died`; a host's close releases it.
///
/// WASM guests are not run here: whether a JSContext runs WasmGC is not
/// something this plugin has measured, and a load that fails later blaming
/// something else is worse than a clear no now.
public class RpcDartWasmPlugin: NSObject, FlutterPlugin {
    private var messenger: FlutterBinaryMessenger?
    private var runtimes: [String: JsRuntime] = [:]

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "rpc_dart_wasm", binaryMessenger: registrar.messenger)
        let instance = RpcDartWasmPlugin()
        instance.messenger = registrar.messenger
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "checkSupport":
            result([
                "jsEngineAvailable": true,
                "hasWebAssembly": false,
                "wasmGC": "NOT_SUPPORTED",
                "jsGuest": true,
                "engine": "JavaScriptCore",
            ] as [String: Any])
        case "loadRuntime":
            result([
                "runtimeId": nil,
                "error": "WASM guests do not run on macOS; load a guest compiled to "
                    + "JavaScript with RpcFlutterWasmBridge.loadJs",
            ] as [String: Any?])
        case "loadJsRuntime":
            let args = call.arguments as? [String: Any] ?? [:]
            loadJs(
                code: args["code"] as? String,
                scripts: (args["scripts"] as? [[String: Any]] ?? []).map {
                    (name: $0["name"] as? String ?? "script", code: $0["code"] as? String ?? "")
                },
                prefix: args["jsBootPrefix"] as? String ?? "",
                requestedId: args["runtimeId"] as? String,
                result: result
            )
        case "closeRuntime":
            let args = call.arguments as? [String: Any]
            closeRuntime(runtimeId: args?["runtimeId"] as? String ?? "")
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func loadJs(
        code: String?,
        scripts: [(name: String, code: String)],
        prefix: String,
        requestedId: String?,
        result: @escaping FlutterResult
    ) {
        guard let code else {
            result(["runtimeId": nil, "error": "Missing the guest's code"] as [String: Any?])
            return
        }
        guard let messenger else {
            result(["runtimeId": nil, "error": "No binary messenger"] as [String: Any?])
            return
        }
        // Dart chose the id so its channel handlers are up BEFORE the guest
        // boots: what the guest sends during its main reaches Dart before this
        // call returns.
        let runtimeId = (requestedId?.isEmpty == false && runtimes[requestedId!] == nil)
            ? requestedId!
            : UUID().uuidString
        let runtime = JsRuntime(runtimeId: runtimeId, messenger: messenger)
        runtimes[runtimeId] = runtime
        registerByteChannel(runtimeId: runtimeId)
        runtime.boot(prefix: prefix, code: code, scripts: scripts) { [weak self] error in
            guard let self else { return }
            if let error {
                self.closeRuntime(runtimeId: runtimeId)
                result(["runtimeId": nil, "error": error] as [String: Any?])
            } else {
                result(["runtimeId": runtimeId, "error": nil] as [String: Any?])
            }
        }
    }

    private func closeRuntime(runtimeId: String) {
        messenger?.setMessageHandlerOnChannel(JsRuntime.txChannel(runtimeId), binaryMessageHandler: nil)
        runtimes.removeValue(forKey: runtimeId)?.close()
    }

    private func registerByteChannel(runtimeId: String) {
        messenger?.setMessageHandlerOnChannel(
            JsRuntime.txChannel(runtimeId),
            binaryMessageHandler: { [weak self] message, reply in
                guard let self, let message, let runtime = self.runtimes[runtimeId] else {
                    reply(nil)
                    return
                }
                runtime.enqueue(message) { reply(nil) }
            }
        )
    }
}

/// One guest: its context, its timers, and the frames held for it.
private final class JsRuntime: @unchecked Sendable {
    static func txChannel(_ id: String) -> String { "rpc_dart_wasm/\(id)/outgoing" }
    static func rxChannel(_ id: String) -> String { "rpc_dart_wasm/\(id)/incoming" }
    static func consoleChannel(_ id: String) -> String { "rpc_dart_wasm/\(id)/console" }

    /// Held frames past which the host's sends are answered only once the
    /// guest has taken them: the host sends one batch and awaits its answer,
    /// so holding it is what bounds the queue.
    static let queueLimitBytes = 1024 * 1024

    let runtimeId: String
    private let messenger: FlutterBinaryMessenger
    private let queue: DispatchQueue

    // Everything below is touched on [queue] only.
    private var context: JSContext?
    /// The environment's timer dispatcher: `fire(id)`.
    private var fire: JSValue?
    private var timers: [Int: DispatchSourceTimer] = [:]
    /// Frames that came before the guest installed its receiver -- it may
    /// await before RpcWasm.run -- held, not dropped: the first is usually the
    /// host's flow-control window grant.
    private var early: [Data] = []
    private var earlyBytes = 0
    private var heldReplies: [() -> Void] = []
    private var closed = false
    /// While booting, the first error a script threw; after, errors go to the
    /// console.
    private var booting = true
    private var bootError: String?

    init(runtimeId: String, messenger: FlutterBinaryMessenger) {
        self.runtimeId = runtimeId
        self.messenger = messenger
        self.queue = DispatchQueue(label: "rpc_dart_wasm.\(runtimeId)", qos: .userInitiated)
    }

    /// Evaluates the environment, [prefix], [code] and [scripts] in order;
    /// [done] gets nil, or the first error, on the main thread.
    func boot(
        prefix: String,
        code: String,
        scripts: [(name: String, code: String)],
        done: @escaping (String?) -> Void
    ) {
        queue.async {
            let error = self.load(prefix: prefix, code: code, scripts: scripts)
            DispatchQueue.main.async { done(error) }
        }
    }

    private func load(prefix: String, code: String, scripts: [(name: String, code: String)]) -> String? {
        guard let c = JSContext() else { return "JavaScriptCore made no context" }
        c.name = "rpc_dart_wasm \(runtimeId)"
        c.exceptionHandler = { [weak self] _, exception in
            self?.uncaught(exception)
        }
        let native = JSValue(newObjectIn: c)!
        let send: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self, let c = JSContext.current(), let data = Self.data(of: value, in: c) else { return }
            self.toHost(data)
        }
        let console: @convention(block) (String, String) -> Void = { [weak self] level, text in
            self?.console(level, text)
        }
        let timer: @convention(block) (Int, Double, Bool) -> Void = { [weak self] id, ms, repeats in
            self?.schedule(id, ms: ms, repeats: repeats)
        }
        let cancel: @convention(block) (Int) -> Void = { [weak self] id in
            self?.timers.removeValue(forKey: id)?.cancel()
        }
        let random: @convention(block) (Int) -> JSValue = { n in
            let c = JSContext.current()!
            var data = Data(count: max(0, min(n, 65536)))
            let count = data.count
            if count > 0 {
                _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
            }
            return Self.uint8Array(data, in: c) ?? JSValue(nullIn: c)
        }
        native.setValue(send, forProperty: "send")
        native.setValue(console, forProperty: "console")
        native.setValue(timer, forProperty: "timer")
        native.setValue(cancel, forProperty: "cancel")
        native.setValue(random, forProperty: "random")
        context = c
        c.evaluateScript(Self.environment, withSourceURL: URL(string: "rpc-wasm:///environment.js"))
        fire = c.objectForKeyedSubscript("__rpcWasmEnvironment")?.call(withArguments: [native])
        c.evaluateScript("delete globalThis.__rpcWasmEnvironment")
        if let error = bootError { return error }
        var steps: [(name: String, code: String)] = []
        if !prefix.isEmpty { steps.append((name: "prefix.js", code: prefix)) }
        steps.append((name: "guest.js", code: code))
        steps.append(contentsOf: scripts)
        for step in steps {
            c.evaluateScript(step.code, withSourceURL: URL(string: "rpc-wasm:///\(Self.path(step.name))"))
            if let error = bootError { return error }
        }
        booting = false
        deliverEarly()
        return nil
    }

    /// An error no script caught: the boot's failure, or a console line.
    private func uncaught(_ exception: JSValue?) {
        guard let exception else { return }
        let source = exception.objectForKeyedSubscript("sourceURL")?.toString()
            .map { $0.replacingOccurrences(of: "rpc-wasm:///", with: "") } ?? "?"
        let line = exception.objectForKeyedSubscript("line")?.toString() ?? "?"
        var text = "\(source):\(line): \(exception.toString() ?? "error")"
        if let stack = exception.objectForKeyedSubscript("stack"), stack.isString,
           let s = stack.toString(), !s.isEmpty {
            text += "\n\(s)"
        }
        if booting {
            if bootError == nil { bootError = text }
        } else {
            console("E", "uncaught: \(text)")
        }
    }

    // MARK: Bytes

    /// A frame from the guest, to Dart, in order.
    private func toHost(_ data: Data) {
        let channel = Self.rxChannel(runtimeId)
        DispatchQueue.main.async { [messenger] in
            messenger.send(onChannel: channel, message: data)
        }
    }

    /// A frame from Dart, for the guest; [onRoom] answers Dart's send.
    func enqueue(_ data: Data, onRoom: @escaping () -> Void) {
        queue.async {
            if self.closed {
                DispatchQueue.main.async(execute: onRoom)
                return
            }
            self.early.append(data)
            self.earlyBytes += data.count
            if self.earlyBytes > Self.queueLimitBytes {
                self.heldReplies.append(onRoom)
            } else {
                DispatchQueue.main.async(execute: onRoom)
            }
            self.deliverEarly()
        }
    }

    /// Hands the held frames to the guest's receiver, once it has one.
    private func deliverEarly() {
        guard !closed, !booting, !early.isEmpty, let c = context,
              let receiver = c.objectForKeyedSubscript("rpcWasmReceiveBytes"), receiver.isObject
        else { return }
        let held = early
        early = []
        earlyBytes = 0
        for data in held {
            if let array = Self.uint8Array(data, in: c) {
                receiver.call(withArguments: [array])
            }
        }
        releaseHeldReplies()
    }

    private func releaseHeldReplies() {
        guard earlyBytes <= Self.queueLimitBytes, !heldReplies.isEmpty else { return }
        let held = heldReplies
        heldReplies = []
        DispatchQueue.main.async { held.forEach { $0() } }
    }

    // MARK: Console and timers

    private func console(_ level: String, _ text: String) {
        let channel = Self.consoleChannel(runtimeId)
        guard let data = "\(level):\(text)".data(using: .utf8) else { return }
        DispatchQueue.main.async { [messenger] in
            messenger.send(onChannel: channel, message: data)
        }
    }

    private func schedule(_ id: Int, ms: Double, repeats: Bool) {
        timers.removeValue(forKey: id)?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.microseconds(Int(max(0, ms) * 1000))
        if repeats {
            t.schedule(deadline: .now() + interval, repeating: interval)
        } else {
            t.schedule(deadline: .now() + interval)
        }
        t.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            if !repeats { self.timers.removeValue(forKey: id) }
            self.fire?.call(withArguments: [id])
            // A receiver the callback installed gets the frames held for it.
            self.deliverEarly()
        }
        timers[id] = t
        t.resume()
    }

    /// Ends the guest: its timers stop, its context goes, the sends held for
    /// room are answered so the host's pump does not wait for good.
    func close() {
        queue.async {
            self.closed = true
            for t in self.timers.values { t.cancel() }
            self.timers = [:]
            self.fire = nil
            self.context = nil
            self.early = []
            self.earlyBytes = 0
            let held = self.heldReplies
            self.heldReplies = []
            DispatchQueue.main.async { held.forEach { $0() } }
        }
    }

    // MARK: Typed arrays

    /// [data] as a new `Uint8Array` of [c].
    private static func uint8Array(_ data: Data, in c: JSContext) -> JSValue? {
        let ctx = c.jsGlobalContextRef
        var exception: JSValueRef?
        guard let array = JSObjectMakeTypedArray(ctx, kJSTypedArrayTypeUint8Array, data.count, &exception),
              exception == nil
        else { return nil }
        if data.count > 0, let p = JSObjectGetTypedArrayBytesPtr(ctx, array, &exception) {
            data.copyBytes(to: p.assumingMemoryBound(to: UInt8.self), count: data.count)
        }
        return JSValue(jsValueRef: array, in: c)
    }

    /// The bytes of a `Uint8Array` the environment made whole (offset 0, its
    /// buffer's full length).
    private static func data(of value: JSValue, in c: JSContext) -> Data? {
        let ctx = c.jsGlobalContextRef
        var exception: JSValueRef?
        guard JSValueGetTypedArrayType(ctx, value.jsValueRef, &exception) == kJSTypedArrayTypeUint8Array,
              let object = JSValueToObject(ctx, value.jsValueRef, &exception)
        else { return nil }
        let count = JSObjectGetTypedArrayByteLength(ctx, object, &exception)
        guard count > 0 else { return Data() }
        guard let p = JSObjectGetTypedArrayBytesPtr(ctx, object, &exception) else { return nil }
        return Data(bytes: p, count: count)
    }

    /// A script's name as a URL path.
    private static func path(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "script"
    }

    /// What dart2js expects of a page and a bare JavaScriptCore lacks, and the
    /// byte pipe: called with the native functions, it answers the timer
    /// dispatcher.
    private static let environment = #"""
    globalThis.__rpcWasmEnvironment = function (native) {
      var g = globalThis;
      g.self = g;
      function text(args) {
        return Array.prototype.map.call(args, function (a) {
          if (typeof a === 'string') return a;
          if (a instanceof Error) return String(a) + (a.stack ? '\n' + a.stack : '');
          try { return JSON.stringify(a); } catch (e) { return String(a); }
        }).join(' ');
      }
      function level(l) { return function () { native.console(l, text(arguments)); }; }
      g.console = { log: level('I'), info: level('I'), warn: level('W'), error: level('E'), debug: level('D') };

      // Timers: callbacks here by id, deadlines on the runtime's queue.
      var timers = {};
      var next = 1;
      function add(fn, ms, args, repeats) {
        var id = next++;
        timers[id] = { fn: typeof fn === 'function' ? fn : function () {}, args: args, repeats: repeats };
        native.timer(id, Math.max(repeats ? 1 : 0, Number(ms) || 0), repeats);
        return id;
      }
      g.setTimeout = function (fn, ms) { return add(fn, ms, Array.prototype.slice.call(arguments, 2), false); };
      g.setInterval = function (fn, ms) { return add(fn, ms, Array.prototype.slice.call(arguments, 2), true); };
      g.clearTimeout = g.clearInterval = function (id) {
        if (timers[id]) { delete timers[id]; native.cancel(id); }
      };
      // dart2js schedules its microtasks with self.scheduleImmediate when there
      // is one; else with a timer, a whole turn later.
      function microtask(cb) {
        Promise.resolve().then(function () {
          try { cb(); } catch (e) { g.console.error(e); }
        });
      }
      g.scheduleImmediate = microtask;
      if (typeof g.queueMicrotask !== 'function') g.queueMicrotask = microtask;

      var start = Date.now();
      g.performance = { now: function () { return Date.now() - start; } };
      g.crypto = {
        getRandomValues: function (a) {
          new Uint8Array(a.buffer, a.byteOffset, a.byteLength).set(native.random(a.byteLength));
          return a;
        },
      };
      // Whole arrays only: a view into a larger buffer is copied first.
      g._rpcWasmSendBytes = function (b) {
        native.send(b.byteOffset === 0 && b.byteLength === b.buffer.byteLength ? b : b.slice());
      };
      return function (id) {
        var t = timers[id];
        if (!t) return;
        if (!t.repeats) delete timers[id];
        try { t.fn.apply(null, t.args); } catch (e) { g.console.error(e); }
      };
    };
    """#
}
