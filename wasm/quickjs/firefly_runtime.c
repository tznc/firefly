/*
 * Firefly plugin runtime: QuickJS-ng as a WASI reactor module.
 *
 * One instance runs one hook call: the host writes the plugin's source, the
 * hook name and its JSON input into memory (`ff_alloc`), calls `ff_run`, and
 * reads the JSON result (`ff_out_ptr`/`ff_out_len`). The plugin reaches the
 * host only through `firefly.call(name, args)`, backed by the
 * `firefly.call`/`firefly.read` imports; the host decides per call which
 * names it answers. Nothing else is imported apart from the few WASI
 * functions wasi-libc needs, which the host stubs (no files, no network, no
 * environment; the clock is the host's).
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "quickjs.h"

__attribute__((import_module("firefly"), import_name("call")))
extern int32_t host_call(const char *name, int32_t name_len, const char *args, int32_t args_len);

__attribute__((import_module("firefly"), import_name("read")))
extern void host_read(char *buf);

enum {
    FF_OK = 0,
    FF_JS_ERROR = 1,
    FF_NO_HANDLER = 2,
    FF_INIT_ERROR = 3,
};

static char *out = NULL;
static int32_t out_len = 0;

__attribute__((export_name("ff_alloc")))
void *ff_alloc(int32_t size) { return malloc(size > 0 ? size : 1); }

__attribute__((export_name("ff_out_ptr")))
char *ff_out_ptr(void) { return out; }

__attribute__((export_name("ff_out_len")))
int32_t ff_out_len(void) { return out_len; }

static void set_out(const char *s, size_t len) {
    free(out);
    out = malloc(len + 1);
    if (!out) { out_len = 0; return; }
    memcpy(out, s, len);
    out[len] = 0;
    out_len = (int32_t)len;
}

/* The pending exception as a JSON string: {"message": ..., "stack": ...}. */
static void set_exception(JSContext *ctx) {
    JSValue exc = JS_GetException(ctx);
    JSValue err = JS_NewObject(ctx);
    JSValue msg = JS_IsError(exc) ? JS_GetPropertyStr(ctx, exc, "message") : JS_ToString(ctx, exc);
    JS_SetPropertyStr(ctx, err, "message", JS_IsException(msg) ? JS_NewString(ctx, "uncatchable error") : msg);
    if (JS_IsError(exc))
        JS_SetPropertyStr(ctx, err, "stack", JS_GetPropertyStr(ctx, exc, "stack"));
    JSValue json = JS_JSONStringify(ctx, err, JS_UNDEFINED, JS_UNDEFINED);
    size_t len;
    const char *s = JS_IsException(json) ? NULL : JS_ToCStringLen(ctx, &len, json);
    if (s) {
        set_out(s, len);
        JS_FreeCString(ctx, s);
    } else {
        /* Out of memory while describing the error. */
        set_out("{\"message\":\"out of memory\"}", 27);
    }
    JS_FreeValue(ctx, json);
    JS_FreeValue(ctx, err);
    JS_FreeValue(ctx, exc);
}

/* firefly.__call(name, json) -> json: one host call, both sides JSON text. */
static JSValue js_host_call(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    size_t name_len, args_len;
    if (argc < 2) return JS_ThrowTypeError(ctx, "expected (name, json)");
    const char *name = JS_ToCStringLen(ctx, &name_len, argv[0]);
    if (!name) return JS_EXCEPTION;
    const char *args = JS_ToCStringLen(ctx, &args_len, argv[1]);
    if (!args) { JS_FreeCString(ctx, name); return JS_EXCEPTION; }
    int32_t len = host_call(name, (int32_t)name_len, args, (int32_t)args_len);
    JS_FreeCString(ctx, name);
    JS_FreeCString(ctx, args);
    if (len < 0) return JS_ThrowInternalError(ctx, "host call failed");
    char *buf = js_malloc(ctx, (size_t)len + 1);
    if (!buf) return JS_EXCEPTION;
    host_read(buf);
    JSValue result = JS_NewStringLen(ctx, buf, (size_t)len);
    js_free(ctx, buf);
    return result;
}

/* Runs `hook` of the plugin `src` (CommonJS-style: it assigns handlers to
 * `exports`) with the JSON `input`, settling a returned promise. */
