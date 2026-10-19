%% The module loader of the reference engine: the module records of a realm,
%% linking, evaluation with top-level await (ECMA-262 16.2.1.5), namespace
%% objects, import.meta, import(), and CommonJS with require and Node's
%% interop between the two formats.
%%
%% A compiled module exports the functions that
%% crates/buoy-compiler/src/reference/linking.rs lists: '$module'/0,
%% '$namespace'/0, '$resolve'/2, '$export'/1, and by format '$body'/0 (ESM),
%% '$cjs'/0 (CommonJS), or '$json'/0 (JSON). A realm keeps its record of
%% each module in its process dictionary, so each module has one instance per
%% realm, and a CommonJS module one entry in the realm's require.cache.
-module(buoy_module).

-include("buoy_ref.hrl").

-export([run/1, run_worker/2, graph/0, evaluate_dependencies/1, throw_load/2]).
-export([namespace/1, foreign_export/2, builtin_export/2, builtin_namespace/1]).
-export([uninitialized/2, hoisted/1]).
-export([dynamic_import/4, meta/1, compiled_wrapper/2]).
-export([define_namespace/3, broken/1]).
-export([deferred_namespace/1, ensure_deferred/1, entry/0]).
-export([hosted_import/3, new_synthetic/3, set_synthetic_export/3, link_requests/2, instantiate/1, evaluate/1]).
-export([program_module/1, set_realm_host/2, status/1, error_of/1, has_async_graph/1, has_top_level_await/1, requests_of/1, module_requests_of/1, set_host/3, required_facade/1]).

-define(RECORD(M), {'$buoy_module', M}).
-define(NAMESPACE(M), {'$buoy_namespace', M}).
-define(FOREIGN(M), {'$buoy_foreign', M}).
-define(META(M), {'$buoy_meta', M}).
-define(ENTRY, '$buoy_entry').
-define(GRAPH, '$buoy_graph').
-define(ASYNC_ORDER, '$buoy_async_order').
-define(CACHE, '$buoy_require_cache').
-define(ACTOR, '$buoy_actor_realm').
-define(SYNTHETIC(M, Name), {'$buoy_synthetic', M, Name}).
%% The host of a module that module_wrap made, or of a script of node:vm:
%% {Realm, Referrer, HostDefinedOption}.
-define(HOST(M), {'$buoy_module_host', M}).
-define(WRITABLE, 1).
-define(ENUMERABLE, 2).

%%% Entry points

%% The entry module of the program of this realm process, from which a
%% ShadowRealm's importValue resolves.
-spec entry() -> module() | undefined.
entry() -> erlang:get(?ENTRY).

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

%% The program of a worker realm (buoy_binding_worker) from its entry module,
%% with Known, the graph of the realm that started the worker, so a module of
%% that program loads without the compiler. Returns the promise of the
%% evaluation, which the worker's main script watches.
-spec run_worker(module(), #{term() => module()}) -> term().
run_worker(Entry, Known) ->
    erlang:put(?ENTRY, Entry),
    Graph = case erlang:function_exported(Entry, '$graph', 0) of
        true -> Entry:'$graph'();
        false -> []
    end,
    erlang:put(?GRAPH, maps:merge(Known, maps:from_list(Graph))),
    link_graph(Entry),
    evaluate(Entry).

%% The modules of the program that this realm runs, by path.
-spec graph() -> #{term() => module()}.
graph() ->
    case erlang:get(?GRAPH) of
        undefined -> #{};
        G -> G
    end.

%% A rejection of the evaluation of the program is an uncaught error: with
%% Node loaded, its _fatalException decides, as for the rejected entry of
%% runEntryPointWithESMLoader, else the program ends.
-spec report_uncaught(term()) -> term().
report_uncaught(Error) ->
    case buoy_node:ready() of
        true -> buoy_node_loop:uncaught(Error, true);
        false -> buoy_ref:report_uncaught(Error)
    end.

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
            R = new_record(M, M:'$module'()),
            erlang:put(?RECORD(M), R),
            R;
        R ->
            R
    end.

new_record(M, Info) ->
    #{module => M, status => new, info => Info, index => 0, ancestor => 0,
      cycle_root => M, order => undefined, pending => 0, parents => [],
      error => none, capability => undefined}.

get(M, Key) -> maps:get(Key, record(M)).

