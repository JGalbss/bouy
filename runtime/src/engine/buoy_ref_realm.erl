%% The realm setup of the reference-semantics engine: the intrinsics and the
%% global bindings of every built-in family, and the global functions.
%%
%% Every intrinsic object is a static record in persistent_term, shared by
%% all processes and read without a copy. The first realm of a process copies
%% a record into its heap only when it writes to the intrinsic, so an empty
%% realm allocates nothing. A builtin function is {'$f', {builtin, Name}, Fun}:
%% the same term in every process. The functions take (This, Args), as
%% compiled code.
%%
%% A process can hold more realms ($262.createRealm, create/0). The realm N
%% names its intrinsics {N, Id} and copies each record on first use, with
%% every intrinsic in it replaced by its twin of realm N (localize/2). The
%% current realm is the pdict key ?REALM_KEY: each builtin and each function
%% of the realm N sets it to N while it runs (realm_fun/2). Code of realm 0
%% does not set it, and pays one pdict read where it reads an intrinsic.
%%
%% A family is a module that exports intrinsics/0, the static records it
%% installs as [{Id, Record}], and globals/0, its global bindings as
%% [{Name, Value}]. Its builtin methods call its method/4, and its
%% constructors call its call_constructor/3 when called without new. To add
%% a family, write the module and list it in families/0.
-module(buoy_ref_realm).

-include("buoy_ref.hrl").

-export([install/0, global/1, set_global/3, has_binding/1, set_resolved/3, not_defined/1, declare_globals/3, declare_script/4, delete_global/1, constructor/2]).
-export([arg/2, rest/2, builtin/2, builtin/4, record/4, methods/3, ctor_record/5, not_constructible/2, callable/1]).
-export([function_record/2, proto_for/2, primordial/2]).
-export([declare_block_functions/3, set_block_function/3]).
-export([create/0, function_realm/1, realm_fun/2, callee/1, localize/2, current/1, global_object/0]).
-export([intrinsics/0, globals/0, method/4]).

families() ->
    [buoy_ref_object,
     buoy_ref_function,
     buoy_ref_boolean,
     buoy_ref_symbol,
     buoy_ref_error,
     buoy_ref_number,
     buoy_ref_math,
     buoy_ref_bigint,
     buoy_ref_string,
     buoy_ref_regexp,
     buoy_ref_array,
     buoy_ref_buffer,
     buoy_ref_typed_array,
     buoy_ref_atomics,
     buoy_ref_iterator,
     buoy_ref_iterator_prototype,
     buoy_ref_generator,
     buoy_ref_dispose,
     buoy_ref_collection,
     buoy_ref_promise,
     buoy_ref_json,
     buoy_ref_date,
     buoy_ref_console,
     buoy_ref_reflect,
     buoy_ref_proxy,
     buoy_ref_weak,
     buoy_ref_shadow_realm,
     buoy_ref_module_source,
     buoy_ref_eval,
     buoy_ref_temporal,
     buoy_ref_intl,
     buoy_ref_intl_collator,
     buoy_ref_intl_locale,
     buoy_ref_intl_plural_rules,
     ?MODULE].

%%% Installation

%% Installs the static intrinsics once per VM, and again after a family
%% module changes.
-spec install() -> ok.
install() ->
    Version = erlang:md5(term_to_binary([M:module_info(md5) || M <- families()])),
    case persistent_term:get({?MODULE, installed}, undefined) of
        Version ->
            ok;
        _ ->
            %% The static records hold the intrinsics of realm 0.
            Realm = erlang:erase(?REALM_KEY),
            [buoy_heap:install_intrinsic(Id, Record) || M <- families(), {Id, Record} <- M:intrinsics()],
            Globals = lists:append([M:globals() || M <- families()]),
            buoy_heap:install_intrinsic('globalThis', global_record(Globals)),
            %% An accessor global, such as process, reads through the global object.
            persistent_term:put({?MODULE, globals}, maps:from_list([G || {_, _} = G <- Globals])),
            persistent_term:put({?MODULE, installed}, Version),
            Realm =:= undefined orelse erlang:put(?REALM_KEY, Realm)
    end,
    ok.

%%% Realms

