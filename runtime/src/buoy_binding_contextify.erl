%% internalBinding('contextify') (src/node_contextify.cc): the native side of
%% node:vm. A context is a realm of the engine (buoy_ref_realm:create/0).
%% makeContext gives the sandbox object the private symbol that isContext
%% reads, ContextifyScript compiles a classic script with the eval compiler,
%% and runInContext runs it in the realm of a context or in this one.
%%
%% The code of a context sees a global proxy (buoy_ref_realm:set_global_proxy/2)
%% in front of the realm's global object, as V8 does: a host proxy whose
%% interceptors below follow the named property callbacks of
%% node_contextify.cc. A read finds the sandbox's property first, then the
%% global's; a write and a definition go to the sandbox and to the global.
-module(buoy_binding_contextify).

-export([binding/0, cached_data/1, source_map_url/1]).
-export([get/4, set/5, has/3, has_binding/3, delete_property/3, own_keys/2, get_own_property/3, define_own_property/4]).

-define(SCRIPT, {'#', ?MODULE, <<"script">>}).
-define(SOURCE, {'#', ?MODULE, <<"source">>}).

%% The globals of V8's realm that a new context has; the realm of the engine
%% also has the host's, such as setTimeout and process, which node:vm does
%% not give a context.
-define(V8_GLOBALS, [<<"Object">>, <<"Function">>, <<"Array">>, <<"Number">>, <<"parseFloat">>, <<"parseInt">>,
                     <<"Infinity">>, <<"NaN">>, <<"undefined">>, <<"Boolean">>, <<"String">>, <<"Symbol">>, <<"Date">>,
                     <<"Promise">>, <<"RegExp">>, <<"Error">>, <<"AggregateError">>, <<"EvalError">>, <<"RangeError">>,
                     <<"ReferenceError">>, <<"SyntaxError">>, <<"TypeError">>, <<"URIError">>, <<"globalThis">>, <<"JSON">>,
                     <<"Math">>, <<"Intl">>, <<"ArrayBuffer">>, <<"Atomics">>, <<"Uint8Array">>, <<"Int8Array">>,
                     <<"Uint16Array">>, <<"Int16Array">>, <<"Uint32Array">>, <<"Int32Array">>, <<"BigUint64Array">>,
                     <<"BigInt64Array">>, <<"Uint8ClampedArray">>, <<"Float32Array">>, <<"Float64Array">>, <<"DataView">>,
                     <<"Map">>, <<"BigInt">>, <<"Set">>, <<"Iterator">>, <<"WeakMap">>, <<"WeakSet">>, <<"Proxy">>,
                     <<"Reflect">>, <<"FinalizationRegistry">>, <<"WeakRef">>, <<"decodeURI">>, <<"decodeURIComponent">>,
                     <<"encodeURI">>, <<"encodeURIComponent">>, <<"escape">>, <<"unescape">>, <<"eval">>, <<"isFinite">>,
                     <<"isNaN">>, <<"console">>, <<"SuppressedError">>, <<"DisposableStack">>, <<"AsyncDisposableStack">>,
                     <<"Float16Array">>, <<"SharedArrayBuffer">>, <<"WebAssembly">>]).

