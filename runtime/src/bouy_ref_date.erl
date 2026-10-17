%% The Date family: the Date constructor, Date.now, and Date.prototype over
%% the time value in milliseconds that a date object holds in its slots.
-module(bouy_ref_date).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3]).

-import(bouy_ref_realm, [arg/2, rest/2, builtin/2, record/4, ctor_record/5, callable/1]).
-import(bouy_ref, [type_error/1]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'Date.prototype', record(object, ?OBJECT_PROTO, ?METHODS(<<"Date.prototype">>, [<<"getTime">>, <<"valueOf">>, <<"toISOString">>, <<"toJSON">>, <<"toString">>]) ++ [{<<"constructor">>, constructor()}], none)},
     {{builtin, <<"Date">>}, ctor_record(<<"Date">>, 7, {'$o', 'Date.prototype'}, ?METHODS(<<"Date">>, [<<"now">>]), fun date_construct/2)}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"Date">>, constructor()}].

constructor() -> bouy_ref_realm:constructor(?MODULE, <<"Date">>).

-spec call_constructor(binary(), term(), list()) -> term().
call_constructor(<<"Date">>, _This, _Args) -> bouy_date:call(<<"toString">>, {'$date', erlang:system_time(millisecond)}, []).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Date.prototype">>, Name, This, Args) -> bouy_date:call(Name, {'$date', bouy_heap:slots(This)}, Args);
method(<<"Date">>, <<"now">>, _This, _Args) -> erlang:system_time(millisecond).

date_construct(_NewTarget, Args) ->
    {'$date', Ms} = bouy_date:new([unwrap_date(A) || A <- Args]),
    bouy_heap:new_exotic(date, {'$o', 'Date.prototype'}, Ms).

unwrap_date({'$o', _} = O) ->
    case bouy_heap:class_of(O) of
        date -> {'$date', bouy_heap:slots(O)};
        _ -> bouy_ref:to_primitive(O, default)
    end;
unwrap_date(V) -> V.