%% A new realm in this process: its global object.
-spec create() -> term().
create() ->
    N = case erlang:get('$buoy_realms') of
        undefined -> 1;
        Last -> Last + 1
    end,
    erlang:put('$buoy_realms', N),
    buoy_heap:intrinsic(N, 'globalThis').

%% The global object of the current realm.
-spec global_object() -> term().
global_object() -> buoy_heap:intrinsic('globalThis').

%% A record of realm 0 for the realm N: each intrinsic in it becomes its twin
%% of realm N, and each builtin function and construct fun runs in realm N.
%% Function.prototype returns undefined in every realm, so its fun stays.
-spec localize(pos_integer(), term()) -> term().
localize(N, {'$o', Id}) when is_atom(Id) -> {'$o', {N, Id}};
localize(N, {'$f', Id, Fun}) when is_atom(Id) -> {'$f', {N, Id}, Fun};
localize(N, {'$f', {builtin, _} = Id, Fun}) -> {'$f', {N, Id}, realm_fun(N, Fun)};
localize(N, M) when is_map(M) ->
    maps:map(fun(construct, F) when is_function(F, 2) -> realm_fun(N, F);
                (_, V) -> localize(N, V)
             end, M);
localize(N, T) when is_tuple(T) -> list_to_tuple([localize(N, E) || E <- tuple_to_list(T)]);
localize(N, L) when is_list(L) -> [localize(N, E) || E <- L];
localize(_N, V) -> V.

%% The twin of V, a value of realm 0, in the current realm.
-spec current(term()) -> term().
current(V) ->
    case buoy_heap:realm() of
        0 -> V;
        N -> localize(N, V)
    end.

%% Fun as a function of the realm N: the current realm is N while it runs.
%% Two wraps of one fun are equal terms, so a builtin keeps its identity.
%% shortcut: a function of realm 0 that a builtin of another realm calls back
%% runs in that realm, and so does the continuation of an async function of
%% another realm after an await; a fix would set the realm in every call of
%% compiled code and in every job.
-spec realm_fun(non_neg_integer(), fun((term(), term()) -> term())) -> fun((term(), term()) -> term()).
realm_fun(N, Fun) -> fun(A, B) -> in_realm(N, Fun, A, B) end.

in_realm(N, Fun, A, B) ->
    case erlang:get(?REALM_KEY) of
        N -> Fun(A, B);
        undefined when N =:= 0 -> Fun(A, B);
        Outer -> enter(N), try Fun(A, B) after enter(Outer) end
    end.

enter(N) when N =:= 0; N =:= undefined -> erlang:erase(?REALM_KEY);
enter(N) -> erlang:put(?REALM_KEY, N).

%% F as a builtin calls user code with it, such as a Proxy trap: in the realm
%% of F. A function of realm N > 0 sets its realm itself, so only one of
%% realm 0 needs it, while another realm is current.
-spec callee(term()) -> term().
callee({'$f', Id, Fun} = F) ->
    case erlang:get(?REALM_KEY) =/= undefined andalso buoy_heap:class_of(F) =/= proxy andalso function_realm(F) =:= 0 of
        true -> {'$f', Id, realm_fun(0, Fun)};
        false -> F
    end.

%% GetFunctionRealm: the realm of a function. A proxy and a bound function
%% take the realm of their target, and a revoked proxy has none.
-spec function_realm(term()) -> non_neg_integer().
function_realm({'$f', {N, _}, _}) when is_integer(N) ->
    N;
