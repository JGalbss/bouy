%% The intrinsics of a reference-semantics realm (spike).
%%
%% Every intrinsic object is a static record in persistent_term, shared by
%% all realms and read without a copy. A realm copies a record into its heap
%% only when it writes to the intrinsic, so an empty realm allocates nothing.
%% A builtin function is {'$f', {builtin, Name}, fun ?MODULE:F/2}: the same
%% term in every realm. The functions take (This, Args), as compiled code.
-module(bouy_ref_builtins).

-compile([export_all, nowarn_export_all]).

-define(OBJECT_PROTO, {'$o', 'Object.prototype'}).
-define(FUNCTION_PROTO, {'$o', 'Function.prototype'}).
-define(ITERATOR_PROTO, {'$o', 'Iterator.prototype'}).
-define(HIDDEN, 5).
-define(IS_OBJECT(V), (is_tuple(V) andalso (element(1, V) =:= '$o' orelse element(1, V) =:= '$f'))).
-define(SYM(Name), {'$sym', Name, <<"Symbol.", (atom_to_binary(Name))/binary>>}).

arg(1, [V | _]) -> V;
arg(N, [_ | Rest]) when N > 1 -> arg(N - 1, Rest);
arg(_, _) -> undefined.

rest(1, Args) -> Args;
rest(N, [_ | Rest]) when N > 1 -> rest(N - 1, Rest);
rest(_, []) -> [].

-spec type_error(binary()) -> no_return().
type_error(Message) -> bouy_heap:throw_error('TypeError', Message).

%% The [[Construct]] of a builtin that new does not support, such as new String().
-spec not_constructible(term(), list()) -> no_return().
not_constructible({'$f', {builtin, <<"Symbol">>}, _}, _Args) -> type_error(<<"Symbol is not a constructor">>);
not_constructible({'$f', {builtin, <<"Function">>}, _}, _Args) -> type_error(<<"Function() is not supported">>);
not_constructible({'$f', {builtin, Name}, _}, _Args) -> type_error(<<"new ", Name/binary, "() is not supported">>);
not_constructible(_NewTarget, _Args) -> type_error(<<"not a constructor">>).

%%% Installation

-spec install() -> ok.
install() ->
    Version = erlang:md5(term_to_binary(?MODULE:module_info(md5))),
    case persistent_term:get({?MODULE, installed}, undefined) of
        Version ->
            ok;
        _ ->
            [bouy_heap:install_intrinsic(Id, Record) || {Id, Record} <- intrinsics()],
            persistent_term:put({?MODULE, globals}, maps:from_list(globals())),
            persistent_term:put({?MODULE, installed}, Version)
    end,
    ok.

-spec global(binary()) -> term().
global(Name) ->
    case persistent_term:get({?MODULE, globals}) of
        #{Name := V} -> V;
        _ -> bouy_heap:throw_error('ReferenceError', <<Name/binary, " is not defined">>)
    end.

-spec constructor(binary()) -> term().
constructor(Name) -> {'$f', {builtin, Name}, fun(This, Args) -> ?MODULE:call_constructor(Name, This, Args) end}.

builtin(Name, Fun) -> {'$f', {builtin, Name}, Fun}.

%% A record whose properties are all builtin data: not enumerable.
record(Class, Proto, Entries, Slots) ->
    Props = maps:from_list(Entries),
    Keys = lists:reverse([K || {K, _} <- Entries, not is_integer(K)]),
    Attrs = maps:from_list([{K, ?HIDDEN} || {K, _} <- Entries]),
    {Class, Proto, Props, Keys, Attrs, Slots}.

methods(Prefix, Names) ->
    [{Name, builtin(<<Prefix/binary, ".", Name/binary>>, fun(This, Args) -> ?MODULE:dispatch(Prefix, Name, This, Args) end)} || Name <- Names].

