%% Node's built-in modules on the reference engine (docs/design/node-builtins.md).
%%
%% Buoy runs Node's own JavaScript: crates/buoy-cli/build.rs compiles each id
%% of runtime/node/builtins.txt, from Node's lib/ or from Buoy's own version,
%% into the module buoy_node@<id>, whose '__eval__'/3 returns the function that
%% Node wraps around the code. This module is the C++ side of Node that the
%% code expects: it builds the primordials, the process object, and the
%% bindings that internalBinding returns, and it runs Node's bootstrap,
%% internal/bootstrap/realm (the BuiltinModule loader) and then the other
%% bootstrap ids that the list holds.
%%
%% The bootstrap runs once per realm, on the first use of a built-in module or
%% of a Node global (buoy_ref_realm makes them lazy), so a program that uses
%% neither pays nothing. A binding is the module buoy_binding_<name>, whose
%% binding/0 returns the binding object; this module caches it per realm.
-module(buoy_node).

-include("buoy_ref.hrl").

-export([linked_binding/2]).
-export([require/1, is_public/1, binding/1, ensure/0, ready/0, global_get/1, global_set/2, lazy_globals/0]).
-export([fn/3, object/1, object/2, typed_array/2, string/1, symbol/1, throw_code/3, call/3, primordials/0, private_symbol/1]).
-export([constructor/3, missing_constructor/3, ids/0, mangle/1, from_json/1, not_implemented/2, stubs/2, arg/2, per_isolate_symbols/0, private_symbols/0, context/0, set_loaders/2, loaders/0, compile/1]).

%% A stub of a binding is a function that only throws, on purpose.
-dialyzer({no_return, [not_implemented/2, missing_constructor/3]}).

-define(STATE, '$buoy_node_state').
-define(LOADERS, '$buoy_node_loaders').
-define(BINDINGS, '$buoy_node_bindings').
-define(PRIMORDIALS, '$buoy_node_primordials').
-define(SYMBOLS, '$buoy_node_symbols').
-define(CONTEXT, '$buoy_node_context').

%% The bootstrap ids that run after internal/bootstrap/realm, in Node's order
%% (node.cc: BootstrapNode, then the main script). Each runs only when the
%% list of runtime/node/builtins.txt holds it.
-define(BOOTSTRAP, [<<"internal/bootstrap/node">>,
                    <<"internal/bootstrap/web/exposed-wildcard">>,
                    <<"internal/bootstrap/web/exposed-window-or-worker">>,
                    <<"internal/bootstrap/switches/is_main_thread">>,
                    <<"internal/bootstrap/switches/does_own_process_state">>,
                    <<"internal/main/buoy">>]).

-define(PER_CONTEXT, [<<"internal/per_context/primordials">>,
                      <<"internal/per_context/domexception">>,
                      <<"internal/per_context/messageport">>]).

%%% The public loader

%% The exports of the public built-in Id, as require('Id') returns them, or
%% error when Buoy does not provide it.
-spec require(binary()) -> {ok, term()} | error.
require(Id) ->
    ensure(),
    %% With --expose-internals, the internal ids load too (BuiltinModule.exposeInternals).
    Exposed = is_internal(Id) andalso lists:member(Id, ids())
        andalso lists:member(<<"--expose-internals">>, buoy_node_process:exec_argv()),
    BuiltinModule = buoy_heap:get(loader_exports(), <<"BuiltinModule">>),
    %% An experimental module, such as sqlite, loads once pre-execution allowed it.
    Allowed = is_public(Id) andalso call_method(BuiltinModule, <<"canBeRequiredByUsers">>, [Id]) =:= true,
    case Allowed orelse Exposed of
        false ->
            error;
        true ->
            Module = call_method(buoy_heap:get(BuiltinModule, <<"map">>), <<"get">>, [Id]),
            {ok, call_method(Module, <<"compileForPublicLoader">>, [])}
    end.

%% Whether Id is a public built-in that the runtime holds: compiled, and one
%% that Node lets users require.
-spec is_public(binary()) -> boolean().
is_public(Id) ->
    lists:member(Id, (index()):ids()) andalso not is_internal(Id).

%% The ids of runtime/node/builtins.txt, from buoy_node_builtins, which
%% crates/buoy-cli/build.rs generates.
-spec ids() -> [binary()].
ids() -> (index()):ids().

index() -> buoy_node_builtins.

is_internal(<<"internal/", _/binary>>) -> true;
is_internal(_) -> false.

loader_exports() ->
    {_InternalBinding, Require} = erlang:get(?LOADERS),
    buoy_heap:call(Require, undefined, [<<"internal/bootstrap/realm">>]).