set(M, Key, Value) -> erlang:put(?RECORD(M), (record(M))#{Key => Value}).

info(M, Key) -> maps:get(Key, get(M, info)).

kind(M) -> info(M, kind).

%% The modules that M imports, without the phase: `{defer, R}` is an import defer.
requests(M) -> [unphase(R) || R <- info(M, requests)].

unphase({defer, R}) -> R;
unphase(R) -> R.

has_tla(M) -> info(M, async).

%%% Link: every module of the graph, before any module evaluates. A module
%%% whose imports did not resolve throws its error here.

link_graph(M) ->
    load_graph(M, []),
    Marked = link_graph(M, []),
    lists:foreach(fun(L) -> set(L, status, linked) end, Marked).

%% LoadRequestedModules: a request that did not resolve, or a module that does
%% not parse, fails the graph before any import is linked, in the order that
%% loading meets them.
load_graph(M, Seen) ->
    case lists:member(M, Seen) orelse get(M, status) =/= new of
        true ->
            Seen;
        false ->
            case {maps:get(loaded, get(M, info), true), info(M, error)} of
                {false, {_, _, _} = Error} -> erlang:error({'$throw', link_error(Error)});
                _ -> lists:foldl(fun load_graph/2, [M | Seen], requests(M))
            end
    end.

link_graph(M, Marked) ->
    case get(M, status) of
        new ->
            set(M, status, linking),
            Marked1 = lists:foldl(fun(R, Acc) -> link_graph(R, Acc) end, [M | Marked], requests(M)),
            case link_failure(M) of
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

%% A SyntaxError of a module that does not compile has its arrow message, the
%% place, the source line, and a caret, in front of its stack, as Node's
%% DecorateErrorStack puts it there.
link_error({Kind, Code, Message, Arrow}) ->
    E = link_error({Kind, Code, Message}),
    buoy_heap:set(E, <<"stack">>, buoy_ref_string:concat([Arrow, <<"\n">>, buoy_heap:get(E, <<"stack">>)])),
    E;
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
            {P, Resolve, Reject} = Capability = buoy_jobs:quiet_capability(),
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
            case kind(M) of
                esm -> inner_evaluate_esm(M, Index);
                synthetic -> evaluate_synthetic(M), Index;
                _ -> evaluate_foreign(M), Index
            end
    end.

%% A synthetic module of module_wrap runs its evaluation steps; an error of
%% the steps is the error of the module.
evaluate_synthetic(M) ->
    set(M, status, evaluating),
    #{steps := Steps} = get(M, info),
    try Steps() of
        _ -> set(M, status, evaluated)
    catch
        error:Reason:Stack ->
            set(M, status, evaluated),
            set(M, error, {error, buoy_ref:caught(Reason, Stack)}),
            erlang:raise(error, Reason, Stack)
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
            case kind(M) =/= esm orelse get(M, status) =:= evaluating orelse scc_evaluated(M) of
                true ->
                    {Found, Seen1};
                false ->
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
    case kind(R) of
        esm ->
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
        _ ->
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
    _ = body(M),
    ok.

%% The top-level code of M, in the realm of its context of node:vm. An ES
%% module of the program that reads a variable of CommonJS gets the advice of
%% Node's ESM loader in its ReferenceError.
body(M) ->
    case erlang:get(?HOST(M)) of
        {Realm, _, _} when Realm =/= 0 ->
            (buoy_ref_realm:realm_fun(Realm, fun(_, _) -> M:'$body'() end))(undefined, undefined);
        undefined ->
            try
                M:'$body'()
            catch
                error:{'$throw', E} = Reason:Stack ->
                    explain_cjs_global(M, E),
                    erlang:raise(error, Reason, Stack)
            end;
        _ ->
            M:'$body'()
    end.

%% explainCommonJSGlobalLikeNotDefinedError of lib/internal/modules/esm/
%% module_job.js: a ReferenceError of require, module, exports, __filename,
%% or __dirname in an ES module says why, and the stack shows the new message,
%% as V8 formats the stack when it is first read.
explain_cjs_global(M, E) ->
    Names = [<<"require">>, <<"module">>, <<"exports">>, <<"__filename">>, <<"__dirname">>],
    Message = kind(M) =:= esm andalso buoy_heap:is_object(E) andalso
        buoy_heap:class_of(E) =:= error andalso text(buoy_heap:get(E, <<"message">>)),
    case is_binary(Message) andalso text(buoy_heap:get(E, <<"name">>)) =:= <<"ReferenceError">> andalso
         [N || N <- Names, Message =:= <<N/binary, " is not defined">>] of
        [Name] ->
            {Explained, Code} = case has_top_level_await(M) of
                true -> {ambiguous_message(Name), <<"ERR_AMBIGUOUS_MODULE_SYNTAX">>};
                false -> {scope_message(M, Name, Message), undefined}
            end,
            Stack = text(buoy_heap:get(E, <<"stack">>)),
            buoy_heap:set(E, <<"message">>, buoy_ref_string:from_utf8(Explained)),
            Code =:= undefined orelse buoy_heap:set(E, <<"code">>, Code),
            case is_binary(Stack) andalso binary:split(Stack, Message) of
                [Before, After] ->
                    buoy_heap:set(E, <<"stack">>, buoy_ref_string:from_utf8(<<Before/binary, Explained/binary, After/binary>>));
                _ ->
                    ok
            end;
        _ ->
            ok
    end.

%% The UTF-8 text of a JavaScript string, or none for another value.
text(V) ->
    case buoy_ref:typeof(V) of
        <<"string">> -> buoy_ref_string:to_utf8(V);
        _ -> none
    end.

ambiguous_message(Name) ->
    Advice = case Name of
        <<"require">> -> <<"replace require() with import">>;
        <<"__filename">> -> <<"use import.meta.filename instead">>;
        <<"__dirname">> -> <<"use import.meta.dirname instead">>;
        _ -> <<"use export instead of module.exports/exports">>
    end,
    <<"Cannot determine intended module format because both '", Name/binary, "' and top-level await are present. ",
      "If the code is intended to be CommonJS, wrap await in an async function. ",
      "If the code is intended to be an ES module, ", Advice/binary, ".">>.

scope_message(M, Name, Message) ->
    Scoped = case Name of
        <<"require">> -> <<Message/binary, " in ES module scope, you can use import instead">>;
        _ -> <<Message/binary, " in ES module scope">>
    end,
    Path = buoy_ref_string:to_utf8(info(M, path)),
    IsFile = binary:first(Path) =:= $/,
    case IsFile andalso filename:extension(Path) =:= <<".js">> andalso buoy_binding_modules:scope_type(file_url(info(M, path))) of
        {<<"module">>, PackageJson} ->
            <<Scoped/binary, "\nThis file is being treated as an ES module because it has a '.js' file extension and '",
              (buoy_ref_string:to_utf8(PackageJson))/binary, "' contains \"type\": \"module\". ",
              "To treat it as a CommonJS script, rename it to use the '.cjs' file extension.">>;
        _ ->
            Scoped
    end.

%% ExecuteAsyncModule
execute_async(M) ->
    P = try body(M)
        catch
            error:Reason:Stack -> buoy_jobs:rejected(buoy_ref:caught(Reason, Stack))
        end,
    Rejected = fun(E) ->
                       erlang:get(?HOST(M)) =:= undefined andalso explain_cjs_global(M, E),
                       async_rejected(M, E),
                       undefined
               end,
    buoy_jobs:perform_then(P, fun(_) -> async_fulfilled(M), undefined end, Rejected, undefined).

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
            NS = make_namespace(namespace_entries(M)),
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
            case scc_evaluated(M) orelse get(M, status) of
                true -> true;
                evaluating -> false;
                evaluating_async -> false;
                _ -> not has_tla(M) andalso lists:all(fun(R) -> ready_for_sync(R, [M | Seen]) end, requests(M))
            end
    end.

%% IsModuleSCCEvaluated: a module of a cycle is done when the root of its
%% cycle is, which awaits after the other modules of the cycle evaluated.
scc_evaluated(M) -> get(get(M, cycle_root), status) =:= evaluated.

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

%% Each id is a module of Node's lib that buoy_node runs. The Module class of
%% `module` keeps require.cache of the program as its _cache, so Node's
%% CommonJS loader and the compiled modules share one record of each module.
builtin(<<"module">>) ->
    case buoy_node:require(<<"module">>) of
        {ok, Module} -> share_cache(Module), {ok, Module};
        error -> error
    end;
builtin(<<"node:", Name/binary>>) -> builtin(Name);
builtin(Name) when is_binary(Name) -> buoy_node:require(Name);
builtin(_) -> error.

-spec no_builtin(term()) -> no_return().
no_builtin(Name) ->
    throw_coded('Error', <<"ERR_BUOY_BUILTIN">>,
                buoy_ref_string:concat([<<"Buoy does not provide the Node built-in module 'node:">>, Name, <<"' yet">>])).

share_cache(Module) ->
    Cache = cache(),
    case buoy_heap:get(Module, <<"_cache">>) of
        Cache ->
            ok;
        Own ->
            [buoy_heap:set(Cache, K, buoy_heap:get(Own, K)) || K <- buoy_heap:own_keys(Own), not buoy_heap:has_own(Cache, K)],
            buoy_heap:set(Module, <<"_cache">>, Cache)
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
    case {erlang:get(?HOST(From)), erlang:get({'$buoy_realm_host', buoy_heap:realm()})} of
        {undefined, undefined} -> import_program_module(From, Specifier, Options, Phase);
        {undefined, Option} -> host_import({0, undefined, Option}, Specifier, Options, Phase);
        {Host, _} -> host_import(Host, Specifier, Options, Phase)
    end.

%% The host-defined option of a context of node:vm, for import() of its code
%% that no script or module of node:vm compiled.
-spec set_realm_host(pos_integer(), term()) -> ok.
set_realm_host(Realm, Option) ->
    erlang:put({'$buoy_realm_host', Realm}, Option),
    ok.

%% import() in code that module_wrap or contextify compiled: the promise of
%% the callback of setImportModuleDynamicallyCallback, as Node's
%% ImportModuleDynamically calls it with the host-defined option.
host_import({_, Referrer, Option}, Specifier, Options, Phase) ->
    {P, Resolve, Reject} = buoy_jobs:capability(),
    try
        Text = buoy_ref:to_string(Specifier),
        Attributes = import_attributes(Options),
        Callback = case erlang:get('$buoy_import_module_dynamically') of
            undefined -> buoy_ref:type_error(<<"import() is not supported here">>);
            C -> C
        end,
        Number = case Phase of source -> 1; _ -> 2 end,
        Result = buoy_heap:call(Callback, undefined, [Option, Text, Number, Attributes, Referrer]),
        buoy_jobs:perform_then(buoy_jobs:promise_resolve(Result), Resolve, Reject, undefined)
    catch
        error:Reason:Stack -> Reject(buoy_ref:caught(Reason, Stack))
    end,
    P.

import_attributes(Options) ->
    check_options(Options),
    With = case Options of
        undefined -> undefined;
        _ -> buoy_heap:get(Options, <<"with">>)
    end,
    Pairs = case With of
        undefined -> [];
        _ -> [{K, buoy_heap:get(With, K)} || K <- buoy_heap:enumerable_keys(With)]
    end,
    buoy_heap:object(null, Pairs).

%% Node's loader publishes import() to the tracing channel module.import.
import_program_module(From, Specifier, Options, Phase) ->
    buoy_binding_diagnostics_channel:trace_promise(<<"module.import">>, fun() -> [{<<"parentURL">>, file_url(info(From, path))}, {<<"url">>, Specifier}] end,
                                                   fun() -> import_traced(From, Specifier, Options, Phase) end).

import_traced(From, Specifier, Options, Phase) ->
    {P, Resolve, Reject} = buoy_jobs:capability(),
    try
        Text = case check_options(Options) of
            none -> buoy_ref:to_string(Specifier);
            Type -> buoy_ref_string:concat([buoy_ref:to_string(Specifier), <<0>>, Type])
        end,
        Phase =:= source andalso
            buoy_heap:throw_error('SyntaxError', buoy_ref_string:concat([<<"Source phase import object is not defined for module '">>, Text, <<"'">>])),
        case target(From, Text, import) of
            {_Path, Module} when is_atom(Module), Module =/= none ->
                validate_attributes(Module, Options),
                import_target(Module, Phase, Resolve, Reject);
            {builtin, Name} ->
                validate_attributes({builtin, Name}, Options),
                import_target({builtin, Name}, Phase, Resolve, Reject);
            _ ->
                node_import(From, Specifier, Options, Phase, Resolve, Reject)
        end
    catch
        error:Reason:Stack -> Reject(buoy_ref:caught(Reason, Stack))
    end,
    P.

%% The import attributes of import() against the format of the target, as
%% Node's ESM loader checks them with validateAttributes: a JSON module needs
%% `type: 'json'`, and another module takes none. An import of a module that
%% is no JSON without attributes needs no check.
validate_attributes(Target, Options) ->
    Attributes = import_attributes(Options),
    Format = case Target of
        {builtin, _} -> <<"builtin">>;
        M -> atom_to_binary(kind(M))
    end,
    %% A text or bytes module took its type when the compiler resolved it.
    Typed = Format =:= <<"text">> orelse Format =:= <<"bytes">>,
    case Typed orelse (Format =/= <<"json">> andalso buoy_heap:own_keys(Attributes) =:= []) of
        true ->
            ok;
        false ->
            ok = buoy_node:ensure(),
            {_, Require} = buoy_node:loaders(),
            Assert = buoy_heap:call(Require, undefined, [<<"internal/modules/esm/assert">>]),
            Url = case Target of
                {builtin, Name} -> buoy_ref_string:concat(<<"node:">>, Name);
                _ -> file_url(info(Target, path))
            end,
            NodeFormat = case Format of
                <<"esm">> -> <<"module">>;
                <<"cjs">> -> <<"commonjs">>;
                Other -> Other
            end,
            buoy_heap:call(buoy_heap:get(Assert, <<"validateAttributes">>), Assert, [Url, NodeFormat, Attributes]),
            ok
    end.

import_target(Target, Phase, Resolve, Reject) ->
    Loaded = case {Phase, Target} of
        {defer, {builtin, _}} -> Target;
        {defer, _} -> {defer, Target};
        _ -> Target
    end,
    buoy_jobs:enqueue(fun() -> load_dynamic(Loaded, Resolve, Reject) end).

%% A specifier that the compiler cannot resolve, such as a data: URL or a
%% file that the program writes, goes to Node's ESM loader, as Node imports
%% from a CommonJS module or an ES module of the program. The loader wraps
%% the modules of the program that it reaches (program_module/1).
node_import(From, Specifier, Options, Phase, Resolve, Reject) ->
    ok = buoy_node:ensure(),
    Symbols = buoy_node:per_isolate_symbols(),
    {Option, Referrer} = case kind(From) of
        esm -> {element(2, lists:keyfind(<<"source_text_module_default_hdo">>, 1, Symbols)), file_url(info(From, path))};
        _ -> {element(2, lists:keyfind(<<"vm_dynamic_import_default_internal">>, 1, Symbols)), info(From, path)}
    end,
    P = host_import({0, Referrer, Option}, Specifier, Options, Phase),
    buoy_jobs:perform_then(P, Resolve, Reject, undefined).

%% ContinueDynamicImport
load_dynamic(Target, Resolve, Reject) ->
    try
        case Target of
            {builtin, B} ->
                Resolve(builtin_namespace(B));
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

%% The import attributes of import(): the type of a text or bytes module, or
%% none. The request key of such a module holds its type after a NUL, as the
%% compiler writes it (TYPE_SEPARATOR of the graph).
check_options(undefined) ->
    none;
check_options(Options) ->
    buoy_heap:is_object(Options) orelse buoy_ref:type_error(<<"The second argument of import() must be an object">>),
    case buoy_heap:get(Options, <<"with">>) of
        undefined ->
            none;
        With ->
            buoy_heap:is_object(With) orelse buoy_ref:type_error(<<"The 'with' option of import() must be an object">>),
            Attributes = [{K, buoy_heap:get(With, K)} || K <- buoy_heap:enumerable_keys(With)],
            lists:foreach(fun({_, V}) ->
                                  ?IS_STRING(V) orelse buoy_ref:type_error(<<"Import attribute values must be strings">>)
                          end, Attributes),
            case lists:keyfind(<<"type">>, 1, Attributes) of
                {_, Type} when Type =:= <<"text">>; Type =:= <<"bytes">> -> Type;
                _ -> none
            end
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
    %% The resolution of a specifier from a module holds for the run, as
    %% Node's loader caches it: an import of a file that the program has
    %% since deleted still finds the module.
    Key = {'$buoy_runtime_target', From, Specifier, Mode},
    case erlang:get(Key) of
        undefined ->
            Found = compile_at_run_time(From, Specifier, Mode),
            case Found of
                {_, Module} when is_atom(Module) -> erlang:put(Key, Found);
                _ -> ok
            end,
            Found;
        Found ->
            Found
    end.

compile_at_run_time(From, Specifier, Mode) ->
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

%%% import.meta

%% The import.meta object of M in this realm, as Node 25 makes it.
-spec meta(module()) -> term().
meta(M) ->
    case {erlang:get(?META(M)), erlang:get(?HOST(M))} of
        {undefined, {_, Referrer, Option}} ->
            O = buoy_heap:new_object(null),
            erlang:put(?META(M), O),
            host_meta(M, O, Referrer, Option),
            O;
        {undefined, _} ->
            Path = info(M, path),
            Resolve = buoy_heap:function(fun(_This, Args) -> meta_resolve(M, buoy_ref_realm:arg(1, Args)) end,
                                         <<"resolve">>, 1, #{}),
            %% A module of a data: URL has no file.
            File = case buoy_ref_string:to_utf8(Path) of
                <<"data:", _/binary>> -> [];
                _ -> [{<<"dirname">>, dirname(Path)}, {<<"filename">>, Path}]
            end,
            O = buoy_heap:object(null, File ++ [{<<"main">>, erlang:get(?ENTRY) =:= M}, {<<"resolve">>, Resolve},
                                                {<<"url">>, file_url(Path)}]),
            erlang:put(?META(M), O),
            O;
        {O, _} ->
            O
    end.

%% import.meta of a module that module_wrap compiled: Node's own fields for
%% a module of the ESM loader, else the callback of
%% setInitializeImportMetaObjectCallback with the host-defined option.
host_meta(M, O, Url, Option) ->
    {_, Default} = lists:keyfind(<<"source_text_module_default_hdo">>, 1, buoy_node:per_isolate_symbols()),
    case Option of
        Default -> default_meta(O, Url);
        _ ->
            case erlang:get('$buoy_initialize_import_meta') of
                undefined -> ok;
                Callback -> buoy_heap:call(Callback, undefined, [Option, O, erlang:get({'$buoy_module_wrap', M})])
            end
    end.

%% DefaultImportMetaObjectInitializer: dirname, filename, and resolve of a
%% file: URL, and url.
default_meta(O, Url) ->
    Text = buoy_ref_string:to_utf8(Url),
    case Text of
        <<"file://", _/binary>> ->
            Path = buoy_ref_string:from_utf8(uri_string:percent_decode(binary:part(Text, 7, byte_size(Text) - 7))),
            buoy_heap:set(O, <<"dirname">>, dirname(Path)),
            buoy_heap:set(O, <<"filename">>, Path);
        _ ->
            ok
    end,
    case erlang:get('$buoy_import_meta_resolve') of
        undefined -> ok;
        Initializer -> buoy_heap:set(O, <<"resolve">>, buoy_heap:call(Initializer, undefined, [Url]))
    end,
    buoy_heap:set(O, <<"url">>, Url),
    ok.

meta_resolve(M, Specifier) ->
    Text = buoy_ref:to_string(Specifier),
    case target(M, Text, import) of
        {builtin, Name} -> buoy_ref_string:concat([<<"node:">>, Name]);
        {error, Code, Message} -> throw_load(Code, Message);
        {Path, _} -> file_url(Path);
        none -> throw_coded('Error', <<"ERR_MODULE_NOT_FOUND">>,
                            buoy_ref_string:concat([<<"Cannot find module '">>, Text, <<"' imported from ">>, info(M, path)]))
    end.

dirname(Path) -> buoy_ref_string:from_utf8(filename:dirname(buoy_ref_string:to_utf8(Path))).

%% pathToFileURL: file:// and the path, with the bytes that a URL path may not
%% hold percent-encoded. The path of a module of a data: URL is its URL.
file_url(Path) ->
    case buoy_ref_string:to_utf8(Path) of
        <<"data:", _/binary>> -> Path;
        Bytes -> path_url(Bytes)
    end.

path_url(Bytes) ->
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
        cjs -> cjs_exports(M);
        json -> buoy_heap:get(load_json(M), <<"exports">>);
        %% `with { type: "text" }` and `with { type: "bytes" }`: the text of the
        %% file, or its bytes over an immutable buffer, as the default export.
        text -> buoy_ref_string:from_utf8(M:'$json'());
        bytes -> immutable_bytes(binary:decode_hex(M:'$json'()))
    end,
    Snapshot = maps:from_list([{Name, snapshot_value(Name, Exports)} || {Name, _} <- M:'$namespace'()]),
    erlang:put(?FOREIGN(M), Snapshot),
    ok.

immutable_bytes(Bytes) ->
    Buffer = buoy_ref_buffer:allocate(byte_size(Bytes)),
    Typed = buoy_ref:construct(buoy_ref_realm:global(<<"Uint8Array">>), [Buffer]),
    byte_size(Bytes) > 0 andalso buoy_ref_buffer:write(Buffer, 0, Bytes),
    buoy_ref_buffer:freeze(Buffer),
    Typed.

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

%% The exports of a CommonJS module of the program. Node's CommonJS loader
%% loads it, as Module._load does, so Module._cache, require.extensions,
%% Module.wrapper, and the hooks of node:module apply. The compiled wrapper
%% of the module is the code cache that compileFunctionForCJSLoader hands the
%% loader. The code of -e and of stdin has no file, so it runs as a Module of
%% its own, as Node's evalScript runs it.
cjs_exports(M) ->
    Path = info(M, path),
    ok = buoy_node:ensure(),
    {ok, Module} = builtin(<<"module">>),
    case filelib:is_regular(buoy_ref_string:to_utf8(Path)) of
        true -> buoy_heap:call(buoy_heap:get(Module, <<"_load">>), Module, [Path, null, erlang:get(?ENTRY) =:= M]);
        false -> eval_exports(Module, Path)
    end.

eval_exports(Module, Path) ->
    Instance = buoy_heap:construct(Module, [Path], Module),
    Paths = buoy_heap:call(buoy_heap:get(Module, <<"_nodeModulePaths">>), Module, [dirname(Path)]),
    [buoy_heap:set(Instance, K, V) || {K, V} <- [{<<"filename">>, Path}, {<<"paths">>, Paths}]],
    buoy_heap:set(buoy_heap:get(Module, <<"_cache">>), Path, Instance),
    buoy_heap:call(buoy_heap:get(Instance, <<"_compile">>), Instance, [<<>>, Path]),
    buoy_heap:set(Instance, <<"loaded">>, true),
    buoy_heap:get(Instance, <<"exports">>).

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

%% The compiled wrapper of the CommonJS module at Path whose source text is
%% Content, which Node's CommonJS loader runs in place of a new compilation,
%% as V8 takes a function from its code cache. The compiler compiled the
%% file, so the cache holds only while Content is the text of the file: a
%% hook of require.extensions may hand _compile other text. The code of -e
%% and stdin has no file, and its module runs whatever the text. A file that
%% the static graph did not reach compiles now and joins the graph.
-spec compiled_wrapper(term(), term()) -> {ok, term()} | none.
compiled_wrapper(Path, Content) ->
    File = buoy_ref_string:to_utf8(Path),
    case {file:read_file(File), graph_module(Path)} of
        {{error, enoent}, {ok, M}} -> cjs_wrapper(M);
        {{ok, Text}, Graph} ->
            case {Text =:= buoy_ref_string:to_utf8(Content), Graph} of
                {true, {ok, M}} -> cjs_wrapper(M);
                {true, none} -> compile_file(File);
                {false, _} -> none
            end;
        _ ->
            none
    end.

graph_module(Path) ->
    Graph = case erlang:get(?GRAPH) of undefined -> #{}; G -> G end,
    case maps:find(Path, Graph) of
        {ok, M} when is_atom(M), M =/= none -> {ok, M};
        _ -> none
    end.

cjs_wrapper(M) ->
    case kind(M) of
        cjs -> {ok, M:'$cjs'()};
        _ -> none
    end.

compile_file(File) ->
    case os:getenv("BUOY_COMPILER") =/= false andalso erlang:get(?ENTRY) of
        Entry when is_atom(Entry), Entry =/= undefined ->
            Main = buoy_ref_string:to_utf8(info(Entry, path)),
            case buoy_ref_eval:load_module(Main, File, File, require) of
                {program, _, M, Added} ->
                    Graph = case erlang:get(?GRAPH) of undefined -> #{}; G -> G end,
                    erlang:put(?GRAPH, maps:merge(maps:from_list(Added), Graph)),
                    cjs_wrapper(M);
                _ ->
                    none
            end;
        _ ->
            none
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
                    Entries = sort_entries([{<<"__esModule">>, fun() -> true end} | namespace_entries(M)]),
                    Facade = make_namespace(Entries),
                    erlang:put(Key, Facade),
                    Facade;
                Facade ->
                    Facade
            end
    end.

-spec throw_coded(atom(), term(), term()) -> no_return().
%% A module that the compiler of the VM cannot load: a SyntaxError for a
%% syntax error, as Node's loaders throw it, else an Error with Node's code.
-spec throw_load(binary(), term()) -> no_return().
throw_load(<<"SyntaxError">>, Message) -> buoy_heap:throw_error('SyntaxError', Message);
throw_load(Code, Message) -> throw_coded('Error', Code, Message).

throw_coded(Name, Code, Message) ->
    E = buoy_heap:error_object(Name, Message, buoy_ref_string:concat([atom_to_binary(Name), <<": ">>, Message])),
    buoy_heap:define(E, <<"code">>, #{value => Code, writable => true, enumerable => true, configurable => true}),
    erlang:error({'$throw', E}).

%%% Modules that the host links: module_wrap's ModuleWrap. A source text
%%% module compiles with hosted requests (buoy_compiler's
%%% compile_hosted_module), which link_requests/2 binds to the modules that
%%% Node's lib chose, and a synthetic module has export names and evaluation
%%% steps. Both take part in the evaluation of the module graph above.

%% A synthetic module of export Names, whose evaluation calls Steps.
-spec new_synthetic(term(), [term()], fun(() -> term())) -> module().
new_synthetic(Url, Names, Steps) ->
    M = list_to_atom("buoy_synthetic_" ++ integer_to_list(erlang:unique_integer([positive]))),
    Info = #{kind => synthetic, path => Url, requests => [], async => false, error => none,
             names => Names, steps => Steps},
    erlang:put(?RECORD(M), new_record(M, Info)),
    M.

-spec set_synthetic_export(module(), term(), term()) -> ok.
set_synthetic_export(M, Name, Value) ->
    lists:member(Name, info(M, names)) orelse
        buoy_heap:throw_error('ReferenceError', buoy_ref_string:concat([<<"Export '">>, Name, <<"' is not defined in module">>])),
    erlang:put(?SYNTHETIC(M, Name), Value),
    ok.

%% The specifiers of the requests of M, in order.
-spec requests_of(module()) -> [term()].
requests_of(M) -> maps:get(hosted, get(M, info), []).

%% The ModuleRequests of M for the host, as getModuleRequests lists them:
%% {Specifier, Attributes, Phase} for each specifier, attributes, and phase,
%% with 1 for the source phase and 2 for evaluation.
-spec module_requests_of(module()) -> [{term(), [{term(), term()}], 1 | 2}].
module_requests_of(M) ->
    Info = get(M, info),
    maps:get(module_requests, Info, [{S, [], 2} || S <- maps:get(hosted, Info, [])]).

%% Binds the requests of M to the modules Targets, in order. A module of the
%% program reports no requests to the host, which links it to none, and keeps
%% the requests that the compiler linked.
-spec link_requests(module(), [module()]) -> ok.
link_requests(M, Targets) ->
    case erlang:get(?HOST(M)) of
        undefined -> ok;
        _ -> set(M, info, (get(M, info))#{requests => Targets, linked => true}), ok
    end.

%% Instantiate: links the graph of M, or throws the error of a request that
%% does not provide an import, as V8's InstantiateModule does. A source text
%% module must have its requests linked first.
-spec instantiate(module()) -> ok.
instantiate(M) ->
    %% A module of the program has no host: the compiler linked it.
    kind(M) =:= synthetic orelse erlang:get(?HOST(M)) =:= undefined orelse is_map_key(linked, get(M, info)) orelse
        throw_coded('Error', <<"ERR_VM_MODULE_LINK_FAILURE">>, <<"module is not linked">>),
    link_graph(M),
    ok.

%% The ES module of the program at the file URL Url, which Node's ESM loader
%% wraps in place of a new compilation, so that the program and the loader
%% share one instance of each module. The compiler linked its requests.
-spec program_module(term()) -> {ok, module()} | none.
program_module(Url) ->
    Graph = case erlang:get(?GRAPH) of undefined -> #{}; G -> G end,
    Path = case buoy_ref_string:to_utf8(Url) of
        <<"file://", Rest/binary>> -> buoy_ref_string:from_utf8(uri_string:percent_decode(hd(binary:split(Rest, [<<"?">>, <<"#">>]))));
        <<"data:", _/binary>> -> Url;
        _ -> none
    end,
    case Path of
        none ->
            none;
        _ ->
            case maps:find(Path, Graph) of
                {ok, M} when is_atom(M), M =/= none ->
                    case kind(M) of
                        esm -> {ok, M};
                        _ -> none
                    end;
                _ ->
                    none
            end
    end.

%% Records the realm of a module and the referrer and host-defined option
%% that import() and import.meta of its code pass to the callbacks of
%% module_wrap.
-spec set_host(module(), non_neg_integer(), {term(), term()}) -> ok.
set_host(M, Realm, {Referrer, Option}) ->
    erlang:put(?HOST(M), {Realm, Referrer, Option}),
    ok.

%% The status of ModuleWrap.getStatus: V8's Module::Status.
-spec status(module()) -> 0..5.
status(M) ->
    case get(M, status) of
        new -> 0;
        linking -> 1;
        linked -> 2;
        evaluating -> 3;
        _ ->
            case get(M, error) of
                none -> 4;
                _ -> 5
            end
    end.

-spec error_of(module()) -> term().
error_of(M) ->
    case get(M, error) of
        {error, E} -> E;
        none -> undefined
    end.

-spec has_top_level_await(module()) -> boolean().
has_top_level_await(M) -> has_tla(M).

%% Whether M or a module that it reaches awaits at its top level.
-spec has_async_graph(module()) -> boolean().
has_async_graph(M) -> has_async_graph(M, []) =:= true.

has_async_graph(M, Seen) ->
    case lists:member(M, Seen) of
        true -> Seen;
        false ->
            case kind(M) =:= esm andalso has_tla(M) of
                true -> true;
                false -> lists:foldl(fun(_, true) -> true;
                                        (R, S) -> has_async_graph(R, S)
                                     end, [M | Seen], requests(M))
            end
    end.

%% The value of the import Name (or the namespace) of the request Index of M.
-spec hosted_import(module(), non_neg_integer(), term()) -> term().
hosted_import(M, Index, Name) ->
    Key = {'$buoy_hosted_import', M, Index, Name},
    case erlang:get(Key) of
        undefined ->
            Target = lists:nth(Index + 1, info(M, requests)),
            Read = case Name of
                namespace -> fun() -> namespace(Target) end;
                _ ->
                    case resolve_export(Target, Name, []) of
                        {ok, F} -> F;
                        _ -> buoy_heap:throw_error('SyntaxError', not_provided(M, Index, Name))
                    end
            end,
            erlang:put(Key, Read),
            Read();
        Read ->
            Read()
    end.

%% The namespace entries of M: its export names in code unit order, each
%% with a fun that reads it.
namespace_entries(M) ->
    case get(M, info) of
        #{kind := synthetic, names := Names} ->
            sort_entries([{N, synthetic_read(M, N)} || N <- Names]);
        #{stars := [_ | _] = Stars} ->
            Static = M:'$namespace'(),
            Known = [N || {N, _} <- Static],
            Candidates = lists:usort([N || I <- Stars, N <- exported_names(lists:nth(I + 1, info(M, requests)), [M]),
                                          N =/= <<"default">>, not lists:member(N, Known)]),
            Found = [{N, F} || N <- Candidates, {ok, F} <- [resolve_export(M, N, [])]],
            sort_entries(Static ++ Found);
        _ ->
            M:'$namespace'()
    end.

%% GetExportedNames: the names that M exports, also through its star exports.
%% Seen is the exportStarSet, so a cycle of star exports ends.
exported_names(M, Seen) ->
    case lists:member(M, Seen) of
        true ->
            [];
        false ->
            case get(M, info) of
                #{kind := synthetic, names := Names} ->
                    Names;
                #{stars := Stars} ->
                    Targets = info(M, requests),
                    [N || {N, _} <- M:'$namespace'()] ++
                        [N || I <- Stars, N <- exported_names(lists:nth(I + 1, Targets), [M | Seen]), N =/= <<"default">>];
                _ ->
                    [N || {N, _} <- namespace_entries(M)]
            end
    end.

sort_entries(Entries) ->
    lists:sort(fun({A, _}, {B, _}) -> buoy_ref_string:compare(A, B) =/= gt end, Entries).

synthetic_read(M, Name) ->
    fun() ->
            case erlang:get(?SYNTHETIC(M, Name)) of
                undefined -> undefined;
                V -> V
            end
    end.

%% ResolveExport over the modules of the realm: {ok, Read}, not_found, or
%% ambiguous.
resolve_export(M, Name, Visited) ->
    case lists:member({M, Name}, Visited) of
        true ->
            not_found;
        false ->
            case get(M, info) of
                #{kind := synthetic, names := Names} ->
                    case lists:member(Name, Names) of
                        true -> {ok, synthetic_read(M, Name)};
                        false -> not_found
                    end;
                #{stars := Stars} ->
                    case lists:keyfind(Name, 1, M:'$namespace'()) of
                        {_, F} -> {ok, F};
                        false when Name =:= <<"default">> -> not_found;
                        false -> star_export(M, Name, Stars, [{M, Name} | Visited])
                    end;
                _ ->
                    case lists:keyfind(Name, 1, namespace_entries(M)) of
                        {_, F} -> {ok, F};
                        false -> not_found
                    end
            end
    end.

star_export(M, Name, Stars, Visited) ->
    Targets = info(M, requests),
    lists:foldl(fun(_, ambiguous) -> ambiguous;
                   (I, Acc) ->
                        case {resolve_export(lists:nth(I + 1, Targets), Name, Visited), Acc} of
                            {ambiguous, _} -> ambiguous;
                            {not_found, _} -> Acc;
                            {Found, not_found} -> Found;
                            {Found, Found} -> Found;
                            {_, _} -> ambiguous
                        end
                end, not_found, Stars).

%% The link error of M: its own, or for a module that the host links, the
%% first import that its request does not provide.
link_failure(M) ->
    case {info(M, error), get(M, info)} of
        {none, #{linked := true, imports := Imports}} ->
            first_unresolved(M, Imports);
        {none, #{linked := true}} ->
            none;
        {none, #{hosted := [Specifier | _]}} ->
            {<<"Error">>, <<"ERR_VM_MODULE_LINK_FAILURE">>,
             buoy_ref_string:concat([<<"request for '">>, Specifier, <<"' can not be resolved on module '">>,
                                     info(M, path), <<"' that is not linked">>])};
        {Error, _} ->
            Error
    end.

first_unresolved(_, []) ->
    none;
first_unresolved(M, [{Index, Name} | Rest]) ->
    case resolve_export(lists:nth(Index + 1, info(M, requests)), Name, []) of
        {ok, _} -> first_unresolved(M, Rest);
        not_found -> {<<"SyntaxError">>, undefined, not_provided(M, Index, Name)};
        ambiguous ->
            {<<"SyntaxError">>, undefined,
             buoy_ref_string:concat([<<"The requested module '">>, lists:nth(Index + 1, requests_of(M)),
                                     <<"' contains conflicting star exports for name '">>, Name, <<"'">>])}
    end.

not_provided(M, Index, Name) ->
    buoy_ref_string:concat([<<"The requested module '">>, lists:nth(Index + 1, requests_of(M)),
                            <<"' does not provide an export named '">>, Name, <<"'">>]).

%% createRequiredModuleFacade: the namespace that require(esm) returns.
-spec required_facade(module()) -> term().
required_facade(M) ->
    required_namespace(M, namespace(M)).