ctor_record(Name, Length, Proto, Statics, Construct) ->
    Entries = [{<<"length">>, Length}, {<<"name">>, Name}, {<<"prototype">>, Proto} | Statics],
    record(function, ?FUNCTION_PROTO, Entries, #{construct => Construct, kind => builtin}).

globals() ->
    Ctors = [<<"Object">>, <<"Array">>, <<"String">>, <<"Number">>, <<"Boolean">>, <<"Symbol">>, <<"Error">>, <<"TypeError">>,
             <<"RangeError">>, <<"SyntaxError">>, <<"ReferenceError">>, <<"AggregateError">>, <<"Map">>, <<"Set">>,
             <<"WeakMap">>, <<"WeakSet">>, <<"Promise">>, <<"Date">>, <<"Function">>],
    [{N, constructor(N)} || N <- Ctors] ++
    [{<<"Math">>, {'$o', 'Math'}}, {<<"JSON">>, {'$o', 'JSON'}}, {<<"console">>, {'$o', 'console'}},
     {<<"globalThis">>, {'$o', 'globalThis'}},
     {<<"undefined">>, undefined}, {<<"NaN">>, 'NaN'}, {<<"Infinity">>, 'Infinity'}] ++
    [{N, builtin(N, fun(This, Args) -> ?MODULE:global_call(N, This, Args) end)}
     || N <- [<<"setTimeout">>, <<"setInterval">>, <<"clearTimeout">>, <<"clearInterval">>, <<"queueMicrotask">>,
              <<"structuredClone">>, <<"parseInt">>, <<"parseFloat">>, <<"isNaN">>, <<"isFinite">>]].

intrinsics() ->
    ErrorNames = [<<"TypeError">>, <<"RangeError">>, <<"SyntaxError">>, <<"ReferenceError">>, <<"DataCloneError">>, <<"AggregateError">>],
    [{'Object.prototype', record(object, null, methods(<<"Object.prototype">>, [<<"hasOwnProperty">>, <<"isPrototypeOf">>, <<"propertyIsEnumerable">>, <<"toString">>, <<"toLocaleString">>, <<"valueOf">>]) ++ [{<<"constructor">>, constructor(<<"Object">>)}], none)},
     {'Function.prototype', record(object, ?OBJECT_PROTO, methods(<<"Function.prototype">>, [<<"call">>, <<"apply">>, <<"bind">>, <<"toString">>]) ++ [{<<"name">>, <<>>}, {<<"length">>, 0}, {<<"constructor">>, constructor(<<"Function">>)}], none)},
     {'Array.prototype', record(object, ?OBJECT_PROTO, methods(<<"Array.prototype">>, array_methods()) ++ [{<<"constructor">>, constructor(<<"Array">>)}, {?SYM(iterator), builtin(<<"Array.prototype.values">>, fun(This, Args) -> ?MODULE:dispatch(<<"Array.prototype">>, <<"values">>, This, Args) end)}], none)},
     {'String.prototype', record(object, ?OBJECT_PROTO, methods(<<"String.prototype">>, string_methods()) ++ [{<<"constructor">>, constructor(<<"String">>)}, {?SYM(iterator), builtin(<<"String.prototype[Symbol.iterator]">>, fun(This, _) -> list_iterator(<<"String Iterator">>, [<<C/utf8>> || <<C/utf8>> <= This]) end)}], none)},
     {'Number.prototype', record(object, ?OBJECT_PROTO, methods(<<"Number.prototype">>, [<<"toString">>, <<"toFixed">>, <<"toPrecision">>, <<"toExponential">>, <<"toLocaleString">>, <<"valueOf">>]) ++ [{<<"constructor">>, constructor(<<"Number">>)}], none)},
     {'Boolean.prototype', record(object, ?OBJECT_PROTO, methods(<<"Boolean.prototype">>, [<<"toString">>, <<"valueOf">>]) ++ [{<<"constructor">>, constructor(<<"Boolean">>)}], none)},
     {'Symbol.prototype', record(object, ?OBJECT_PROTO, methods(<<"Symbol.prototype">>, [<<"toString">>, <<"valueOf">>]) ++ [{<<"constructor">>, constructor(<<"Symbol">>)}], none)},
     {'Error.prototype', record(object, ?OBJECT_PROTO, methods(<<"Error.prototype">>, [<<"toString">>]) ++ [{<<"name">>, <<"Error">>}, {<<"message">>, <<>>}, {<<"constructor">>, constructor(<<"Error">>)}], none)},
     {'Iterator.prototype', record(object, ?OBJECT_PROTO, [{?SYM(iterator), builtin(<<"[Symbol.iterator]">>, fun(This, _) -> This end)}], none)},
     {'ListIterator.prototype', record(object, ?ITERATOR_PROTO, methods(<<"ListIterator.prototype">>, [<<"next">>]), none)},
     {'Generator.prototype', record(object, ?ITERATOR_PROTO, methods(<<"Generator.prototype">>, [<<"next">>, <<"return">>, <<"throw">>]) ++ [{?SYM(toStringTag), <<"Generator">>}], none)},
     {'Map.prototype', record(object, ?OBJECT_PROTO, methods(<<"Map.prototype">>, [<<"get">>, <<"set">>, <<"has">>, <<"delete">>, <<"clear">>, <<"forEach">>, <<"keys">>, <<"values">>, <<"entries">>])
         ++ [{<<"size">>, {'$accessor', builtin(<<"get size">>, fun(This, _) -> ?MODULE:collection_size(This) end), undefined}},
             {<<"constructor">>, constructor(<<"Map">>)}, {?SYM(toStringTag), <<"Map">>},
             {?SYM(iterator), builtin(<<"Map.prototype.entries">>, fun(This, Args) -> ?MODULE:dispatch(<<"Map.prototype">>, <<"entries">>, This, Args) end)}], none)},
     {'Set.prototype', record(object, ?OBJECT_PROTO, methods(<<"Set.prototype">>, [<<"add">>, <<"has">>, <<"delete">>, <<"clear">>, <<"forEach">>, <<"keys">>, <<"values">>, <<"entries">>])
         ++ [{<<"size">>, {'$accessor', builtin(<<"get size">>, fun(This, _) -> ?MODULE:collection_size(This) end), undefined}},
             {<<"constructor">>, constructor(<<"Set">>)}, {?SYM(toStringTag), <<"Set">>},
             {?SYM(iterator), builtin(<<"Set.prototype.values">>, fun(This, Args) -> ?MODULE:dispatch(<<"Set.prototype">>, <<"values">>, This, Args) end)}], none)},
     {'WeakMap.prototype', record(object, ?OBJECT_PROTO, methods(<<"Map.prototype">>, [<<"get">>, <<"set">>, <<"has">>, <<"delete">>]) ++ [{<<"constructor">>, constructor(<<"WeakMap">>)}], none)},
     {'WeakSet.prototype', record(object, ?OBJECT_PROTO, methods(<<"Set.prototype">>, [<<"add">>, <<"has">>, <<"delete">>]) ++ [{<<"constructor">>, constructor(<<"WeakSet">>)}], none)},
     {'Promise.prototype', record(object, ?OBJECT_PROTO, methods(<<"Promise.prototype">>, [<<"then">>, <<"catch">>, <<"finally">>]) ++ [{<<"constructor">>, constructor(<<"Promise">>)}, {?SYM(toStringTag), <<"Promise">>}], none)},
     {'Date.prototype', record(object, ?OBJECT_PROTO, methods(<<"Date.prototype">>, [<<"getTime">>, <<"valueOf">>, <<"toISOString">>, <<"toJSON">>, <<"toString">>]) ++ [{<<"constructor">>, constructor(<<"Date">>)}], none)},
     {'Math', record(object, ?OBJECT_PROTO, methods(<<"Math">>, math_functions()) ++ [{C, bouy_math:'$member'(C)} || C <- [<<"PI">>, <<"E">>, <<"LN2">>, <<"LN10">>, <<"LOG2E">>, <<"LOG10E">>, <<"SQRT2">>, <<"SQRT1_2">>]] ++ [{?SYM(toStringTag), <<"Math">>}], none)},
     {'JSON', record(object, ?OBJECT_PROTO, methods(<<"JSON">>, [<<"stringify">>, <<"parse">>]) ++ [{?SYM(toStringTag), <<"JSON">>}], none)},
     {'console', record(object, ?OBJECT_PROTO, methods(<<"console">>, [<<"log">>, <<"error">>, <<"warn">>, <<"info">>, <<"debug">>]), none)},
     {'globalThis', record(object, ?OBJECT_PROTO, [], none)}]
    ++ [{binary_to_atom(<<N/binary, ".prototype">>), record(object, {'$o', 'Error.prototype'}, [{<<"name">>, N}, {<<"message">>, <<>>}, {<<"constructor">>, constructor(N)}], none)} || N <- ErrorNames]
    ++ [{{builtin, N}, R} || {N, R} <- constructor_records()].

constructor_records() ->
    Errors = [<<"Error">>, <<"TypeError">>, <<"RangeError">>, <<"SyntaxError">>, <<"ReferenceError">>, <<"AggregateError">>],
    [{<<"Object">>, ctor_record(<<"Object">>, 1, ?OBJECT_PROTO, methods(<<"Object">>, object_statics()), fun(_NT, Args) -> object_call(undefined, Args) end)},
     {<<"Function">>, ctor_record(<<"Function">>, 1, ?FUNCTION_PROTO, [], fun ?MODULE:not_constructible/2)},
     {<<"Array">>, ctor_record(<<"Array">>, 1, {'$o', 'Array.prototype'}, methods(<<"Array">>, [<<"isArray">>, <<"from">>, <<"of">>]), fun(_NT, Args) -> array_call(undefined, Args) end)},
     {<<"String">>, ctor_record(<<"String">>, 1, {'$o', 'String.prototype'}, methods(<<"String">>, [<<"fromCharCode">>, <<"fromCodePoint">>]), fun ?MODULE:not_constructible/2)},
     {<<"Number">>, ctor_record(<<"Number">>, 1, {'$o', 'Number.prototype'}, methods(<<"Number">>, [<<"isInteger">>, <<"isSafeInteger">>, <<"isFinite">>, <<"isNaN">>, <<"parseFloat">>, <<"parseInt">>])
         ++ [{<<"MAX_SAFE_INTEGER">>, 9007199254740991}, {<<"MIN_SAFE_INTEGER">>, -9007199254740991}, {<<"EPSILON">>, 2.220446049250313e-16},
             {<<"MAX_VALUE">>, 1.7976931348623157e308}, {<<"MIN_VALUE">>, 5.0e-324}, {<<"POSITIVE_INFINITY">>, 'Infinity'},
             {<<"NEGATIVE_INFINITY">>, '-Infinity'}, {<<"NaN">>, 'NaN'}], fun ?MODULE:not_constructible/2)},
     {<<"Boolean">>, ctor_record(<<"Boolean">>, 1, {'$o', 'Boolean.prototype'}, [], fun ?MODULE:not_constructible/2)},
     {<<"Symbol">>, ctor_record(<<"Symbol">>, 0, {'$o', 'Symbol.prototype'}, methods(<<"Symbol">>, [<<"for">>, <<"keyFor">>])
         ++ [{atom_to_binary(W), ?SYM(W)} || W <- [iterator, asyncIterator, hasInstance, toPrimitive, toStringTag]], fun ?MODULE:not_constructible/2)},
     {<<"Map">>, ctor_record(<<"Map">>, 0, {'$o', 'Map.prototype'}, methods(<<"Map">>, [<<"groupBy">>]), fun map_construct/2)},
     {<<"Set">>, ctor_record(<<"Set">>, 0, {'$o', 'Set.prototype'}, [], fun set_construct/2)},
     {<<"WeakMap">>, ctor_record(<<"WeakMap">>, 0, {'$o', 'WeakMap.prototype'}, [], fun map_construct/2)},
     {<<"WeakSet">>, ctor_record(<<"WeakSet">>, 0, {'$o', 'WeakSet.prototype'}, [], fun set_construct/2)},
     {<<"Promise">>, ctor_record(<<"Promise">>, 1, {'$o', 'Promise.prototype'}, methods(<<"Promise">>, [<<"resolve">>, <<"reject">>, <<"all">>, <<"allSettled">>, <<"race">>, <<"any">>, <<"withResolvers">>]), fun promise_construct/2)},
     {<<"Date">>, ctor_record(<<"Date">>, 7, {'$o', 'Date.prototype'}, methods(<<"Date">>, [<<"now">>]), fun date_construct/2)}]
    ++ [{N, ctor_record(N, 1, {'$o', binary_to_atom(<<N/binary, ".prototype">>)}, methods(N, [<<"captureStackTrace">>]), fun(NT, Args) -> error_construct(N, NT, Args) end)} || N <- Errors].

%%% Calls of constructors as functions

%% The record of {builtin, Name} holds the construct fun; a call without new
%% goes through call_builtin/3, which the value of the global holds.
-spec call_constructor(binary(), term(), list()) -> term().
call_constructor(<<"Object">>, This, Args) -> object_call(This, Args);
call_constructor(<<"Array">>, This, Args) -> array_call(This, Args);
call_constructor(<<"String">>, _This, []) -> <<>>;
call_constructor(<<"String">>, _This, [{'$sym', _, _} = S | _]) -> bouy_ref:describe(S);
call_constructor(<<"String">>, _This, [V | _]) -> bouy_ref:to_string(V);
call_constructor(<<"Number">>, _This, []) -> 0;
call_constructor(<<"Number">>, _This, [V | _]) -> bouy_ref:to_number(V);
call_constructor(<<"Boolean">>, _This, Args) -> bouy_ref:truthy(arg(1, Args));
call_constructor(<<"Symbol">>, _This, Args) ->
    case arg(1, Args) of
        undefined -> bouy_heap:symbol(undefined);
        D -> bouy_heap:symbol(bouy_ref:to_string(D))
    end;
call_constructor(<<"Date">>, _This, _Args) -> bouy_date:call(<<"toString">>, {'$date', erlang:system_time(millisecond)}, []);
call_constructor(Name, _This, Args) when Name =:= <<"Error">>; Name =:= <<"TypeError">>; Name =:= <<"RangeError">>;
                                         Name =:= <<"SyntaxError">>; Name =:= <<"ReferenceError">>; Name =:= <<"AggregateError">> ->
    error_construct(Name, constructor(Name), Args);
call_constructor(Name, _This, _Args) ->
    type_error(<<"Constructor ", Name/binary, " requires 'new'">>).

object_call(_This, Args) ->
    case arg(1, Args) of
        V when ?IS_OBJECT(V) -> V;
        _ -> bouy_heap:new_object(?OBJECT_PROTO)
    end.

array_call(_This, [N]) when is_integer(N), N >= 0 ->
    A = bouy_heap:new_array([]),
    bouy_heap:set(A, <<"length">>, N),
    A;
array_call(_This, Args) ->
    bouy_heap:new_array(Args).

%%% Dispatch of builtin methods

-spec dispatch(binary(), binary(), term(), list()) -> term().
dispatch(<<"Object.prototype">>, Name, This, Args) -> object_proto(Name, This, Args);
dispatch(<<"Function.prototype">>, Name, This, Args) -> function_proto(Name, This, Args);
dispatch(<<"Array.prototype">>, Name, This, Args) -> array_proto(Name, This, Args);
dispatch(<<"String.prototype">>, Name, This, Args) -> string_proto(Name, This, Args);
dispatch(<<"Number.prototype">>, Name, This, Args) -> bouy_number:call(Name, This, Args);
dispatch(<<"Boolean.prototype">>, <<"toString">>, This, _) -> atom_to_binary(This);
dispatch(<<"Boolean.prototype">>, <<"valueOf">>, This, _) -> This;
dispatch(<<"Symbol.prototype">>, <<"toString">>, This, _) -> bouy_ref:describe(This);
dispatch(<<"Symbol.prototype">>, <<"valueOf">>, This, _) -> This;
dispatch(<<"Error.prototype">>, <<"toString">>, This, _) -> error_to_string(This);
dispatch(<<"ListIterator.prototype">>, <<"next">>, This, _) ->
    case list_iterator_next(This) of
        {value, V} -> result(V, false);
        done -> result(undefined, true)
    end;
dispatch(<<"Generator.prototype">>, Name, This, Args) ->
    Resumption = case Name of
        <<"next">> -> {next, arg(1, Args)};
        <<"return">> -> {return, arg(1, Args)};
        <<"throw">> -> {throw, arg(1, Args)}
    end,
    case bouy_ref:generator_resume(This, Resumption) of
        {yield, V} -> result(V, false);
        {done, V} -> result(V, true)
    end;
dispatch(<<"Map.prototype">>, Name, This, Args) -> map_proto(Name, This, Args);
dispatch(<<"Set.prototype">>, Name, This, Args) -> set_proto(Name, This, Args);
dispatch(<<"Promise.prototype">>, Name, This, Args) -> promise_proto(Name, This, Args);
dispatch(<<"Date.prototype">>, Name, This, Args) -> bouy_date:call(Name, {'$date', bouy_heap:slots(This)}, Args);
dispatch(<<"Math">>, Name, _This, Args) -> math(Name, [bouy_ref:to_number(A) || A <- Args]);
dispatch(<<"JSON">>, <<"stringify">>, _This, Args) -> bouy_ref_json:stringify(arg(1, Args), arg(2, Args), arg(3, Args));
dispatch(<<"JSON">>, <<"parse">>, _This, Args) -> bouy_ref_json:parse(bouy_ref:to_string(arg(1, Args)));
dispatch(<<"console">>, Name, _This, Args) -> bouy_ref_console:write(Name, Args);
dispatch(<<"Object">>, Name, _This, Args) -> object_static(Name, Args);
dispatch(<<"Array">>, Name, _This, Args) -> array_static(Name, Args);
dispatch(<<"String">>, Name, _This, Args) -> bouy_string:(binary_to_existing_atom(Name))([bouy_ref:to_number(A) || A <- Args]);
dispatch(<<"Number">>, Name, _This, Args) -> bouy_number:(binary_to_atom(Name))(Args);
dispatch(<<"Symbol">>, <<"for">>, _This, Args) -> bouy_heap:symbol_for(bouy_ref:to_string(arg(1, Args)));
dispatch(<<"Symbol">>, <<"keyFor">>, _This, Args) ->
    case arg(1, Args) of
        {'$sym', registered, Key} -> Key;
        _ -> undefined
    end;
dispatch(<<"Map">>, <<"groupBy">>, _This, Args) ->
    M = map_construct(constructor(<<"Map">>), []),
    lists:foreach(fun({I, V}) ->
                          K = bouy_ref:call(arg(2, Args), undefined, [V, I]),
                          case map_proto(<<"get">>, M, [K]) of
                              undefined -> map_proto(<<"set">>, M, [K, bouy_heap:new_array([V])]);
                              Group -> array_proto(<<"push">>, Group, [V])
                          end
                  end, lists:enumerate(0, bouy_ref:to_list(arg(1, Args)))),
    M;
dispatch(<<"Promise">>, Name, _This, Args) -> promise_static(Name, Args);
dispatch(<<"Date">>, <<"now">>, _This, _Args) -> erlang:system_time(millisecond);
dispatch(_ErrorName, <<"captureStackTrace">>, _This, _Args) -> undefined.

result(V, Done) -> bouy_heap:object(?OBJECT_PROTO, [{<<"value">>, V}, {<<"done">>, Done}]).

%%% Globals

global_call(<<"setTimeout">>, _This, Args) -> bouy_jobs:set_timer(arg(1, Args), arg(2, Args), rest(3, Args), false);
global_call(<<"setInterval">>, _This, Args) -> bouy_jobs:set_timer(arg(1, Args), arg(2, Args), rest(3, Args), true);
global_call(<<"clearTimeout">>, _This, Args) -> bouy_jobs:clear_timer(arg(1, Args));
global_call(<<"clearInterval">>, _This, Args) -> bouy_jobs:clear_timer(arg(1, Args));
global_call(<<"queueMicrotask">>, _This, Args) ->
    F = arg(1, Args),
    bouy_heap:is_callable(F) orelse type_error(<<"The \"callback\" argument must be of type function">>),
    bouy_jobs:enqueue(fun() -> bouy_ref:call(F, undefined, []) end),
    undefined;
global_call(<<"structuredClone">>, _This, Args) -> bouy_heap:clone_in(bouy_heap:clone_out(arg(1, Args)));
global_call(<<"parseInt">>, _This, Args) -> bouy_number:'parseInt'(Args);
global_call(<<"parseFloat">>, _This, Args) -> bouy_number:'parseFloat'(Args);
global_call(<<"isNaN">>, _This, Args) -> bouy_number:'$isNaN'([bouy_ref:to_number(arg(1, Args))]);
global_call(<<"isFinite">>, _This, Args) -> bouy_number:'$isFinite'([bouy_ref:to_number(arg(1, Args))]).

%%% Object

object_proto(<<"hasOwnProperty">>, This, Args) -> has_own(This, bouy_ref:to_property_key(arg(1, Args)));
object_proto(<<"isPrototypeOf">>, This, Args) ->
    case arg(1, Args) of
        V when ?IS_OBJECT(V) -> chain_has(bouy_heap:prototype_of(V), This);
        _ -> false
    end;
object_proto(<<"propertyIsEnumerable">>, This, Args) ->
    case bouy_heap:get_own(This, bouy_ref:to_property_key(arg(1, Args))) of
        {data, _, Bits} -> Bits band 2 =/= 0;
        {accessor, _, _, Bits} -> Bits band 2 =/= 0;
        none -> false
    end;
object_proto(<<"toString">>, This, _Args) -> <<"[object ", (tag(This))/binary, "]">>;
object_proto(<<"toLocaleString">>, This, _Args) -> bouy_ref:call_method(This, <<"toString">>, []);
object_proto(<<"valueOf">>, This, _Args) -> This.

has_own(O, K) when ?IS_OBJECT(O) -> bouy_heap:has_own(O, K);
has_own(S, K) when is_binary(S) -> K =:= <<"length">> orelse (is_integer(K) andalso K < bouy_string:char_count(S));
has_own(_, _) -> false.

chain_has(null, _) -> false;
chain_has(P, P) -> true;
chain_has(O, P) -> chain_has(bouy_heap:prototype_of(O), P).

tag(undefined) -> <<"Undefined">>;
tag(null) -> <<"Null">>;
tag(V) when ?IS_OBJECT(V) ->
    case bouy_ref:get(V, ?SYM(toStringTag)) of
        T when is_binary(T) -> T;
        _ ->
            case bouy_heap:class_of(V) of
                array -> <<"Array">>;
                function -> <<"Function">>;
                error -> <<"Error">>;
                date -> <<"Date">>;
                _ -> <<"Object">>
            end
    end;
tag(V) when is_binary(V) -> <<"String">>;
tag(V) when is_boolean(V) -> <<"Boolean">>;
tag({'$sym', _, _}) -> <<"Symbol">>;
tag(_) -> <<"Number">>.

object_statics() ->
    [<<"keys">>, <<"values">>, <<"entries">>, <<"assign">>, <<"freeze">>, <<"isFrozen">>, <<"create">>, <<"getPrototypeOf">>,
     <<"setPrototypeOf">>, <<"defineProperty">>, <<"getOwnPropertyNames">>, <<"getOwnPropertySymbols">>,
     <<"getOwnPropertyDescriptor">>, <<"fromEntries">>, <<"hasOwn">>, <<"is">>].

object_static(<<"keys">>, Args) -> bouy_heap:new_array([bouy_heap:key_to_value(K) || K <- enumerable(arg(1, Args))]);
object_static(<<"values">>, Args) ->
    O = arg(1, Args),
    bouy_heap:new_array([bouy_ref:get(O, K) || K <- enumerable(O)]);
object_static(<<"entries">>, Args) ->
    O = arg(1, Args),
    bouy_heap:new_array([bouy_heap:new_array([bouy_heap:key_to_value(K), bouy_ref:get(O, K)]) || K <- enumerable(O)]);
object_static(<<"assign">>, [Target | Sources]) ->
    [bouy_ref:set(Target, K, bouy_ref:get(S, K)) || S <- Sources, ?IS_OBJECT(S), K <- enumerable(S) ++ enumerable_symbols(S)],
    Target;
object_static(<<"freeze">>, Args) ->
    case arg(1, Args) of
        O when ?IS_OBJECT(O) -> bouy_heap:freeze(O);
        V -> V
    end;
object_static(<<"isFrozen">>, Args) ->
    case arg(1, Args) of
        O when ?IS_OBJECT(O) -> bouy_heap:is_frozen(O);
        _ -> true
    end;
object_static(<<"create">>, Args) ->
    case arg(1, Args) of
        P when ?IS_OBJECT(P); P =:= null ->
            O = bouy_heap:new_object(P),
            case arg(2, Args) of
                undefined -> ok;
                Props -> object_static(<<"defineProperties">>, [O, Props])
            end,
            O;
        P ->
            type_error(<<"Object prototype may only be an Object or null: ", (bouy_ref:describe(P))/binary>>)
    end;
object_static(<<"defineProperties">>, [O, Props]) ->
    [object_static(<<"defineProperty">>, [O, bouy_heap:key_to_value(K), bouy_ref:get(Props, K)]) || K <- enumerable(Props)],
    O;
object_static(<<"getPrototypeOf">>, Args) ->
    case arg(1, Args) of
        O when ?IS_OBJECT(O) -> bouy_heap:prototype_of(O);
        S when is_binary(S) -> {'$o', 'String.prototype'};
        B when is_boolean(B) -> {'$o', 'Boolean.prototype'};
        {'$sym', _, _} -> {'$o', 'Symbol.prototype'};
        undefined -> type_error(<<"Cannot convert undefined or null to object">>);
        null -> type_error(<<"Cannot convert undefined or null to object">>);
        _ -> {'$o', 'Number.prototype'}
    end;
object_static(<<"setPrototypeOf">>, Args) ->
    case arg(1, Args) of
        O when ?IS_OBJECT(O) -> bouy_heap:set_prototype_of(O, arg(2, Args));
        V -> V
    end;
object_static(<<"defineProperty">>, Args) ->
    O = arg(1, Args),
    ?IS_OBJECT(O) orelse type_error(<<"Object.defineProperty called on non-object">>),
    D = arg(3, Args),
    Descriptor = maps:from_list([{binary_to_atom(F), bouy_ref:get(D, F)}
                                 || F <- [<<"value">>, <<"writable">>, <<"enumerable">>, <<"configurable">>, <<"get">>, <<"set">>],
                                    bouy_heap:has(D, F)]),
    Flags = maps:map(fun(K, V) when K =:= writable; K =:= enumerable; K =:= configurable -> bouy_ref:truthy(V); (_, V) -> V end, Descriptor),
    bouy_heap:define(O, bouy_ref:to_property_key(arg(2, Args)), Flags);
object_static(<<"getOwnPropertyNames">>, Args) ->
    bouy_heap:new_array([bouy_heap:key_to_value(K) || K <- bouy_heap:own_keys(arg(1, Args)), not is_tuple(K)]);
object_static(<<"getOwnPropertySymbols">>, Args) ->
    bouy_heap:new_array([K || {'$sym', _, _} = K <- bouy_heap:own_keys(arg(1, Args))]);
object_static(<<"getOwnPropertyDescriptor">>, Args) ->
    case bouy_heap:get_own(arg(1, Args), bouy_ref:to_property_key(arg(2, Args))) of
        none -> undefined;
        {data, V, Bits} ->
            bouy_heap:object(?OBJECT_PROTO, [{<<"value">>, V}, {<<"writable">>, Bits band 1 =/= 0},
                                             {<<"enumerable">>, Bits band 2 =/= 0}, {<<"configurable">>, Bits band 4 =/= 0}]);
        {accessor, G, S, Bits} ->
            bouy_heap:object(?OBJECT_PROTO, [{<<"get">>, G}, {<<"set">>, S},
                                             {<<"enumerable">>, Bits band 2 =/= 0}, {<<"configurable">>, Bits band 4 =/= 0}])
    end;
object_static(<<"fromEntries">>, Args) ->
    O = bouy_heap:new_object(?OBJECT_PROTO),
    [bouy_ref:define_field(O, bouy_ref:to_property_key(bouy_ref:get(E, 0)), bouy_ref:get(E, 1)) || E <- bouy_ref:to_list(arg(1, Args))],
    O;
object_static(<<"hasOwn">>, Args) -> has_own(arg(1, Args), bouy_ref:to_property_key(arg(2, Args)));
object_static(<<"is">>, Args) -> same_value(arg(1, Args), arg(2, Args)).

same_value(A, B) when is_float(A), is_float(B) -> <<A/float>> =:= <<B/float>>;
same_value(A, B) -> bouy_ref:strict_eq(A, B) orelse (A =:= 'NaN' andalso B =:= 'NaN').

enumerable(O) when ?IS_OBJECT(O) -> bouy_heap:enumerable_keys(O);
enumerable(S) when is_binary(S) -> lists:seq(0, bouy_string:char_count(S) - 1);
enumerable(undefined) -> type_error(<<"Cannot convert undefined or null to object">>);
enumerable(null) -> type_error(<<"Cannot convert undefined or null to object">>);
enumerable(_) -> [].

enumerable_symbols(O) ->
    [K || {'$sym', _, _} = K <- bouy_heap:own_keys(O),
          case bouy_heap:get_own(O, K) of
              {data, _, B} -> B band 2 =/= 0;
              {accessor, _, _, B} -> B band 2 =/= 0;
              none -> false
          end].

%%% Function

function_proto(<<"call">>, F, Args) -> bouy_ref:call(F, arg(1, Args), rest(2, Args));
function_proto(<<"apply">>, F, Args) ->
    List = case arg(2, Args) of
        A when A =:= undefined; A =:= null -> [];
        A -> bouy_ref:to_list(A)
    end,
    bouy_ref:call(F, arg(1, Args), List);
function_proto(<<"bind">>, F, Args) ->
    BoundThis = arg(1, Args),
    Bound = rest(2, Args),
    Name = case bouy_ref:get(F, <<"name">>) of
        N when is_binary(N) -> N;
        _ -> <<>>
    end,
    bouy_heap:function(fun(_This, More) -> bouy_ref:call(F, BoundThis, Bound ++ More) end, <<"bound ", Name/binary>>, 0, #{}) ;
function_proto(<<"toString">>, F, _Args) ->
    case bouy_heap:slots(F) of
        #{kind := class} -> <<"class ", (bouy_ref:get(F, <<"name">>))/binary, " { }">>;
        _ -> <<"function ", (bouy_ref:get(F, <<"name">>))/binary, "() { [native code] }">>
    end.

%%% Array

array_methods() ->
    [<<"push">>, <<"pop">>, <<"shift">>, <<"unshift">>, <<"slice">>, <<"splice">>, <<"concat">>, <<"join">>, <<"indexOf">>,
     <<"lastIndexOf">>, <<"includes">>, <<"find">>, <<"findIndex">>, <<"findLast">>, <<"findLastIndex">>, <<"filter">>,
     <<"map">>, <<"forEach">>, <<"some">>, <<"every">>, <<"reduce">>, <<"reduceRight">>, <<"sort">>, <<"reverse">>,
     <<"fill">>, <<"at">>, <<"flat">>, <<"flatMap">>, <<"keys">>, <<"values">>, <<"entries">>, <<"toString">>,
     <<"toSorted">>, <<"toReversed">>].

items(A) -> bouy_heap:array_items(A).

callback(F) ->
    bouy_heap:is_callable(F) orelse type_error(<<(bouy_ref:describe(F))/binary, " is not a function">>),
    F.

array_proto(<<"push">>, A, Items) -> bouy_heap:array_push(A, Items);
array_proto(<<"pop">>, A, _) ->
    case bouy_heap:array_length(A) of
        0 -> undefined;
        N ->
            V = bouy_heap:get(A, N - 1),
            bouy_heap:set(A, <<"length">>, N - 1),
            V
    end;
array_proto(<<"shift">>, A, _) ->
    case items(A) of
        [] -> undefined;
        [H | T] -> bouy_heap:array_set_items(A, T), H
    end;
array_proto(<<"unshift">>, A, New) ->
    All = New ++ items(A),
    bouy_heap:array_set_items(A, All),
    length(All);
array_proto(<<"slice">>, A, Args) ->
    L = items(A),
    {S, E} = range(length(L), arg(1, Args), arg(2, Args)),
    bouy_heap:new_array(lists:sublist(L, S + 1, max(0, E - S)));
array_proto(<<"splice">>, A, Args) ->
    L = items(A),
    Len = length(L),
    {Start, _} = range(Len, arg(1, Args), undefined),
    Count = case Args of
        [_] -> Len - Start;
        [] -> 0;
        _ -> max(0, min(Len - Start, int(arg(2, Args))))
    end,
    {Before, After} = lists:split(Start, L),
    {Removed, Kept} = lists:split(Count, After),
    bouy_heap:array_set_items(A, Before ++ rest(3, Args) ++ Kept),
    bouy_heap:new_array(Removed);
array_proto(<<"concat">>, A, Args) ->
    bouy_heap:new_array(items(A) ++ lists:append([concat_items(X) || X <- Args]));
array_proto(<<"join">>, A, Args) ->
    Sep = case arg(1, Args) of
        undefined -> <<",">>;
        S -> bouy_ref:to_string(S)
    end,
    iolist_to_binary(lists:join(Sep, [join_text(V) || V <- items(A)]));
array_proto(<<"toString">>, A, _) -> array_proto(<<"join">>, A, []);
array_proto(<<"indexOf">>, A, Args) -> index_of(items(A), arg(1, Args), 0, fun bouy_ref:strict_eq/2);
array_proto(<<"lastIndexOf">>, A, Args) ->
    L = items(A),
    case index_of(lists:reverse(L), arg(1, Args), 0, fun bouy_ref:strict_eq/2) of
        -1 -> -1;
        I -> length(L) - 1 - I
    end;
array_proto(<<"includes">>, A, Args) ->
    index_of(items(A), arg(1, Args), 0, fun(X, Y) -> bouy_ref:strict_eq(X, Y) orelse (X =:= 'NaN' andalso Y =:= 'NaN') end) >= 0;
array_proto(<<"find">>, A, Args) -> find(A, Args, items(A), value);
array_proto(<<"findIndex">>, A, Args) -> find(A, Args, items(A), index);
array_proto(<<"findLast">>, A, Args) -> find_last(A, Args, value);
array_proto(<<"findLastIndex">>, A, Args) -> find_last(A, Args, index);
array_proto(<<"filter">>, A, Args) ->
    F = callback(arg(1, Args)),
    bouy_heap:new_array([V || {I, V} <- lists:enumerate(0, items(A)), bouy_ref:truthy(bouy_ref:call(F, arg(2, Args), [V, I, A]))]);
array_proto(<<"map">>, A, Args) ->
    F = callback(arg(1, Args)),
    bouy_heap:new_array([bouy_ref:call(F, arg(2, Args), [V, I, A]) || {I, V} <- lists:enumerate(0, items(A))]);
array_proto(<<"forEach">>, A, Args) ->
    F = callback(arg(1, Args)),
    [bouy_ref:call(F, arg(2, Args), [V, I, A]) || {I, V} <- lists:enumerate(0, items(A))],
    undefined;
array_proto(<<"some">>, A, Args) ->
    F = callback(arg(1, Args)),
    lists:any(fun({I, V}) -> bouy_ref:truthy(bouy_ref:call(F, arg(2, Args), [V, I, A])) end, lists:enumerate(0, items(A)));
array_proto(<<"every">>, A, Args) ->
    F = callback(arg(1, Args)),
    lists:all(fun({I, V}) -> bouy_ref:truthy(bouy_ref:call(F, arg(2, Args), [V, I, A])) end, lists:enumerate(0, items(A)));
array_proto(<<"reduce">>, A, Args) -> reduce(A, Args, lists:enumerate(0, items(A)));
array_proto(<<"reduceRight">>, A, Args) -> reduce(A, Args, lists:reverse(lists:enumerate(0, items(A))));
array_proto(<<"sort">>, A, Args) ->
    L = items(A),
    {Defined, Undefined} = lists:partition(fun(V) -> V =/= undefined end, L),
    Sorted = case arg(1, Args) of
        undefined -> [V || {_, V} <- lists:keysort(1, [{bouy_ref:to_string(V), V} || V <- Defined])];
        F -> bouy_sort:sort(Defined, fun(CallArgs) -> bouy_ref:call(F, undefined, CallArgs) end)
    end,
    bouy_heap:array_set_items(A, Sorted ++ Undefined),
    A;
array_proto(<<"toSorted">>, A, Args) ->
    array_proto(<<"sort">>, bouy_heap:new_array(items(A)), Args);
array_proto(<<"toReversed">>, A, _) ->
    bouy_heap:new_array(lists:reverse(items(A)));
array_proto(<<"reverse">>, A, _) ->
    bouy_heap:array_set_items(A, lists:reverse(items(A))),
    A;
array_proto(<<"fill">>, A, Args) ->
    L = items(A),
    {S, E} = range(length(L), arg(2, Args), arg(3, Args)),
    V = arg(1, Args),
    bouy_heap:array_set_items(A, [case I >= S andalso I < E of true -> V; false -> X end || {I, X} <- lists:enumerate(0, L)]),
    A;
array_proto(<<"at">>, A, Args) ->
    Len = bouy_heap:array_length(A),
    case int(arg(1, Args)) of
        I when I < 0, I + Len >= 0 -> bouy_heap:get(A, I + Len);
        I when I >= 0, I < Len -> bouy_heap:get(A, I);
        _ -> undefined
    end;
array_proto(<<"flat">>, A, Args) ->
    Depth = case arg(1, Args) of
        undefined -> 1;
        D -> int(D)
    end,
    bouy_heap:new_array(flatten(items(A), Depth));
array_proto(<<"flatMap">>, A, Args) ->
    F = callback(arg(1, Args)),
    Mapped = [bouy_ref:call(F, arg(2, Args), [V, I, A]) || {I, V} <- lists:enumerate(0, items(A))],
    bouy_heap:new_array(flatten(Mapped, 1));
array_proto(<<"keys">>, A, _) -> list_iterator(<<"Array Iterator">>, lists:seq(0, bouy_heap:array_length(A) - 1));
array_proto(<<"values">>, A, _) -> list_iterator(<<"Array Iterator">>, items(A));
array_proto(<<"entries">>, A, _) -> list_iterator(<<"Array Iterator">>, [bouy_heap:new_array([I, V]) || {I, V} <- lists:enumerate(0, items(A))]).

is_array({'$o', _} = O) -> bouy_heap:class_of(O) =:= array;
is_array(_) -> false.

concat_items(X) ->
    case is_array(X) of
        true -> items(X);
        false -> [X]
    end.

flatten(L, 0) -> L;
flatten(L, Depth) ->
    lists:append([case is_array(V) of true -> flatten(items(V), Depth - 1); false -> [V] end || V <- L]).

join_text(undefined) -> <<>>;
join_text(null) -> <<>>;
join_text(V) -> bouy_ref:to_string(V).

int(V) ->
    case bouy_ref:to_number(V) of
        I when is_integer(I) -> I;
        F when is_float(F) -> trunc(F);
        'Infinity' -> 1 bsl 53;
        '-Infinity' -> -(1 bsl 53);
        _ -> 0
    end.

%% Relative start and end, clamped to [0, Len].
range(Len, Start, End) ->
    S = relative(Start, 0, Len),
    E = case End of
        undefined -> Len;
        _ -> relative(End, Len, Len)
    end,
    {S, max(S, E)}.

relative(undefined, Default, _Len) -> Default;
relative(V, _Default, Len) ->
    case int(V) of
        I when I < 0 -> max(0, Len + I);
        I -> min(I, Len)
    end.

index_of([], _, _, _) -> -1;
index_of([V | Rest], X, I, Eq) ->
    case Eq(V, X) of
        true -> I;
        false -> index_of(Rest, X, I + 1, Eq)
    end.

find(A, Args, L, What) ->
    F = callback(arg(1, Args)),
    find_in(lists:enumerate(0, L), F, arg(2, Args), A, What).

find_in([], _F, _This, _A, value) -> undefined;
find_in([], _F, _This, _A, index) -> -1;
find_in([{I, V} | Rest], F, This, A, What) ->
    case bouy_ref:truthy(bouy_ref:call(F, This, [V, I, A])) of
        true when What =:= value -> V;
        true -> I;
        false -> find_in(Rest, F, This, A, What)
    end.

find_last(A, Args, What) ->
    F = callback(arg(1, Args)),
    find_in(lists:reverse(lists:enumerate(0, items(A))), F, arg(2, Args), A, What).

reduce(A, Args, Indexed) ->
    F = callback(arg(1, Args)),
    {Acc0, Rest} = case Args of
        [_, Init | _] -> {Init, Indexed};
        _ ->
            case Indexed of
                [] -> type_error(<<"Reduce of empty array with no initial value">>);
                [{_, First} | T] -> {First, T}
            end
    end,
    lists:foldl(fun({I, V}, Acc) -> bouy_ref:call(F, undefined, [Acc, V, I, A]) end, Acc0, Rest).

array_static(<<"isArray">>, Args) -> is_array(arg(1, Args));
array_static(<<"of">>, Args) -> bouy_heap:new_array(Args);
array_static(<<"from">>, Args) ->
    Source = arg(1, Args),
    Items = case Source of
        S when ?IS_OBJECT(S) ->
            case bouy_ref:get(S, ?SYM(iterator)) of
                undefined ->
                    Len = int(bouy_ref:get(S, <<"length">>)),
                    [bouy_ref:get(S, I) || I <- lists:seq(0, Len - 1)];
                _ ->
                    bouy_ref:to_list(S)
            end;
        S when is_binary(S) -> bouy_ref:to_list(S);
        _ -> []
    end,
    case arg(2, Args) of
        undefined -> bouy_heap:new_array(Items);
        F -> bouy_heap:new_array([bouy_ref:call(F, arg(3, Args), [V, I]) || {I, V} <- lists:enumerate(0, Items)])
    end.

%%% Iterators over a snapshot list: the iterators of arrays, Maps, Sets, and strings.

list_iterator(Kind, Items) ->
    bouy_heap:new_exotic(list_iterator, {'$o', 'ListIterator.prototype'}, {Kind, Items}).

-spec list_iterator_next(term()) -> {value, term()} | done.
list_iterator_next(O) ->
    case bouy_heap:slots(O) of
        {Kind, [V | Rest]} -> bouy_heap:set_slots(O, {Kind, Rest}), {value, V};
        {_, []} -> done
    end.

%%% String

string_methods() ->
    [<<"at">>, <<"charAt">>, <<"charCodeAt">>, <<"codePointAt">>, <<"concat">>, <<"endsWith">>, <<"includes">>, <<"indexOf">>,
     <<"lastIndexOf">>, <<"localeCompare">>, <<"padEnd">>, <<"padStart">>, <<"repeat">>, <<"replace">>, <<"replaceAll">>,
     <<"slice">>, <<"split">>, <<"startsWith">>, <<"substring">>, <<"substr">>, <<"toLowerCase">>, <<"toUpperCase">>,
     <<"toLocaleLowerCase">>, <<"toLocaleUpperCase">>, <<"toString">>, <<"valueOf">>, <<"trim">>, <<"trimStart">>,
     <<"trimEnd">>, <<"normalize">>].

%% The value core implements the string methods; a callback becomes a value
%% fun and an array result becomes a heap array.
string_proto(Name, S, Args) when is_binary(S) ->
    Converted = [value_arg(A) || A <- Args],
    from_value(bouy_string:call(Name, S, Converted));
string_proto(Name, S, Args) ->
    string_proto(Name, bouy_ref:to_string(S), Args).

value_arg({'$f', _, _} = F) -> fun(CallArgs) -> bouy_ref:call(F, undefined, CallArgs) end;
value_arg(V) -> V.

from_value(L) when is_list(L) -> bouy_heap:new_array(L);
from_value(V) -> V.

%%% Map and Set
%%
%% The slots of a Map: {Index, Next}, where Index maps a key to
%% {Sequence, Value}. A Set: {Index, Next} with Index mapping a member to
%% its sequence. Keys are SameValueZero: numbers through collection_key,
%% objects by identity.

map_construct(NewTarget, Args) ->
    M = bouy_heap:new_exotic(map, collection_proto(NewTarget, 'Map.prototype'), {#{}, 0}),
    case arg(1, Args) of
        V when V =:= undefined; V =:= null -> ok;
        Iterable -> [map_proto(<<"set">>, M, [bouy_ref:get(E, 0), bouy_ref:get(E, 1)]) || E <- bouy_ref:to_list(Iterable)]
    end,
    M.

set_construct(NewTarget, Args) ->
    S = bouy_heap:new_exotic(set, collection_proto(NewTarget, 'Set.prototype'), {#{}, 0}),
    case arg(1, Args) of
        V when V =:= undefined; V =:= null -> ok;
        Iterable -> [set_proto(<<"add">>, S, [X]) || X <- bouy_ref:to_list(Iterable)]
    end,
    S.

collection_proto({'$f', {builtin, <<"WeakMap">>}, _}, _) -> {'$o', 'WeakMap.prototype'};
collection_proto({'$f', {builtin, <<"WeakSet">>}, _}, _) -> {'$o', 'WeakSet.prototype'};
collection_proto({'$f', {builtin, _}, _}, Default) -> {'$o', Default};
collection_proto(NewTarget, _Default) -> bouy_ref:get(NewTarget, <<"prototype">>).

collection_size(O) ->
    {Index, _} = bouy_heap:slots(O),
    map_size(Index).

key(K) -> bouy_rt:collection_key(K).

map_entries(M) ->
    {Index, _} = bouy_heap:slots(M),
    [{K, V} || {_, K, V} <- lists:sort([{Seq, K, V} || K := {Seq, V} <- Index])].

map_proto(<<"get">>, M, Args) ->
    {Index, _} = bouy_heap:slots(M),
    K = key(arg(1, Args)),
    case Index of
        #{K := {_, V}} -> V;
        _ -> undefined
    end;
map_proto(<<"set">>, M, Args) ->
    {Index, Next} = bouy_heap:slots(M),
    K = key(arg(1, Args)),
    V = arg(2, Args),
    case Index of
        #{K := {Seq, _}} -> bouy_heap:set_slots(M, {Index#{K := {Seq, V}}, Next});
        _ -> bouy_heap:set_slots(M, {Index#{K => {Next, V}}, Next + 1})
    end,
    M;
map_proto(<<"has">>, M, Args) ->
    {Index, _} = bouy_heap:slots(M),
    is_map_key(key(arg(1, Args)), Index);
map_proto(<<"delete">>, M, Args) ->
    {Index, Next} = bouy_heap:slots(M),
    K = key(arg(1, Args)),
    case Index of
        #{K := _} -> bouy_heap:set_slots(M, {maps:remove(K, Index), Next}), true;
        _ -> false
    end;
map_proto(<<"clear">>, M, _) ->
    {_, Next} = bouy_heap:slots(M),
    bouy_heap:set_slots(M, {#{}, Next}),
    undefined;
map_proto(<<"forEach">>, M, Args) ->
    F = callback(arg(1, Args)),
    [bouy_ref:call(F, arg(2, Args), [V, K, M]) || {K, V} <- map_entries(M)],
    undefined;
map_proto(<<"keys">>, M, _) -> list_iterator(<<"Map Iterator">>, [K || {K, _} <- map_entries(M)]);
map_proto(<<"values">>, M, _) -> list_iterator(<<"Map Iterator">>, [V || {_, V} <- map_entries(M)]);
map_proto(<<"entries">>, M, _) -> list_iterator(<<"Map Entries">>, [bouy_heap:new_array([K, V]) || {K, V} <- map_entries(M)]).

set_members(S) ->
    {Index, _} = bouy_heap:slots(S),
    [K || {_, K} <- lists:sort([{Seq, K} || K := Seq <- Index])].

set_proto(<<"add">>, S, Args) ->
    {Index, Next} = bouy_heap:slots(S),
    K = key(arg(1, Args)),
    case Index of
        #{K := _} -> ok;
        _ -> bouy_heap:set_slots(S, {Index#{K => Next}, Next + 1})
    end,
    S;
set_proto(<<"has">>, S, Args) ->
    {Index, _} = bouy_heap:slots(S),
    is_map_key(key(arg(1, Args)), Index);
set_proto(<<"delete">>, S, Args) ->
    {Index, Next} = bouy_heap:slots(S),
    K = key(arg(1, Args)),
    case Index of
        #{K := _} -> bouy_heap:set_slots(S, {maps:remove(K, Index), Next}), true;
        _ -> false
    end;
set_proto(<<"clear">>, S, _) ->
    {_, Next} = bouy_heap:slots(S),
    bouy_heap:set_slots(S, {#{}, Next}),
    undefined;
set_proto(<<"forEach">>, S, Args) ->
    F = callback(arg(1, Args)),
    [bouy_ref:call(F, arg(2, Args), [K, K, S]) || K <- set_members(S)],
    undefined;
set_proto(Name, S, _) when Name =:= <<"values">>; Name =:= <<"keys">> -> list_iterator(<<"Set Iterator">>, set_members(S));
set_proto(<<"entries">>, S, _) -> list_iterator(<<"Set Entries">>, [bouy_heap:new_array([K, K]) || K <- set_members(S)]).

%%% Promise

promise_construct(_NewTarget, Args) ->
    Executor = arg(1, Args),
    bouy_heap:is_callable(Executor) orelse
        type_error(<<"Promise resolver ", (bouy_ref:describe(Executor))/binary, " is not a function">>),
    P = bouy_jobs:new_promise(),
    {Resolve, Reject} = bouy_jobs:resolving_functions(P),
    try bouy_ref:call(Executor, undefined, [js(Resolve), js(Reject)]) of
        _ -> ok
    catch
        error:Reason:Stack -> Reject(bouy_ref:caught(Reason, Stack))
    end,
    P.

js(Fun) -> bouy_heap:function(fun(_This, Args) -> Fun(arg(1, Args)) end).

promise_proto(<<"then">>, P, Args) ->
    bouy_jobs:is_promise(P) orelse type_error(<<"Method Promise.prototype.then called on incompatible receiver">>),
    bouy_jobs:then(P, arg(1, Args), arg(2, Args));
promise_proto(<<"catch">>, P, Args) ->
    bouy_ref:call_method(P, <<"then">>, [undefined, arg(1, Args)]);
promise_proto(<<"finally">>, P, Args) ->
    case arg(1, Args) of
        {'$f', _, _} = OnFinally ->
            ThenFinally = bouy_heap:function(fun(_, [Value | _]) ->
                Result = bouy_ref:call(OnFinally, undefined, []),
                Promise = bouy_jobs:promise_resolve(Result),
                bouy_ref:call_method(Promise, <<"then">>, [bouy_heap:function(fun(_, _) -> Value end)])
            end),
            CatchFinally = bouy_heap:function(fun(_, [Reason | _]) ->
                Result = bouy_ref:call(OnFinally, undefined, []),
                Promise = bouy_jobs:promise_resolve(Result),
                bouy_ref:call_method(Promise, <<"then">>, [bouy_heap:function(fun(_, _) -> erlang:error({'$throw', Reason}) end)])
            end),
            bouy_ref:call_method(P, <<"then">>, [ThenFinally, CatchFinally]);
        Other ->
            bouy_ref:call_method(P, <<"then">>, [Other, Other])
    end.

promise_static(<<"resolve">>, Args) -> bouy_jobs:promise_resolve(arg(1, Args));
promise_static(<<"reject">>, Args) -> bouy_jobs:rejected(arg(1, Args));
promise_static(<<"all">>, Args) -> settle_list(fun(L) -> bouy_jobs:all(L, true) end, Args);
promise_static(<<"allSettled">>, Args) -> settle_list(fun bouy_jobs:all_settled/1, Args);
promise_static(<<"race">>, Args) -> settle_list(fun bouy_jobs:race/1, Args);
promise_static(<<"any">>, Args) -> settle_list(fun bouy_jobs:any/1, Args);
promise_static(<<"withResolvers">>, _Args) ->
    {P, Resolve, Reject} = bouy_jobs:capability(),
    bouy_heap:object(?OBJECT_PROTO, [{<<"promise">>, P}, {<<"resolve">>, js(Resolve)}, {<<"reject">>, js(Reject)}]).

%% An iterable that throws rejects the result instead of throwing.
settle_list(Combinator, Args) ->
    try bouy_ref:to_list(arg(1, Args)) of
        L -> Combinator(L)
    catch
        error:Reason:Stack -> bouy_jobs:rejected(bouy_ref:caught(Reason, Stack))
    end.

%%% Errors

error_construct(Name, NewTarget, Args) ->
    Proto = case NewTarget of
        {'$f', {builtin, _}, _} -> {'$o', binary_to_atom(<<Name/binary, ".prototype">>)};
        _ -> bouy_ref:get(NewTarget, <<"prototype">>)
    end,
    {MessageArg, OptionsArg} = case Name of
        <<"AggregateError">> -> {arg(2, Args), arg(3, Args)};
        _ -> {arg(1, Args), arg(2, Args)}
    end,
    Message = case MessageArg of
        undefined -> undefined;
        M -> bouy_ref:to_string(M)
    end,
    Header = case Message of
        undefined -> Name;
        <<>> -> Name;
        _ -> <<Name/binary, ": ", Message/binary>>
    end,
    E = bouy_heap:error_object(Proto, <<>>, <<Header/binary, "\n    at <anonymous>">>),
    case Message of
        undefined -> bouy_heap:delete(E, <<"message">>);
        _ -> bouy_heap:set(E, <<"message">>, Message)
    end,
    case ?IS_OBJECT(OptionsArg) andalso bouy_heap:has(OptionsArg, <<"cause">>) of
        true -> bouy_heap:define(E, <<"cause">>, #{value => bouy_ref:get(OptionsArg, <<"cause">>), writable => true, enumerable => false, configurable => true});
        false -> ok
    end,
    case Name of
        <<"AggregateError">> ->
            bouy_heap:define(E, <<"errors">>, #{value => bouy_heap:new_array(bouy_ref:to_list(arg(1, Args))), writable => true, enumerable => false, configurable => true});
        _ ->
            ok
    end,
    E.

error_to_string(E) ->
    Name = case bouy_ref:get(E, <<"name">>) of
        undefined -> <<"Error">>;
        N -> bouy_ref:to_string(N)
    end,
    Message = case bouy_ref:get(E, <<"message">>) of
        undefined -> <<>>;
        M -> bouy_ref:to_string(M)
    end,
    case {Name, Message} of
        {<<>>, _} -> Message;
        {_, <<>>} -> Name;
        _ -> <<Name/binary, ": ", Message/binary>>
    end.

%%% Date

date_construct(_NewTarget, Args) ->
    {'$date', Ms} = bouy_date:new([unwrap_date(A) || A <- Args]),
    bouy_heap:new_exotic(date, {'$o', 'Date.prototype'}, Ms).

unwrap_date({'$o', _} = O) ->
    case bouy_heap:class_of(O) of
        date -> {'$date', bouy_heap:slots(O)};
        _ -> bouy_ref:to_primitive(O, default)
    end;
unwrap_date(V) -> V.

%%% Math

math_functions() ->
    [<<"abs">>, <<"acos">>, <<"acosh">>, <<"asin">>, <<"asinh">>, <<"atan">>, <<"atan2">>, <<"atanh">>, <<"cbrt">>, <<"ceil">>,
     <<"clz32">>, <<"cos">>, <<"cosh">>, <<"exp">>, <<"expm1">>, <<"floor">>, <<"fround">>, <<"hypot">>, <<"imul">>, <<"log">>,
     <<"log10">>, <<"log1p">>, <<"log2">>, <<"max">>, <<"min">>, <<"pow">>, <<"random">>, <<"round">>, <<"sign">>, <<"sin">>,
     <<"sinh">>, <<"sqrt">>, <<"tan">>, <<"tanh">>, <<"trunc">>].

math(Name, Args) -> bouy_math:(binary_to_existing_atom(Name))(Args).