%%% The bootstrap

%% Runs the bootstrap in this realm unless it ran or is running.
-spec ensure() -> ok.
ensure() ->
    case erlang:get(?STATE) of
        undefined ->
            try boot()
            catch
                Class:Reason:Stack ->
                    Shown = case Reason of
                        {'$throw', V} -> try buoy_ref_string:to_utf8(buoy_ref:to_string(V)) catch _:_ -> V end;
                        _ -> Reason
                    end,
                    Frames = fun(S) -> [io_lib:format("  ~ts:~w~n", [M, proplists:get_value(line, I, 0)]) || {M, _, _, I} <- lists:sublist(S, 14)] end,
                    debug("bootstrap failed: ~tp~n~ts", [Shown, Frames(Stack)]),
                    case erlang:get('$buoy_last_throw') of
                        {LastMessage, LastStack} -> debug("last error thrown: ~tp~n~ts", [LastMessage, Frames(LastStack)]);
                        _ -> ok
                    end,
                    erlang:raise(Class, Reason, Stack)
            end;
        _ ->
            ok
    end.

%% Whether the bootstrap finished in this realm.
-spec ready() -> boolean().
ready() -> erlang:get(?STATE) =:= ready.

boot() ->
    erlang:put(?STATE, booting),
    persistent_term:put({buoy_node, debug}, os:getenv("BUOY_NODE_DEBUG") =/= false),
    Primordials = buoy_heap:object(null, []),
    erlang:put(?PRIMORDIALS, Primordials),
    Private = symbols(private_symbol_names()),
    PerIsolate = symbols(per_isolate_symbol_names()),
    erlang:put(?SYMBOLS, {Private, PerIsolate}),
    Context = object([{<<"primordials">>, Primordials}]),
    erlang:put(?CONTEXT, Context),
    [run(Id, [Context, Primordials, Private, PerIsolate]) || Id <- ?PER_CONTEXT, is_compiled(Id)],
    Process = buoy_node_process:create(),
    buoy_node_loop:set_process(Process),
    GetLinked = fn(<<"getLinkedBinding">>, 1, fun ?MODULE:linked_binding/2),
    GetInternal = fn(<<"getInternalBinding">>, 1, fun(_, Args) -> binding(buoy_ref_realm:arg(1, Args)) end),
    run(<<"internal/bootstrap/realm">>, [Process, GetLinked, GetInternal, Primordials]),
    {InternalBinding, Require} = erlang:get(?LOADERS),
    [run(Id, [Process, Require, InternalBinding, Primordials]) || Id <- ?BOOTSTRAP, is_compiled(Id)],
    %% A global that the bootstrap did not define, such as Storage under
    %% --no-webstorage, is not defined, as in Node.
    [buoy_heap:delete_property({'$o', 'globalThis'}, Name) || Name <- lazy_globals(), is_lazy(Name)],
    erlang:put(?STATE, ready),
    debug("bootstrap done~n", []),
    ok.

is_compiled(Id) -> lists:member(Id, (index()):ids()).

%% Calls the function around the code of the built-in Id with Args.
run(Id, Args) ->
    buoy_heap:call(compile(Id), undefined, Args).

