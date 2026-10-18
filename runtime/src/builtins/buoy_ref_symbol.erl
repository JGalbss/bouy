%% The Symbol family: the Symbol function, its registry functions, the
%% well-known symbols, and Symbol.prototype.
-module(buoy_ref_symbol).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3, well_known_names/0]).

-import(buoy_ref_realm, [arg/2, rest/2, builtin/2, record/4, ctor_record/5, callable/1]).
-import(buoy_ref, [type_error/1]).

%% The well-known symbols of ECMA-262 §6.1.5.1, and asyncDispose and dispose
%% of explicit resource management.
-spec well_known_names() -> [atom()].
well_known_names() ->
    [asyncDispose, asyncIterator, dispose, hasInstance, isConcatSpreadable, iterator, match, matchAll, replace, search,
     species, split, toPrimitive, toStringTag, unscopables].

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Description = buoy_ref_realm:builtin(<<"Symbol.prototype.description">>, <<"get description">>, 0,
                                         fun(This, Args) -> ?MODULE:method(<<"Symbol.prototype">>, <<"description">>, This, Args) end),
    ToPrimitive = buoy_ref_realm:builtin(<<"Symbol.prototype[Symbol.toPrimitive]">>, <<"[Symbol.toPrimitive]">>, 1,
                                         fun(This, Args) -> ?MODULE:method(<<"Symbol.prototype">>, <<"valueOf">>, This, Args) end),
    ProtoEntries = ?METHODS(<<"Symbol.prototype">>, [{<<"toString">>, 0}, {<<"valueOf">>, 0}])
        ++ [{<<"constructor">>, constructor()}, {<<"description">>, {'$accessor', Description, undefined}},
            {?SYM(toPrimitive), ToPrimitive}, {?SYM(toStringTag), <<"Symbol">>}],
    {PC, PP, PProps, PKeys, PAttrs, PSlots} = record(object, ?OBJECT_PROTO, ProtoEntries, none),
    ProtoAttrs = PAttrs#{<<"description">> => 4, ?SYM(toPrimitive) => 4, ?SYM(toStringTag) => 4},
    Wellknown = [{atom_to_binary(W), ?SYM(W)} || W <- well_known_names()],
    {CC, CP, CProps, CKeys, CAttrs, CSlots} =
        ctor_record(<<"Symbol">>, 0, {'$o', 'Symbol.prototype'}, ?METHODS(<<"Symbol">>, [{<<"for">>, 1}, {<<"keyFor">>, 1}]) ++ Wellknown,
                    fun buoy_ref_realm:not_constructible/2),
    Fixed = maps:from_list([{K, 0} || {K, _} <- Wellknown]),
    [{'Symbol.prototype', {PC, PP, PProps, PKeys, ProtoAttrs, PSlots}},
     {{builtin, <<"Symbol">>}, {CC, CP, CProps, CKeys, maps:merge(CAttrs, Fixed), CSlots}}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"Symbol">>, constructor()}].

constructor() -> buoy_ref_realm:constructor(?MODULE, <<"Symbol">>).

-spec call_constructor(binary(), term(), list()) -> term().
call_constructor(<<"Symbol">>, _This, Args) ->
    case arg(1, Args) of
        undefined -> buoy_heap:symbol(undefined);
        D -> buoy_heap:symbol(buoy_ref:to_string(D))
    end.

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Symbol.prototype">>, <<"toString">>, This, _) -> descriptive(this_symbol(This));
method(<<"Symbol.prototype">>, <<"valueOf">>, This, _) -> this_symbol(This);
method(<<"Symbol.prototype">>, <<"description">>, This, _) -> element(3, this_symbol(This));
method(<<"Symbol">>, <<"for">>, _This, Args) -> buoy_heap:symbol_for(buoy_ref:to_string(arg(1, Args)));
method(<<"Symbol">>, <<"keyFor">>, _This, Args) ->
    case arg(1, Args) of
        {'$sym', registered, Key} -> Key;
        {'$sym', _, _} -> undefined;
        V -> type_error(buoy_ref_string:concat(buoy_ref:to_string(describe(V)), <<" is not a symbol">>))
    end.

%% thisSymbolValue: a symbol, or the [[SymbolData]] of a Symbol object.
this_symbol({'$sym', _, _} = S) -> S;
this_symbol({'$o', _} = O) ->
    case buoy_heap:class_of(O) of
        symbol -> buoy_heap:slots(O);
        _ -> type_error(<<"Symbol.prototype method called on incompatible receiver">>)
    end;
this_symbol(_) -> type_error(<<"Symbol.prototype method called on incompatible receiver">>).

%% SymbolDescriptiveString.
descriptive({'$sym', _, undefined}) -> <<"Symbol()">>;
descriptive({'$sym', _, D}) -> buoy_ref_string:concat([<<"Symbol(">>, D, <<")">>]).

describe(V) when ?IS_OBJECT(V) -> <<"[object Object]">>;
describe(V) -> V.
