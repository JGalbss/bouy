%% The module loader of the reference engine: the module records of a realm,
%% linking, evaluation with top-level await (ECMA-262 16.2.1.5), namespace
%% objects, import.meta, import(), and CommonJS with require and Node's
%% interop between the two formats.
%%
%% A compiled module exports the functions that
%% crates/buoy-compiler/src/reference/linking.rs lists: '$module'/0,
%% '$namespace'/0, '$resolve'/2, '$export'/1, and by format '$body'/0 (ESM),
%% '$cjs'/0 (CommonJS), '$json'/0 (JSON), or '$wasm'/0 and '$body'/0
%% (WebAssembly, a cyclic module record as in the ESM integration of
%% WebAssembly, which Node's wasm translator follows). A realm keeps its record of
%% each module in its process dictionary, so each module has one instance per
%% realm, and a CommonJS module one entry in the realm's require.cache.
-module(buoy_module).

-include("buoy_ref.hrl").

-export([run/1, evaluate_dependencies/1]).
-export([namespace/1, foreign_export/2, builtin_export/2, builtin_namespace/1]).
-export([uninitialized/2, hoisted/1]).
-export([dynamic_import/4, meta/1, require/2]).
-export([define_namespace/3, broken/1]).
-export([deferred_namespace/1, ensure_deferred/1]).
-export([wasm_body/1, wasm_export/2, source_phase/1]).

-define(RECORD(M), {'$buoy_module', M}).
-define(NAMESPACE(M), {'$buoy_namespace', M}).
-define(FOREIGN(M), {'$buoy_foreign', M}).
-define(META(M), {'$buoy_meta', M}).
-define(ENTRY, '$buoy_entry').
-define(GRAPH, '$buoy_graph').
-define(ASYNC_ORDER, '$buoy_async_order').
-define(CACHE, '$buoy_require_cache').
-define(MAIN_MODULE, '$buoy_main_module').
-define(ACTOR, '$buoy_actor_realm').
-define(WASM_SOURCE(M), {'$buoy_wasm_source', M}).
-define(WASM_INSTANCE(M), {'$buoy_wasm_instance', M}).
-define(WASM_EXPORTS(M), {'$buoy_wasm_exports', M}).
-define(WRITABLE, 1).
-define(ENUMERABLE, 2).

%%% Entry points

%% Links and evaluates the program from its entry module. Returns the promise
%% of the evaluation when the graph awaits, else undefined. An error of a
%% graph that does not await throws, as an uncaught exception.
-spec run(module()) -> term().
run(Entry) ->
    erlang:put(?ENTRY, Entry),
    Graph = case erlang:function_exported(Entry, '$graph', 0) of
        true -> Entry:'$graph'();
        false -> []
    end,
    erlang:put(?GRAPH, maps:from_list(Graph)),
    link_graph(Entry),
    P = evaluate(Entry),
    case buoy_heap:slots(P) of
        {fulfilled, _, _} ->
            undefined;
        {rejected, Reason, _} ->
            buoy_jobs:perform_then(P, fun(_) -> undefined end, fun(_) -> undefined end, undefined),
            erlang:error({'$throw', Reason});
        {pending, _, _, _} ->
            buoy_jobs:perform_then(P, fun(_) -> undefined end, fun report_uncaught/1, undefined),
            P
    end.

%% A rejection of the evaluation of the program ends it, as an uncaught error.
-spec report_uncaught(term()) -> no_return().
report_uncaught(Error) -> buoy_ref:report_uncaught(Error).

%% In an actor realm, whose top-level code does not run: evaluates the
%% modules that Module imports, so that its class sees them initialized.
-spec evaluate_dependencies(module()) -> ok.
evaluate_dependencies(Module) ->
    erlang:put(?ACTOR, true),
    _ = code:ensure_loaded(Module),
    case erlang:function_exported(Module, '$module', 0) of
        true ->
            #{requests := Requests} = Module:'$module'(),
            lists:foreach(fun(M) -> link_graph(M), _ = evaluate(M) end, [M || M <- Requests, is_atom(M)]);
        false ->
            ok
    end.

%%% Module records

record(M) ->
    case erlang:get(?RECORD(M)) of
        undefined ->
            R = #{module => M, status => new, info => M:'$module'(), index => 0, ancestor => 0,
                  cycle_root => M, order => undefined, pending => 0, parents => [],
                  error => none, capability => undefined},
            erlang:put(?RECORD(M), R),
            R;
        R ->
            R
    end.

get(M, Key) -> maps:get(Key, record(M)).

