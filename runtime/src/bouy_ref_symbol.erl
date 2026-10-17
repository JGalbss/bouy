%% The Symbol family: the Symbol function, its registry functions, the
%% well-known symbols, and Symbol.prototype.
-module(bouy_ref_symbol).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3]).

-import(bouy_ref_realm, [arg/2, rest/2, builtin/2, record/4, ctor_record/5, callable/1]).
-import(bouy_ref, [type_error/1]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'Symbol.prototype', record(object, ?OBJECT_PROTO, ?METHODS(<<"Symbol.prototype">>, [<<"toString">>, <<"valueOf">>]) ++ [{<<"constructor">>, constructor()}], none)},
     {{builtin, <<"Symbol">>}, ctor_record(<<"Symbol">>, 0, {'$o', 'Symbol.prototype'}, ?METHODS(<<"Symbol">>, [<<"for">>, <<"keyFor">>])
         ++ [{atom_to_binary(W), ?SYM(W)} || W <- [iterator, asyncIterator, hasInstance, toPrimitive, toStringTag, match, matchAll, replace, search, split, species]], fun bouy_ref_realm:not_constructible/2)}].

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
method(<<"Symbol.prototype">>, <<"toString">>, This, _) -> bouy_ref:describe(This);
method(<<"Symbol.prototype">>, <<"valueOf">>, This, _) -> This;
method(<<"Symbol">>, <<"for">>, _This, Args) -> bouy_heap:symbol_for(bouy_ref:to_string(arg(1, Args)));
method(<<"Symbol">>, <<"keyFor">>, _This, Args) ->
    case arg(1, Args) of
        {'$sym', registered, Key} -> Key;
        _ -> undefined
    end.