%% The function around the code of the built-in Id, new in each call, as
%% compileFunction of the builtins binding returns it.
-spec compile(binary()) -> term().
compile(Id) ->
    Module = binary_to_atom(<<"buoy_node@", (mangle(Id))/binary>>),
    debug("compile ~ts~n", [Id]),
    Module:'__eval__'(undefined, [], #{}).

%% BUOY_NODE_DEBUG=1 traces the bootstrap on stderr.
debug(Format, Args) ->
    case os:getenv("BUOY_NODE_DEBUG") of
        false -> ok;
        _ -> io:format(standard_error, Format, Args)
    end.

-spec mangle(binary()) -> binary().
mangle(Id) ->
    << <<(case C of $/ -> $@; $- -> $_; _ -> C end)>> || <<C>> <= Id >>.

%%% The globals that the bootstrap defines

%% The globals of Node that the engine does not define. Each is an accessor
%% of the global object until the bootstrap runs; the bootstrap then defines
%% the real property.
%% The globals that Node's bootstrap defines and the engine does not: the
%% globals of tests/node/surface.json. Crypto, Storage, and the others that
%% Node defines only with OpenSSL or SQLite read as undefined after the
%% bootstrap.
-spec lazy_globals() -> [binary()].
lazy_globals() ->
    [<<"process">>, <<"Buffer">>, <<"global">>, <<"setImmediate">>, <<"clearImmediate">>
     | [atom_to_binary(Name) || Name <- ['AbortController', 'AbortSignal', 'Blob', 'BroadcastChannel',
        'ByteLengthQueuingStrategy', 'CloseEvent', 'CompressionStream', 'CountQueuingStrategy', 'Crypto', 'CryptoKey',
        'CustomEvent', 'DOMException', 'DecompressionStream', 'ErrorEvent', 'Event', 'EventTarget', 'File', 'FormData',
        'Headers', 'MessageChannel', 'MessageEvent', 'MessagePort', 'Navigator', 'Performance', 'PerformanceEntry',
        'PerformanceMark', 'PerformanceMeasure', 'PerformanceObserver', 'PerformanceObserverEntryList',
        'PerformanceResourceTiming', 'ReadableByteStreamController', 'ReadableStream', 'ReadableStreamBYOBReader',
        'ReadableStreamBYOBRequest', 'ReadableStreamDefaultController', 'ReadableStreamDefaultReader', 'Request',
        'Response', 'Storage', 'SubtleCrypto', 'TextDecoder', 'TextDecoderStream', 'TextEncoder', 'TextEncoderStream',
        'TransformStream', 'TransformStreamDefaultController', 'URL', 'URLPattern', 'URLSearchParams', 'WebSocket',
        'WritableStream', 'WritableStreamDefaultController', 'WritableStreamDefaultWriter', atob, btoa, crypto, fetch,
        localStorage, navigator, performance, sessionStorage]]].

%% The getter of a lazy global: runs the bootstrap, then reads the property
%% that it defined.
-spec global_get(binary()) -> term().
global_get(Name) ->
    ensure(),
    G = {'$o', 'globalThis'},
    case buoy_heap:get_own(G, Name) of
        {accessor, {'$f', {builtin, <<"node:", _/binary>>}, _}, _, _} ->
            %% The bootstrap did not define it: the list lacks the id that does.
            _ = buoy_heap:delete_property(G, Name),
            undefined;
        _ ->
            buoy_heap:get(G, Name)
    end.

is_lazy(Name) ->
    case buoy_heap:get_own({'$o', 'globalThis'}, Name) of
        {accessor, {'$f', {builtin, <<"node:", _/binary>>}, _}, _, _} -> true;
        _ -> false
    end.

%% The setter of a lazy global: the program's value replaces it.
-spec global_set(binary(), term()) -> undefined.
global_set(Name, Value) ->
    buoy_heap:define({'$o', 'globalThis'}, Name, #{value => Value, writable => true, enumerable => true, configurable => true}),
    undefined.

%% setInternalLoaders of the builtins binding: realm.js hands over its
%% internalBinding and requireBuiltin.
-spec set_loaders(term(), term()) -> ok.
set_loaders(InternalBinding, Require) ->
    erlang:put(?LOADERS, {InternalBinding, Require}),
    ok.

-spec loaders() -> {term(), term()}.
loaders() -> erlang:get(?LOADERS).

%%% Bindings

%% internalBinding(Name): the binding object of this realm.
-spec binding(term()) -> term().
binding(Name) ->
    Cache = case erlang:get(?BINDINGS) of
        undefined -> #{};
        C -> C
    end,
    case Cache of
        #{Name := Binding} ->
            Binding;
        _ ->
            Binding = case binding_module(Name) of
                {stub, Stub} -> buoy_node_stubs:binding(Stub);
                Module -> Module:binding()
            end,
            erlang:put(?BINDINGS, Cache#{Name => Binding}),
            Binding
    end.

binding_module(Name) when is_binary(Name) ->
    case lists:member(Name, (index()):bindings()) of
        true -> binary_to_atom(<<"buoy_binding_", Name/binary>>);
        false ->
            case buoy_node_stubs:has(Name) of
                true -> {stub, Name};
                false -> no_binding(Name)
            end
    end;
binding_module(Name) ->
    no_binding(buoy_ref:to_string(Name)).

-spec no_binding(term()) -> no_return().
no_binding(Name) ->
    throw_code('Error', <<"ERR_INVALID_MODULE">>, buoy_ref_string:concat([<<"No such binding: ">>, Name])).

%%% Helpers for the bindings

%% A function with a name and a length, whose Fun takes (This, Args).
-spec fn(binary(), non_neg_integer(), fun((term(), list()) -> term())) -> term().
fn(Name, Length, Fun) -> buoy_heap:function(Fun, Name, Length, #{}).

%% A function with a prototype object, as a class or a C++ FunctionTemplate
%% gives: Fun takes (This, Args) for a call and for new.
-spec constructor(binary(), non_neg_integer(), fun((term(), list()) -> term())) -> term().
constructor(Name, Length, Fun) ->
    %% kind normal makes `new F` and `class extends F` construct a this from new.target.
    F = buoy_heap:function(Fun, Name, Length, #{kind => normal}),
    Proto = object([]),
    buoy_heap:define(Proto, <<"constructor">>, #{value => F, writable => true, enumerable => false, configurable => true}),
    buoy_heap:define(F, <<"prototype">>, #{value => Proto, writable => true, enumerable => false, configurable => false}),
    F.

%% The JavaScript value of JSON text, with the keys of each object in order.
-spec from_json(binary()) -> term().
from_json(Text) ->
    Push = fun(Key, Value, Acc) -> [{Key, Value} | Acc] end,
    Finish = fun(Acc, Old) -> {{pairs, lists:reverse(Acc)}, Old} end,
    {Term, ok, <<>>} = json:decode(Text, ok, #{object_push => Push, object_finish => Finish}),
    js(Term).

js({pairs, Pairs}) -> object([{buoy_ref_string:from_utf8(K), js(V)} || {K, V} <- Pairs]);
js(List) when is_list(List) -> buoy_heap:new_array([js(V) || V <- List]);
js(Text) when is_binary(Text) -> buoy_ref_string:from_utf8(Text);
js(null) -> null;
js(Other) -> Other.

%% A function of the binding Binding that Buoy does not implement yet: it
%% throws ERR_BUOY_NOT_IMPLEMENTED when called.
-spec not_implemented(binary(), binary()) -> term().
not_implemented(Binding, Name) ->
    Message = <<"internalBinding('", Binding/binary, "').", Name/binary, " is not implemented on Buoy">>,
    buoy_heap:function(fun(_, _) -> missing(Message) end, Name, 0, #{}).

%% A class of the binding Binding that Buoy does not implement yet: it throws
%% ERR_BUOY_NOT_IMPLEMENTED when called or constructed.
-spec missing_constructor(binary(), binary(), non_neg_integer()) -> term().
missing_constructor(Binding, Name, Length) ->
    Message = <<"internalBinding('", Binding/binary, "').", Name/binary, " is not implemented on Buoy">>,
    constructor(Name, Length, fun(_, _) -> missing(Message) end).

-spec missing(binary()) -> no_return().
missing(Message) -> throw_code('Error', <<"ERR_BUOY_NOT_IMPLEMENTED">>, Message).

%% getLinkedBinding(name): Buoy links no native module.
-spec linked_binding(term(), list()) -> no_return().
linked_binding(_This, Args) ->
    throw_code('Error', <<"ERR_INVALID_MODULE">>, buoy_ref_string:concat([<<"No such binding: ">>, buoy_ref:to_string(buoy_ref_realm:arg(1, Args))])).

%% The pairs of not_implemented/2 for each name of Names.
-spec stubs(binary(), [binary()]) -> [{binary(), term()}].
stubs(Binding, Names) -> [{N, not_implemented(Binding, N)} || N <- Names].

-spec arg(pos_integer(), list()) -> term().
arg(N, Args) -> buoy_ref_realm:arg(N, Args).

%% An ordinary object with the properties Pairs, in order.
-spec object([{term(), term()}]) -> term().
object(Pairs) -> buoy_heap:object(?OBJECT_PROTO, Pairs).

-spec object(term(), [{term(), term()}]) -> term().
object(Proto, Pairs) -> buoy_heap:object(Proto, Pairs).

%% A new typed array of the global constructor Kind, such as <<"Float64Array">>,
%% with Length elements.
-spec typed_array(binary(), non_neg_integer()) -> term().
typed_array(Kind, Length) ->
    Constructor = buoy_ref_realm:global(Kind),
    buoy_heap:construct(Constructor, [Length], Constructor).

%% A JavaScript string from UTF-8 text.
-spec string(unicode:chardata()) -> term().
string(Text) -> buoy_ref_string:from_utf8(unicode:characters_to_binary(Text)).

%% A new symbol with the description Text.
-spec symbol(binary()) -> term().
symbol(Text) -> buoy_heap:symbol(Text).

%% Throws a new error of the class Name with Node's code property.
-spec throw_code(atom(), binary(), term()) -> no_return().
throw_code(Name, Code, Message) ->
    E = buoy_heap:error_object(Name, Message, buoy_ref_string:concat([atom_to_binary(Name), <<": ">>, Message])),
    buoy_heap:define(E, <<"code">>, #{value => Code, writable => true, enumerable => true, configurable => true}),
    erlang:error({'$throw', E}).

-spec call(term(), term(), list()) -> term().
call(F, This, Args) -> buoy_heap:call(F, This, Args).

call_method(O, Name, Args) -> buoy_heap:call(buoy_heap:get(O, Name), O, Args).

-spec primordials() -> term().
primordials() -> erlang:get(?PRIMORDIALS).

%% The symbol of Node's private symbol Name, such as exit_info_private_symbol.
-spec private_symbol(binary()) -> term().
private_symbol(Name) ->
    {Private, _} = erlang:get(?SYMBOLS),
    buoy_heap:get(Private, Name).

%%% The symbols of env_properties.h

symbols(Names) -> buoy_heap:object(null, [{N, symbol(D)} || {N, D} <- Names]).

%% The per-isolate symbols, keyed by their descriptions, as the symbols
%% binding has them.
-spec per_isolate_symbols() -> [{term(), term()}].
per_isolate_symbols() ->
    {_, PerIsolate} = erlang:get(?SYMBOLS),
    [{D, buoy_heap:get(PerIsolate, N)} || {N, D} <- per_isolate_symbol_names()].

%% The private symbols, keyed by their names, as the util binding has them.
-spec private_symbols() -> term().
private_symbols() ->
    {Private, _} = erlang:get(?SYMBOLS),
    Private.

%% The per-context exports object of this realm, which holds the primordials
%% and the classes of the per-context scripts, such as DOMException.
-spec context() -> term().
context() -> erlang:get(?CONTEXT).

private_symbol_names() ->
    [{<<"arrow_message_private_symbol">>, <<"node:arrowMessage">>},
     {<<"contextify_context_private_symbol">>, <<"node:contextify:context">>},
     {<<"decorated_private_symbol">>, <<"node:decorated">>},
     {<<"empty_context_frame_sentinel_symbol">>, <<"node:empty_context_frame_sentinel">>},
     {<<"transfer_mode_private_symbol">>, <<"node:transfer_mode">>},
     {<<"host_defined_option_symbol">>, <<"node:host_defined_option_symbol">>},
     {<<"js_transferable_wrapper_private_symbol">>, <<"node:js_transferable_wrapper">>},
     {<<"entry_point_module_private_symbol">>, <<"node:entry_point_module">>},
     {<<"entry_point_promise_private_symbol">>, <<"node:entry_point_promise">>},
     {<<"module_source_private_symbol">>, <<"node:module_source">>},
     {<<"module_export_names_private_symbol">>, <<"node:module_export_names">>},
     {<<"module_circular_visited_private_symbol">>, <<"node:module_circular_visited">>},
     {<<"module_export_private_symbol">>, <<"node:module_export">>},
     {<<"module_first_parent_private_symbol">>, <<"node:module_first_parent">>},
     {<<"module_last_parent_private_symbol">>, <<"node:module_last_parent">>},
     {<<"napi_type_tag">>, <<"node:napi:type_tag">>},
     {<<"napi_wrapper">>, <<"node:napi:wrapper">>},
     {<<"untransferable_object_private_symbol">>, <<"node:untransferableObject">>},
     {<<"exit_info_private_symbol">>, <<"node:exit_info_private_symbol">>},
     {<<"promise_trace_id">>, <<"node:promise_trace_id">>},
     {<<"source_map_data_private_symbol">>, <<"node:source_map_data_private_symbol">>}].

per_isolate_symbol_names() ->
    [{N, N} || N <- [<<"fs_use_promises_symbol">>, <<"async_id_symbol">>, <<"constructor_key_symbol">>,
                     <<"no_message_symbol">>, <<"messaging_deserialize_symbol">>, <<"imported_cjs_symbol">>,
                     <<"messaging_transfer_symbol">>, <<"messaging_clone_symbol">>,
                     <<"messaging_transfer_list_symbol">>, <<"owner_symbol">>, <<"resource_symbol">>,
                     <<"trigger_async_id_symbol">>, <<"builtin_source_text_module_hdo">>,
                     <<"embedder_module_hdo">>, <<"source_text_module_default_hdo">>,
                     <<"vm_context_no_contextify">>, <<"vm_dynamic_import_default_internal">>,
                     <<"vm_dynamic_import_main_context_default">>, <<"vm_dynamic_import_missing_flag">>,
                     <<"vm_dynamic_import_no_callback">>]]
    ++ [{<<"handle_onclose_symbol">>, <<"handle_onclose">>}, {<<"oninit_symbol">>, <<"oninit">>},
        {<<"onpskexchange_symbol">>, <<"onpskexchange">>}].
