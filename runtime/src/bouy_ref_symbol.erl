%% The Symbol family: the Symbol function, its registry functions, the
%% well-known symbols, and Symbol.prototype.
-module(bouy_ref_symbol).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3]).

-import(bouy_ref_realm, [arg/2, rest/2, builtin/2, record/4, ctor_record/5, callable/1]).
-import(bouy_ref, [type_error/1]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    ToPrimitive = bouy_ref_realm:function(<<"Symbol.prototype[Symbol.toPrimitive]">>, <<"[Symbol.toPrimitive]">>, 1,
                                          fun(This, _) -> ?MODULE:method(<<"Symbol.prototype">>, <<"valueOf">>, This, []) end),
    Description = bouy_ref_realm:function(<<"get Symbol.prototype.description">>, <<"get description">>, 0,
                                          fun(This, _) -> ?MODULE:method(<<"Symbol.prototype">>, <<"description">>, This, []) end),
    [{'Symbol.prototype', record(object, ?OBJECT_PROTO, ?METHODS(<<"Symbol.prototype">>, [{<<"toString">>, 0}, {<<"valueOf">>, 0}])
          ++ [{<<"constructor">>, constructor()}, {<<"description">>, {'$accessor', Description, undefined}, 4},
              {?SYM(toPrimitive), ToPrimitive, 4}, {?SYM(toStringTag), <<"Symbol">>, 4}], none)},
     {{builtin, <<"Symbol">>}, ctor_record(<<"Symbol">>, 0, {'$o', 'Symbol.prototype'}, ?METHODS(<<"Symbol">>, [<<"for">>, <<"keyFor">>])
         ++ [{atom_to_binary(W), ?SYM(W), 0} || W <- [asyncIterator, hasInstance, isConcatSpreadable, iterator, match, matchAll, replace, search, species, split, toPrimitive, toStringTag, unscopables]], fun bouy_ref_realm:not_constructible/2)}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"Symbol">>, constructor()}].

constructor() -> bouy_ref_realm:constructor(?MODULE, <<"Symbol">>).

-spec call_constructor(binary(), term(), list()) -> term().
call_constructor(<<"Symbol">>, _This, Args) ->
    case arg(1, Args) of
        undefined -> bouy_heap:symbol(undefined);
        D -> bouy_heap:symbol(bouy_ref:to_string(D))
    end.

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Symbol.prototype">>, <<"toString">>, This, _) -> bouy_ref:describe(this_symbol(This));
method(<<"Symbol.prototype">>, <<"valueOf">>, This, _) -> this_symbol(This);
method(<<"Symbol.prototype">>, <<"description">>, This, _) -> element(3, this_symbol(This));
method(<<"Symbol">>, <<"for">>, _This, Args) -> bouy_heap:symbol_for(bouy_ref:to_string(arg(1, Args)));
method(<<"Symbol">>, <<"keyFor">>, _This, Args) ->
    case arg(1, Args) of
        {'$sym', registered, Key} -> Key;
        _ -> undefined
    end.

%% thisSymbolValue: a symbol, or the [[SymbolData]] of a Symbol object.
this_symbol({'$sym', _, _} = S) -> S;
this_symbol({'$o', _} = O) ->
    case bouy_heap:class_of(O) of
        symbol -> bouy_heap:slots(O);
        _ -> type_error(<<"Symbol.prototype method called on incompatible receiver">>)
    end;
this_symbol(_) -> type_error(<<"Symbol.prototype method called on incompatible receiver">>).