-spec binding() -> term().
binding() ->
    Constants = buoy_node:object([{<<"measureMemory">>, buoy_node:object([
        {<<"mode">>, buoy_node:object([{<<"SUMMARY">>, 0}, {<<"DETAILED">>, 1}])},
        {<<"execution">>, buoy_node:object([{<<"DEFAULT">>, 0}, {<<"EAGER">>, 1}])}])}]),
    F = fun buoy_node:fn/3,
    A = fun buoy_node:arg/2,
    Script = buoy_node:constructor(<<"ContextifyScript">>, 8, fun(This, Args) -> new_script(This, Args) end),
    Proto = buoy_heap:get(Script, <<"prototype">>),
    buoy_heap:define(Proto, <<"runInContext">>, #{value => F(<<"runInContext">>, 0, fun(This, Args) ->
        run_in_context(This, A(1, Args), A(2, Args))
    end), writable => true, enumerable => true, configurable => true}),
    buoy_heap:define(Proto, <<"createCachedData">>, #{value => F(<<"createCachedData">>, 0, fun(This, _) ->
        {ok, Source} = buoy_heap:private_find(This, ?SOURCE),
        buoy_node_encoding:new_buffer(cached_data(Source))
    end), writable => true, enumerable => true, configurable => true}),
    buoy_node:object([
        {<<"ContextifyScript">>, Script},
        {<<"makeContext">>, F(<<"makeContext">>, 0, fun(_, Args) -> make_context(A(1, Args), A(7, Args)) end)},
        {<<"compileFunction">>, F(<<"compileFunction">>, 0, fun(_, Args) -> compile_function(Args) end)},
        {<<"constants">>, Constants},
        {<<"startSigintWatchdog">>, F(<<"startSigintWatchdog">>, 0, fun(_, _) -> undefined end)},
        {<<"stopSigintWatchdog">>, F(<<"stopSigintWatchdog">>, 0, fun(_, _) -> false end)},
        {<<"watchdogHasPendingSigint">>, F(<<"watchdogHasPendingSigint">>, 0, fun(_, _) -> false end)},
        {<<"containsModuleSyntax">>, F(<<"containsModuleSyntax">>, 2, fun(_, _) -> false end)},
        {<<"measureMemory">>, F(<<"measureMemory">>, 2, fun(_, Args) -> measure_memory(A(1, Args)) end)},
        {<<"compileFunctionForCJSLoader">>, F(<<"compileFunctionForCJSLoader">>, 4, fun(_, Args) ->
            compile_function_for_cjs_loader(A(1, Args), A(2, Args))
        end)}]).

%% measureMemory(mode, execution): a promise of V8's estimate of the memory
%% of each context. All contexts share the heap of the process, so a context
%% of node:vm counts the records of its own realm, and the main context the
%% rest of the process.
measure_memory(Mode) ->
    {memory, Total} = erlang:process_info(self(), memory),
    Contexts = case erlang:get('$buoy_realms') of
        undefined -> [];
        Last -> [realm_bytes(N) || N <- lists:seq(1, Last)]
    end,
    Current = max(0, Total - lists:sum(Contexts)),
    Summary = [{<<"total">>, estimate(Total)}],
    Result = case Mode of
        1 -> Summary ++ [{<<"current">>, estimate(Current)}, {<<"other">>, buoy_heap:new_array([estimate(B) || B <- Contexts])}];
        _ -> Summary
    end,
    buoy_jobs:fulfilled(buoy_node:object(Result)).

estimate(Bytes) ->
    buoy_node:object([{<<"jsMemoryEstimate">>, Bytes}, {<<"jsMemoryRange">>, buoy_heap:new_array([Bytes, Bytes])}]).

realm_bytes(N) ->
    Words = lists:sum([erts_debug:flat_size(V) || {{R, _}, V} <- erlang:get(), R =:= N]),
    Words * erlang:system_info(wordsize).

private() -> buoy_node:private_symbol(<<"contextify_context_private_symbol">>).

