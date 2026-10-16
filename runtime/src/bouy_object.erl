%% The `Object` namespace. Objects are maps with binary keys, and keys
%% iterate in Erlang term order (contract section 3).
-module(bouy_object).

-export(['$member'/1, '$call'/1, new/1]).
-export([keys/1, values/1, entries/1, 'fromEntries'/1, assign/1, freeze/1, 'hasOwn'/1]).
-export([is/1, create/1, 'getOwnPropertyNames'/1, 'groupBy'/1, 'setPrototypeOf'/1]).
-export([own_entries/1, groups/2]).

-define(FUNCTIONS, [
    <<"keys">>, <<"values">>, <<"entries">>, <<"fromEntries">>, <<"assign">>, <<"freeze">>, <<"hasOwn">>,
    <<"is">>, <<"create">>, <<"getOwnPropertyNames">>, <<"groupBy">>, <<"setPrototypeOf">>
]).

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
    maps:from_list([entry(Entry) || Entry <- bouy_rt:to_list(bouy_rt:arg(1, Args))]).

entry(Entry) when is_list(Entry); is_map(Entry); is_tuple(Entry) ->
    {bouy_rt:to_key(bouy_rt:get(Entry, 0)), bouy_rt:get(Entry, 1)};
entry(Entry) ->
    bouy_error:throw(<<"TypeError">>, <<"Iterator value ", (bouy_rt:describe(Entry))/binary, " is not an entry object">>).

-spec assign(list()) -> term().
assign([Target | Sources]) ->
    lists:foldl(fun assign_source/2, object(Target), Sources);
assign([]) ->
    object(undefined).

assign_source(Source, Target) ->
    lists:foldl(fun({Key, Value}, Acc) -> bouy_rt:set(Acc, Key, Value) end, Target, own_entries(Source)).

%% Values are immutable copies, so freezing changes nothing (contract
%% section 3).
-spec freeze(list()) -> term().
freeze(Args) -> bouy_rt:arg(1, Args).

%% Bouy values have no prototype chain to change: an error keeps the
%% classes that built it, so `Object.setPrototypeOf(this, E.prototype)` in
%% an error constructor has nothing to do.
-spec 'setPrototypeOf'(list()) -> term().
'setPrototypeOf'(Args) -> object(bouy_rt:arg(1, Args)).

-spec 'hasOwn'(list()) -> boolean().
'hasOwn'(Args) ->
    has_own(object(bouy_rt:arg(1, Args)), bouy_rt:to_key(bouy_rt:arg(2, Args))).

has_own(Object, Key) when is_map(Object) -> maps:is_key(Key, Object);
has_own(Value, <<"length">>) when is_list(Value); is_binary(Value) -> true;
has_own(Value, Key) -> lists:keymember(Key, 1, own_entries(Value)).

%% SameValue: NaN equals NaN, and 0 differs from -0.
-spec is(list()) -> boolean().
is(Args) ->
    same_value(bouy_rt:arg(1, Args), bouy_rt:arg(2, Args)).

same_value(A, B) when is_float(A), A == 0; is_float(B), B == 0 ->
    is_number(A) andalso is_number(B) andalso A == B andalso negative_zero(A) =:= negative_zero(B);
same_value(A, B) ->
    bouy_rt:same_value_zero(A, B).

negative_zero(F) when is_float(F) -> <<F/float>> =:= <<(-0.0)/float>>;
negative_zero(_) -> false.

%% `Object.create(null)` and `Object.create(Object.prototype)`: an empty
%% object. Bouy objects have no prototype chain, so another prototype is
%% an error instead of an object that silently lacks its inherited members.
-spec create(list()) -> map().
create(Args) ->
    case bouy_rt:arg(1, Args) of
        null -> #{};
        {'$prototype', {'$namespace', ?MODULE}} -> #{};
        _ -> bouy_error:throw(<<"TypeError">>, <<"Object.create takes null or Object.prototype: Bouy objects have no prototype chain">>)
    end.

%% The own keys, the ones that JavaScript does not enumerate included.
-spec 'getOwnPropertyNames'(list()) -> [binary()].
'getOwnPropertyNames'(Args) ->
    case object(bouy_rt:arg(1, Args)) of
        #{'$error' := _} = Error -> hidden_names(Error) ++ keys([Error]);
        Value when is_list(Value); is_binary(Value) -> keys([Value]) ++ [<<"length">>];
        Value -> keys([Value])
    end.

hidden_names(Error) ->
    [Key || Key <- [<<"stack">>, <<"message">>, <<"cause">>], maps:is_key(Key, Error)].

%% `Object.groupBy(items, f)`: an object of arrays, in the order of the items.
-spec 'groupBy'(list()) -> map().
'groupBy'(Args) ->
    maps:from_list([{bouy_rt:to_key(Key), Items} || {Key, Items} <- groups(bouy_rt:arg(1, Args), bouy_rt:arg(2, Args))]).

%% The items of an iterable grouped by the key that F returns for each
%% one, keys and items in their first order.
-spec groups(term(), term()) -> [{term(), list()}].
groups(Iterable, F) ->
    Keyed = [{bouy_rt:call(F, [Item, Index]), Item} || {Index, Item} <- lists:enumerate(0, bouy_rt:to_list(Iterable))],
    Keys = lists:foldl(fun({Key, _}, Seen) -> add_new(Key, Seen) end, [], Keyed),
    [{Key, [Item || {K, Item} <- Keyed, bouy_rt:same_value_zero(K, Key)]} || Key <- lists:reverse(Keys)].

add_new(Key, Seen) ->
    case lists:any(fun(Other) -> bouy_rt:same_value_zero(Other, Key) end, Seen) of
        true -> Seen;
        false -> [Key | Seen]
    end.

own_object_entries(Args) ->
    own_entries(object(bouy_rt:arg(1, Args))).

object(Value) when Value =:= undefined; Value =:= null ->
    bouy_error:throw(<<"TypeError">>, <<"Cannot convert undefined or null to object">>);
object(Value) ->
    Value.

%% The own enumerable properties of any value, sorted by key: what
%% `Object.entries`, `for...in`, and object spreads visit. Only binary keys
%% are properties: the compiler keeps private fields under atom keys.
-spec own_entries(term()) -> [{binary(), term()}].
own_entries(#{'$error' := _} = Error) ->
    lists:sort(maps:to_list(bouy_error:fields(Error)));
own_entries(Object) when is_map(Object) ->
    lists:sort([{Key, Value} || Key := Value <- Object, is_binary(Key)]);
own_entries(L) when is_list(L) ->
    [{integer_to_binary(I), Item} || {I, Item} <- lists:enumerate(0, L)];
own_entries(S) when is_binary(S) ->
    [{integer_to_binary(I), Char} || {I, Char} <- lists:enumerate(0, bouy_rt:to_list(S))];
own_entries(_) ->
    [].
