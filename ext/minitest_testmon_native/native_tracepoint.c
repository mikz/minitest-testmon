#include "ruby.h"
#include "ruby/debug.h"
#include "ruby/ractor.h"

static ID callback_ivar;
static ID filters_ivar;
static ID call_id;
static ID owner_ivar;
static rb_ractor_local_key_t owner_key;
static ID target_ivar, attribution_ivar, scope_ivar, live_ivar, test_id_ivar;
static ID require_id, line_id, test_scope_id;
static ID router_ivar, enabled_ivar, router_callback_ivar;

static int target_recorded(VALUE tracepoint, rb_trace_arg_t *argument)
{
    VALUE target = rb_ivar_get(tracepoint, target_ivar);
    if (NIL_P(target)) return 0;
    Check_Type(target, T_ARRAY);
    VALUE event = rb_tracearg_event(argument);
    if (event == ID2SYM(call_id) && rb_tracearg_method_id(argument) == ID2SYM(require_id)) return 0;
    if (RARRAY_LEN(target) != 4) return 0;
    VALUE paths = rb_ary_entry(target, 0);
    Check_Type(paths, T_ARRAY);
    Check_Type(rb_ary_entry(target, 1), T_STRING);
    Check_Type(rb_ary_entry(target, 2), T_HASH);
    Check_Type(rb_ary_entry(target, 3), T_HASH);
    VALUE path = rb_tracearg_path(argument);
    Check_Type(path, T_STRING);
    int matched = 0;
    for (long index = 0; index < RARRAY_LEN(paths); index++) {
        Check_Type(RARRAY_AREF(paths, index), T_STRING);
        if (RTEST(rb_str_equal(path, RARRAY_AREF(paths, index)))) matched = 1;
    }
    if (!matched) return 0;
    if (event == ID2SYM(line_id) &&
        RTEST(rb_hash_lookup2(rb_ary_entry(target, 2), rb_tracearg_lineno(argument), Qfalse))) return 0;
    VALUE thread = rb_thread_current();
    VALUE token = rb_ivar_get(thread, attribution_ivar);
    if (NIL_P(token) || !RTEST(rb_ivar_get(token, live_ivar))) return 0;
    VALUE test_id = rb_ivar_get(token, test_id_ivar);
    VALUE scope = rb_ivar_get(thread, scope_ivar);
    if (NIL_P(scope)) scope = ID2SYM(test_scope_id);
    VALUE scopes = rb_hash_lookup2(rb_ary_entry(target, 3), test_id, Qnil);
    if (NIL_P(scopes)) return 0;
    Check_Type(scopes, T_HASH);
    VALUE sources = rb_hash_lookup2(scopes, scope, Qnil);
    if (NIL_P(sources)) return 0;
    Check_Type(sources, T_HASH);
    return RTEST(rb_hash_lookup2(sources, rb_ary_entry(target, 1), Qfalse));
}

static void dispatch_router(VALUE tracepoint, VALUE index, rb_trace_arg_t *argument)
{
    Check_Type(index, T_HASH);
    VALUE methods = rb_hash_lookup2(index, rb_tracearg_event(argument), Qnil);
    if (NIL_P(methods)) return;
    Check_Type(methods, T_HASH);
    VALUE candidates = rb_hash_lookup2(methods, rb_tracearg_method_id(argument), Qundef);
    if (candidates == Qundef) candidates = rb_hash_lookup2(methods, Qnil, Qnil);
    if (NIL_P(candidates)) return;
    Check_Type(candidates, T_ARRAY);
    for (long position = 0; position < RARRAY_LEN(candidates); position++) {
        VALUE activation = RARRAY_AREF(candidates, position);
        if (RTEST(rb_ivar_get(activation, enabled_ivar))) {
            VALUE callback = rb_ivar_get(activation, router_callback_ivar);
            rb_funcall(callback, call_id, 1, tracepoint);
        }
    }
    RB_GC_GUARD(candidates);
}

static void dispatch(VALUE tracepoint, void *unused)
{
    if (rb_ractor_local_storage_value(owner_key) != rb_ivar_get(tracepoint, owner_ivar)) return;
    rb_trace_arg_t *argument = rb_tracearg_from_tracepoint(tracepoint);
    VALUE router = rb_ivar_get(tracepoint, router_ivar);
    if (!NIL_P(router)) {
        dispatch_router(tracepoint, router, argument);
        return;
    }
    if (target_recorded(tracepoint, argument)) return;
    VALUE filters = rb_ivar_get(tracepoint, filters_ivar);
    Check_Type(filters, T_HASH);
    VALUE methods = rb_hash_lookup2(filters, rb_tracearg_event(argument), Qundef);
    if (methods != Qundef) Check_Type(methods, T_HASH);
    if (methods != Qundef) {
        VALUE requirement = rb_hash_lookup2(methods, rb_tracearg_method_id(argument), Qfalse);
        if (!RTEST(requirement)) return;
        if ((RB_TYPE_P(requirement, T_CLASS) || RB_TYPE_P(requirement, T_MODULE)) &&
            !RTEST(rb_obj_is_kind_of(rb_tracearg_self(argument), requirement))) return;
    }
    rb_funcall(rb_ivar_get(tracepoint, callback_ivar), call_id, 1, tracepoint);
}