set(M, Key, Value) -> erlang:put(?RECORD(M), (record(M))#{Key => Value}).

info(M, Key) -> maps:get(Key, get(M, info)).

kind(M) -> info(M, kind).

%% Whether M is a cyclic module record: an ES module or a WebAssembly module.
is_cyclic(M) -> lists:member(kind(M), [esm, wasm]).

%% The modules that M imports, without the phase: `{defer, R}` is an import
%% defer. An `import source` links and evaluates nothing.
requests(M) -> [unphase(R) || R <- info(M, requests), not is_source(R)].

is_source({source, _}) -> true;
is_source(_) -> false.

unphase({defer, R}) -> R;
unphase(R) -> R.

has_tla(M) -> info(M, async).

%%% Link: every module of the graph, before any module evaluates. A module
%%% whose imports did not resolve throws its error here.

link_graph(M) ->
    Marked = link_graph(M, []),
    lists:foreach(fun(L) -> set(L, status, linked) end, Marked).

link_graph(M, Marked) ->
    case get(M, status) of
        new ->
            set(M, status, linking),
            Marked1 = lists:foldl(fun(R, Acc) -> link_graph(R, Acc) end, [M | Marked], requests(M)),
            Sources = [R || {source, R} <- info(M, requests), kind(R) =/= wasm],
            Error0 = case {info(M, error), Sources} of
                {none, [R | _]} -> {<<"SyntaxError">>, undefined, no_source_message(R)};
                {E0, _} -> E0
            end,
            case Error0 of
                none ->
                    Marked1;
                Error ->
                    lists:foreach(fun(L) -> set(L, status, new) end, Marked1),
                    erlang:error({'$throw', link_error(Error)})
            end;
        _ ->
            Marked
    end.

%% Loading a module that does not compile throws its error.
-spec broken(module()) -> no_return().
broken(M) ->
    erlang:error({'$throw', link_error(info(M, error))}).

link_error({Kind, Code, Message}) ->
    Name = binary_to_atom(Kind),
    E = buoy_heap:error_object(Name, Message, buoy_ref_string:concat([Kind, <<": ">>, Message])),
    case Code of
        undefined -> ok;
        _ -> buoy_heap:define(E, <<"code">>, #{value => Code, writable => true, enumerable => true, configurable => true})
    end,
    E.

%%% Evaluate (16.2.1.5.3.1): the promise of the evaluation of M's graph.

evaluate(M0) ->
    M = case get(M0, status) of
        S when S =:= evaluating_async; S =:= evaluated -> get(M0, cycle_root);
        _ -> M0
    end,
    case get(M, capability) of
        {P, _, _} ->
            P;
        undefined ->
            {P, Resolve, Reject} = Capability = buoy_jobs:capability(),
            %% require(esm) can evaluate a graph while another one evaluates.
            Outer = get_stack(),
            put_stack([]),
            try inner_evaluate(M, 0) of
                _ ->
                    case get(M, order) of
                        undefined -> Resolve(undefined);
                        done -> Resolve(undefined);
                        _ -> ok
                    end
            catch
                error:Reason:Stack ->
                    Error = buoy_ref:caught(Reason, Stack),
                    lists:foreach(fun(S) -> set(S, status, evaluated), set(S, error, {error, Error}) end, get_stack()),
                    Reject(Error)
            end,
            put_stack(Outer),
            set(M, capability, Capability),
            P
    end.

get_stack() -> case erlang:get('$buoy_module_stack') of undefined -> []; S -> S end.
put_stack(S) -> erlang:put('$buoy_module_stack', S).

%% InnerModuleEvaluation
inner_evaluate(M, Index) ->
    case get(M, status) of
        S when S =:= evaluating_async; S =:= evaluated ->
            case get(M, error) of
                none -> Index;
                {error, E} -> erlang:error({'$throw', E})
            end;
        evaluating ->
            Index;
        _ ->
            case is_cyclic(M) of
                true -> inner_evaluate_esm(M, Index);
                false -> evaluate_foreign(M), Index
            end
    end.

%% A CommonJS or JSON module runs at once, as the synthetic module that Node
%% makes of it. A failure leaves it unevaluated, so a later import runs it again.
evaluate_foreign(M) ->
    set(M, status, evaluating),
    try load_foreign(M) of
        _ -> set(M, status, evaluated)
    catch
        Class:Reason:Stack ->
            set(M, status, linked),
            erlang:raise(Class, Reason, Stack)
    end.

inner_evaluate_esm(M, Index) ->
    set(M, status, evaluating),
    set(M, index, Index),
    set(M, ancestor, Index),
    set(M, pending, 0),
    put_stack([M | get_stack()]),
    Index1 = lists:foldl(fun(R, I) -> required(M, R, I) end, Index + 1, evaluation_requests(M)),
    case get(M, pending) > 0 orelse has_tla(M) of
        true ->
            set(M, order, next_order()),
            case get(M, pending) of
                0 -> execute_async(M);
                _ -> ok
            end;
        false ->
            execute(M)
    end,
    case get(M, ancestor) =:= get(M, index) of
        true -> pop_cycle(M);
        false -> ok
    end,
    Index1.

%% The modules that evaluate before M: each eager import, and for an import defer
%% only the modules with top-level await that it reaches.
evaluation_requests(M) ->
    lists:foldl(fun({defer, R}, Acc) -> add_new(gather_async(R, []), Acc);
                   ({source, _}, Acc) -> Acc;
                   (R, Acc) -> add_new([R], Acc)
                end, [], info(M, requests)).

add_new(Items, Acc) -> Acc ++ [I || I <- Items, not lists:member(I, Acc)].

%% GatherAsynchronousTransitiveDependencies
gather_async(M, Seen) ->
    {Found, _} = gather_async(M, [], Seen),
    Found.

gather_async(M, Found, Seen) ->
    case lists:member(M, Seen) of
        true ->
            {Found, Seen};
        false ->
            Seen1 = [M | Seen],
            case is_cyclic(M) andalso get(M, status) of
                S when S =:= evaluating; S =:= evaluated; S =:= evaluating_async; S =:= false ->
                    {Found, Seen1};
                _ ->
                    case has_tla(M) of
                        true ->
                            {add_new([M], Found), Seen1};
                        false ->
                            lists:foldl(fun(R, {F, Sn}) -> gather_async(R, F, Sn) end,
                                        {Found, Seen1}, requests(M))
                    end
            end
    end.

required(M, R, Index) ->
    Index1 = inner_evaluate(R, Index),
    case is_cyclic(R) of
        true ->
            Required = case get(R, status) of
                evaluating ->
                    set(M, ancestor, min(get(M, ancestor), get(R, ancestor))),
                    R;
                _ ->
                    Root = get(R, cycle_root),
                    case get(Root, error) of
                        {error, E} -> erlang:error({'$throw', E});
                        none -> Root
                    end
            end,
            case get(Required, order) of
                Order when is_integer(Order) ->
                    set(M, pending, get(M, pending) + 1),
                    set(Required, parents, get(Required, parents) ++ [M]);
                _ ->
                    ok
            end;
        false ->
            ok
    end,
    Index1.

pop_cycle(M) ->
    [Top | Rest] = get_stack(),
    put_stack(Rest),
    case get(Top, order) of
        undefined -> set(Top, status, evaluated);
        _ -> set(Top, status, evaluating_async)
    end,
    set(Top, cycle_root, M),
    case Top of
        M -> ok;
        _ -> pop_cycle(M)
    end.

next_order() ->
    N = case erlang:get(?ASYNC_ORDER) of undefined -> 1; C -> C + 1 end,
    erlang:put(?ASYNC_ORDER, N),
    N.

%% ExecuteModule of a module without top-level await.
execute(M) ->
    _ = M:'$body'(),
    ok.

%% ExecuteAsyncModule
execute_async(M) ->
    P = try M:'$body'()
        catch
            error:Reason:Stack -> buoy_jobs:rejected(buoy_ref:caught(Reason, Stack))
        end,
    buoy_jobs:perform_then(P, fun(_) -> async_fulfilled(M), undefined end,
                           fun(E) -> async_rejected(M, E), undefined end, undefined).

%% GatherAvailableAncestors
gather(M, List) ->
    lists:foldl(
        fun(Parent, Acc) ->
                case lists:member(Parent, Acc) orelse get(get(Parent, cycle_root), error) =/= none of
                    true ->
                        Acc;
                    false ->
                        Pending = get(Parent, pending) - 1,
                        set(Parent, pending, Pending),
                        case Pending of
                            0 ->
                                Acc1 = Acc ++ [Parent],
                                case has_tla(Parent) of
                                    true -> Acc1;
                                    false -> gather(Parent, Acc1)
                                end;
                            _ ->
                                Acc
                        end
                end
        end, List, get(M, parents)).

%% AsyncModuleExecutionFulfilled
async_fulfilled(M) ->
    case get(M, status) of
        evaluated ->
            ok;
        _ ->
            set(M, order, done),
            set(M, status, evaluated),
            settle(M, ok),
            Ready = lists:sort(fun(A, B) -> get(A, order) =< get(B, order) end, gather(M, [])),
            lists:foreach(fun run_ready/1, Ready)
    end.

run_ready(M) ->
    case get(M, status) of
        evaluated ->
            ok;
        _ ->
            case has_tla(M) of
                true ->
                    execute_async(M);
                false ->
                    try execute(M) of
                        ok ->
                            set(M, order, done),
                            set(M, status, evaluated),
                            settle(M, ok)
                    catch
                        error:Reason:Stack -> async_rejected(M, buoy_ref:caught(Reason, Stack))
                    end
            end
    end.

%% AsyncModuleExecutionRejected
async_rejected(M, Error) ->
    case get(M, status) of
        evaluated ->
            ok;
        _ ->
            set(M, error, {error, Error}),
            set(M, status, evaluated),
            set(M, order, done),
            settle(M, {error, Error}),
            lists:foreach(fun(Parent) -> async_rejected(Parent, Error) end, get(M, parents))
    end.

settle(M, Outcome) ->
    case {get(M, capability), Outcome} of
        {undefined, _} -> ok;
        {{_, Resolve, _}, ok} -> Resolve(undefined);
        {{_, _, Reject}, {error, E}} -> Reject(E)
    end.

%%% Namespaces

%% The namespace object of M in this realm: a null-prototype object whose
%% properties read the live bindings, in code unit order, then
%% Symbol.toStringTag.
-spec namespace(module()) -> term().
namespace(M) ->
    case erlang:get(?NAMESPACE(M)) of
        undefined ->
            NS = make_namespace(M:'$namespace'()),
            erlang:put(?NAMESPACE(M), NS),
            NS;
        NS ->
            NS
    end.

make_namespace(Named) ->
    Tag = ?SYM(toStringTag),
    %% An export named "0" is the property key 0, as ToPropertyKey makes it.
    Entries = [{buoy_heap:to_key(Name), Read} || {Name, Read} <- Named],
    Props = maps:from_list([{Name, {'$live', Read}} || {Name, Read} <- Entries] ++ [{Tag, <<"Module">>}]),
    Keys = lists:reverse([Name || {Name, _} <- Entries, not is_integer(Name)] ++ [Tag]),
    Attrs = maps:from_list([{Name, ?WRITABLE bor ?ENUMERABLE} || {Name, _} <- Entries] ++ [{Tag, 0}, {'$noext', true}]),
    Id = buoy_heap:new_exotic(namespace, null, none),
    {'$o', Raw} = Id,
    erlang:put(Raw, {namespace, null, Props, Keys, Attrs, none}),
    Id.

%% The deferred namespace of M (`import defer * as ns`): the exports of M, which
%% evaluates when code first reads a string key of it (buoy_heap calls
%% ensure_deferred/1), and the tag "Deferred Module".
-spec deferred_namespace(module()) -> term().
deferred_namespace(M) ->
    Key = {'$buoy_deferred_namespace', M},
    case erlang:get(Key) of
        undefined ->
            {'$o', Id} = NS = make_namespace(M:'$namespace'()),
            {namespace, P, Props, Keys, Attrs, _} = erlang:get(Id),
            Tag = ?SYM(toStringTag),
            erlang:put(Id, {deferred_namespace, P, Props#{Tag => <<"Deferred Module">>}, Keys, Attrs, M}),
            erlang:put(Key, NS),
            NS;
        NS ->
            NS
    end.

%% EnsureDeferredNamespaceEvaluation: evaluates M now, or throws a TypeError when
%% M cannot evaluate synchronously, because it or a module it imports awaits or
%% is evaluating.
-spec ensure_deferred(module()) -> ok.
ensure_deferred(M) ->
    case get(M, status) of
        evaluated ->
            case get(M, error) of
                none -> ok;
                {error, E} -> erlang:error({'$throw', E})
            end;
        _ ->
            ready_for_sync(M, []) orelse
                buoy_ref:type_error(<<"Cannot evaluate a deferred module that is evaluating or awaits">>),
            P = evaluate(M),
            case buoy_heap:slots(P) of
                {rejected, Reason, _} ->
                    buoy_jobs:perform_then(P, fun(_) -> undefined end, fun(_) -> undefined end, undefined),
                    erlang:error({'$throw', Reason});
                _ ->
                    ok
            end
    end.

%% ReadyForSyncExecution
ready_for_sync(M, Seen) ->
    case lists:member(M, Seen) orelse kind(M) =/= esm of
        true ->
            true;
        false ->
            case get(M, status) of
                evaluated -> true;
                evaluating -> false;
                evaluating_async -> false;
                _ -> not has_tla(M) andalso lists:all(fun(R) -> ready_for_sync(R, [M | Seen]) end, requests(M))
            end
    end.

%% [[DefineOwnProperty]] of a namespace: it succeeds only when it changes nothing.
-spec define_namespace(term(), term(), map()) -> boolean().
define_namespace(NS, K, Descriptor) ->
    case buoy_heap:get_own(NS, K) of
        none -> false;
        {data, V, Bits} ->
            maps:get(configurable, Descriptor, false) =/= true
                andalso maps:get(enumerable, Descriptor, Bits band ?ENUMERABLE =/= 0) =:= (Bits band ?ENUMERABLE =/= 0)
                andalso not is_map_key(get, Descriptor) andalso not is_map_key(set, Descriptor)
                andalso maps:get(writable, Descriptor, Bits band ?WRITABLE =/= 0) =:= (Bits band ?WRITABLE =/= 0)
                andalso (not is_map_key(value, Descriptor) orelse buoy_ref_object:same_value(maps:get(value, Descriptor), V))
    end.

%% The value that the snapshot of a CommonJS or JSON module holds for Key.
-spec foreign_export(module(), term()) -> term().
foreign_export(M, Key) ->
    case erlang:get(?FOREIGN(M)) of
        #{Key := V} -> V;
        _ -> uninitialized(Key, fun() -> load_foreign(M), foreign_export(M, Key) end)
    end.

%%% Built-in modules of Node

%% An import of a built-in module reads its ES module facade, as Node's
%% BuiltinModule.getESMFacade makes it: `default` is module.exports, and each
%% other export is the property of module.exports with that name.
-spec builtin_export(term(), term()) -> term().
builtin_export(Name, <<"default">>) ->
    builtin_exports(Name);
builtin_export(Name, Export) ->
    buoy_heap:get(builtin_exports(Name), Export).

%% The namespace of the facade: the keys of module.exports when the first
%% import reads it, and `default`.
-spec builtin_namespace(term()) -> term().
builtin_namespace(Name) ->
    Key = {'$buoy_builtin_namespace', Name},
    case erlang:get(Key) of
        undefined ->
            Exports = builtin_exports(Name),
            Names = lists:usort(fun(A, B) -> buoy_ref_string:compare(A, B) =/= gt end,
                                [<<"default">> | [K || K <- buoy_heap:enumerable_keys(Exports), ?IS_STRING(K)]]),
            NS = make_namespace([{K, fun() -> builtin_export(Name, K) end} || K <- Names]),
            erlang:put(Key, NS),
            NS;
        NS ->
            NS
    end.

%% module.exports of a built-in module, which require() returns.
builtin_exports(Name) ->
    case builtin(Name) of
        {ok, Value} -> Value;
        error -> no_builtin(Name)
    end.

%% `module` until Node's lib/module.js runs here; every other id is a module
%% of Node's lib that buoy_node runs.
builtin(<<"module">>) -> {ok, module_builtin()};
builtin(<<"node:", Name/binary>>) -> builtin(Name);
builtin(Name) when is_binary(Name) -> buoy_node:require(Name);
builtin(_) -> error.

-spec no_builtin(term()) -> no_return().
no_builtin(<<"node:", Id/binary>>) ->
    no_builtin(Id);
no_builtin(Name) when is_binary(Name) ->
    %% A module of Node that a flag turned off, such as sqlite under --no-experimental-sqlite.
    case buoy_node:is_public(Name) of
        true ->
            throw_coded('Error', <<"ERR_UNKNOWN_BUILTIN_MODULE">>,
                        buoy_ref_string:concat([<<"No such built-in module: node:">>, Name]));
        false ->
            missing_builtin(Name)
    end;
no_builtin(Name) ->
    missing_builtin(Name).

-spec missing_builtin(term()) -> no_return().
missing_builtin(Name) ->
    throw_coded('Error', <<"ERR_BUOY_BUILTIN">>,
                buoy_ref_string:concat([<<"Buoy does not provide the Node built-in module 'node:">>, Name, <<"' yet">>])).

module_builtin() ->
    Key = '$buoy_builtin_module',
    case erlang:get(Key) of
        undefined ->
            CreateRequire = buoy_heap:function(fun(_This, Args) -> create_require(buoy_ref_realm:arg(1, Args)) end,
                                               <<"createRequire">>, 1, #{}),
            Builtins = buoy_heap:new_array([B || B <- builtin_names()]),
            IsBuiltin = buoy_heap:function(fun(_This, Args) -> is_builtin(buoy_ref_realm:arg(1, Args)) end,
                                           <<"isBuiltin">>, 1, #{}),
            O = buoy_heap:object(?OBJECT_PROTO, [{<<"createRequire">>, CreateRequire}, {<<"builtinModules">>, Builtins},
                                                 {<<"isBuiltin">>, IsBuiltin}]),
            erlang:put(Key, O),
            O;
        O ->
            O
    end.

%% require('module').builtinModules of Node 25.9.0.
builtin_names() ->
    [<<"_http_agent">>, <<"_http_client">>, <<"_http_common">>, <<"_http_incoming">>, <<"_http_outgoing">>,
     <<"_http_server">>, <<"_stream_duplex">>, <<"_stream_passthrough">>, <<"_stream_readable">>,
     <<"_stream_transform">>, <<"_stream_wrap">>, <<"_stream_writable">>, <<"_tls_common">>, <<"_tls_wrap">>,
     <<"assert">>, <<"assert/strict">>, <<"async_hooks">>, <<"buffer">>, <<"child_process">>, <<"cluster">>,
     <<"console">>, <<"constants">>, <<"crypto">>, <<"dgram">>, <<"diagnostics_channel">>, <<"dns">>,
     <<"dns/promises">>, <<"domain">>, <<"events">>, <<"fs">>, <<"fs/promises">>, <<"http">>, <<"http2">>,
     <<"https">>, <<"inspector">>, <<"inspector/promises">>, <<"module">>, <<"net">>, <<"os">>, <<"path">>,
     <<"path/posix">>, <<"path/win32">>, <<"perf_hooks">>, <<"process">>, <<"punycode">>, <<"querystring">>,
     <<"readline">>, <<"readline/promises">>, <<"repl">>, <<"stream">>, <<"stream/consumers">>,
     <<"stream/promises">>, <<"stream/web">>, <<"string_decoder">>, <<"sys">>, <<"timers">>,
     <<"timers/promises">>, <<"tls">>, <<"trace_events">>, <<"tty">>, <<"url">>, <<"util">>, <<"util/types">>,
     <<"v8">>, <<"vm">>, <<"wasi">>, <<"worker_threads">>, <<"zlib">>, <<"node:sea">>, <<"node:sqlite">>,
     <<"node:test">>, <<"node:test/reporters">>].

is_builtin(<<"node:", Rest/binary>> = Name) ->
    lists:member(Rest, builtin_names()) orelse lists:member(Name, builtin_names());
is_builtin(Name) when is_binary(Name) ->
    lists:member(Name, builtin_names());
is_builtin(_) -> false.

%%% Bindings before initialization

%% A `let`, `const`, `class`, or import read before its declaration ran: a
%% ReferenceError. An actor realm, whose top-level code does not run, runs
%% Lazy instead.
-spec uninitialized(term(), fun(() -> term())) -> term().
uninitialized(Name, Lazy) ->
    case erlang:get(?ACTOR) of
        true -> Lazy();
        _ -> buoy_heap:throw_error('ReferenceError', buoy_ref_string:concat([<<"Cannot access '">>, Name, <<"' before initialization">>]))
    end.

%% A `var` read before its declaration ran: undefined.
-spec hoisted(fun(() -> term())) -> term().
hoisted(Lazy) ->
    case erlang:get(?ACTOR) of
        true -> Lazy();
        _ -> undefined
    end.

%%% import()

%% import(Specifier, Options) from module From: a promise of the namespace.
%% The module loads in a later microtask, as Node loads it asynchronously.
%% A source phase import fails: a JavaScript module has no source object.
-spec dynamic_import(module(), term(), term(), evaluation | source | defer) -> term().
dynamic_import(From, Specifier, Options, Phase) ->
    {P, Resolve, Reject} = buoy_jobs:capability(),
    try
        Text = buoy_ref:to_string(Specifier),
        check_options(Options),
        Target = case target(From, Text, import) of
            {_Path, Module} when is_atom(Module), Module =/= none -> Module;
            {builtin, Name} -> {builtin, Name};
            {error, Code, Message} -> throw_coded('Error', Code, Message);
            _ -> throw_coded('Error', <<"ERR_MODULE_NOT_FOUND">>,
                             buoy_ref_string:concat([<<"Cannot find module '">>, Text, <<"' imported from ">>, info(From, path)]))
        end,
        Loaded = case {Phase, Target} of
            {defer, {builtin, _}} -> Target;
            {defer, _} -> {defer, Target};
            {source, {builtin, Builtin}} ->
                buoy_heap:throw_error('SyntaxError', buoy_ref_string:concat([<<"Source phase import object is not defined for module 'node:">>, Builtin, <<"'">>]));
            {source, _} -> {source, Target};
            _ -> Target
        end,
        buoy_jobs:enqueue(fun() -> load_dynamic(Loaded, Resolve, Reject) end)
    catch
        error:Reason:Stack -> Reject(buoy_ref:caught(Reason, Stack))
    end,
    P.

%% ContinueDynamicImport
load_dynamic(Target, Resolve, Reject) ->
    try
        case Target of
            {builtin, B} ->
                Resolve(builtin_namespace(B));
            {source, M} ->
                Resolve(source_phase(M));
            {defer, M} ->
                link_graph(M),
                Evaluation = buoy_jobs:all([evaluate(D) || D <- gather_async(M, [])]),
                buoy_jobs:perform_then(Evaluation, fun(_) -> Resolve(deferred_namespace(M)) end, Reject, undefined);
            M ->
                link_graph(M),
                Evaluation = evaluate(M),
                buoy_jobs:perform_then(Evaluation, fun(_) -> Resolve(namespace(M)) end, Reject, undefined)
        end
    catch
        error:Reason:Stack -> Reject(buoy_ref:caught(Reason, Stack))
    end.

check_options(undefined) ->
    ok;
check_options(Options) ->
    buoy_heap:is_object(Options) orelse buoy_ref:type_error(<<"The second argument of import() must be an object">>),
    case buoy_heap:get(Options, <<"with">>) of
        undefined ->
            ok;
        With ->
            buoy_heap:is_object(With) orelse buoy_ref:type_error(<<"The 'with' option of import() must be an object">>),
            lists:foreach(fun(K) ->
                                  ?IS_STRING(buoy_heap:get(With, K)) orelse
                                      buoy_ref:type_error(<<"Import attribute values must be strings">>)
                          end, buoy_heap:enumerable_keys(With))
    end.

%% What Specifier of From names: the compiled table of the module, then the
%% files of the program for a path that the code computed.
target(From, Specifier, Mode) ->
    case From:'$resolve'(Specifier, Mode) of
        none -> runtime_target(From, Specifier, Mode);
        Found -> Found
    end.

runtime_target(From, Specifier, Mode) ->
    Graph = case erlang:get(?GRAPH) of undefined -> #{}; G -> G end,
    Path = buoy_ref_string:to_utf8(Specifier),
    Base = filename:dirname(buoy_ref_string:to_utf8(info(From, path))),
    case relative(Path) of
        true ->
            Full = normalize(filename:join(Base, Path)),
            Candidates = case Mode of
                import -> [Full];
                require -> [Full, <<Full/binary, ".js">>, <<Full/binary, ".json">>, <<Full/binary, "/index.js">>, <<Full/binary, "/index.json">>]
            end,
            case [{C, maps:get(buoy_ref_string:from_utf8(C), Graph)} || C <- Candidates, is_map_key(buoy_ref_string:from_utf8(C), Graph)] of
                [{C, Module} | _] -> {buoy_ref_string:from_utf8(C), Module};
                [] -> load_at_run_time(From, Path, Mode)
            end;
        false ->
            case is_builtin(Specifier) of
                true -> {builtin, case Specifier of <<"node:", R/binary>> -> R; _ -> Specifier end};
                false -> load_at_run_time(From, Path, Mode)
            end
    end.

%% A specifier that the static graph did not reach, such as
%% require(path.join(dir, name)): the compiler of the VM resolves it as Node
%% does and compiles the target's program, whose modules join the graph.
load_at_run_time(From, Specifier, Mode) ->
    case os:getenv("BUOY_COMPILER") =/= false andalso erlang:get(?ENTRY) of
        Entry when is_atom(Entry), Entry =/= undefined ->
            Main = buoy_ref_string:to_utf8(info(Entry, path)),
            Importer = buoy_ref_string:to_utf8(info(From, path)),
            case buoy_ref_eval:load_module(Main, Importer, Specifier, Mode) of
                {builtin, Name} ->
                    {builtin, Name};
                {program, Path, Module, Added} ->
                    Graph = case erlang:get(?GRAPH) of undefined -> #{}; G -> G end,
                    erlang:put(?GRAPH, maps:merge(maps:from_list(Added), Graph)),
                    {buoy_ref_string:from_utf8(Path), Module};
                {error, Code, Message} ->
                    {error, Code, buoy_ref_string:from_utf8(Message)}
            end;
        _ ->
            none
    end.

relative(<<"./", _/binary>>) -> true;
relative(<<"../", _/binary>>) -> true;
relative(<<"/", _/binary>>) -> true;
relative(_) -> false.

normalize(Path) ->
    Parts = lists:foldl(fun(<<"..">>, [_ | Acc]) -> Acc;
                           (<<"..">>, []) -> [];
                           (<<".">>, Acc) -> Acc;
                           (<<>>, Acc) -> Acc;
                           (Part, Acc) -> [Part | Acc]
                        end, [], binary:split(Path, <<"/">>, [global])),
    iolist_to_binary([[<<"/">>, P] || P <- lists:reverse(Parts)]).

%%% WebAssembly modules

%% The source object of M: its WebAssembly.Module, one per realm, so that every
%% `import source` of M and its instance share it. A JavaScript module has none.
-spec source_phase(module()) -> term().
source_phase(M) ->
    case erlang:get(?WASM_SOURCE(M)) of
        undefined ->
            kind(M) =:= wasm orelse
                buoy_heap:throw_error('SyntaxError', no_source_message(M)),
            WebAssembly = buoy_ref_realm:global(<<"WebAssembly">>),
            Constructor = buoy_heap:get(WebAssembly, <<"Module">>),
            Bytes = M:'$wasm'(),
            Buffer = buoy_ref_buffer:allocate(byte_size(Bytes)),
            buoy_ref_buffer:write(Buffer, 0, Bytes),
            %% The options of Node's wasm translator.
            Options = buoy_heap:object(?OBJECT_PROTO, [
                {<<"builtins">>, buoy_heap:new_array([<<"js-string">>])},
                {<<"importedStringConstants">>, <<"wasm:js/string-constants">>}]),
            Module = try buoy_heap:construct(Constructor, [Buffer, Options], Constructor)
                     catch error:{'$throw', E} -> erlang:error({'$throw', with_path(E, M)})
                     end,
            erlang:put(?WASM_SOURCE(M), Module),
            Module;
        Module ->
            Module
    end.

no_source_message(M) ->
    buoy_ref_string:concat([<<"Source phase import object is not defined for module '">>, file_url(info(M, path)), <<"'">>]).

%% errPath(url) + ': ' + the message, as the translator prefixes a CompileError.
with_path(E, M) ->
    case buoy_heap:is_object(E) of
        true ->
            Message = buoy_ref:to_string(buoy_heap:get(E, <<"message">>)),
            Prefixed = buoy_ref_string:concat([info(M, path), <<": ">>, Message]),
            buoy_heap:set(E, <<"message">>, Prefixed),
            %% V8 formats the stack when it is first read, so its header shows the new message.
            case buoy_heap:get(E, <<"stack">>) of
                Stack when ?IS_STRING(Stack), Message =/= <<>> ->
                    [Old, New, Text] = [buoy_ref_string:to_utf8(S) || S <- [Message, Prefixed, Stack]],
                    buoy_heap:set(E, <<"stack">>, buoy_ref_string:from_utf8(binary:replace(Text, Old, New)));
                _ ->
                    ok
            end,
            E;
        false ->
            E
    end.

%% Node's wasm translator: the import and export names that the ESM
%% integration reserves throw a LinkError, the imports of the instance are the
%% namespaces of the modules that they name, with the globals of a WebAssembly
%% instance unwrapped, and each export keeps the value of its global.
-spec wasm_body(module()) -> undefined.
wasm_body(M) ->
    Module = source_phase(M),
    WebAssembly = buoy_ref_realm:global(<<"WebAssembly">>),
    Constructor = buoy_heap:get(WebAssembly, <<"Module">>),
    Url = file_url(info(M, path)),
    Describe = fun(Fn) ->
        [{buoy_heap:get(D, <<"module">>), buoy_heap:get(D, <<"name">>), buoy_heap:get(D, <<"kind">>)}
         || D <- buoy_heap:array_items(buoy_heap:call(buoy_heap:get(Constructor, Fn), Constructor, [Module]))]
    end,
    Imports = [{Mod, Name, Kind} || {Mod, Name, Kind} <- Describe(<<"imports">>), not is_string_builtin(Mod)],
    LinkError = fun(Parts) ->
        Class = buoy_heap:get(WebAssembly, <<"LinkError">>),
        erlang:error({'$throw', buoy_heap:construct(Class, [buoy_ref_string:concat(Parts)], Class)})
    end,
    lists:foreach(fun({Mod, Name, _}) ->
        starts_with(Mod, <<"wasm-js:">>) andalso
            LinkError([<<"Invalid Wasm import \"">>, Mod, <<"\" in ">>, Url]),
        (starts_with(Name, <<"wasm:">>) orelse starts_with(Name, <<"wasm-js:">>)) andalso
            LinkError([<<"Invalid Wasm import name \"">>, Mod, <<"\" in ">>, Url])
    end, Imports),
    Exports = [{Name, Kind} || {_, Name, Kind} <- [{undefined, buoy_heap:get(D, <<"name">>), buoy_heap:get(D, <<"kind">>)}
                                                    || D <- buoy_heap:array_items(buoy_heap:call(buoy_heap:get(Constructor, <<"exports">>), Constructor, [Module]))]],
    lists:foreach(fun({Name, _}) ->
        (starts_with(Name, <<"wasm:">>) orelse starts_with(Name, <<"wasm-js:">>)) andalso
            LinkError([<<"Invalid Wasm export name \"">>, Name, <<"\" in ">>, Url])
    end, Exports),
    experimental_warning(<<"Importing WebAssembly module instances">>),
    Modules = lists:usort([Mod || {Mod, _, _} <- Imports]),
    ImportObject = buoy_heap:object(?OBJECT_PROTO,
                                    [{Mod, import_namespace(M, Mod, [Name || {Mod1, Name, <<"global">>} <- Imports, Mod1 =:= Mod])}
                                     || Mod <- Modules]),
    Instance = buoy_heap:construct(buoy_heap:get(WebAssembly, <<"Instance">>), [Module, ImportObject],
                                   buoy_heap:get(WebAssembly, <<"Instance">>)),
    InstanceExports = buoy_heap:get(Instance, <<"exports">>),
    erlang:put(?WASM_INSTANCE(M), InstanceExports),
    Snapshot = lists:foldl(
        fun({Name, Kind}, Acc) ->
            Value = buoy_heap:get(InstanceExports, Name),
            case Kind of
                <<"global">> ->
                    %% A v128 global has no JavaScript value: its binding stays undefined.
                    try Acc#{Name => buoy_heap:get(Value, <<"value">>)}
                    catch error:{'$throw', _} -> Acc
                    end;
                _ ->
                    Acc#{Name => Value}
            end
        end, #{}, Exports),
    erlang:put(?WASM_EXPORTS(M), Snapshot),
    undefined.

%% The value of an export of a WebAssembly module, or the error of a binding
%% that its instance did not initialize yet.
-spec wasm_export(module(), term()) -> term().
wasm_export(M, Key) ->
    case erlang:get(?WASM_EXPORTS(M)) of
        undefined -> uninitialized(Key, fun() -> undefined end);
        Snapshot -> maps:get(Key, Snapshot, undefined)
    end.

%% The namespace that an import of module Mod of the WebAssembly module M
%% reads. The globals that a WebAssembly instance exports stay
%% WebAssembly.Global objects, as the ESM integration links them.
import_namespace(M, Mod, Globals) ->
    case target(M, Mod, import) of
        {builtin, Name} ->
            builtin_namespace(Name);
        {_Path, Target} when is_atom(Target), Target =/= none ->
            Namespace = namespace(Target),
            case kind(Target) =:= wasm andalso erlang:get(?WASM_INSTANCE(Target)) of
                Exports when Exports =/= false, Exports =/= undefined ->
                    Wrapped = buoy_heap:object(null, [{K, buoy_heap:get(Namespace, K)}
                                                      || K <- buoy_heap:enumerable_keys(Namespace), ?IS_STRING(K)]),
                    [buoy_heap:set(Wrapped, G, buoy_heap:get(Exports, G)) || G <- Globals],
                    Wrapped;
                _ ->
                    Namespace
            end;
        {error, Code, Message} ->
            throw_coded('Error', Code, Message);
        _ ->
            throw_coded('Error', <<"ERR_MODULE_NOT_FOUND">>,
                        buoy_ref_string:concat([<<"Cannot find module '">>, Mod, <<"' imported from ">>, info(M, path)]))
    end.

is_string_builtin(Mod) -> Mod =:= <<"wasm:js-string">> orelse Mod =:= <<"wasm:js/string-constants">>.

starts_with(Text, Prefix) when is_binary(Text) ->
    binary:longest_common_prefix([Text, Prefix]) =:= byte_size(Prefix);
starts_with(_, _) ->
    false.

%% emitExperimentalWarning of internal/util.
experimental_warning(Feature) ->
    buoy_node:ensure(),
    {_, Require} = buoy_node:loaders(),
    Util = buoy_heap:call(Require, undefined, [<<"internal/util">>]),
    _ = buoy_heap:call(buoy_heap:get(Util, <<"emitExperimentalWarning">>), Util, [Feature]),
    ok.

%%% import.meta

%% The import.meta object of M in this realm, as Node 25 makes it.
-spec meta(module()) -> term().
meta(M) ->
    case erlang:get(?META(M)) of
        undefined ->
            Path = info(M, path),
            Resolve = buoy_heap:function(fun(_This, Args) -> meta_resolve(M, buoy_ref_realm:arg(1, Args)) end,
                                         <<"resolve">>, 1, #{}),
            O = buoy_heap:object(null, [{<<"dirname">>, dirname(Path)}, {<<"filename">>, Path},
                                        {<<"main">>, erlang:get(?ENTRY) =:= M}, {<<"resolve">>, Resolve},
                                        {<<"url">>, file_url(Path)}]),
            erlang:put(?META(M), O),
            O;
        O ->
            O
    end.

meta_resolve(M, Specifier) ->
    Text = buoy_ref:to_string(Specifier),
    case target(M, Text, import) of
        {builtin, Name} -> buoy_ref_string:concat([<<"node:">>, Name]);
        {error, Code, Message} -> throw_coded('Error', Code, Message);
        {Path, _} -> file_url(Path);
        none -> throw_coded('Error', <<"ERR_MODULE_NOT_FOUND">>,
                            buoy_ref_string:concat([<<"Cannot find module '">>, Text, <<"' imported from ">>, info(M, path)]))
    end.

dirname(Path) -> buoy_ref_string:from_utf8(filename:dirname(buoy_ref_string:to_utf8(Path))).

%% pathToFileURL: file:// and the path, with the bytes that a URL path may not
%% hold percent-encoded.
file_url(Path) ->
    Bytes = buoy_ref_string:to_utf8(Path),
    Encoded = << <<(encode_byte(B))/binary>> || <<B>> <= Bytes >>,
    buoy_ref_string:from_utf8(<<"file://", Encoded/binary>>).

encode_byte(B) when B >= $a, B =< $z; B >= $A, B =< $Z; B >= $0, B =< $9 -> <<B>>;
encode_byte(B) ->
    case lists:member(B, "-._~!$&'()*+,;=:@/") of
        true -> <<B>>;
        false -> iolist_to_binary(io_lib:format("%~2.16.0B", [B]))
    end.

%%% CommonJS

%% Runs a CommonJS or JSON module through require.cache, and takes the
%% snapshot of its exports that an import reads.
load_foreign(M) ->
    Exports = case kind(M) of
        cjs -> buoy_heap:get(load_cjs(M), <<"exports">>);
        json -> buoy_heap:get(load_json(M), <<"exports">>)
    end,
    Snapshot = maps:from_list([{Name, snapshot_value(Name, Exports)} || {Name, _} <- M:'$namespace'()]),
    erlang:put(?FOREIGN(M), Snapshot),
    ok.

snapshot_value(<<"default">>, Exports) -> Exports;
snapshot_value(<<"module.exports">>, Exports) -> Exports;
snapshot_value(Name, Exports) ->
    case buoy_heap:is_object(Exports) of
        true -> buoy_heap:get(Exports, Name);
        false -> undefined
    end.

cache() ->
    case erlang:get(?CACHE) of
        undefined ->
            C = buoy_heap:new_object(null),
            erlang:put(?CACHE, C),
            C;
        C ->
            C
    end.

%% The Module object of a CommonJS module in this realm, loading it when
%% require.cache holds none.
load_cjs(M) ->
    Path = info(M, path),
    Cache = cache(),
    case buoy_heap:has_own(Cache, Path) of
        true ->
            buoy_heap:get(Cache, Path);
        false ->
            Exports = buoy_heap:new_object(?OBJECT_PROTO),
            Main = erlang:get(?ENTRY) =:= M,
            Module = buoy_heap:object(?OBJECT_PROTO,
                                      [{<<"id">>, case Main of true -> <<".">>; false -> Path end},
                                       {<<"path">>, dirname(Path)},
                                       {<<"exports">>, Exports},
                                       {<<"filename">>, Path},
                                       {<<"loaded">>, false},
                                       {<<"children">>, buoy_heap:new_array([])},
                                       {<<"paths">>, buoy_heap:new_array(module_paths(Path))}]),
            Main andalso erlang:put(?MAIN_MODULE, Module),
            Require = make_require(M, Module),
            buoy_heap:set(Module, <<"require">>, Require),
            buoy_heap:set(Cache, Path, Module),
            Wrapper = M:'$cjs'(),
            try buoy_heap:call(Wrapper, Exports, [Exports, Require, Module, Path, dirname(Path)]) of
                _ -> ok
            catch
                Class:Reason:Stack ->
                    buoy_heap:delete(Cache, Path),
                    erlang:raise(Class, Reason, Stack)
            end,
            buoy_heap:set(Module, <<"loaded">>, true),
            Module
    end.

%% A JSON module, as require loads it: a Module whose exports is the value.
load_json(M) ->
    Path = info(M, path),
    Cache = cache(),
    case buoy_heap:has_own(Cache, Path) of
        true ->
            buoy_heap:get(Cache, Path);
        false ->
            Value = try buoy_ref_json:parse(buoy_ref_string:from_utf8(M:'$json'()))
                    catch
                        error:{'$throw', E} ->
                            Message = buoy_heap:get(E, <<"message">>),
                            buoy_heap:throw_error('SyntaxError', buoy_ref_string:concat([Path, <<": ">>, Message]))
                    end,
            Module = buoy_heap:object(?OBJECT_PROTO, [{<<"id">>, Path}, {<<"path">>, dirname(Path)},
                                                      {<<"exports">>, Value}, {<<"filename">>, Path},
                                                      {<<"loaded">>, true}]),
            buoy_heap:set(Cache, Path, Module),
            Module
    end.

%% node_modules directories from the module's directory up to the root.
module_paths(Path) ->
    Dir = filename:dirname(buoy_ref_string:to_utf8(Path)),
    Parts = binary:split(Dir, <<"/">>, [global, trim_all]),
    Dirs = [lists:sublist(Parts, N) || N <- lists:seq(length(Parts), 0, -1)],
    [buoy_ref_string:from_utf8(iolist_to_binary([[<<"/">>, P] || P <- D] ++ [<<"/node_modules">>]))
     || D <- Dirs, lists:last([<<>> | D]) =/= <<"node_modules">>].

%% The require function of module M.
make_require(M, Module) ->
    Require = buoy_heap:function(fun(_This, Args) -> require(M, buoy_ref_realm:arg(1, Args)) end,
                                 <<"require">>, 1, #{}),
    ResolveFn = buoy_heap:function(fun(_This, Args) -> require_resolve(M, buoy_ref_realm:arg(1, Args)) end,
                                   <<"resolve">>, 2, #{}),
    Paths = buoy_heap:function(fun(_This, Args) -> resolve_paths(M, buoy_ref_realm:arg(1, Args)) end,
                               <<"paths">>, 1, #{}),
    buoy_heap:set(ResolveFn, <<"paths">>, Paths),
    buoy_heap:set(Require, <<"resolve">>, ResolveFn),
    buoy_heap:set(Require, <<"main">>, case erlang:get(?MAIN_MODULE) of undefined -> undefined; Main -> Main end),
    Extensions = buoy_heap:object(null, [{E, buoy_heap:function(fun(_, _) -> undefined end)} || E <- [<<".js">>, <<".json">>, <<".node">>]]),
    buoy_heap:set(Require, <<"extensions">>, Extensions),
    buoy_heap:set(Require, <<"cache">>, cache()),
    _ = Module,
    Require.

%% create_require(filename) of node:module: a require for a file of the program.
create_require(Filename) ->
    Text = buoy_ref:to_string(Filename),
    Path = case Text of
        <<"file://", Rest/binary>> -> buoy_ref_string:from_utf8(uri_string:percent_decode(buoy_ref_string:to_utf8(Rest)));
        _ -> Text
    end,
    Graph = case erlang:get(?GRAPH) of undefined -> #{}; G -> G end,
    case maps:find(Path, Graph) of
        {ok, M} -> make_require(M, undefined);
        error -> buoy_ref:type_error(buoy_ref_string:concat([<<"createRequire: ">>, Path, <<" is not a module of the program">>]))
    end.

%% require(Specifier) from module M.
-spec require(module(), term()) -> term().
require(M, Specifier) ->
    ?IS_STRING(Specifier) orelse throw_coded('TypeError', <<"ERR_INVALID_ARG_TYPE">>,
                                             buoy_ref_string:concat([<<"The \"id\" argument must be of type string. Received ">>, buoy_ref:describe(Specifier)])),
    Specifier =:= <<>> andalso throw_coded('TypeError', <<"ERR_INVALID_ARG_VALUE">>,
                                           <<"The argument 'id' must be a non-empty string. Received ''">>),
    %% --expose-internals lets require load the internal ids of Node's lib.
    Internal = lists:member(<<"--expose-internals">>, buoy_node_process:exec_argv())
        andalso lists:member(Specifier, buoy_node:ids()),
    case target(M, Specifier, require) of
        {builtin, Name} ->
            builtin_exports(Name);
        _ when Internal ->
            builtin_exports(Specifier);
        {error, Code, Message} ->
            throw_coded('Error', Code, Message);
        {_Path, Target} when is_atom(Target), Target =/= none ->
            require_module(Target);
        _ ->
            not_found(M, Specifier)
    end.

-spec not_found(module(), term()) -> no_return().
not_found(M, Specifier) ->
    throw_coded('Error', <<"MODULE_NOT_FOUND">>,
                buoy_ref_string:concat([<<"Cannot find module '">>, Specifier, <<"'\nRequire stack:\n- ">>, info(M, path)])).

require_module(Target) ->
    case kind(Target) of
        cjs -> buoy_heap:get(load_cjs(Target), <<"exports">>);
        json -> buoy_heap:get(load_json(Target), <<"exports">>);
        esm -> require_esm(Target)
    end.

%% require(esm): the namespace, or its 'module.exports' export. A graph that
%% awaits cannot load synchronously.
require_esm(M) ->
    link_graph(M),
    P = evaluate(M),
    case buoy_heap:slots(P) of
        {fulfilled, _, _} ->
            NS = namespace(M),
            case buoy_heap:has_own(NS, <<"module.exports">>) of
                true -> buoy_heap:get(NS, <<"module.exports">>);
                false -> required_namespace(M, NS)
            end;
        {rejected, Reason, _} ->
            buoy_jobs:perform_then(P, fun(_) -> undefined end, fun(_) -> undefined end, undefined),
            erlang:error({'$throw', Reason});
        {pending, _, _, _} ->
            buoy_jobs:perform_then(P, fun(_) -> undefined end, fun(_) -> undefined end, undefined),
            throw_coded('Error', <<"ERR_REQUIRE_ASYNC_MODULE">>,
                        <<"require() cannot be used on an ESM graph with top-level await. Use import() instead. To see where the top-level await comes from, use --experimental-print-required-tla.">>)
    end.

%% The namespace that require(esm) returns: with a default export, Node adds
%% `__esModule: true`, so that code compiled from ES modules reads the default.
required_namespace(M, NS) ->
    case buoy_heap:has_own(NS, <<"default">>) andalso not buoy_heap:has_own(NS, <<"__esModule">>) of
        false ->
            NS;
        true ->
            Key = {'$buoy_required_namespace', M},
            case erlang:get(Key) of
                undefined ->
                    Entries = lists:sort(fun({A, _}, {B, _}) -> buoy_ref_string:compare(A, B) =/= gt end,
                                         [{<<"__esModule">>, fun() -> true end} | M:'$namespace'()]),
                    Facade = make_namespace(Entries),
                    erlang:put(Key, Facade),
                    Facade;
                Facade ->
                    Facade
            end
    end.

require_resolve(M, Specifier) ->
    ?IS_STRING(Specifier) orelse throw_coded('TypeError', <<"ERR_INVALID_ARG_TYPE">>,
                                             <<"The \"request\" argument must be of type string">>),
    case target(M, Specifier, require) of
        {builtin, Name} -> Name;
        {error, Code, Message} -> throw_coded('Error', Code, Message);
        {Path, _} -> Path;
        none -> throw_coded('Error', <<"MODULE_NOT_FOUND">>,
                            buoy_ref_string:concat([<<"Cannot find module '">>, Specifier, <<"'\nRequire stack:\n- ">>, info(M, path)]))
    end.

resolve_paths(M, Specifier) ->
    case is_builtin(Specifier) orelse relative(buoy_ref_string:to_utf8(Specifier)) of
        true -> null;
        false -> buoy_heap:new_array(module_paths(info(M, path)))
    end.

-spec throw_coded(atom(), term(), term()) -> no_return().
throw_coded(Name, Code, Message) ->
    E = buoy_heap:error_object(Name, Message, buoy_ref_string:concat([atom_to_binary(Name), <<": ">>, Message])),
    buoy_heap:define(E, <<"code">>, #{value => Code, writable => true, enumerable => true, configurable => true}),
    erlang:error({'$throw', E}).
