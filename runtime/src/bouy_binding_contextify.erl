%% internalBinding('contextify') (src/node_contextify.cc): the native side of
%% node:vm. A context is a realm of the engine (bouy_ref_realm:create/0):
%% makeContext gives the sandbox object the private symbol that isContext
%% reads, ContextifyScript compiles a classic script with the eval compiler,
%% and runInContext runs it in the realm of a context or in this one.
-module(bouy_binding_contextify).

-export([binding/0]).

-define(SCRIPT, {'#', ?MODULE, <<"script">>}).

-spec binding() -> term().
binding() ->
    Constants = bouy_node:object([{<<"measureMemory">>, bouy_node:object([
        {<<"mode">>, bouy_node:object([{<<"SUMMARY">>, 0}, {<<"DETAILED">>, 1}])},
        {<<"execution">>, bouy_node:object([{<<"DEFAULT">>, 0}, {<<"EAGER">>, 1}])}])}]),
    F = fun bouy_node:fn/3,
    A = fun bouy_node:arg/2,
    Script = bouy_node:constructor(<<"ContextifyScript">>, 8, fun(This, Args) -> new_script(This, Args) end),
    Proto = bouy_heap:get(Script, <<"prototype">>),
    bouy_heap:define(Proto, <<"runInContext">>, #{value => F(<<"runInContext">>, 0, fun(This, Args) ->
        run_in_context(This, A(1, Args))
    end), writable => true, enumerable => true, configurable => true}),
    bouy_heap:define(Proto, <<"createCachedData">>, #{value => F(<<"createCachedData">>, 0, fun(_, _) ->
        bouy_node_encoding:new_buffer(<<>>)
    end), writable => true, enumerable => true, configurable => true}),
    bouy_node:object([
        {<<"ContextifyScript">>, Script},
        {<<"makeContext">>, F(<<"makeContext">>, 0, fun(_, Args) -> make_context(A(1, Args)) end)},
        {<<"compileFunction">>, F(<<"compileFunction">>, 0, fun(_, Args) -> compile_function(Args) end)},
        {<<"constants">>, Constants},
        {<<"startSigintWatchdog">>, F(<<"startSigintWatchdog">>, 0, fun(_, _) -> undefined end)},
        {<<"stopSigintWatchdog">>, F(<<"stopSigintWatchdog">>, 0, fun(_, _) -> false end)},
        {<<"watchdogHasPendingSigint">>, F(<<"watchdogHasPendingSigint">>, 0, fun(_, _) -> false end)},
        {<<"containsModuleSyntax">>, F(<<"containsModuleSyntax">>, 2, fun(_, _) -> false end)}]
        ++ bouy_node:stubs(<<"contextify">>, [<<"measureMemory">>, <<"compileFunctionForCJSLoader">>])).

private() -> bouy_node:private_symbol(<<"contextify_context_private_symbol">>).

%% makeContext(contextObject, ...): a new realm for the sandbox, or the
%% global object of a new realm for vm.constants.DONT_CONTEXTIFY.
make_context(Sandbox) ->
    Global = bouy_ref_realm:create(),
    Realm = erlang:get('$bouy_realms'),
    erlang:put({?MODULE, builtins, Realm}, own_keys(Global)),
    Context = case bouy_heap:is_object(Sandbox) of
        true -> Sandbox;
        false -> Global
    end,
    bouy_heap:define(Context, private(), #{value => Realm, writable => false, enumerable => false, configurable => false}),
    erlang:put({?MODULE, global, Realm}, Global),
    Context.

%% The own keys that a run copies: no private name, and not the private symbol
%% that marks a context.
own_keys(O) ->
    Marker = private(),
    [K || K <- bouy_heap:own_keys(O), K =/= Marker, not is_tuple(K) orelse element(1, K) =/= '#'].

%% new ContextifyScript(code, filename, lineOffset, columnOffset, cachedData,
%% produceCachedData, parsingContext): the script compiles now, so a
%% SyntaxError throws from the constructor.
new_script(This, Args) ->
    Code = bouy_node:arg(1, Args),
    Module = bouy_ref_eval:compile_script(Code),
    bouy_heap:private_put(This, ?SCRIPT, Module),
    case bouy_node:arg(5, Args) of
        undefined -> ok;
        _ -> bouy_heap:set(This, <<"cachedDataRejected">>, false)
    end,
    case bouy_ref:truthy(bouy_node:arg(6, Args)) of
        true ->
            bouy_heap:set(This, <<"cachedDataProduced">>, true),
            bouy_heap:set(This, <<"cachedData">>, bouy_node_encoding:new_buffer(<<>>));
        false ->
            ok
    end,
    bouy_heap:set(This, <<"sourceMapURL">>, undefined),
    undefined.

%% runInContext(contextifiedObject or null, timeout, ...): the completion value
%% of the script in the realm of the context, or in this realm for null.
%% shortcut: the sandbox's properties are copied to the realm's global object
%% before the run and the new globals back after it, where V8 intercepts each
%% access; a function that the script leaves behind reads the realm's global
%% object later. Intercept global accesses when the engine has a hook for it.
run_in_context(This, Context) ->
    Module = case bouy_heap:is_object(This) andalso bouy_heap:private_find(This, ?SCRIPT) of
        {ok, M} -> M;
        _ -> bouy_ref:type_error(<<"Illegal invocation">>)
    end,
    case Context of
        null ->
            Module:'$body'();
        _ ->
            Realm = bouy_heap:get(Context, private()),
            Global = erlang:get({?MODULE, global, Realm}),
            Sandboxed = Global =/= Context,
            Sandboxed andalso copy(Context, Global, own_keys(Context)),
            Run = bouy_ref_realm:realm_fun(Realm, fun(_, _) -> Module:'$body'() end),
            try Run(undefined, undefined)
            after
                Sandboxed andalso copy(Global, Context, own_keys(Global) -- erlang:get({?MODULE, builtins, Realm}))
            end
    end.

copy(From, To, Keys) ->
    [bouy_heap:set(To, K, bouy_heap:get(From, K)) || K <- Keys],
    true.

%% compileFunction(code, filename, lineOffset, columnOffset, cachedData,
%% produceCachedData, parsingContext, contextExtensions, params, ...):
%% { function }, the code as the body of a function of the params.
compile_function(Args) ->
    Code = bouy_node:arg(1, Args),
    Params = case bouy_node:arg(9, Args) of
        undefined -> [];
        List -> bouy_heap:array_items(List)
    end,
    Make = fun(_, _) -> bouy_ref_eval:create_function(Params ++ [Code]) end,
    Function = case bouy_node:arg(7, Args) of
        Context when Context =:= undefined; Context =:= null -> Make(undefined, undefined);
        Context -> (bouy_ref_realm:realm_fun(bouy_heap:get(Context, private()), Make))(undefined, undefined)
    end,
    bouy_node:object([{<<"function">>, Function}, {<<"sourceMapURL">>, undefined}]).
