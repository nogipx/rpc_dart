// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

package com.nogipx.rpc_dart_wasm

import android.content.Context
import androidx.core.content.ContextCompat
import androidx.javascriptengine.IsolateTerminatedException
import androidx.javascriptengine.JavaScriptIsolate
import androidx.javascriptengine.JavaScriptSandbox
import androidx.javascriptengine.TerminationInfo
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.guava.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.yield
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

class RpcDartWasmPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var messenger: BinaryMessenger
    private lateinit var context: Context
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private val runtimes = mutableMapOf<String, JavaScriptIsolate>()
    private var sandbox: JavaScriptSandbox? = null
    private var sandboxFuture: kotlinx.coroutines.Deferred<JavaScriptSandbox>? = null
    private val messageCounter = AtomicInteger(0)
    private val driverWakers = mutableMapOf<String, CompletableDeferred<Unit>>()

    companion object {
        private const val NAMED_DATA_THRESHOLD = 65536
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "rpc_dart_wasm")
        channel.setMethodCallHandler(this)
        messenger = binding.binaryMessenger
        context = binding.applicationContext
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        scope.cancel()
        driverWakers.values.forEach { it.complete(Unit) }
        driverWakers.clear()
        runtimes.keys.forEach { runtimeId ->
            messenger.setMessageHandler(runtimeTxChannel(runtimeId), null)
        }
        // Each close guarded, as closeRuntime guards its own: one isolate that
        // throws must not leave the rest, and the sandbox, open.
        val closing = runtimes.values.toList()
        runtimes.clear()
        closing.forEach {
            try {
                it.close()
            } catch (e: Exception) {
                android.util.Log.w("RpcDartWasm", "Isolate close on detach: ${e.message}")
            }
        }
        try {
            sandbox?.close()
        } catch (e: Exception) {
            android.util.Log.w("RpcDartWasm", "Sandbox close on detach: ${e.message}")
        }
        sandbox = null
        sandboxFuture = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        scope.launch {
            try {
                when (call.method) {
                    "checkSupport" -> result.success(checkSupport())
                    "loadRuntime" -> result.success(loadRuntime(
                        call.argument("wasm"),
                        call.argument("mjs"),
                        call.argument<String>("jsBootPrefix") ?: "",
                        call.argument<String>("runtimeId"),
                    ))
                    "closeRuntime" -> {
                        closeRuntime(call.argument<String>("runtimeId")!!)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                android.util.Log.e("RpcDartWasm", "Error in ${call.method}", e)
                result.error("RPC_WASM_ERROR", e.message, e.stackTraceToString())
            }
        }
    }

    private suspend fun ensureSandbox(): JavaScriptSandbox {
        sandbox?.let { return it }
        val pending = sandboxFuture ?: scope.async {
            JavaScriptSandbox.createConnectedInstanceAsync(context).await()
        }.also { sandboxFuture = it }
        try {
            return pending.await().also { sandbox = it }
        } catch (e: Exception) {
            // Not cached: a failed bind would otherwise be rethrown to every
            // later checkSupport and loadRuntime until the app restarts.
            if (sandboxFuture === pending) sandboxFuture = null
            throw e
        }
    }

    /// Forgets [dead] once its process has died, so the next runtime binds a
    /// new sandbox. The cache otherwise lives as long as the plugin, and
    /// createIsolate on a dead sandbox does not throw: it returns an isolate
    /// that fails its first evaluation, so every later loadRuntime failed with
    /// "sandbox was dead before call to createIsolate". Each of the dead
    /// sandbox's isolates reports it, possibly after a new one is bound, so
    /// only the sandbox named is dropped.
    private fun dropDeadSandbox(dead: JavaScriptSandbox) {
        if (sandbox !== dead) return
        sandbox = null
        sandboxFuture = null
        try {
            dead.close()
        } catch (e: Exception) {
            android.util.Log.w("RpcDartWasm", "Dead sandbox close: ${e.message}")
        }
    }

    private suspend fun checkSupport(): Map<String, Any> {
        val results = mutableMapOf<String, Any>()
        val supported = JavaScriptSandbox.isSupported()
        results["jsEngineAvailable"] = supported
        if (!supported) return results

        val sb = ensureSandbox()
        results["wasmCompilationSupported"] =
            sb.isFeatureSupported(JavaScriptSandbox.JS_FEATURE_WASM_COMPILATION)
        results["namedDataSupported"] =
            sb.isFeatureSupported(JavaScriptSandbox.JS_FEATURE_PROVIDE_CONSUME_ARRAY_BUFFER)

        val isolate = sb.createIsolate()
        try {
            val hasWasm = isolate.evaluateJavaScriptAsync(
                "(typeof WebAssembly !== 'undefined').toString()"
            ).await()
            results["hasWebAssembly"] = hasWasm == "true"
            if (hasWasm == "true") {
                val gcCheck = isolate.evaluateJavaScriptAsync("""
                    (function() {
                      try {
                        var bytes = new Uint8Array([
                          0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
                          0x01, 0x05, 0x01, 0x5F, 0x01, 0x7F, 0x01
                        ]);
                        return WebAssembly.validate(bytes) ? 'GC_SUPPORTED' : 'GC_NOT_VALIDATED';
                      } catch(e) { return 'GC_ERROR: ' + e; }
                    })()
                """.trimIndent()).await()
                results["wasmGC"] = gcCheck
            }
        } finally {
            isolate.close()
        }
        return results
    }

    private suspend fun loadRuntime(
        wasmBytes: ByteArray?,
        mjsCode: String?,
        jsBootPrefix: String,
        requestedId: String?,
    ): Map<String, Any?> {
        if (wasmBytes == null || mjsCode == null) {
            return mapOf("error" to "Missing wasm or mjs data")
        }

        val sb = ensureSandbox()
        if (!sb.isFeatureSupported(JavaScriptSandbox.JS_FEATURE_WASM_COMPILATION)) {
            return mapOf("runtimeId" to null, "error" to "JS_FEATURE_WASM_COMPILATION is not supported")
        }
        if (!sb.isFeatureSupported(JavaScriptSandbox.JS_FEATURE_PROVIDE_CONSUME_ARRAY_BUFFER)) {
            return mapOf("error" to "Named data API not supported")
        }

        // Checked BEFORE anything is allocated: the isolate, its channel and
        // the named data would all have to be torn down again, and the answer
        // does not depend on any of them.
        val plainJs = stripModuleSyntax(mjsCode)
        val leftover = unstrippedModuleSyntax(plainJs)
        if (leftover != null) {
            return mapOf(
                "runtimeId" to null,
                "error" to "The dart2wasm glue uses module syntax this plugin " +
                    "does not strip, so it cannot run as a classic script: " +
                    "\"$leftover\". The strip handles `export async function`, " +
                    "`export const`, `export function` and `export class`; " +
                    "a newer Dart SDK emitting another form needs " +
                    "stripModuleSyntax updated.",
            )
        }

        // Dart chooses the id so it can install its channel handlers BEFORE the
        // boot below pushes what the guest sent; Flutter buffers one message per
        // channel with no handler.
        val runtimeId = requestedId?.takeIf { it.isNotEmpty() && !runtimes.containsKey(it) }
            ?: UUID.randomUUID().toString()
        val isolate = sb.createIsolate()
        runtimes[runtimeId] = isolate
        // The only signal for a death while the driver is PARKED: with no timer
        // pending it waits on its waker and evaluates nothing, so no evaluation
        // is in flight to fail. A sandbox process killed then went unreported,
        // and every call waited out its own deadline. An ordinary close removes
        // the id first, so reportDeath ignores the callback it causes.
        isolate.addOnTerminatedCallback(ContextCompat.getMainExecutor(context)) { info ->
            if (info.status == TerminationInfo.STATUS_SANDBOX_DEAD) dropDeadSandbox(sb)
            reportDeath(runtimeId, info.toString())
        }
        registerByteChannel(runtimeId)
        isolate.provideNamedData("rpc_wasm_module", wasmBytes)
        val bootScript = """
            var globalThis = this;
            var _rpcWasmOutbox = [];
            var _rpcWasmBootError = null;
            var _rpcWasmBootTrace = null;
            var _rpcWasmBootPhase = 'init';
            var _timerId = 0;
            var _timers = {};
            // Onto the ENGINE's microtask queue, through a promise job. A queue
            // of our own, drained only on a timer tick or an inbound frame, held
            // every Dart continuation a native promise resumed: the engine runs
            // that resumption, and nothing drained what it scheduled until the
            // next tick -- on an idle runtime, never.
            function queueMicrotask(fn) {
              Promise.resolve().then(function() {
                try { fn(); } catch(e) { console.error(e); }
              });
            }
            function _flushMicrotasks() {
              // Every timer and every inbound frame ends here, so a receiver the
              // guest installed in either gets the frames held for it.
              _rpcWasmDeliverEarly();
            }
            var _rpcConsoleLog = [];
            var console = {
              log: function() { _rpcConsoleLog.push('I:' + Array.prototype.join.call(arguments, ' ')); },
              warn: function() { _rpcConsoleLog.push('W:' + Array.prototype.join.call(arguments, ' ')); },
              error: function() { _rpcConsoleLog.push('E:' + Array.prototype.join.call(arguments, ' ')); },
              info: function() { _rpcConsoleLog.push('I:' + Array.prototype.join.call(arguments, ' ')); },
              debug: function() { _rpcConsoleLog.push('D:' + Array.prototype.join.call(arguments, ' ')); }
            };
            function _rpcDrainConsole() {
              if (_rpcConsoleLog.length === 0) return '';
              var out = _rpcConsoleLog.join('\n');
              _rpcConsoleLog = [];
              return out;
            }
            // dart2wasm's glue calls `performance.now()` for Stopwatch and for
            // anything else on the high-resolution clock. JavaScriptSandbox is
            // a bare V8 isolate with no `performance` global, so a guest that
            // used a Stopwatch died here with an opaque "Internal server error"
            // -- while the SAME guest worked on iOS, where WKWebView supplies
            // the real thing. Measured: Timer(1ms..1000ms) reported lag on iOS
            // and threw on Android.
            //
            // Date.now() is millisecond-resolution where the real API is
            // microsecond, so a guest measuring sub-millisecond intervals sees
            // 0 rather than a wrong number. That is the honest floor available
            // in this sandbox.
            if (typeof performance === 'undefined') {
              var performance = { now: function() { return Date.now(); } };
            }
            function _rpcTimerFn(fn, args) {
              return args.length === 0 ? fn : function() { fn.apply(null, args); };
            }
            function setTimeout(fn, ms) {
              var id = ++_timerId;
              var f = _rpcTimerFn(fn, Array.prototype.slice.call(arguments, 2));
              _timers[id] = { fn: f, interval: false, ms: ms || 0, next: Date.now() + (ms || 0) };
              return id;
            }
            // A zero interval is held at 16 ms: the driver evaluates a tick per
            // deadline, so 0 would spin it with no pause at all.
            function setInterval(fn, ms) {
              var id = ++_timerId;
              var f = _rpcTimerFn(fn, Array.prototype.slice.call(arguments, 2));
              _timers[id] = { fn: f, interval: true, ms: ms || 16, next: Date.now() + (ms || 16) };
              return id;
            }
            function clearInterval(id) { delete _timers[id]; }
            function clearTimeout(id) { delete _timers[id]; }
            // Due timers fire as a browser fires them: in deadline order, ties
            // in creation order, and the microtasks one schedules run before
            // the next -- the `await` yields to the engine's microtask queue,
            // where dart2wasm drains every pending Dart microtask in one job.
            // The driver awaits the returned promise.
            async function _tickAndReportNext() {
              var now = Date.now();
              var due = [];
              var ids = Object.keys(_timers);
              for (var i = 0; i < ids.length; i++) {
                var t = _timers[ids[i]];
                if (t && now >= t.next) due.push({ id: +ids[i], t: t });
              }
              due.sort(function(a, b) { return (a.t.next - b.t.next) || (a.id - b.id); });
              for (var i = 0; i < due.length; i++) {
                var id = due[i].id, t = due[i].t;
                // Cleared by a timer that ran before it.
                if (_timers[id] !== t) continue;
                if (t.interval) {
                  t.next = now + t.ms;
                } else {
                  delete _timers[id];
                }
                try { t.fn(); } catch(e) { console.error(e); }
                await null;
              }
              _flushMicrotasks();
              now = Date.now();
              var minDelay = Infinity;
              ids = Object.keys(_timers);
              for (var i = 0; i < ids.length; i++) {
                var t = _timers[ids[i]];
                if (t) {
                  var d = t.next - now;
                  if (d < minDelay) minDelay = d;
                }
              }
              return minDelay === Infinity ? 'null' : '' + Math.max(0, minDelay);
            }
            var _b64c = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
            var _b64lookup = (function() {
              var l = {};
              for (var i = 0; i < _b64c.length; i++) l[_b64c[i]] = i;
              return l;
            })();
            function _bytesToBase64(bytes) {
              var r = '', i = 0, len = bytes.length;
              while (i < len) {
                var a = bytes[i++], b = i < len ? bytes[i++] : -1, c = i < len ? bytes[i++] : -1;
                r += _b64c[a >> 2];
                if (b < 0) { r += _b64c[(a & 3) << 4] + '=='; }
                else if (c < 0) { r += _b64c[((a & 3) << 4) | (b >> 4)] + _b64c[(b & 15) << 2] + '='; }
                else { r += _b64c[((a & 3) << 4) | (b >> 4)] + _b64c[((b & 15) << 2) | (c >> 6)] + _b64c[c & 63]; }
              }
              return r;
            }
            function _base64ToBytes(b64) {
              var lookup = _b64lookup;
              var len = b64.length;
              var pad = b64[len-1] === '=' ? (b64[len-2] === '=' ? 2 : 1) : 0;
              var outLen = (len * 3 / 4) - pad;
              var bytes = new Uint8Array(outLen);
              var p = 0;
              for (var i = 0; i < len; i += 4) {
                var a = lookup[b64[i]], b = lookup[b64[i+1]];
                var c = lookup[b64[i+2]], d = lookup[b64[i+3]];
                bytes[p++] = (a << 2) | (b >> 4);
                if (p < outLen) bytes[p++] = ((b & 15) << 4) | (c >> 2);
                if (p < outLen) bytes[p++] = ((c & 3) << 6) | d;
              }
              return bytes;
            }
            function _rpcWasmSendBytes(bytes) {
              _rpcWasmOutbox.push(_bytesToBase64(bytes));
            }
            // BOUNDED per call. The outbox leaves as the return VALUE of
            // evaluateJavaScriptAsync, and JavaScriptSandbox caps that at 20 MiB
            // by default -- while rpc_dart's own default maxMessageLengthBytes
            // is 16 MiB, which is 22.4 MB once base64'd. Draining everything at
            // once therefore killed the whole runtime on a message the policy
            // above it calls legal:
            //
            //   AssetFileDescriptor.getLength() should be <= 20971520
            //
            // Splitting is safe because this bridge is a byte STREAM, not a
            // message boundary: RpcFrameMultiplexedChannel reassembles frames
            // across chunks. A single over-budget entry is cut on a multiple of
            // 4 so each half is independently decodable base64.
            var _rpcOutboxBudget = 4194304;
            function _rpcWasmDrainOutbox() {
              if (_rpcWasmOutbox.length === 0) return '';
              var out = [], used = 0;
              while (_rpcWasmOutbox.length > 0) {
                var head = _rpcWasmOutbox[0];
                if (used + head.length <= _rpcOutboxBudget) {
                  out.push(head);
                  used += head.length;
                  _rpcWasmOutbox.shift();
                } else if (out.length === 0) {
                  var take = _rpcOutboxBudget - (_rpcOutboxBudget % 4);
                  out.push(head.slice(0, take));
                  _rpcWasmOutbox[0] = head.slice(take);
                  break;
                } else {
                  break;
                }
              }
              return out.join('\n');
            }
            // Frames that arrive before the guest has installed its receiver --
            // it may await before RpcWasm.run -- are held, not dropped: the first
            // is usually the host's flow-control window grant.
            var _rpcWasmEarly = [];
            function _rpcWasmReceiver() {
              if (typeof rpcWasmReceiveBytes === 'function') return rpcWasmReceiveBytes;
              if (typeof globalThis.rpcWasmReceiveBytes === 'function') return globalThis.rpcWasmReceiveBytes;
              return null;
            }
            function _rpcWasmDeliverEarly() {
              if (_rpcWasmEarly.length === 0) return;
              var f = _rpcWasmReceiver();
              if (!f) return;
              var held = _rpcWasmEarly;
              _rpcWasmEarly = [];
              for (var i = 0; i < held.length; i++) f(held[i]);
            }
            function _rpcWasmReceiveBytes(bytes) {
              if (_rpcWasmReceiver()) {
                _rpcWasmDeliverEarly();
                _rpcWasmReceiver()(bytes);
              } else {
                _rpcWasmEarly.push(bytes);
              }
              _flushMicrotasks();
            }
            function _rpcWasmReceiveBytesB64(b64) {
              _rpcWasmReceiveBytes(_base64ToBytes(b64));
            }
            $jsBootPrefix
            $plainJs
            (async function() {
              try {
                if (typeof WebAssembly === 'undefined') {
                  throw new Error('WebAssembly is not available in this JS runtime');
                }
                _rpcWasmBootPhase = 'consumeNamedData';
                var wasmBuf = await android.consumeNamedDataAsArrayBuffer('rpc_wasm_module');
                var wasmBytes = new Uint8Array(wasmBuf);
                _rpcWasmBootPhase = 'compile';
                var compiled = await compile(wasmBytes);
                _rpcWasmBootPhase = 'instantiate';
                var app = await compiled.instantiate({});
                _rpcWasmBootPhase = 'invokeMain';
                app.invokeMain();
                _rpcWasmBootPhase = 'flushMicrotasks';
                _flushMicrotasks();
                _rpcWasmBootPhase = 'done';
                return 'ok';
              } catch (e) {
                _rpcWasmBootError = '' + e;
                _rpcWasmBootTrace = e && e.stack ? '' + e.stack : null;
                throw e;
              }
            })()
        """.trimIndent()

        return try {
            val evalResult = withTimeoutOrNull(30_000) {
                isolate.evaluateJavaScriptAsync(bootScript).await()
            } ?: throw Exception("boot_timeout: no response within 30s")
            drainAndPush(runtimeId)
            android.util.Log.d("RpcDartWasm", "Runtime $runtimeId booted: ${evalResult.take(100)}")
            startDriver(runtimeId)
            mapOf("runtimeId" to runtimeId, "error" to null)
        } catch (e: Exception) {
            // `_rpcWasmBootError` is only ever set inside the boot IIFE's own
            // catch, so a script that dies BEFORE reaching it -- a syntax error
            // or a throw in the injected glue -- leaves every field null. That
            // JSON is still a non-null String, so it used to win the `?:` below
            // and the real V8 message in `e.message` was thrown away:
            //
            //   before : {"error":null,"trace":null,"phase":"init"}
            //
            // Ask for it only when there IS one, so the fallback can do its job.
            val jsError = runCatching {
                isolate.evaluateJavaScriptAsync(
                    "_rpcWasmBootError ? JSON.stringify({ error: _rpcWasmBootError," +
                        " trace: _rpcWasmBootTrace, phase: _rpcWasmBootPhase }) : ''"
                ).await()
            }.getOrNull()?.takeIf { it.isNotEmpty() }
            android.util.Log.e(
                "RpcDartWasm",
                "Runtime boot failed: $runtimeId jsError=$jsError",
                e,
            )
            messenger.setMessageHandler(runtimeTxChannel(runtimeId), null)
            runtimes.remove(runtimeId)?.close()
            mapOf(
                "runtimeId" to null,
                "error" to (jsError ?: e.message ?: e.toString()),
            )
        }
    }

    // MARK: - Driver loop

    private fun startDriver(runtimeId: String) {
        scope.launch {
            while (runtimes.containsKey(runtimeId)) {
                try {
                    val waker = CompletableDeferred<Unit>()
                    driverWakers[runtimeId] = waker

                    val nextDeadlineMs = tickAndDrain(runtimeId)

                    if (waker.isCompleted) {
                        driverWakers.remove(runtimeId)
                        continue
                    }

                    if (nextDeadlineMs == null) {
                        waker.await()
                    } else if (nextDeadlineMs > 0) {
                        withTimeoutOrNull(nextDeadlineMs) { waker.await() }
                    }
                    driverWakers.remove(runtimeId)
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (e: Exception) {
                    android.util.Log.w("RpcDartWasm", "Driver loop error for $runtimeId", e)
                    // The driver used to log and break: the isolate stayed in
                    // `runtimes`, nothing further was evaluated, and Dart was
                    // never told -- so every in-flight call hung. A sandbox that
                    // dies (IsolateTerminatedException, sandbox process killed)
                    // arrives here and nowhere else.
                    reportDeath(runtimeId, e.message ?: e.toString())
                    break
                }
            }
            driverWakers.remove(runtimeId)
        }
    }

    /// Tells Dart the runtime is gone and releases its slot.
    private fun reportDeath(runtimeId: String, reason: String) {
        if (!runtimes.containsKey(runtimeId)) return
        messenger.setMessageHandler(runtimeTxChannel(runtimeId), null)
        try {
            runtimes.remove(runtimeId)?.close()
        } catch (e: Exception) {
            android.util.Log.w("RpcDartWasm", "Isolate close for $runtimeId: ${e.message}")
        }
        val bytes = reason.toByteArray(Charsets.UTF_8)
        val buffer = ByteBuffer.allocateDirect(bytes.size)
        buffer.put(bytes)
        messenger.send(runtimeDiedChannel(runtimeId), buffer)
        // A parked driver would otherwise wait on its waker forever.
        wakeDriver(runtimeId)
    }

    private fun wakeDriver(runtimeId: String) {
        driverWakers[runtimeId]?.let { if (!it.isCompleted) it.complete(Unit) }
    }

    private suspend fun tickAndDrain(runtimeId: String): Long? {
        val isolate = runtimes[runtimeId] ?: return null
        val nextMs = isolate.evaluateJavaScriptAsync("_tickAndReportNext()").await()
        drainAndPush(runtimeId)
        return if (nextMs == "null" || nextMs.isEmpty()) null else nextMs.toLongOrNull()
    }

    // MARK: - Byte transport

    private suspend fun forwardBytesToRuntime(runtimeId: String, bytes: ByteArray) {
        val isolate = runtimes[runtimeId] ?: return
        try {
            evaluateForward(isolate, bytes)
        } finally {
            // In a finally: a forward that throws must still wake the driver,
            // or a parked one never notices anything.
            wakeDriver(runtimeId)
        }
    }

    private suspend fun evaluateForward(isolate: JavaScriptIsolate, bytes: ByteArray) {
        if (bytes.size >= NAMED_DATA_THRESHOLD) {
            val name = "rpc_msg_${messageCounter.getAndIncrement()}"
            isolate.provideNamedData(name, bytes)
            isolate.evaluateJavaScriptAsync("""
                (async function() {
                  var buf = await android.consumeNamedDataAsArrayBuffer('$name');
                  _rpcWasmReceiveBytes(new Uint8Array(buf));
                  return 'ok';
                })()
            """.trimIndent()).await()
        } else {
            val b64 = android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)
            isolate.evaluateJavaScriptAsync("_rpcWasmReceiveBytesB64('$b64')").await()
        }
    }

    private suspend fun drainAndPush(runtimeId: String) {
        val isolate = runtimes[runtimeId] ?: return

        val consoleLogs = isolate.evaluateJavaScriptAsync("_rpcDrainConsole()").await()
        if (consoleLogs.isNotEmpty()) {
            sendConsoleLog(runtimeId, consoleLogs)
        }

        // Keep draining: the outbox now hands back a bounded slice per call, so
        // one tick must not leave a partially drained frame sitting there --
        // the peer would wait on bytes the guest has already produced. Bounded
        // so a guest that produces during the drain cannot pin the loop here.
        var rounds = 0
        var sentSinceYield = 0
        while (rounds++ < 64) {
            val raw = isolate.evaluateJavaScriptAsync("_rpcWasmDrainOutbox()").await()
            if (raw.isEmpty()) return

            for (b64 in raw.split('\n')) {
                if (b64.isEmpty()) continue
                val bytes = android.util.Base64.decode(b64, android.util.Base64.DEFAULT)
                sendRuntimeBytes(runtimeId, bytes)
                // Give the main thread back every so often. Each send runs the
                // Dart handler right here, on this thread, and Dart's microtasks
                // -- where the transport hands a frame to its consumer -- only run
                // once this task returns. Without the yield one drain delivered
                // thousands of frames before the consumer saw any, and the host's
                // per-stream cap (maxBufferedMessagesPerStream, 1024 by default)
                // failed the call. 256 keeps that lag well under the default at a
                // fraction of the cost of yielding per frame.
                if (++sentSinceYield >= 256) {
                    sentSinceYield = 0
                    yield()
                }
            }
        }
        // Still more queued after the cap: come straight back rather than
        // sleeping on the next timer deadline.
        wakeDriver(runtimeId)
    }

    private fun sendConsoleLog(runtimeId: String, log: String) {
        val channel = "rpc_dart_wasm/$runtimeId/console"
        val bytes = log.toByteArray(Charsets.UTF_8)
        val buffer = java.nio.ByteBuffer.allocateDirect(bytes.size)
        buffer.put(bytes)
        messenger.send(channel, buffer)
    }

    private fun closeRuntime(runtimeId: String) {
        messenger.setMessageHandler(runtimeTxChannel(runtimeId), null)
        wakeDriver(runtimeId)
        try {
            runtimes.remove(runtimeId)?.close()
        } catch (e: Exception) {
            android.util.Log.w("RpcDartWasm", "Isolate close for $runtimeId: ${e.message}")
        }
    }

    private fun registerByteChannel(runtimeId: String) {
        messenger.setMessageHandler(runtimeTxChannel(runtimeId)) { message, reply ->
            val bytes = message?.let { buffer ->
                val copy = buffer.asReadOnlyBuffer()
                copy.rewind()
                val data = ByteArray(copy.remaining())
                copy.get(data)
                data
            }

            scope.launch {
                try {
                    if (bytes != null) {
                        forwardBytesToRuntime(runtimeId, bytes)
                    }
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (e: Exception) {
                    // KILLED THE APP before this catch existed. Closing the
                    // isolate completes every in-flight evaluateJavaScriptAsync
                    // with IsolateTerminatedException, and a forward started
                    // just before close() resumes HERE -- a StandaloneCoroutine
                    // on Dispatchers.Main with only a `finally`, so the throw
                    // was uncaught:
                    //
                    //   FATAL EXCEPTION: main
                    //   androidx.javascriptengine.IsolateTerminatedException:
                    //     isolate closed
                    //
                    // An ordinary close with traffic in flight is the common
                    // case, not an edge one: the last thing an endpoint does is
                    // send, then close.
                    android.util.Log.w(
                        "RpcDartWasm",
                        "Forward to $runtimeId dropped: ${e.message}",
                    )
                    // A runtime that died under the forward is reported here,
                    // not left for a driver that may be parked. After an
                    // ordinary close the id is already gone and this is a no-op.
                    if (e is IsolateTerminatedException) {
                        reportDeath(runtimeId, e.message ?: e.toString())
                    }
                } finally {
                    reply.reply(null)
                }
            }
        }
    }

    private fun sendRuntimeBytes(runtimeId: String, bytes: ByteArray) {
        val buffer = ByteBuffer.allocateDirect(bytes.size)
        buffer.put(bytes)
        messenger.send(runtimeRxChannel(runtimeId), buffer)
    }

    private fun runtimeTxChannel(runtimeId: String) = "rpc_dart_wasm/$runtimeId/outgoing"

    private fun runtimeRxChannel(runtimeId: String) = "rpc_dart_wasm/$runtimeId/incoming"

    private fun runtimeDiedChannel(runtimeId: String) = "rpc_dart_wasm/$runtimeId/died"

    private fun stripModuleSyntax(code: String): String = code
        .replace("export async function ", "async function ")
        .replace("export const ", "const ")
        .replace("export function ", "function ")
        .replace("export class ", "class ")

    /// The first line of module syntax [stripModuleSyntax] did not handle, or
    /// null when the glue is now a classic script.
    ///
    /// The strip is four literal prefixes pinned to what dart2wasm emits today.
    /// `export let`, `export default`, a trailing `export {a, b}` or any
    /// `import` would all survive it and reach the engine as module syntax
    /// inside a classic script.
    ///
    /// LINE-ANCHORED, and that is the whole design. The words appear 19 times
    /// in the real glue and only 4 at statement position: `dartInstance.exports`,
    /// `importObjectPromise` and a comment naming the `'import'` API are the
    /// rest, so a `contains` check would refuse every working boot -- a far
    /// worse failure than the one it is meant to diagnose.
    ///
    /// Deliberately not a regex: the same check runs in Swift, and hasPrefix on
    /// a trimmed line means the same thing in both languages, which no two
    /// regex engines guarantee.
    private fun unstrippedModuleSyntax(code: String): String? =
        code.lineSequence().firstOrNull { line ->
            val t = line.trimStart()
            t.startsWith("export ") || t.startsWith("import ")
        }?.trim()
}