__attribute__((export_name("ff_run")))
int32_t ff_run(const char *src, int32_t src_len, const char *hook, int32_t hook_len,
               const char *input, int32_t input_len, int32_t memory_limit) {
    JSRuntime *rt = JS_NewRuntime();
    if (!rt) { set_out("{\"message\":\"out of memory\"}", 27); return FF_INIT_ERROR; }
    JS_SetMemoryLimit(rt, (size_t)memory_limit);
    JS_SetMaxStackSize(rt, 256 * 1024);
    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) { set_out("{\"message\":\"out of memory\"}", 27); return FF_INIT_ERROR; }

    JSValue global = JS_GetGlobalObject(ctx);
    JSValue firefly = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, firefly, "__call", JS_NewCFunction(ctx, js_host_call, "__call", 2));
    JS_SetPropertyStr(ctx, global, "firefly", firefly);
    JS_SetPropertyStr(ctx, global, "exports", JS_NewObject(ctx));

    int32_t status = FF_OK;
    JSValue value = JS_Eval(ctx, src, (size_t)src_len, "plugin.js", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(value)) {
        set_exception(ctx);
        status = FF_JS_ERROR;
        goto done;
    }
    JS_FreeValue(ctx, value);

    JSValue exports = JS_GetPropertyStr(ctx, global, "exports");
    JSAtom hook_atom = JS_NewAtomLen(ctx, hook, (size_t)hook_len);
    JSValue fn = JS_GetProperty(ctx, exports, hook_atom);
    JS_FreeAtom(ctx, hook_atom);
    if (!JS_IsFunction(ctx, fn)) {
        JS_FreeValue(ctx, fn);
        JS_FreeValue(ctx, exports);
        set_out("{\"message\":\"no handler\"}", 24);
        status = FF_NO_HANDLER;
        goto done;
    }

    JSValue arg = JS_ParseJSON(ctx, input, (size_t)input_len, "input");
    if (JS_IsException(arg)) {
        JS_FreeValue(ctx, fn);
        JS_FreeValue(ctx, exports);
        set_exception(ctx);
        status = FF_JS_ERROR;
        goto done;
    }
    value = JS_Call(ctx, fn, exports, 1, (JSValueConst *)&arg);
    JS_FreeValue(ctx, arg);
    JS_FreeValue(ctx, fn);
    JS_FreeValue(ctx, exports);

    /* Settle an async handler: host calls are synchronous, so the job queue
     * drains without any outside event. */
    if (!JS_IsException(value) && JS_IsPromise(value)) {
        JSContext *job_ctx;
        while (JS_ExecutePendingJob(rt, &job_ctx) > 0) {}
        switch (JS_PromiseState(ctx, value)) {
        case JS_PROMISE_FULFILLED: {
            JSValue result = JS_PromiseResult(ctx, value);
            JS_FreeValue(ctx, value);
            value = result;
            break;
        }
        case JS_PROMISE_REJECTED: {
            JSValue reason = JS_PromiseResult(ctx, value);
            JS_FreeValue(ctx, value);
            value = JS_Throw(ctx, reason);
            break;
        }
        default:
            JS_FreeValue(ctx, value);
            value = JS_ThrowInternalError(ctx, "handler's promise never settled");
        }
    }
    if (JS_IsException(value)) {
        set_exception(ctx);
        status = FF_JS_ERROR;
        goto done;
    }

    JSValue json = JS_JSONStringify(ctx, value, JS_UNDEFINED, JS_UNDEFINED);
    JS_FreeValue(ctx, value);
    if (JS_IsException(json)) {
        set_exception(ctx);
        status = FF_JS_ERROR;
        goto done;
    }
    if (JS_IsUndefined(json)) {
        set_out("null", 4);
    } else {
        size_t len;
        const char *s = JS_ToCStringLen(ctx, &len, json);
        if (s) { set_out(s, len); JS_FreeCString(ctx, s); }
        else { set_exception(ctx); status = FF_JS_ERROR; }
    }
    JS_FreeValue(ctx, json);

done:
    JS_FreeValue(ctx, global);
    /* The instance is thrown away after this call; freeing the runtime would
     * only cost time. */
    return status;
}