function_realm({'$f', Id, _} = F) when is_integer(Id) ->
    case {buoy_heap:class_of(F), buoy_heap:slots(F)} of
        {proxy, {revoked, _}} -> buoy_ref:type_error(<<"Cannot get the realm of a revoked proxy">>);
        {proxy, {Target, _}} -> function_realm(Target);
        {_, #{kind := bound, target := Target}} -> function_realm(Target);
        {_, #{realm := N}} -> N;
        _ -> 0
    end;
function_realm(_) ->
    0.

%% The global object: each global binding is a writable, configurable, and
%% non-enumerable property, except undefined, NaN, and Infinity, which are
%% read-only and non-configurable.
global_record(Globals) ->
    {Class, Proto, Props, Keys, Attrs, Slots} = record(object, ?OBJECT_PROTO, Globals, none),
    Fixed = maps:from_list([{K, 0} || K <- [<<"undefined">>, <<"NaN">>, <<"Infinity">>], is_map_key(K, Props)]),
    {Class, Proto, Props, Keys, maps:merge(Attrs, Fixed), Slots}.

%% The global declarative record of the realm (ECMA-262 §9.1.1.4): the
%% top-level let, const, and class of its scripts, by name. Each holds the
%% key of the module variable of its script, {v, Value} once initialized,
%% and whether it is mutable: a const is immutable.
-define(LEXICAL, '$buoy_lexical').

%% The key of the global declarative record of the current realm.
lexical_key() ->
    case erlang:get(?REALM_KEY) of
        undefined -> ?LEXICAL;
        N -> {?LEXICAL, N}
    end.

%% The value of an identifier that no scope declares: a binding of the
%% global declarative record, else a property of the global object, up its
%% prototype chain, else a ReferenceError. A realm that has not written to
%% its global object reads the static bindings.
-spec global(binary()) -> term().
global(Name) ->
    case erlang:get(lexical_key()) of
        #{Name := Binding} -> lexical_value(Name, Binding);
        _ -> global_object_value(Name)
    end.

global_object_value(Name) ->
    case erlang:get('globalThis') =:= undefined andalso erlang:get(?REALM_KEY) =:= undefined of
        true ->
            case persistent_term:get({?MODULE, globals}) of
                #{Name := V} -> V;
                _ -> global_slow(Name)
            end;
        false ->
            global_slow(Name)
    end.

lexical_value(Name, {Key, _Kind}) ->
    case erlang:get(Key) of
        {v, V} -> V;
        _ -> buoy_ref:tdz_error(Name)
    end.

%% The ReferenceError of a name that no environment binds.
-spec not_defined(buoy_ref_string:js_string()) -> no_return().
not_defined(Name) ->
    buoy_heap:throw_error('ReferenceError', buoy_ref_string:concat(Name, <<" is not defined">>)).

%% HasBinding of the global environment: the declarative record, then the
%% global object.
-spec has_binding(binary()) -> boolean().
has_binding(Name) ->
    case erlang:get(lexical_key()) of
        #{Name := _} -> true;
        _ -> buoy_heap:has(global_object(), Name)
    end.

%% `name = value` in strict code for a name that no scope declares, which
%% Resolved says the global environment had before the value ran: an
%% unresolvable reference is a ReferenceError (PutValue, §6.2.5.6).
-spec set_resolved(binary(), term(), boolean()) -> term().
set_resolved(Name, Value, true) -> set_global(Name, Value, strict);
set_resolved(Name, _Value, false) -> not_defined(Name).

%% Global.Key as the runtime installed it, whatever a program wrote since:
%% the static record of the standard global Global holds the original data
%% property, which internal code reads (EvalContext internal, such as
%% Math.sign in the Temporal polyfill). An accessor, or a key that the record
%% does not hold, reads the current value.
-spec primordial(binary(), term()) -> term().
primordial(Global, Key) ->
    Static = case persistent_term:get({?MODULE, globals}) of
        #{Global := V} -> static_props(V);
        _ -> #{}
    end,
    case Static of
        #{Key := {'$accessor', _, _}} -> buoy_heap:get(global(Global), Key);
        #{Key := {'$live', _}} -> buoy_heap:get(global(Global), Key);
        #{Key := Value} -> current(Value);
        _ -> buoy_heap:get(global(Global), Key)
    end.

static_props({'$o', Id}) when is_atom(Id) -> record_props(persistent_term:get({buoy_heap, Id}, undefined));
static_props({'$f', {builtin, _} = Id, _}) -> record_props(persistent_term:get({buoy_heap, Id}, undefined));
static_props(_) -> #{}.

record_props({_Class, _Proto, Props, _Keys, _Attrs, _Slots}) when is_map(Props) -> Props;
record_props(_) -> #{}.

global_slow(Name) ->
    G = global_object(),
    case buoy_heap:has(G, Name) of
        true -> buoy_heap:get(G, Name);
        false -> not_defined(Name)
    end.

%% `name = value` for an identifier that no scope declares: a binding of the
%% global declarative record, else the global object. Strict code throws a
%% ReferenceError when the global object lacks the name; sloppy code creates
%% the property.
-spec set_global(binary(), term(), strict | sloppy) -> term().
set_global(Name, Value, Mode) ->
    case erlang:get(lexical_key()) of
        #{Name := Binding} -> set_lexical(Name, Value, Binding);
        _ -> set_global_object(Name, Value, Mode)
    end.

set_global_object(Name, Value, Mode) ->
    G = global_object(),
    case Mode =:= sloppy orelse buoy_heap:has(G, Name) of
        true -> set_in_mode(G, Name, Value, Mode);
        false -> not_defined(Name)
    end.

%% SetMutableBinding of the declarative record: a const binding is
%% immutable in sloppy code too.
set_lexical(Name, Value, {Key, Kind}) ->
    case {erlang:get(Key), Kind} of
        {{v, _}, mutable} -> erlang:put(Key, {v, Value}), Value;
        {{v, _}, immutable} -> buoy_heap:throw_error('TypeError', <<"Assignment to constant variable.">>);
        _ -> buoy_ref:tdz_error(Name)
    end.

%% GlobalDeclarationInstantiation of a script (§16.1.7) that declares the
%% let, const, and class names Lexicals in Module: a SyntaxError
%% when a name is already lexical or a non-configurable property of the
%% global object, or when a var name or function is lexical. Then the var
%% names and functions as declare_globals makes them, and the lexical names,
%% uninitialized until the script declares them.
-spec declare_script(module(), [{binary(), mutable | immutable}], [binary()], [{binary(), term()}]) -> ok.
declare_script(Module, Lexicals, Vars, Functions) ->
    G = global_object(),
    Lexical = lexical_record(),
    lists:foreach(fun({Name, _}) ->
                          case is_map_key(Name, Lexical) orelse is_restricted(buoy_heap:get_own(G, Name)) of
                              true -> redeclared(Name);
                              false -> ok
                          end
                  end, Lexicals),
    declare_globals(Vars, Functions, false),
    Declared = maps:from_list([{Name, {{'$m', Module, Name}, Kind}} || {Name, Kind} <- Lexicals]),
    erlang:put(lexical_key(), maps:merge(Lexical, Declared)),
    ok.

lexical_record() ->
    case erlang:get(lexical_key()) of
        undefined -> #{};
        Lexical -> Lexical
    end.

%% HasRestrictedGlobalProperty: a non-configurable own property.
is_restricted({data, _, Bits}) -> Bits band 4 =:= 0;
is_restricted({accessor, _, _, Bits}) -> Bits band 4 =:= 0;
is_restricted(none) -> false.

-spec redeclared(binary()) -> no_return().
redeclared(Name) ->
    buoy_heap:throw_error('SyntaxError', buoy_ref_string:concat([<<"Identifier '">>, Name, <<"' has already been declared">>])).

%% GlobalDeclarationInstantiation of a script (ECMA-262 §16.1.7): each `var`
%% name that the global object lacks becomes a property, and each function a
%% property with its value. Both are writable and enumerable, and
%% configurable only for eval code (EvalDeclarationInstantiation).
-spec declare_globals([binary()], [{binary(), term()}], boolean()) -> ok.
declare_globals(Vars, Functions, Configurable) ->
    G = global_object(),
    Lexical = lexical_record(),
    lists:foreach(fun(Name) ->
                          case is_map_key(Name, Lexical) of
                              true -> redeclared(Name);
                              false -> ok
                          end
                  end, [Name || {Name, _} <- Functions] ++ Vars),
    %% CanDeclareGlobalFunction and CanDeclareGlobalVar: nothing is declared
    %% when one name cannot be.
    lists:foreach(fun({Name, _}) ->
                          case can_declare_function(buoy_heap:get_own(G, Name)) of
                              true -> ok;
                              false -> buoy_heap:throw_error('TypeError', buoy_ref_string:concat(<<"Cannot redefine global function ">>, Name))
                          end
                  end, Functions),
    lists:foreach(fun(Name) ->
                          case buoy_heap:has_own(G, Name) orelse buoy_heap:is_extensible(G) of
                              true -> ok;
                              false -> buoy_heap:throw_error('TypeError', buoy_ref_string:concat(<<"Cannot define global variable ">>, Name))
                          end
                  end, Vars),
    lists:foreach(fun({Name, F}) ->
                          Desc = case buoy_heap:get_own(G, Name) of
                              {_, _, _, Bits} when Bits band 4 =:= 0 -> #{value => F};
                              {_, _, Bits} when Bits band 4 =:= 0 -> #{value => F};
                              _ -> #{value => F, writable => true, enumerable => true, configurable => Configurable}
                          end,
                          buoy_heap:define(G, Name, Desc)
                  end, Functions),
    lists:foreach(fun(Name) ->
                          case buoy_heap:has_own(G, Name) of
                              true -> ok;
                              false -> buoy_heap:define(G, Name, #{value => undefined, writable => true, enumerable => true, configurable => Configurable})
                          end
                  end, Vars).

%% Annex B.3.3.2 and B.3.3.3 for the block functions Names of the script or
%% the eval code Module: a name that no global lexical binding has and that the
%% global object can take becomes a property, undefined until its declaration
%% runs, configurable only for eval code; the others stay as they are, and their
%% declarations set nothing.
-spec declare_block_functions(module(), [binary()], boolean()) -> ok.
declare_block_functions(Module, Names, Configurable) ->
    G = global_object(),
    Lexical = lexical_record(),
    Definable = [Name || Name <- Names,
                         not is_map_key(Name, Lexical),
                         buoy_heap:has_own(G, Name) orelse buoy_heap:is_extensible(G)],
    lists:foreach(fun(Name) ->
                          buoy_heap:has_own(G, Name) orelse
                              buoy_heap:define(G, Name, #{value => undefined, writable => true, enumerable => true, configurable => Configurable})
                  end, Definable),
    erlang:put({'$buoy_block_functions', Module}, Definable),
    ok.

%% The declaration of a block function of the script Module runs: the global
%% takes its value, when the script could declare it.
-spec set_block_function(module(), binary(), term()) -> term().
set_block_function(Module, Name, Value) ->
    Definable = case erlang:get({'$buoy_block_functions', Module}) of
        undefined -> [];
        Names -> Names
    end,
    case lists:member(Name, Definable) of
        true -> set_in_mode(global_object(), Name, Value, sloppy);
        false -> Value
    end.

%% A function may replace a configurable global, or a writable and
%% enumerable data property, or define a new one on an extensible global.
can_declare_function(none) -> buoy_heap:is_extensible(global_object());
can_declare_function({data, _, Bits}) -> Bits band 4 =/= 0 orelse Bits band 3 =:= 3;
can_declare_function({accessor, _, _, Bits}) -> Bits band 4 =/= 0.

%% `delete name` in sloppy code for a global: false for a binding of the
%% declarative record.
-spec delete_global(binary()) -> boolean().
delete_global(Name) ->
    case erlang:get(lexical_key()) of
        #{Name := _} -> false;
        _ -> buoy_heap:delete_property(global_object(), Name)
    end.

set_in_mode(G, Name, Value, strict) -> buoy_heap:set(G, Name, Value);
set_in_mode(G, Name, Value, sloppy) -> _ = buoy_heap:set(G, Name, Value, G), Value.

%%% Builders for the intrinsics of a family

%% The value of the builtin constructor Name: its record holds the construct
%% fun, and a call without new goes to Module:call_constructor/3.
-spec constructor(module(), binary()) -> term().
constructor(Module, Name) -> {'$f', {builtin, Name}, fun(This, Args) -> Module:call_constructor(Name, This, Args) end}.

-spec builtin(binary(), fun((term(), list()) -> term())) -> term().
builtin(Name, Fun) -> {'$f', {builtin, Name}, Fun}.

%% A record whose properties are builtin data: an entry {Key, Value} is
%% writable, configurable, and not enumerable, and {Key, Value, Bits} has the
%% attribute bits of buoy_heap (writable 1, enumerable 2, configurable 4).
-spec record(atom(), term(), [{term(), term()} | {term(), term(), 0..7}], term()) -> tuple().
record(Class, Proto, Entries, Slots) ->
    Triples = [entry(E) || E <- Entries],
    Props = maps:from_list([{K, V} || {K, V, _} <- Triples]),
    Keys = lists:reverse([K || {K, _, _} <- Triples, not is_integer(K)]),
    Attrs = maps:from_list([{K, Bits} || {K, _, Bits} <- Triples, Bits =/= 7]),
    {Class, Proto, Props, Keys, Attrs, Slots}.

entry({K, V}) -> {K, V, ?HIDDEN};
entry({_, _, _} = E) -> E.

%% The builtin methods of Owner. A name is a binary, or {Name, Length} for a
%% method that gets the name and length properties of a builtin function.
-spec methods(module(), binary(), [binary() | {binary(), non_neg_integer()}]) -> [{binary(), term()}].
methods(Module, Owner, Names) -> [method_entry(Module, Owner, N) || N <- Names].

method_entry(Module, Owner, {Name, Length}) ->
    {Name, builtin(<<Owner/binary, ".", Name/binary>>, Name, Length, fun(This, Args) -> Module:method(Owner, Name, This, Args) end)};
method_entry(Module, Owner, Name) ->
    {Name, builtin(<<Owner/binary, ".", Name/binary>>, fun(This, Args) -> Module:method(Owner, Name, This, Args) end)}.

%% The builtin Id with the name and length properties of CreateBuiltinFunction.
%% Families call it while the realm installs, so the record is in place before
%% any realm reads it.
-spec builtin(binary(), term(), non_neg_integer(), fun((term(), list()) -> term())) -> term().
builtin(Id, Name, Length, Fun) ->
    buoy_heap:install_intrinsic({builtin, Id}, function_record(Name, Length)),
    builtin(Id, Fun).

%% The record of a builtin function: length, then name, both configurable only.
-spec function_record(term(), non_neg_integer()) -> tuple().
function_record(Name, Length) ->
    record(function, ?FUNCTION_PROTO, [{<<"length">>, Length, 4}, {<<"name">>, Name, 4}], #{}).

-spec ctor_record(binary(), non_neg_integer(), term(), [tuple()], fun((term(), list()) -> term())) -> tuple().
ctor_record(Name, Length, Proto, Statics, Construct) ->
    Entries = [{<<"length">>, Length, 4}, {<<"name">>, Name, 4}, {<<"prototype">>, Proto, 0} | Statics],
    record(function, ?FUNCTION_PROTO, Entries, #{construct => Construct, kind => builtin}).

%% GetPrototypeFromConstructor: the prototype property of NewTarget, or the
%% intrinsic Default of the realm of NewTarget when it is not an object.
-spec proto_for(term(), atom()) -> term().
proto_for(NewTarget, Default) ->
    case buoy_ref:get(NewTarget, <<"prototype">>) of
        P when ?IS_OBJECT(P) -> P;
        _ -> buoy_heap:intrinsic(function_realm(NewTarget), Default)
    end.

%% The [[Construct]] of a builtin that new does not support, such as new String().
-spec not_constructible(term(), list()) -> no_return().
not_constructible({'$f', {N, Id}, F}, Args) when is_integer(N) -> not_constructible({'$f', Id, F}, Args);
not_constructible({'$f', {builtin, <<"Symbol">>}, _}, _Args) -> buoy_ref:type_error(<<"Symbol is not a constructor">>);
not_constructible({'$f', {builtin, <<"Function">>}, _}, _Args) -> buoy_ref:type_error(<<"Function() is not supported">>);
not_constructible({'$f', {builtin, Name}, _}, _Args) -> buoy_ref:type_error(<<"new ", Name/binary, "() is not supported">>);
not_constructible(_NewTarget, _Args) -> buoy_ref:type_error(<<"not a constructor">>).

%%% Arguments

-spec arg(pos_integer(), list()) -> term().
arg(1, [V | _]) -> V;
arg(N, [_ | Rest]) when N > 1 -> arg(N - 1, Rest);
arg(_, _) -> undefined.

-spec rest(pos_integer(), list()) -> list().
rest(1, Args) -> Args;
rest(N, [_ | Rest]) when N > 1 -> rest(N - 1, Rest);
rest(_, []) -> [].

%% A callback argument: a TypeError unless it is callable.
-spec callable(term()) -> term().
callable(F) ->
    buoy_heap:is_callable(F) orelse buoy_ref:type_error(buoy_ref_string:concat(buoy_ref:describe(F), <<" is not a function">>)),
    F.

%%% The global object and the global functions

%% The global object is not here: install/0 builds it from the globals of
%% every family. A second record here would race with that one when two
%% realms install at once.
-spec intrinsics() -> [{term(), tuple()}].
intrinsics() -> [].

-spec globals() -> [{binary(), term()} | {binary(), term(), 0..7}].
globals() ->
    [{<<"globalThis">>, {'$o', 'globalThis'}}, {<<"undefined">>, undefined}]
    ++ ?METHODS(<<"globalThis">>, [{<<"setTimeout">>, 2}, {<<"setInterval">>, 2}, {<<"clearTimeout">>, 1},
                                   {<<"clearInterval">>, 1}, {<<"queueMicrotask">>, 1}, {<<"structuredClone">>, 2}])
    ++ [node_global(Name) || Name <- buoy_node:lazy_globals()].

%% A global of Node, such as process: an accessor that runs Node's bootstrap
%% on first use (buoy_node), configurable and not enumerable.
node_global(Name) ->
    Get = builtin(<<"node:get ", Name/binary>>, <<"get ", Name/binary>>, 0, fun(_This, _Args) -> buoy_node:global_get(Name) end),
    Set = builtin(<<"node:set ", Name/binary>>, <<"set ", Name/binary>>, 1, fun(_This, Args) -> buoy_node:global_set(Name, arg(1, Args)) end),
    {Name, {'$accessor', Get, Set}, 4}.

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"globalThis">>, <<"setTimeout">>, This, Args) -> node_timer(<<"setTimeout">>, This, Args);
method(<<"globalThis">>, <<"setInterval">>, This, Args) -> node_timer(<<"setInterval">>, This, Args);
method(<<"globalThis">>, <<"clearTimeout">>, This, Args) -> node_clear(<<"clearTimeout">>, This, Args);
method(<<"globalThis">>, <<"clearInterval">>, This, Args) -> node_clear(<<"clearInterval">>, This, Args);
method(<<"globalThis">>, <<"queueMicrotask">>, _This, Args) ->
    F = arg(1, Args),
    buoy_heap:is_callable(F) orelse buoy_ref:type_error(<<"The \"callback\" argument must be of type function">>),
    buoy_jobs:enqueue(fun() -> buoy_ref:call(F, undefined, []) end),
    undefined;
method(<<"globalThis">>, <<"structuredClone">>, _This, Args) -> buoy_heap:clone_in(buoy_heap:clone_out(arg(1, Args))).

%% The timers are Node's: the first setTimeout or setInterval runs Node's
%% bootstrap, which replaces these globals, and goes on with Node's function,
%% so a timer is a Timeout with ref, unref, and refresh, as in Node. While the
%% bootstrap runs, the timer is the realm's own.
node_timer(Name, This, Args) ->
    buoy_node:ensure(),
    case buoy_heap:get({'$o', 'globalThis'}, Name) of
        {'$f', {builtin, <<"globalThis.", Name/binary>>}, _} ->
            buoy_jobs:set_timer(arg(1, Args), arg(2, Args), rest(3, Args), Name =:= <<"setInterval">>);
        F ->
            buoy_heap:call(F, This, Args)
    end.

%% Before the bootstrap no timer of Node exists, so there is none to clear.
node_clear(Name, This, Args) ->
    case buoy_node:ready() andalso buoy_heap:get({'$o', 'globalThis'}, Name) of
        false -> buoy_jobs:clear_timer(arg(1, Args));
        {'$f', {builtin, <<"globalThis.", Name/binary>>}, _} -> buoy_jobs:clear_timer(arg(1, Args));
        F -> buoy_heap:call(F, This, Args)
    end.
