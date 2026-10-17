%% The realm setup of the reference-semantics engine: the intrinsics and the
%% global bindings of every built-in family, and the global functions.
%%
%% Every intrinsic object is a static record in persistent_term, shared by
%% all realms and read without a copy. A realm copies a record into its heap
%% only when it writes to the intrinsic, so an empty realm allocates nothing.
%% A builtin function is {'$f', {builtin, Name}, Fun}: the same term in every
%% realm. The functions take (This, Args), as compiled code.
%%
%% A family is a module that exports intrinsics/0, the static records it
%% installs as [{Id, Record}], and globals/0, its global bindings as
%% [{Name, Value}]. Its builtin methods call its method/4, and its
%% constructors call its call_constructor/3 when called without new. To add
%% a family, write the module and list it in families/0.
-module(bouy_ref_realm).

-include("bouy_ref.hrl").

-export([install/0, global/1, set_global/3, declare_globals/3, delete_global/1, constructor/2]).
-export([arg/2, rest/2, builtin/2, builtin/4, record/4, methods/3, ctor_record/5, not_constructible/2, callable/1]).
-export([intrinsics/0, globals/0, method/4]).

families() ->
    [bouy_ref_object,
     bouy_ref_function,
     bouy_ref_boolean,
     bouy_ref_symbol,
     bouy_ref_error,
     bouy_ref_number,
     bouy_ref_math,
     bouy_ref_bigint,
     bouy_ref_string,
     bouy_ref_regexp,
     bouy_ref_array,
     bouy_ref_iterator,
     bouy_ref_collection,
     bouy_ref_promise,
     bouy_ref_json,
     bouy_ref_date,
     bouy_ref_console,
     bouy_ref_reflect,
     bouy_ref_proxy,
     bouy_ref_weak,
     bouy_ref_eval,
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
            [bouy_heap:install_intrinsic(Id, Record) || M <- families(), {Id, Record} <- M:intrinsics()],
            Globals = lists:append([M:globals() || M <- families()]),
            bouy_heap:install_intrinsic('globalThis', global_object(Globals)),
            persistent_term:put({?MODULE, globals}, maps:from_list(Globals)),
            persistent_term:put({?MODULE, installed}, Version)
    end,
    ok.

%% The global object: each global binding is a writable, configurable, and
%% non-enumerable property, except undefined, NaN, and Infinity, which are
%% read-only and non-configurable.
global_object(Globals) ->
    {Class, Proto, Props, Keys, Attrs, Slots} = record(object, ?OBJECT_PROTO, Globals, none),
    Fixed = maps:from_list([{K, 0} || K <- [<<"undefined">>, <<"NaN">>, <<"Infinity">>], is_map_key(K, Props)]),
    {Class, Proto, Props, Keys, maps:merge(Attrs, Fixed), Slots}.

%% The value of an identifier that no scope declares: a property of the
%% global object, up its prototype chain, else a ReferenceError. A realm
%% that has not written to its global object reads the static bindings.
-spec global(binary()) -> term().
global(Name) ->
    case erlang:get('globalThis') of
        undefined ->
            case persistent_term:get({?MODULE, globals}) of
                #{Name := V} -> V;
                _ -> global_slow(Name)
            end;
        _ ->
            global_slow(Name)
    end.

global_slow(Name) ->
    G = {'$o', 'globalThis'},
    case bouy_heap:has(G, Name) of
        true -> bouy_heap:get(G, Name);
        false -> bouy_heap:throw_error('ReferenceError', bouy_ref_string:concat(Name, <<" is not defined">>))
    end.

%% `name = value` for an identifier that no scope declares. Strict code
%% throws a ReferenceError when the global object lacks the name; sloppy
%% code creates the property.
-spec set_global(binary(), term(), strict | sloppy) -> term().
set_global(Name, Value, Mode) ->
    G = {'$o', 'globalThis'},
    case Mode =:= sloppy orelse bouy_heap:has(G, Name) of
        true -> set_in_mode(G, Name, Value, Mode);
        false -> bouy_heap:throw_error('ReferenceError', bouy_ref_string:concat(Name, <<" is not defined">>))
    end.

%% GlobalDeclarationInstantiation of a script (ECMA-262 §16.1.7): each `var`
%% name that the global object lacks becomes a property, and each function a
%% property with its value. Both are writable and enumerable, and
%% configurable only for eval code (EvalDeclarationInstantiation).
-spec declare_globals([binary()], [{binary(), term()}], boolean()) -> ok.
declare_globals(Vars, Functions, Configurable) ->
    G = {'$o', 'globalThis'},
    lists:foreach(fun({Name, F}) ->
                          Desc = case bouy_heap:get_own(G, Name) of
                              {_, _, _, Bits} when Bits band 4 =:= 0 -> #{value => F};
                              {_, _, Bits} when Bits band 4 =:= 0 -> #{value => F};
                              _ -> #{value => F, writable => true, enumerable => true, configurable => Configurable}
                          end,
                          bouy_heap:define(G, Name, Desc)
                  end, Functions),
    lists:foreach(fun(Name) ->
                          case bouy_heap:has_own(G, Name) of
                              true -> ok;
                              false -> bouy_heap:define(G, Name, #{value => undefined, writable => true, enumerable => true, configurable => Configurable})
                          end
                  end, Vars).

%% `delete name` in sloppy code for a global.
-spec delete_global(binary()) -> boolean().
delete_global(Name) -> bouy_heap:delete_property({'$o', 'globalThis'}, Name).

set_in_mode(G, Name, Value, strict) -> bouy_heap:set(G, Name, Value);
set_in_mode(G, Name, Value, sloppy) -> _ = bouy_heap:set(G, Name, Value, G), Value.

%%% Builders for the intrinsics of a family

%% The value of the builtin constructor Name: its record holds the construct
%% fun, and a call without new goes to Module:call_constructor/3.
-spec constructor(module(), binary()) -> term().
constructor(Module, Name) -> {'$f', {builtin, Name}, fun(This, Args) -> Module:call_constructor(Name, This, Args) end}.

-spec builtin(binary(), fun((term(), list()) -> term())) -> term().
builtin(Name, Fun) -> {'$f', {builtin, Name}, Fun}.

%% A builtin with its own name and length properties: Id names it uniquely,
%% such as <<"Symbol.prototype.description">>, and Name is the value of its
%% name property, such as <<"get description">>.
-spec builtin(binary(), binary(), non_neg_integer(), fun((term(), list()) -> term())) -> term().
builtin(Id, Name, Length, Fun) ->
    {Class, Proto, Props, Keys, Attrs, Slots} = record(function, ?FUNCTION_PROTO, [{<<"length">>, Length}, {<<"name">>, Name}], #{}),
    bouy_heap:install_intrinsic({builtin, Id}, {Class, Proto, Props, Keys, Attrs#{<<"length">> => 4, <<"name">> => 4}, Slots}),
    builtin(Id, Fun).

%% A record whose properties are all builtin data: not enumerable.
-spec record(atom(), term(), [{term(), term()}], term()) -> tuple().
record(Class, Proto, Entries, Slots) ->
    Props = maps:from_list(Entries),
    Keys = lists:reverse([K || {K, _} <- Entries, not is_integer(K)]),
    Attrs = maps:from_list([{K, ?HIDDEN} || {K, _} <- Entries]),
    {Class, Proto, Props, Keys, Attrs, Slots}.

%% The builtin methods of Owner. A name with its length, {Name, Length}, also
%% gets its own name and length properties.
-spec methods(module(), binary(), [binary() | {binary(), non_neg_integer()}]) -> [{binary(), term()}].
methods(Module, Owner, Names) ->
    [method_entry(Module, Owner, Name) || Name <- Names].

method_entry(Module, Owner, {Name, Length}) ->
    {Name, builtin(<<Owner/binary, ".", Name/binary>>, Name, Length, fun(This, Args) -> Module:method(Owner, Name, This, Args) end)};
method_entry(Module, Owner, Name) ->
    {Name, builtin(<<Owner/binary, ".", Name/binary>>, fun(This, Args) -> Module:method(Owner, Name, This, Args) end)}.

-spec ctor_record(binary(), non_neg_integer(), term(), [{term(), term()}], fun((term(), list()) -> term())) -> tuple().
ctor_record(Name, Length, Proto, Statics, Construct) ->
    Entries = [{<<"length">>, Length}, {<<"name">>, Name}, {<<"prototype">>, Proto} | Statics],
    {Class, P, Props, Keys, Attrs, Slots} = record(function, ?FUNCTION_PROTO, Entries, #{construct => Construct, kind => builtin}),
    %% name and length are configurable only; prototype is fixed.
    {Class, P, Props, Keys, Attrs#{<<"length">> => 4, <<"name">> => 4, <<"prototype">> => 0}, Slots}.

%% The [[Construct]] of a builtin that new does not support, such as new String().
-spec not_constructible(term(), list()) -> no_return().
not_constructible({'$f', {builtin, <<"Symbol">>}, _}, _Args) -> bouy_ref:type_error(<<"Symbol is not a constructor">>);
not_constructible({'$f', {builtin, <<"Function">>}, _}, _Args) -> bouy_ref:type_error(<<"Function() is not supported">>);
not_constructible({'$f', {builtin, Name}, _}, _Args) -> bouy_ref:type_error(<<"new ", Name/binary, "() is not supported">>);
not_constructible(_NewTarget, _Args) -> bouy_ref:type_error(<<"not a constructor">>).

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
    bouy_heap:is_callable(F) orelse bouy_ref:type_error(bouy_ref_string:concat(bouy_ref:describe(F), <<" is not a function">>)),
    F.

%%% The global object and the global functions

%% The global object is not here: install/0 builds it from the globals of
%% every family. A second record here would race with that one when two
%% realms install at once.
-spec intrinsics() -> [{term(), tuple()}].
intrinsics() -> [].

-spec globals() -> [{binary(), term()}].
globals() ->
    [{<<"globalThis">>, {'$o', 'globalThis'}}, {<<"undefined">>, undefined}]
    ++ ?METHODS(<<"globalThis">>, [<<"setTimeout">>, <<"setInterval">>, <<"clearTimeout">>, <<"clearInterval">>,
                                   <<"queueMicrotask">>, <<"structuredClone">>]).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"globalThis">>, <<"setTimeout">>, _This, Args) -> bouy_jobs:set_timer(arg(1, Args), arg(2, Args), rest(3, Args), false);
method(<<"globalThis">>, <<"setInterval">>, _This, Args) -> bouy_jobs:set_timer(arg(1, Args), arg(2, Args), rest(3, Args), true);
method(<<"globalThis">>, <<"clearTimeout">>, _This, Args) -> bouy_jobs:clear_timer(arg(1, Args));
method(<<"globalThis">>, <<"clearInterval">>, _This, Args) -> bouy_jobs:clear_timer(arg(1, Args));
method(<<"globalThis">>, <<"queueMicrotask">>, _This, Args) ->
    F = arg(1, Args),
    bouy_heap:is_callable(F) orelse bouy_ref:type_error(<<"The \"callback\" argument must be of type function">>),
    bouy_jobs:enqueue(fun() -> bouy_ref:call(F, undefined, []) end),
    undefined;
method(<<"globalThis">>, <<"structuredClone">>, _This, Args) -> bouy_heap:clone_in(bouy_heap:clone_out(arg(1, Args))).