static VALUE build(VALUE self, VALUE events, VALUE filters)
{
    rb_event_flag_t flags = 0;
    Check_Type(events, T_ARRAY);
    Check_Type(filters, T_HASH);
    for (long index = 0; index < RARRAY_LEN(events); index++) {
        VALUE event = RARRAY_AREF(events, index);
        Check_Type(event, T_SYMBOL);
        ID name = SYM2ID(event);
        if (name == rb_intern("call")) flags |= RUBY_EVENT_CALL;
        else if (name == rb_intern("line")) flags |= RUBY_EVENT_LINE;
        else if (name == rb_intern("b_call")) flags |= RUBY_EVENT_B_CALL;
        else if (name == rb_intern("return")) flags |= RUBY_EVENT_RETURN;
        else if (name == rb_intern("c_call")) flags |= RUBY_EVENT_C_CALL;
        else if (name == rb_intern("c_return")) flags |= RUBY_EVENT_C_RETURN;
        else if (name == rb_intern("script_compiled")) flags |= RUBY_EVENT_SCRIPT_COMPILED;
        else rb_raise(rb_eArgError, "unsupported native filter event");
        VALUE methods = rb_hash_lookup2(filters, event, Qundef);
        if (methods != Qundef) Check_Type(methods, T_HASH);
    }
    if (!flags) rb_raise(rb_eArgError, "at least one event is required");
    VALUE owner = rb_ractor_local_storage_value(owner_key);
    if (NIL_P(owner)) {
        owner = rb_obj_freeze(rb_obj_alloc(rb_cObject));
        rb_ractor_local_storage_value_set(owner_key, owner);
    }
    VALUE callback = rb_block_proc();
    VALUE tracepoint = rb_tracepoint_new(Qnil, flags, dispatch, NULL);
    rb_ivar_set(tracepoint, filters_ivar, rb_obj_freeze(rb_hash_dup(filters)));
    rb_ivar_set(tracepoint, owner_ivar, owner);
    rb_ivar_set(tracepoint, callback_ivar, callback);
    return tracepoint;
}

static VALUE build_router(VALUE self, VALUE events, VALUE index)
{
    Check_Type(index, T_HASH);
    VALUE tracepoint = build(self, events, rb_hash_new());
    rb_ivar_set(tracepoint, router_ivar, index);
    return tracepoint;
}

static VALUE build_target(VALUE self, VALUE paths, VALUE source, VALUE constants, VALUE recorded)
{
    Check_Type(paths, T_ARRAY);
    Check_Type(source, T_STRING);
    Check_Type(constants, T_HASH);
    Check_Type(recorded, T_HASH);
    for (long index = 0; index < RARRAY_LEN(paths); index++) Check_Type(RARRAY_AREF(paths, index), T_STRING);
    VALUE events = rb_ary_new_from_args(3, ID2SYM(rb_intern("line")), ID2SYM(rb_intern("call")), ID2SYM(rb_intern("b_call")));
    VALUE tracepoint = build(self, events, rb_hash_new());
    VALUE target = rb_ary_new_from_args(4, rb_obj_freeze(rb_ary_dup(paths)), source, rb_obj_freeze(rb_hash_dup(constants)), recorded);
    rb_ivar_set(tracepoint, target_ivar, rb_obj_freeze(target));
    return tracepoint;
}

void Init_native_tracepoint(void)
{
    VALUE minitest = rb_define_module("Minitest");
    VALUE testmon = rb_define_module_under(minitest, "Testmon");
    VALUE native = rb_define_module_under(testmon, "NativeTracePoint");
    rb_ext_ractor_safe(true);
    owner_key = rb_ractor_local_storage_value_newkey();
    owner_ivar = rb_intern("@testmon_owner");
    callback_ivar = rb_intern("@testmon_callback");
    filters_ivar = rb_intern("@testmon_filters");
    call_id = rb_intern("call");
    target_ivar = rb_intern("@testmon_target");
    router_ivar = rb_intern("@testmon_router");
    enabled_ivar = rb_intern("@enabled");
    router_callback_ivar = rb_intern("@callback");
    rb_define_singleton_method(native, "build_router", build_router, 2);
    attribution_ivar = rb_intern("@__testmon_attribution");
    scope_ivar = rb_intern("@__testmon_evidence_scope");
    live_ivar = rb_intern("@live");
    test_id_ivar = rb_intern("@test_id");
    require_id = rb_intern("require");
    line_id = rb_intern("line");
    test_scope_id = rb_intern("test");
    rb_define_singleton_method(native, "build_target", build_target, 4);
    rb_define_singleton_method(native, "build", build, 2);
}
