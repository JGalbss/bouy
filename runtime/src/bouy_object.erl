%% The `Object` namespace. Objects are maps with binary keys, and keys
%% iterate in Erlang term order (contract section 3).
-module(bouy_object).

-export(['$member'/1, '$call'/1, new/1]).
-export([keys/1, values/1, entries/1, 'fromEntries'/1, assign/1, freeze/1, 'hasOwn'/1]).
-export([own_entries/1]).

-define(FUNCTIONS, [<<"keys">>, <<"values">>, <<"entries">>, <<"fromEntries">>, <<"assign">>, <<"freeze">>, <<"hasOwn">>]).

-spec '$member'(binary()) -> term().
'$member'(Name) -> bouy_rt:member_function(?MODULE, Name, ?FUNCTIONS).

%% `Object(x)`: an object stays itself, null and undefined become `{}`.
%% Bouy has no wrapper objects, so a primitive stays a primitive.
-spec '$call'(list()) -> term().
'$call'(Args) ->
    case bouy_rt:arg(1, Args) of
        undefined -> #{};
        null -> #{};
        Value -> Value
    end.

-spec new(list()) -> term().
new(Args) -> '$call'(Args).

-spec keys(list()) -> [binary()].
keys(Args) -> [Key || {Key, _} <- own_object_entries(Args)].

-spec values(list()) -> list().
values(Args) -> [Value || {_, Value} <- own_object_entries(Args)].

-spec entries(list()) -> [[term()]].
entries(Args) -> [[Key, Value] || {Key, Value} <- own_object_entries(Args)].

-spec 'fromEntries'(list()) -> map().
'fromEntries'(Args) ->
    maps:from_list([{bouy_rt:to_key(bouy_rt:get(Entry, 0)), bouy_rt:get(Entry, 1)} || Entry <- bouy_rt:to_list(bouy_rt:arg(1, Args))]).

-spec assign(list()) -> term().
assign([Target | Sources]) ->
    lists:foldl(fun assign_source/2, object(Target), Sources);
assign([]) ->
    object(undefined).

assign_source(Source, Target) ->
    lists:foldl(fun({Key, Value}, Acc) -> bouy_rt:set(Acc, Key, Value) end, Target, own_entries(Source)).

%% Values are immutable, so freezing changes nothing.
-spec freeze(list()) -> term().
freeze(Args) -> bouy_rt:arg(1, Args).

-spec 'hasOwn'(list()) -> boolean().
'hasOwn'(Args) ->
    has_own(object(bouy_rt:arg(1, Args)), bouy_rt:to_key(bouy_rt:arg(2, Args))).

has_own(#{<<"$error">> := true}, <<"$error">>) -> false;
has_own(Object, Key) when is_map(Object) -> maps:is_key(Key, Object);
has_own(Value, <<"length">>) when is_list(Value); is_binary(Value) -> true;
has_own(Value, Key) -> lists:keymember(Key, 1, own_entries(Value)).

own_object_entries(Args) ->
    own_entries(object(bouy_rt:arg(1, Args))).

object(Value) when Value =:= undefined; Value =:= null ->
    bouy_error:throw(<<"TypeError">>, <<"Cannot convert undefined or null to object">>);
object(Value) ->
    Value.

%% The own enumerable properties of any value, sorted by key: what
%% `Object.entries`, `for...in`, and object spreads visit.
-spec own_entries(term()) -> [{binary(), term()}].
own_entries(#{<<"$error">> := true} = Error) ->
    lists:sort(maps:to_list(bouy_error:fields(Error)));
own_entries(Object) when is_map(Object) ->
    lists:sort(maps:to_list(Object));
own_entries(L) when is_list(L) ->
    [{integer_to_binary(I), Item} || {I, Item} <- lists:enumerate(0, L)];
own_entries(S) when is_binary(S) ->
    [{integer_to_binary(I), Char} || {I, Char} <- lists:enumerate(0, bouy_rt:to_list(S))];
own_entries(_) ->
    [].
