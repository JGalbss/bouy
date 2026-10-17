%% The Array family: the Array constructor, its statics, and
%% Array.prototype.
-module(bouy_ref_array).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3]).

-import(bouy_ref_realm, [arg/2, rest/2, builtin/2, record/4, ctor_record/5, callable/1]).
-import(bouy_ref, [type_error/1]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'Array.prototype', record(object, ?OBJECT_PROTO, ?METHODS(<<"Array.prototype">>, array_methods()) ++ [{<<"constructor">>, constructor()}, {?SYM(iterator), builtin(<<"Array.prototype.values">>, fun(This, Args) -> ?MODULE:method(<<"Array.prototype">>, <<"values">>, This, Args) end)}], none)},
     {{builtin, <<"Array">>}, ctor_record(<<"Array">>, 1, {'$o', 'Array.prototype'}, ?METHODS(<<"Array">>, [<<"isArray">>, <<"from">>, <<"of">>]), fun(_NT, Args) -> array_call(undefined, Args) end)}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"Array">>, constructor()}].

constructor() -> bouy_ref_realm:constructor(?MODULE, <<"Array">>).

-spec call_constructor(binary(), term(), list()) -> term().
call_constructor(<<"Array">>, This, Args) -> array_call(This, Args).

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Array.prototype">>, Name, This, Args) -> array_proto(Name, This, Args);
method(<<"Array">>, Name, _This, Args) -> array_static(Name, Args).

array_call(_This, [N]) when is_integer(N), N >= 0 ->
    A = bouy_heap:new_array([]),
    bouy_heap:set(A, <<"length">>, N),
    A;
array_call(_This, Args) ->
    bouy_heap:new_array(Args).

array_methods() ->
    [<<"push">>, <<"pop">>, <<"shift">>, <<"unshift">>, <<"slice">>, <<"splice">>, <<"concat">>, <<"join">>, <<"indexOf">>,
     <<"lastIndexOf">>, <<"includes">>, <<"find">>, <<"findIndex">>, <<"findLast">>, <<"findLastIndex">>, <<"filter">>,
     <<"map">>, <<"forEach">>, <<"some">>, <<"every">>, <<"reduce">>, <<"reduceRight">>, <<"sort">>, <<"reverse">>,
     <<"fill">>, <<"at">>, <<"flat">>, <<"flatMap">>, <<"keys">>, <<"values">>, <<"entries">>, <<"toString">>,
     <<"toSorted">>, <<"toReversed">>].

%% The items of an array, or of an array-like object by its length, as the
%% methods that only read take them.
items(A) ->
    case is_array(A) of
        true -> bouy_heap:array_items(A);
        false -> [bouy_ref:get(A, I) || I <- lists:seq(0, max(0, int(bouy_ref:get(A, <<"length">>))) - 1)]
    end.

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
    bouy_ref_string:concat(lists:join(Sep, [join_text(V) || V <- items(A)]));
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
    F = callable(arg(1, Args)),
    bouy_heap:new_array([V || {I, V} <- lists:enumerate(0, items(A)), bouy_ref:truthy(bouy_ref:call(F, arg(2, Args), [V, I, A]))]);
array_proto(<<"map">>, A, Args) ->
    F = callable(arg(1, Args)),
    bouy_heap:new_array([bouy_ref:call(F, arg(2, Args), [V, I, A]) || {I, V} <- lists:enumerate(0, items(A))]);
array_proto(<<"forEach">>, A, Args) ->
    F = callable(arg(1, Args)),
    [bouy_ref:call(F, arg(2, Args), [V, I, A]) || {I, V} <- lists:enumerate(0, items(A))],
    undefined;
array_proto(<<"some">>, A, Args) ->
    F = callable(arg(1, Args)),
    lists:any(fun({I, V}) -> bouy_ref:truthy(bouy_ref:call(F, arg(2, Args), [V, I, A])) end, lists:enumerate(0, items(A)));
array_proto(<<"every">>, A, Args) ->
    F = callable(arg(1, Args)),
    lists:all(fun({I, V}) -> bouy_ref:truthy(bouy_ref:call(F, arg(2, Args), [V, I, A])) end, lists:enumerate(0, items(A)));
array_proto(<<"reduce">>, A, Args) -> reduce(A, Args, lists:enumerate(0, items(A)));
array_proto(<<"reduceRight">>, A, Args) -> reduce(A, Args, lists:reverse(lists:enumerate(0, items(A))));
array_proto(<<"sort">>, A, Args) ->
    L = items(A),
    {Defined, Undefined} = lists:partition(fun(V) -> V =/= undefined end, L),
    Sorted = case arg(1, Args) of
        undefined -> [V || {_, V} <- lists:sort(fun({X, _}, {Y, _}) -> bouy_ref_string:compare(X, Y) =/= gt end, [{bouy_ref:to_string(V), V} || V <- Defined])];
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
    F = callable(arg(1, Args)),
    Mapped = [bouy_ref:call(F, arg(2, Args), [V, I, A]) || {I, V} <- lists:enumerate(0, items(A))],
    bouy_heap:new_array(flatten(Mapped, 1));
array_proto(<<"keys">>, A, _) -> bouy_ref_iterator:list_iterator(<<"Array Iterator">>, lists:seq(0, bouy_heap:array_length(A) - 1));
array_proto(<<"values">>, A, _) -> bouy_ref_iterator:list_iterator(<<"Array Iterator">>, items(A));
array_proto(<<"entries">>, A, _) -> bouy_ref_iterator:list_iterator(<<"Array Iterator">>, [bouy_heap:new_array([I, V]) || {I, V} <- lists:enumerate(0, items(A))]).

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
    F = callable(arg(1, Args)),
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
    F = callable(arg(1, Args)),
    find_in(lists:reverse(lists:enumerate(0, items(A))), F, arg(2, Args), A, What).

reduce(A, Args, Indexed) ->
    F = callable(arg(1, Args)),
    {Acc0, Rest} = case Args of
        [_, Init | _] -> {Init, Indexed};
        _ ->
            case Indexed of
                [] -> type_error(<<"Reduce of empty array with no initial value">>);
                [{_, First} | T] -> {First, T}
            end
    end,
    lists:foldl(fun({I, V}, Acc) -> bouy_ref:call(F, undefined, [Acc, V, I, A]) end, Acc0, Rest).

array_static(<<"isArray">>, Args) -> bouy_ref_object:is_array(arg(1, Args));
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
                    bouy_ref_iterator:to_list(S)
            end;
        S when ?IS_STRING(S) -> bouy_ref_iterator:to_list(S);
        _ -> []
    end,
    case arg(2, Args) of
        undefined -> bouy_heap:new_array(Items);
        F -> bouy_heap:new_array([bouy_ref:call(F, arg(3, Args), [V, I]) || {I, V} <- lists:enumerate(0, Items)])
    end.
