%% internalBinding('module_wrap') (src/module_wrap.cc): the ModuleWrap class
%% of node:vm's modules and of Node's ESM loader. A source text module
%% compiles at run time with its requests left to the host
%% (buoy_ref_eval:compile_hosted_module/2), link binds them to the modules
%% that Node's lib chose, and buoy_module instantiates and evaluates the
%% graph, as V8 does for a v8::Module. A synthetic module has export names
%% and evaluation steps.
-module(buoy_binding_module_wrap).

-export([binding/0]).

-include("buoy_ref.hrl").

-define(WRAPPED, {'#', ?MODULE, <<"module">>}).
-define(SOURCE_OBJECT, {'#', ?MODULE, <<"source">>}).
-define(SOURCE_TEXT, {'#', ?MODULE, <<"text">>}).
-define(REALM, {'#', ?MODULE, <<"realm">>}).

-spec binding() -> term().
binding() ->
    F = fun buoy_node:fn/3,
    A = fun buoy_node:arg/2,
    ModuleWrap = buoy_node:constructor(<<"ModuleWrap">>, 0, fun(This, Args) -> new(This, Args) end),
    Proto = buoy_heap:get(ModuleWrap, <<"prototype">>),
    Methods = [
        {<<"link">>, 1, fun(This, Args) -> link_modules(This, A(1, Args)) end},
        {<<"getModuleRequests">>, 0, fun(This, _) -> module_requests(wrapped(This)) end},
        {<<"instantiate">>, 0, fun(This, _) -> instantiate(This) end},
        {<<"evaluateSync">>, 2, fun(This, Args) -> evaluate_sync(This, A(1, Args), A(2, Args)) end},
        {<<"evaluate">>, 2, fun(This, Args) -> evaluate(This, A(1, Args)) end},
        {<<"setExport">>, 2, fun(This, Args) ->
            ok = buoy_module:set_synthetic_export(wrapped(This), A(1, Args), A(2, Args)),
            undefined
        end},
        {<<"setModuleSourceObject">>, 1, fun(This, Args) ->
            buoy_heap:private_put(This, ?SOURCE_OBJECT, A(1, Args)),
            undefined
        end},
        {<<"getModuleSourceObject">>, 0, fun(This, _) -> source_object(This) end},
        {<<"createCachedData">>, 0, fun(This, _) -> cached_data(This) end},
        {<<"getNamespace">>, 0, fun(This, _) -> namespace(This) end},
        {<<"getStatus">>, 0, fun(This, _) -> buoy_module:status(wrapped(This)) end},
        {<<"getError">>, 0, fun(This, _) -> buoy_module:error_of(wrapped(This)) end}],
    [buoy_heap:define(Proto, Name, #{value => F(Name, Length, Fun), writable => true, enumerable => true, configurable => true})
     || {Name, Length, Fun} <- Methods],
    Statuses = lists:enumerate(0, [<<"kUninstantiated">>, <<"kInstantiating">>, <<"kInstantiated">>,
                                   <<"kEvaluating">>, <<"kEvaluated">>, <<"kErrored">>]),
    Setter = fun(Name, Key) -> {Name, F(Name, 1, fun(_, Args) -> erlang:put(Key, A(1, Args)), undefined end)} end,
    buoy_node:object(
        [{<<"ModuleWrap">>, ModuleWrap},
         Setter(<<"setImportModuleDynamicallyCallback">>, '$buoy_import_module_dynamically'),
         Setter(<<"setInitializeImportMetaObjectCallback">>, '$buoy_initialize_import_meta'),
         Setter(<<"setImportMetaResolveInitializer">>, '$buoy_import_meta_resolve'),
         {<<"createRequiredModuleFacade">>, F(<<"createRequiredModuleFacade">>, 1, fun(_, Args) ->
             buoy_module:required_facade(wrapped(A(1, Args)))
         end)},
         {<<"throwIfPromiseRejected">>, F(<<"throwIfPromiseRejected">>, 1, fun(_, Args) ->
             throw_if_rejected(A(1, Args))
         end)}]
        ++ [{Name, Value} || {Value, Name} <- Statuses]
        ++ [{<<"kEvaluationPhase">>, 2}, {<<"kSourcePhase">>, 1}]).

%% new ModuleWrap(url, context, source, lineOffset, columnOffset,
%% cachedData or hostDefinedOption), or new ModuleWrap(url, context,
%% exportNames, evaluationSteps) for a synthetic module.
new(This, Args) ->
    Url = buoy_node:arg(1, Args),
    Realm = case buoy_node:arg(2, Args) of
        undefined -> 0;
        Context -> buoy_heap:get(Context, buoy_node:private_symbol(<<"contextify_context_private_symbol">>))
    end,
    Third = buoy_node:arg(3, Args),
    M = case buoy_heap:is_object(Third) andalso buoy_heap:class_of(Third) =:= array of
        true -> new_synthetic(This, Url, Third, buoy_node:arg(4, Args));
        false -> new_source_text(This, Url, Realm, Third, buoy_node:arg(6, Args))
    end,
    buoy_heap:private_put(This, ?WRAPPED, M),
    buoy_heap:private_put(This, ?REALM, Realm),
    erlang:put({'$buoy_module_wrap', M}, This),
    buoy_heap:set(This, <<"url">>, Url),
    undefined.

new_synthetic(This, Url, Names, Steps) ->
    buoy_heap:set(This, <<"synthetic">>, true),
    M = buoy_module:new_synthetic(Url, buoy_heap:array_items(Names), fun() -> buoy_heap:call(Steps, This, []) end),
    has_async_graph_property(This, M),
    M.

%% hasAsyncGraph, which V8 knows once the module is instantiated.
has_async_graph_property(This, M) ->
    Get = buoy_node:fn(<<"hasAsyncGraph">>, 0, fun(_, _) ->
        buoy_module:status(M) >= 2 orelse
            buoy_node:throw_code('Error', <<"ERR_MODULE_NOT_INSTANTIATED">>, <<"Module is not instantiated">>),
        buoy_module:has_async_graph(M)
    end),
    buoy_heap:define(This, <<"hasAsyncGraph">>, #{get => Get, enumerable => true, configurable => true}).

new_source_text(This, Url, 0, Source, Last) ->
    case buoy_module:program_module(Url) of
        {ok, M} ->
            has_async_graph_property(This, M),
            [buoy_heap:set(This, K, V) || {K, V} <- [{<<"hasTopLevelAwait">>, buoy_module:has_top_level_await(M)},
                                                    {<<"sourceURL">>, undefined}, {<<"sourceMapURL">>, undefined},
                                                    {<<"synthetic">>, false}]],
            M;
        none ->
            compile_source_text(This, Url, 0, Source, Last)
    end;
new_source_text(This, Url, Realm, Source, Last) ->
    compile_source_text(This, Url, Realm, Source, Last).

compile_source_text(This, Url, Realm, Source, Last) ->
    Text = buoy_ref:to_string(Source),
    Option = case Last of
        {'$sym', _, _} -> Last;
        _ -> buoy_heap:symbol(Url)
    end,
    case buoy_heap:is_object(Last) of
        true ->
            buoy_node_encoding:view_bytes(Last) =:= buoy_binding_contextify:cached_data(Text) orelse
                buoy_node:throw_code('Error', <<"ERR_VM_MODULE_CACHED_DATA_REJECTED">>, <<"cachedData buffer was rejected">>);
        false ->
            ok
    end,
    M = buoy_ref_eval:compile_hosted_module(Text, Url),
    ok = buoy_module:set_host(M, Realm, {Url, Option}),
    buoy_heap:private_put(This, ?SOURCE_TEXT, Text),
    buoy_heap:define(This, buoy_node:private_symbol(<<"host_defined_option_symbol">>),
                     #{value => Option, writable => true, enumerable => false, configurable => true}),
    has_async_graph_property(This, M),
    [buoy_heap:set(This, K, V) || {K, V} <- [{<<"hasTopLevelAwait">>, buoy_module:has_top_level_await(M)},
                                            {<<"sourceURL">>, undefined},
                                            {<<"sourceMapURL">>, buoy_binding_contextify:source_map_url(Text)},
                                            {<<"synthetic">>, false}]],
    M.

wrapped(This) ->
    case buoy_heap:is_object(This) andalso buoy_heap:private_find(This, ?WRAPPED) of
        {ok, M} -> M;
        _ -> buoy_ref:type_error(<<"Illegal invocation">>)
    end.

%% getModuleRequests(): [{ specifier, attributes, phase }] in source order.
module_requests(M) ->
    buoy_heap:new_array([buoy_heap:object(null, [{<<"specifier">>, S}, {<<"attributes">>, buoy_heap:object(null, [])},
                                                 {<<"phase">>, 2}])
                         || S <- buoy_module:requests_of(M)]).

%% link(modules): the ModuleWrap of each request, in order.
link_modules(This, Modules) ->
    M = wrapped(This),
    Targets = [wrapped(W) || W <- buoy_heap:array_items(Modules)],
    length(Targets) =:= length(buoy_module:requests_of(M)) orelse
        buoy_node:throw_code('Error', <<"ERR_VM_MODULE_LINK_FAILURE">>,
                             iolist_to_binary(["Expected ", integer_to_binary(length(buoy_module:requests_of(M))),
                                               " modules, got ", integer_to_binary(length(Targets))])),
    ok = buoy_module:link_requests(M, Targets),
    undefined.

instantiate(This) ->
    M = wrapped(This),
    ok = buoy_module:instantiate(M),
    undefined.

%% evaluate(timeout, breakOnSigint): the promise of the evaluation. A
%% timeout of -1 runs without a deadline.
evaluate(This, Timeout) ->
    M = wrapped(This),
    %% A context with a microtask queue of its own runs its microtasks after
    %% the evaluation, as microtaskMode 'afterEvaluate' asks.
    {ok, Realm} = buoy_heap:private_find(This, ?REALM),
    Evaluate = fun() ->
        P = buoy_module:evaluate(M),
        (buoy_ref_realm:realm_fun(Realm, fun(_, _) -> buoy_jobs:checkpoint(Realm) end))(undefined, undefined),
        P
    end,
    case is_number(Timeout) andalso Timeout >= 0 of
        false ->
            Evaluate();
        true ->
            Ms = trunc(Timeout),
            case buoy_ref_eval:run_until(Ms, Evaluate) of
                {ok, P} -> P;
                timeout -> buoy_node:throw_code('Error', <<"ERR_SCRIPT_EXECUTION_TIMEOUT">>,
                                                iolist_to_binary(["Script execution timed out after ", integer_to_binary(Ms), "ms"]))
            end
    end.

%% evaluateSync(filename, parentFilename): the namespace of a graph that
%% evaluates at once, as require(esm) needs.
evaluate_sync(This, Filename, Parent) ->
    M = wrapped(This),
    P = buoy_module:evaluate(M),
    case buoy_heap:slots(P) of
        {fulfilled, _, _} ->
            buoy_module:namespace(M);
        {rejected, Reason, _} ->
            buoy_jobs:perform_then(P, fun(_) -> undefined end, fun(_) -> undefined end, undefined),
            erlang:error({'$throw', Reason});
        {pending, _, _, _} ->
            buoy_jobs:perform_then(P, fun(_) -> undefined end, fun(_) -> undefined end, undefined),
            Message = [<<"require() cannot be used on an ESM graph with top-level await. Use import() instead. ">>,
                       <<"To see where the top-level await comes from, use --experimental-print-required-tla.">>]
                ++ [[<<"\n  From ">>, buoy_ref_string:to_utf8(Parent), <<" ">>] || is_name(Parent)]
                ++ [[<<"\n  Requiring ">>, buoy_ref_string:to_utf8(Filename), <<" ">>] || is_name(Filename)],
            buoy_node:throw_code('Error', <<"ERR_REQUIRE_ASYNC_MODULE">>, iolist_to_binary(Message))
    end.

is_name(Value) -> ?IS_STRING(Value) andalso Value =/= <<>>.

namespace(This) ->
    M = wrapped(This),
    buoy_module:status(M) >= 2 orelse
        buoy_node:throw_code('Error', <<"ERR_MODULE_NOT_INSTANTIATED">>, <<"Module is not instantiated">>),
    buoy_module:namespace(M).

source_object(This) ->
    case buoy_heap:private_find(This, ?SOURCE_OBJECT) of
        {ok, Source} -> Source;
        _ -> buoy_heap:throw_error('SyntaxError', buoy_ref_string:concat([<<"Source phase import object is not defined for module '">>,
                                                                          buoy_heap:get(This, <<"url">>), <<"'">>]))
    end.

cached_data(This) ->
    case buoy_heap:private_find(This, ?SOURCE_TEXT) of
        {ok, Text} -> buoy_node_encoding:new_buffer(buoy_binding_contextify:cached_data(Text));
        _ -> buoy_node_encoding:new_buffer(<<>>)
    end.

%% throwIfPromiseRejected(promise): the reason of a rejected promise throws.
throw_if_rejected(P) ->
    case buoy_jobs:is_promise(P) andalso buoy_heap:slots(P) of
        {rejected, Reason, _} -> erlang:error({'$throw', Reason});
        _ -> undefined
    end.