%% makeContext(contextObject, ...): a new realm whose global proxy intercepts
%% the sandbox, or the global object of a new realm for
%% vm.constants.DONT_CONTEXTIFY.
make_context(Sandbox, Option) ->
    Global = buoy_ref_realm:create(),
    Realm = erlang:get('$buoy_realms'),
    [buoy_heap:delete_property(Global, K) || K <- buoy_heap:own_keys(Global), is_binary(K), not lists:member(K, ?V8_GLOBALS)],
    Context = case buoy_heap:is_object(Sandbox) of
        true ->
            Proxy = buoy_heap:proxy(Global, {host, ?MODULE, Sandbox}),
            buoy_heap:define(Global, <<"globalThis">>, #{value => Proxy}),
            buoy_ref_realm:set_global_proxy(Realm, Proxy),
            Sandbox;
        false ->
            Global
    end,
    buoy_heap:define(Context, private(), #{value => Realm, writable => false, enumerable => false, configurable => false}),
    %% import() of code of the context without a script, such as indirect eval
    %% in a job, takes the context's host-defined option.
    case Option of
        {'$sym', _, _} ->
            buoy_heap:define(Context, buoy_node:private_symbol(<<"host_defined_option_symbol">>),
                             #{value => Option, writable => true, enumerable => false, configurable => true}),
            buoy_module:set_realm_host(Realm, Option);
        _ ->
            ok
    end,
    Context.

%% new ContextifyScript(code, filename, lineOffset, columnOffset, cachedData,
%% produceCachedData, parsingContext): the script compiles now, so a
%% SyntaxError throws from the constructor.
new_script(This, Args) ->
    Code = buoy_node:arg(1, Args),
    Module = buoy_ref_eval:compile_script(Code),
    buoy_heap:private_put(This, ?SCRIPT, Module),
    buoy_heap:private_put(This, ?SOURCE, Code),
    set_host(This, Module, buoy_node:arg(2, Args), buoy_node:arg(8, Args)),
    [buoy_heap:set(This, K, V) || {K, V} <- cache_fields(Code, Args) ++ [{<<"sourceMapURL">>, source_map_url(Code)}]],
    undefined.

%% The fields of a code cache of Code that the arguments ask for: whether a
%% given cache was rejected, and a new one.
cache_fields(Code, Args) ->
    Rejected = case buoy_node:arg(5, Args) of
        undefined -> [];
        Data -> [{<<"cachedDataRejected">>, buoy_node_encoding:view_bytes(Data) =/= cached_data(Code)}]
    end,
    Produced = case buoy_ref:truthy(buoy_node:arg(6, Args)) of
        true -> [{<<"cachedDataProduced">>, true}, {<<"cachedData">>, buoy_node_encoding:new_buffer(cached_data(Code))}];
        false -> []
    end,
    Rejected ++ Produced.

%% The code cache of a source text. The compiled module lives in the VM, so
%% the cache only identifies it, as V8's checks its source hash and flags: a
%% cache of another source or of another runtime is rejected.
-spec cached_data(term()) -> binary().
cached_data(Code) ->
    Tag = buoy_binding_v8:version_tag(),
    <<"BUOY", Tag:32, (erlang:md5(buoy_ref_string:to_utf8(buoy_ref:to_string(Code))))/binary>>.

%% The URL of the last `//# sourceMappingURL=` comment of the code, as V8's
%% scanner reads the magic comment, or undefined.
-spec source_map_url(term()) -> term().
source_map_url(Code) ->
    Text = buoy_ref_string:to_utf8(buoy_ref:to_string(Code)),
    case re:run(Text, <<"//[#@][ \\t]sourceMappingURL=([^\\s'\"]+)[ \\t]*(?:\\r|\\n|$)">>, [global, {capture, all_but_first, binary}, unicode]) of
        {match, Matches} -> buoy_node:string(lists:last(lists:last(Matches)));
        nomatch -> undefined
    end.

%% runInContext(contextifiedObject or null, timeout, ...): the completion value
%% of the script in the realm of the context, or in this realm for null. A
%% timeout runs the script compiled to check its deadline, as V8's watchdog
%% stops a run.
run_in_context(This, Context, Timeout) ->
    Module = case buoy_heap:is_object(This) andalso buoy_heap:private_find(This, ?SCRIPT) of
        {ok, M} -> M;
        _ -> buoy_ref:type_error(<<"Illegal invocation">>)
    end,
    case is_integer(Timeout) andalso Timeout >= 0 of
        false ->
            run(Module, Context);
        true ->
            {ok, Source} = buoy_heap:private_find(This, ?SOURCE),
            Interruptible = buoy_ref_eval:compile_script(Source, ["--interruptible"]),
            case buoy_ref_eval:run_until(Timeout, fun() -> run(Interruptible, Context) end) of
                {ok, Value} -> Value;
                timeout -> buoy_node:throw_code('Error', <<"ERR_SCRIPT_EXECUTION_TIMEOUT">>,
                                                iolist_to_binary(["Script execution timed out after ", integer_to_binary(Timeout), "ms"]))
            end
    end.

run(Module, null) -> Module:'$body'();
run(Module, Context) -> (buoy_ref_realm:realm_fun(realm_of(Context), fun(_, _) -> Module:'$body'() end))(undefined, undefined).

realm_of(Context) -> buoy_heap:get(Context, private()).

%% compileFunction(code, filename, lineOffset, columnOffset, cachedData,
%% produceCachedData, parsingContext, contextExtensions, params, ...):
%% { function }, the code as the body of a function of the params.
compile_function(Args) ->
    Code = buoy_node:arg(1, Args),
    Params = case buoy_node:arg(9, Args) of
        undefined -> [];
        List -> buoy_heap:array_items(List)
    end,
    Make = fun(_, _) -> buoy_ref_eval:create_function(Params ++ [Code]) end,
    Function = case buoy_node:arg(7, Args) of
        Context when Context =:= undefined; Context =:= null -> Make(undefined, undefined);
        Context -> (buoy_ref_realm:realm_fun(realm_of(Context), Make))(undefined, undefined)
    end,
    {'$f', _, Fun} = Function,
    {module, Module} = erlang:fun_info(Fun, module),
    set_host(Function, Module, buoy_node:arg(2, Args), buoy_node:arg(10, Args)),
    buoy_node:object([{<<"function">>, Function}, {<<"sourceMapURL">>, source_map_url(Code)}] ++ cache_fields(Code, Args)).

%% The host-defined option of a script or a function, which import() of its
%% code passes to the dynamic import callback of module_wrap, as V8 keeps it
%% in the script's host-defined options.
%% shortcut: scripts of one source text share their compiled module, so the
%% last of them names the option; a module of each script would separate
%% them.
set_host(Referrer, Module, Filename, {'$sym', _, _} = Option) ->
    buoy_heap:define(Referrer, buoy_node:private_symbol(<<"host_defined_option_symbol">>),
                     #{value => Option, writable => true, enumerable => false, configurable => true}),
    buoy_module:set_host(Module, 0, {Filename, Option});
set_host(_, _, _, _) ->
    ok.

%% compileFunctionForCJSLoader(content, filename, isSeaMain, shouldDetectModule):
%% the function of a CommonJS module of the parameters of Node's wrapper, as
%% Node's CommonJS loader runs it. A module of the program has its compiled
%% function already, as V8 takes a function from its code cache. A hashbang
%% line becomes a comment, as V8 reads it in the source of a script.
compile_function_for_cjs_loader(Code, Filename) ->
    Text = buoy_ref:to_string(Code),
    Function = case buoy_module:compiled_wrapper(Filename) of
        {ok, Wrapper} -> Wrapper;
        none -> compile_cjs(Text)
    end,
    buoy_node:object([{<<"cachedDataRejected">>, false}, {<<"sourceMapURL">>, source_map_url(Text)},
                      {<<"sourceURL">>, undefined}, {<<"function">>, Function}, {<<"canParseAsESM">>, false}]).

compile_cjs(Text) ->
    Length = buoy_ref_string:length_of(Text),
    Body = case buoy_ref_string:slice(Text, 0, min(2, Length)) of
        <<"#!">> -> buoy_ref_string:concat(<<"//">>, buoy_ref_string:slice(Text, 2, Length));
        _ -> Text
    end,
    buoy_ref_eval:create_function([<<"exports">>, <<"require">>, <<"module">>, <<"__filename">>, <<"__dirname">>, Body]).

%%% The interceptors of the global proxy. Sandbox is the contextified object
%%% and Global the realm's own global object.

%% PropertyGetterCallback: the sandbox's property, up its chain, else the
%% global's. The sandbox itself reads as the global proxy.
-spec get(term(), term(), buoy_heap:key(), term()) -> term().
get(Sandbox, Global, K, Receiver) ->
    case is_intercepted(K) andalso buoy_heap:has(Sandbox, K) of
        true -> proxy_for(Sandbox, buoy_heap:get(Sandbox, K, Sandbox));
        false -> buoy_heap:get(Global, K, Receiver)
    end.

proxy_for(Sandbox, Sandbox) -> buoy_ref_realm:global_object(realm_of(Sandbox));
proxy_for(_Sandbox, Value) -> Value.

%% PropertySetterCallback: a read-only property on the global or the sandbox
%% keeps the global's own behavior. Otherwise the value goes to the sandbox,
%% and to the global unless the sandbox's own property is an accessor.
-spec set(term(), term(), buoy_heap:key(), term(), term()) -> boolean().
set(Sandbox, Global, K, V, _Receiver) ->
    case is_intercepted(K) andalso {find(Global, K), find(Sandbox, K)} of
        false ->
            buoy_heap:set(Global, K, V, Global);
        {OnGlobal, OnSandbox} ->
            case is_read_only(OnGlobal) orelse is_read_only(OnSandbox) of
                true -> false;
                false when OnGlobal =:= none, OnSandbox =:= none, is_tuple(K) -> buoy_heap:set(Global, K, V, Global);
                false -> set_sandbox(Sandbox, Global, K, V)
            end
    end.

set_sandbox(Sandbox, Global, K, V) ->
    buoy_heap:set(Sandbox, K, V, Sandbox) andalso
        case buoy_heap:get_own(Sandbox, K) of
            {accessor, _, _, _} -> true;
            _ -> buoy_heap:set(Global, K, V, Global)
        end.

%% PropertyQueryCallback: the sandbox's own property, else the global's, up
%% the chain of the context.
-spec has(term(), term(), buoy_heap:key()) -> boolean().
has(Sandbox, Global, K) ->
    (is_intercepted(K) andalso buoy_heap:get_own(Sandbox, K) =/= none) orelse buoy_heap:has(Global, K).

%% A name resolves through the getter callback, up the sandbox's chain.
-spec has_binding(term(), term(), buoy_heap:key()) -> boolean().
has_binding(Sandbox, Global, K) ->
    (is_intercepted(K) andalso buoy_heap:has(Sandbox, K)) orelse buoy_heap:has(Global, K).

%% PropertyDeleterCallback: a property that the sandbox keeps stays on the
%% global too.
-spec delete_property(term(), term(), buoy_heap:key()) -> boolean().
delete_property(Sandbox, Global, K) ->
    case is_intercepted(K) of
        true -> buoy_heap:delete_property(Sandbox, K) andalso buoy_heap:delete_property(Global, K);
        false -> buoy_heap:delete_property(Global, K)
    end.

%% The global's own keys, then those of the sandbox that the global lacks,
%% as V8 adds the keys of PropertyEnumeratorCallback to the object's own.
-spec own_keys(term(), term()) -> [buoy_heap:key()].
own_keys(Sandbox, Global) ->
    Own = buoy_heap:own_keys(Global),
    Own ++ ([K || K <- buoy_heap:own_keys(Sandbox), K =/= private()] -- Own).

%% PropertyDescriptorCallback: the sandbox's own property, else the global's.
-spec get_own_property(term(), term(), buoy_heap:key()) -> buoy_heap:property().
get_own_property(Sandbox, Global, K) ->
    case is_intercepted(K) andalso buoy_heap:get_own(Sandbox, K) of
        Found when Found =:= false; Found =:= none -> buoy_heap:get_own(Global, K);
        Own -> Own
    end.

%% PropertyDefinerCallback: the definition goes to the sandbox, as the
%% descriptor it gives. Then the global defines it, checked against the
%% property that the descriptor callback reports, as V8 checks a definition
%% that the interceptor did not take. A read-only and non-configurable
%% property of the global stays the global's own.
-spec define_own_property(term(), term(), buoy_heap:key(), map()) -> boolean().
define_own_property(Sandbox, Global, K, Desc) ->
    case is_intercepted(K) andalso not is_fixed(buoy_heap:get_own(Global, K)) of
        false ->
            buoy_heap:define_own_property(Global, K, Desc);
        true ->
            _ = buoy_heap:define_own_property(Sandbox, K, sandbox_descriptor(Desc)),
            Current = get_own_property(Sandbox, Global, K),
            buoy_heap:validate_and_apply(undefined, K, buoy_heap:is_extensible(Global), Desc, Current)
                andalso buoy_heap:define_own_property(Global, K, Desc)
    end.

%% The descriptor that node_contextify.cc gives the sandbox: a missing value
%% or accessor function becomes undefined.
sandbox_descriptor(Desc) ->
    Base = case buoy_heap:is_accessor_descriptor(Desc) of
        true -> #{get => maps:get(get, Desc, undefined), set => maps:get(set, Desc, undefined)};
        false -> maps:put(value, maps:get(value, Desc, undefined), maps:with([writable], Desc))
    end,
    maps:merge(Base, maps:with([enumerable, configurable], Desc)).

%% The private symbol of a context is the sandbox's own, which no interceptor
%% reports, as V8 keeps private symbols out of interceptors.
is_intercepted(K) -> K =/= private().

%% The property K of O or up its chain, as GetRealNamedPropertyAttributes
%% finds it.
find(null, _K) -> none;
find(O, K) ->
    case buoy_heap:get_own(O, K) of
        none -> find(buoy_heap:prototype_of(O), K);
        Found -> Found
    end.

is_read_only({data, _, Bits}) -> Bits band 1 =:= 0;
is_read_only(_) -> false.

is_fixed({data, _, Bits}) -> Bits band 5 =:= 0;
is_fixed(_) -> false.
