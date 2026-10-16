%% `Map`. A Map is `{'$map', {Index, Next}}`: Index maps each key to
%% `{Sequence, Value}`, and Next is the next sequence number. Iteration
%% sorts by sequence, so entries keep insertion order (contract section 3).
-module(bouy_map).

-export(['$member'/1, new/1, call/3, get/2, mutate/3]).
-export([entries/1]).

-type map_value() :: {'$map', {#{term() => {non_neg_integer(), term()}}, non_neg_integer()}}.
-export_type([map_value/0]).

-spec '$member'(binary()) -> undefined.
'$member'(_Name) -> undefined.

%% `new Map(entries)`.
-spec new(list()) -> map_value().
new(Args) ->
    case bouy_rt:arg(1, Args) of
        Empty when Empty =:= undefined; Empty =:= null -> empty();
        Iterable -> lists:foldl(fun add_entry/2, empty(), bouy_rt:to_list(Iterable))
    end.

add_entry(Entry, Map) when is_list(Entry); is_map(Entry) ->
    put(Map, bouy_rt:get(Entry, 0), bouy_rt:get(Entry, 1));
add_entry(Entry, _Map) ->
    bouy_error:throw(<<"TypeError">>, <<"Iterator value ", (bouy_rt:describe(Entry))/binary, " is not an entry object">>).

empty() -> {'$map', {#{}, 0}}.

-spec get(map_value(), term()) -> term().
get({'$map', {Index, _}}, <<"size">>) -> map_size(Index);
get(_Map, _Key) -> undefined.

%% The entries in insertion order.
-spec entries(map_value()) -> [{term(), term()}].
entries({'$map', {Index, _}}) ->
    [{Key, Value} || {_, Key, Value} <- lists:sort([{Sequence, Key, Value} || Key := {Sequence, Value} <- Index])].

-spec call(binary(), map_value(), list()) -> term().
call(<<"get">>, {'$map', {Index, _}}, Args) ->
    case maps:find(bouy_rt:collection_key(bouy_rt:arg(1, Args)), Index) of
        {ok, {_, Value}} -> Value;
        error -> undefined
    end;
call(<<"has">>, {'$map', {Index, _}}, Args) ->
    maps:is_key(bouy_rt:collection_key(bouy_rt:arg(1, Args)), Index);
call(<<"forEach">>, Map, Args) ->
    F = bouy_rt:arg(1, Args),
    lists:foreach(fun({Key, Value}) -> bouy_rt:call(F, [Value, Key, Map]) end, entries(Map)),
    undefined;
call(<<"keys">>, Map, _Args) ->
    [Key || {Key, _} <- entries(Map)];
call(<<"values">>, Map, _Args) ->
    [Value || {_, Value} <- entries(Map)];
call(<<"entries">>, Map, _Args) ->
    [[Key, Value] || {Key, Value} <- entries(Map)];
call(<<"set">>, Map, Args) ->
    element(2, mutate(<<"set">>, Map, Args));
call(Name, Map, Args) when Name =:= <<"delete">>; Name =:= <<"clear">> ->
    element(1, mutate(Name, Map, Args));
call(Name, Map, _Args) ->
    bouy_rt:no_method(Map, Name).

-spec mutate(binary(), map_value(), list()) -> {term(), map_value()}.
mutate(<<"set">>, Map, Args) ->
    New = put(Map, bouy_rt:arg(1, Args), bouy_rt:arg(2, Args)),
    {New, New};
mutate(<<"delete">>, {'$map', {Index, Next}}, Args) ->
    Key = bouy_rt:collection_key(bouy_rt:arg(1, Args)),
    {maps:is_key(Key, Index), {'$map', {maps:remove(Key, Index), Next}}};
mutate(<<"clear">>, _Map, _Args) ->
    {undefined, empty()};
mutate(Name, Map, Args) ->
    {call(Name, Map, Args), Map}.

%% Setting an existing key keeps its position.
put({'$map', {Index, Next}}, KeyArg, Value) ->
    Key = bouy_rt:collection_key(KeyArg),
    case Index of
        #{Key := {Sequence, _}} -> {'$map', {Index#{Key := {Sequence, Value}}, Next}};
        _ -> {'$map', {Index#{Key => {Next, Value}}, Next + 1}}
    end.
