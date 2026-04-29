package com.nogipx.rpc_dart_wasm

import android.content.Context
import androidx.javascriptengine.JavaScriptIsolate
import androidx.javascriptengine.JavaScriptSandbox
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.guava.await
import kotlinx.coroutines.launch
import java.nio.ByteBuffer
import java.util.UUID

class RpcDartWasmPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var messenger: BinaryMessenger
    private lateinit var context: Context
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private val runtimes = mutableMapOf<String, JavaScriptIsolate>()
    private var sandbox: JavaScriptSandbox? = null
    private var sandboxFuture: kotlinx.coroutines.Deferred<JavaScriptSandbox>? = null
    private var messageCounter = 0

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "rpc_dart_wasm")
        channel.setMethodCallHandler(this)
        messenger = binding.binaryMessenger
        context = binding.applicationContext
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        scope.launch {
            runtimes.keys.forEach { runtimeId ->
                messenger.setMessageHandler(runtimeTxChannel(runtimeId), null)
            }
            runtimes.values.forEach { it.close() }
            runtimes.clear()
            sandbox?.close()
            sandbox = null
        }
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
        if (sandbox != null) return sandbox!!
        if (sandboxFuture == null) {
            sandboxFuture = scope.async {
                JavaScriptSandbox.createConnectedInstanceAsync(context).await()
            }
        }
        sandbox = sandboxFuture!!.await()
        return sandbox!!
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

        val runtimeId = UUID.randomUUID().toString()
        val isolate = sb.createIsolate()
        runtimes[runtimeId] = isolate
        registerByteChannel(runtimeId)
        isolate.provideNamedData("rpc_wasm_module", wasmBytes)

        val plainJs = stripModuleSyntax(mjsCode)
        val bootScript = """
            var globalThis = this;
            var _rpcWasmOutbox = [];
            var _microtaskQueue = [];
            var _rpcWasmBootError = null;
            var _rpcWasmBootTrace = null;
            var _rpcWasmBootPhase = 'init';
            var _timerId = 0;
            var _timers = {};
            function queueMicrotask(fn) { _microtaskQueue.push(fn); }
            function _flushMicrotasks() {
              while (_microtaskQueue.length > 0) {
                var fn = _microtaskQueue.shift();
                try { fn(); } catch(e) { console.error(e); }
              }
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
              var active = 0;
              for (var i = 0; i < ids.length; i++) {
                var id = ids[i];
                var t = _timers[id];
                if (!t) continue;
                if (now >= t.next) {
                  try { t.fn(); } catch(e) { console.error(e); }
                  if (t.interval) {
                    t.next = now + t.ms;
                    active++;
                  } else {
                    delete _timers[id];
                  }
                } else {
                  active++;
                }
              }
              _flushMicrotasks();
              return '' + active;
            }
            var _b64c = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
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
            function _rpcWasmSendBytes(bytes) {
              _rpcWasmOutbox.push(_bytesToBase64(bytes));
            }
            function _rpcWasmDrainOutbox() {
              if (_rpcWasmOutbox.length === 0) return '';
              var out = _rpcWasmOutbox.join('\n');
              _rpcWasmOutbox = [];
              return out;
            }
            function _rpcWasmReceiveBytes(bytes) {
              if (typeof rpcWasmReceiveBytes === 'function') {
                rpcWasmReceiveBytes(bytes);
              } else if (typeof globalThis.rpcWasmReceiveBytes === 'function') {
                globalThis.rpcWasmReceiveBytes(bytes);
              }
              _flushMicrotasks();
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
            val evalResult = isolate.evaluateJavaScriptAsync(bootScript).await()
            drainAndPush(runtimeId)
            android.util.Log.d("RpcDartWasm", "Runtime $runtimeId booted: ${evalResult.take(100)}")
            mapOf("runtimeId" to runtimeId, "error" to null)
        } catch (e: Exception) {
            val jsError = runCatching {
                isolate.evaluateJavaScriptAsync(
                    "JSON.stringify({ error: _rpcWasmBootError, trace: _rpcWasmBootTrace, phase: _rpcWasmBootPhase })"
                ).await()
            }.getOrNull()
            android.util.Log.e(
                "RpcDartWasm",
                "Runtime boot failed: $runtimeId jsError=$jsError",
                e,
            )
            mapOf(
                "runtimeId" to runtimeId,
                "error" to (jsError ?: e.message ?: e.toString()),
            )
        }
    }

    private suspend fun forwardBytesToRuntime(runtimeId: String, bytes: ByteArray) {
        val isolate = runtimes[runtimeId] ?: return
        android.util.Log.d(
            "RpcDartWasm",
            "Forwarding ${bytes.size} bytes to runtime $runtimeId",
        )
        val name = "rpc_msg_${messageCounter++}"
        isolate.provideNamedData(name, bytes)
        isolate.evaluateJavaScriptAsync("""
            (async function() {
              var buf = await android.consumeNamedDataAsArrayBuffer('$name');
              _rpcWasmReceiveBytes(new Uint8Array(buf));
              return 'ok';
            })()
        """.trimIndent()).await()
        drainAndPush(runtimeId)
    }

    private suspend fun drainAndPush(runtimeId: String) {
        val isolate = runtimes[runtimeId] ?: return

        // Drain console logs and forward to Flutter.
        val consoleLogs = isolate.evaluateJavaScriptAsync("_rpcDrainConsole()").await()
        if (consoleLogs.isNotEmpty()) {
            sendConsoleLog(runtimeId, consoleLogs)
        }

        val raw = isolate.evaluateJavaScriptAsync("_rpcWasmDrainOutbox()").await()
        if (raw.isEmpty()) return

        for (b64 in raw.split('\n')) {
            if (b64.isEmpty()) continue
            val bytes = android.util.Base64.decode(b64, android.util.Base64.DEFAULT)
            sendRuntimeBytes(runtimeId, bytes)
        }
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
                } finally {
                    reply.reply(null)
                }
            }
        }
    }

    private fun sendRuntimeBytes(runtimeId: String, bytes: ByteArray) {
        android.util.Log.d(
            "RpcDartWasm",
            "Sending ${bytes.size} bytes back to Flutter from runtime $runtimeId",
        )
        // Flutter JNI uses buffer.position() as data length, NOT as read offset.
        // Do NOT call flip() or rewind() — leave position at end after put().
        val buffer = ByteBuffer.allocateDirect(bytes.size)
        buffer.put(bytes)
        messenger.send(runtimeRxChannel(runtimeId), buffer)
    }

    private fun runtimeTxChannel(runtimeId: String) = "rpc_dart_wasm/$runtimeId/outgoing"

    private fun runtimeRxChannel(runtimeId: String) = "rpc_dart_wasm/$runtimeId/incoming"

    private fun stripModuleSyntax(code: String): String = code
        .replace("export async function ", "async function ")
        .replace("export const ", "const ")
        .replace("export function ", "function ")
        .replace("export class ", "class ")
}
