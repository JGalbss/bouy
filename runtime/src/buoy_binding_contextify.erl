%% internalBinding('contextify') (src/node_contextify.cc): the native side of
%% node:vm. A context is a realm of the engine (buoy_ref_realm:create/0):
%% makeContext gives the sandbox object the private symbol that isContext
%% reads, ContextifyScript compiles a classic script with the eval compiler,
%% and runInContext runs it in the realm of a context or in this one.
-module(buoy_binding_contextify).

-export([binding/0]).

-define(SCRIPT, {'#', ?MODULE, <<"script">>}).

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
        run_in_context(This, A(1, Args))
    end), writable => true, enumerable => true, configurable => true}),
    buoy_heap:define(Proto, <<"createCachedData">>, #{value => F(<<"createCachedData">>, 0, fun(_, _) ->
        buoy_node_encoding:new_buffer(<<>>)
    end), writable => true, enumerable => true, configurable => true}),
    buoy_node:object([
        {<<"ContextifyScript">>, Script},
        {<<"makeContext">>, F(<<"makeContext">>, 0, fun(_, Args) -> make_context(A(1, Args)) end)},
        {<<"compileFunction">>, F(<<"compileFunction">>, 0, fun(_, Args) -> compile_function(Args) end)},
        {<<"constants">>, Constants},
        {<<"startSigintWatchdog">>, F(<<"startSigintWatchdog">>, 0, fun(_, _) -> undefined end)},
        {<<"stopSigintWatchdog">>, F(<<"stopSigintWatchdog">>, 0, fun(_, _) -> false end)},
        {<<"watchdogHasPendingSigint">>, F(<<"watchdogHasPendingSigint">>, 0, fun(_, _) -> false end)},
        {<<"containsModuleSyntax">>, F(<<"containsModuleSyntax">>, 2, fun(_, _) -> false end)}]
        ++ buoy_node:stubs(<<"contextify">>, [<<"measureMemory">>, <<"compileFunctionForCJSLoader">>])).

private() -> buoy_node:private_symbol(<<"contextify_context_private_symbol">>).

%% makeContext(contextObject, ...): a new realm for the sandbox, or the
%% global object of a new realm for vm.constants.DONT_CONTEXTIFY.
make_context(Sandbox) ->
    Global = buoy_ref_realm:create(),
    Realm = erlang:get('$buoy_realms'),
    erlang:put({?MODULE, builtins, Realm}, own_keys(Global)),
    Context = case buoy_heap:is_object(Sandbox) of
        true -> Sandbox;
        false -> Global
    end,
    buoy_heap:define(Context, private(), #{value => Realm, writable => false, enumerable => false, configurable => false}),
    erlang:put({?MODULE, global, Realm}, Global),
    Context.

%% The own keys that a run copies: no private name, and not the private symbol
%% that marks a context.
own_keys(O) ->
    Marker = private(),
    [K || K <- buoy_heap:own_keys(O), K =/= Marker, not is_tuple(K) orelse element(1, K) =/= '#'].

%% new ContextifyScript(code, filename, lineOffset, columnOffset, cachedData,
%% produceCachedData, parsingContext): the script compiles now, so a
%% SyntaxError throws from the constructor.
new_script(This, Args) ->
    Code = buoy_node:arg(1, Args),
    Module = buoy_ref_eval:compile_script(Code),
    buoy_heap:private_put(This, ?SCRIPT, Module),
    case buoy_node:arg(5, Args) of
        undefined -> ok;
        _ -> buoy_heap:set(This, <<"cachedDataRejected">>, false)
    end,
    case buoy_ref:truthy(buoy_node:arg(6, Args)) of
        true ->
            buoy_heap:set(This, <<"cachedDataProduced">>, true),
            buoy_heap:set(This, <<"cachedData">>, buoy_node_encoding:new_buffer(<<>>));
        false ->
            ok
    end,
    buoy_heap:set(This, <<"sourceMapURL">>, undefined),
    host_defined(This, buoy_node:arg(8, Args)).

%% The id symbol of the host-defined options of a script or a function,
%% which registerModule of internal/modules/esm/utils keys the callbacks of
%% importModuleDynamically by.
host_defined(O, Id) ->
    buoy_heap:define(O, buoy_node:private_symbol(<<"host_defined_option_symbol">>),
                     #{value => Id, writable => true, enumerable => false, configurable => true}),
    undefined.

%% runInContext(contextifiedObject or null, timeout, ...): the completion value
%% of the script in the realm of the context, or in this realm for null.
%% shortcut: the sandbox's properties are copied to the realm's global object
%% before the run and the new globals back after it, where V8 intercepts each
%% access; a function that the script leaves behind reads the realm's global
%% object later. Intercept global accesses when the engine has a hook for it.
run_in_context(This, Context) ->
    Module = case buoy_heap:is_object(This) andalso buoy_heap:private_find(This, ?SCRIPT) of
        {ok, M} -> M;
        _ -> buoy_ref:type_error(<<"Illegal invocation">>)
    end,
    case Context of
        null ->
            Module:'$body'();
        _ ->
            Realm = buoy_heap:get(Context, private()),
            Global = erlang:get({?MODULE, global, Realm}),
            Sandboxed = Global =/= Context,
            Sandboxed andalso copy(Context, Global, own_keys(Context)),
            Run = buoy_ref_realm:realm_fun(Realm, fun(_, _) -> Module:'$body'() end),
            try Run(undefined, undefined)
            after
                Sandboxed andalso copy(Global, Context, own_keys(Global) -- erlang:get({?MODULE, builtins, Realm}))
            end
    end.

copy(From, To, Keys) ->
    [buoy_heap:set(To, K, buoy_heap:get(From, K)) || K <- Keys],
    true.

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
        Context -> (buoy_ref_realm:realm_fun(buoy_heap:get(Context, private()), Make))(undefined, undefined)
    end,
    host_defined(Function, buoy_node:arg(10, Args)),
    buoy_node:object([{<<"function">>, Function}, {<<"sourceMapURL">>, undefined}]).
