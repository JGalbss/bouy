%% `Array.prototype.sort` with a comparator, as V8 sorts: binary insertion
%% sort for up to 7 items, else TimSort with runs, galloping merges, and
%% V8's order of comparator calls. A comparator that is not consistent,
%% such as `(a, b) => a < b ? -1 : 1`, so orders items exactly as Node does.
%%
%% Runs are tuples for random access, and a merge builds a new tuple, so
%% the copies cost O(n log n) as in any merge sort.
-module(bouy_sort).

-export([sort/2]).

-define(SMALL, 7).
-define(MIN_GALLOP, 7).

%% Items without undefined, and the comparator function value.
-spec sort(list(), term()) -> list().
sort(Items, F) ->
    Compare = fun(X, Y) -> order(bouy_rt:to_number(bouy_rt:call(F, [X, Y]))) end,
    case length(Items) of
        N when N < 2 -> Items;
        N when N =< ?SMALL -> tuple_to_list(insert_all(list_to_tuple(tl(Items)), {hd(Items)}, Compare));
        N -> timsort(Items, min_run(N, 0), Compare)
    end.

%% The comparator result as V8 reads it: NaN is 0.
order('NaN') -> 0;
order('-Infinity') -> -1;
order('Infinity') -> 1;
order(N) when N < 0 -> -1;
order(N) when N > 0 -> 1;
order(_) -> 0.

min_run(N, R) when N >= 64 -> min_run(N bsr 1, R bor (N band 1));
min_run(N, R) -> N + R.

%%% Binary insertion

%% Inserts each item of the tuple Pending into the sorted tuple Sorted.
insert_all(Pending, Sorted, Compare) ->
    lists:foldl(fun(Pivot, Acc) -> insert(Pivot, Acc, Compare) end, Sorted, tuple_to_list(Pending)).

insert(Pivot, Sorted, Compare) ->
    Left = insertion_point(Pivot, Sorted, 0, tuple_size(Sorted), Compare),
    erlang:insert_element(Left + 1, Sorted, Pivot).

insertion_point(_Pivot, _Sorted, Left, Right, _Compare) when Left >= Right ->
    Left;
insertion_point(Pivot, Sorted, Left, Right, Compare) ->
    Mid = Left + ((Right - Left) bsr 1),
    case Compare(Pivot, element(Mid + 1, Sorted)) < 0 of
        true -> insertion_point(Pivot, Sorted, Left, Mid, Compare);
        false -> insertion_point(Pivot, Sorted, Mid + 1, Right, Compare)
    end.

%%% TimSort

%% Stack holds the pending runs {Length, Tuple}, the last run first.
timsort(Items, MinRun, Compare) ->
    timsort(Items, MinRun, Compare, [], ?MIN_GALLOP).

timsort([], _MinRun, Compare, Stack, MinGallop) ->
    {[{_, Run}], _} = force_collapse(Stack, MinGallop, Compare),
    tuple_to_list(Run);
timsort(Items, MinRun, Compare, Stack, MinGallop) ->
    {Run, Rest} = make_run(Items, Compare),
    Length = length(Run),
    {Extended, Remaining} =
        case Length < MinRun of
            true ->
                {Insert, After} = lists:split(min(MinRun - Length, length(Rest)), Rest),
                {insert_all(list_to_tuple(Insert), list_to_tuple(Run), Compare), After};
            false ->
                {list_to_tuple(Run), Rest}
        end,
    {Stack1, MinGallop1} = collapse([{tuple_size(Extended), Extended} | Stack], MinGallop, Compare),
    timsort(Remaining, MinRun, Compare, Stack1, MinGallop1).

%% The natural run at the head of Items, reversed when it descends.
make_run([Only], _Compare) ->
    {[Only], []};
make_run([First, Second | Rest], Compare) ->
    Descending = Compare(Second, First) < 0,
    {Run, Remaining} = extend_run(Rest, Second, [Second, First], Descending, Compare),
    case Descending of
        true -> {Run, Remaining};
        false -> {lists:reverse(Run), Remaining}
    end.

extend_run([Current | Rest] = Items, Previous, Run, Descending, Compare) ->
    Order = Compare(Current, Previous),
    case (Descending andalso Order >= 0) orelse (not Descending andalso Order < 0) of
        true -> {Run, Items};
        false -> extend_run(Rest, Current, [Current | Run], Descending, Compare)
    end;
extend_run([], _Previous, Run, _Descending, _Compare) ->
    {Run, []}.

%% V8's MergeCollapse, on a stack whose head is the last run: C is run
%% n + 1, B is run n, A is run n - 1, and Z is run n - 2.
collapse([C, B | Rest] = Stack, MinGallop, Compare) ->
    Established =
        case Rest of
            [Previous, Z | _] -> invariant(Previous, B, C) andalso invariant(Z, Previous, B);
            [Previous] -> invariant(Previous, B, C);
            [] -> true
        end,
    case {Established, Rest} of
        {false, [A | Below]} when element(1, A) < element(1, C) ->
            {Merged, MinGallop1} = merge_at(A, B, MinGallop, Compare),
            collapse([C, Merged | Below], MinGallop1, Compare);
        {false, _} ->
            merge_top(Stack, MinGallop, Compare);
        {true, _} when element(1, B) =< element(1, C) ->
            merge_top(Stack, MinGallop, Compare);
        {true, _} ->
            {Stack, MinGallop}
    end;
collapse(Stack, MinGallop, _Compare) ->
    {Stack, MinGallop}.

merge_top([C, B | Rest], MinGallop, Compare) ->
    {Merged, MinGallop1} = merge_at(B, C, MinGallop, Compare),
    collapse([Merged | Rest], MinGallop1, Compare).

invariant({LengthA, _}, {LengthB, _}, {LengthC, _}) -> LengthA > LengthB + LengthC.

%% V8's MergeForceCollapse.
force_collapse([C, B, A | Rest], MinGallop, Compare) when element(1, A) < element(1, C) ->
    {Merged, MinGallop1} = merge_at(A, B, MinGallop, Compare),
    force_collapse([C, Merged | Rest], MinGallop1, Compare);
force_collapse([C, B | Rest], MinGallop, Compare) ->
    {Merged, MinGallop1} = merge_at(B, C, MinGallop, Compare),
    force_collapse([Merged | Rest], MinGallop1, Compare);
force_collapse(Stack, MinGallop, _Compare) ->
    {Stack, MinGallop}.

%% Merges the adjacent runs A and B into one run.
merge_at({LengthA, A}, {LengthB, B}, MinGallop, Compare) ->
    Skip = gallop_right(element(1, B), A, 0, LengthA, 0, Compare),
    case Skip =:= LengthA of
        true ->
            {joined([slice(A, 0, LengthA), slice(B, 0, LengthB)]), MinGallop};
        false ->
            Keep = gallop_left(element(LengthA, A), B, 0, LengthB, LengthB - 1, Compare),
            merge_rest(A, Skip, LengthA - Skip, B, Keep, LengthB, MinGallop, Compare)
    end.

merge_rest(A, _Skip, _RestA, B, 0, LengthB, MinGallop, _Compare) ->
    {joined([slice(A, 0, tuple_size(A)), slice(B, 0, LengthB)]), MinGallop};
merge_rest(A, Skip, RestA, B, Keep, LengthB, MinGallop, Compare) ->
    {Merged, MinGallop1} =
        case RestA =< Keep of
            true -> merge_low(A, Skip, RestA, B, Keep, MinGallop, Compare);
            false -> merge_high(A, Skip, RestA, B, Keep, MinGallop, Compare)
        end,
    {joined([slice(A, 0, Skip), Merged, slice(B, Keep, LengthB - Keep)]), MinGallop1}.

joined(Parts) ->
    Items = lists:append(Parts),
    {length(Items), list_to_tuple(Items)}.

%% The Count items of Tuple from the 0-based index From.
slice(_Tuple, _From, 0) -> [];
slice(Tuple, From, Count) -> [element(I, Tuple) || I <- lists:seq(From + 1, From + Count)].

%%% Galloping

%% V8's GallopLeft: the offset in [0, Length] where Key belongs, left of
%% any equal items, searching from Hint.
gallop_left(Key, Array, Base, Length, Hint, Compare) ->
    At = fun(I) -> element(Base + I + 1, Array) end,
    {Low, High} =
        case Compare(At(Hint), Key) < 0 of
            true ->
                Max = Length - Hint,
                {Last, Offset} = gallop(fun(O) -> Compare(At(Hint + O), Key) >= 0 end, 0, 1, Max),
                {Last + Hint, Offset + Hint};
            false ->
                Max = Hint + 1,
                {Last, Offset} = gallop(fun(O) -> Compare(At(Hint - O), Key) < 0 end, 0, 1, Max),
                {Hint - Offset, Hint - Last}
        end,
    bisect(fun(M) -> Compare(At(M), Key) < 0 end, Low + 1, High).

%% V8's GallopRight: like gallop_left, but right of any equal items.
gallop_right(Key, Array, Base, Length, Hint, Compare) ->
    At = fun(I) -> element(Base + I + 1, Array) end,
    {Low, High} =
        case Compare(Key, At(Hint)) < 0 of
            true ->
                Max = Hint + 1,
                {Last, Offset} = gallop(fun(O) -> Compare(Key, At(Hint - O)) >= 0 end, 0, 1, Max),
                {Hint - Offset, Hint - Last};
            false ->
                Max = Length - Hint,
                {Last, Offset} = gallop(fun(O) -> Compare(Key, At(Hint + O)) < 0 end, 0, 1, Max),
                {Last + Hint, Offset + Hint}
        end,
    bisect(fun(M) -> Compare(Key, At(M)) >= 0 end, Low + 1, High).

%% Doubles Offset (0, 1, 3, 7, ...) until Stop holds or Max is reached.
gallop(Stop, Last, Offset, Max) when Offset < Max ->
    case Stop(Offset) of
        true -> {Last, Offset};
        false -> gallop(Stop, Offset, (Offset bsl 1) + 1, Max)
    end;
gallop(_Stop, Last, _Offset, Max) ->
    {Last, Max}.

%% The first M in [Low, High) for which GoRight is false.
bisect(GoRight, Low, High) when Low < High ->
    M = Low + ((High - Low) bsr 1),
    case GoRight(M) of
        true -> bisect(GoRight, M + 1, High);
        false -> bisect(GoRight, Low, M)
    end;
bisect(_GoRight, Low, _High) ->
    Low.

%%% Merging

%% V8's MergeLow: run A from index Skip (RestA items) merges with the first
%% Keep items of run B, front to back. Out is reversed.
-record(low, {a, b, cursor_a, length_a, cursor_b, length_b, out = [], min_gallop, state}).

merge_low(A, Skip, RestA, B, Keep, MinGallop, Compare) ->
    S = #low{a = A, b = B, cursor_a = Skip, length_a = RestA, cursor_b = 0, length_b = Keep, min_gallop = MinGallop, state = MinGallop},
    S1 = take_b(S, 1),
    if
        S1#low.length_b =:= 0 -> low_done(S1);
        S1#low.length_a =:= 1 -> low_copy_b(S1);
        true -> low_straight(S1, 0, 0, Compare)
    end.

low_straight(#low{a = A, b = B, cursor_a = CA, cursor_b = CB, min_gallop = MG} = S, WinsA, WinsB, Compare) ->
    case Compare(element(CB + 1, B), element(CA + 1, A)) < 0 of
        true ->
            S1 = take_b(S, 1),
            if
                S1#low.length_b =:= 0 -> low_done(S1);
                WinsB + 1 >= MG -> low_gallop(S1#low{min_gallop = MG + 1}, 0, WinsB + 1, true, Compare);
                true -> low_straight(S1, 0, WinsB + 1, Compare)
            end;
        false ->
            S1 = take_a(S, 1),
            if
                S1#low.length_a =:= 1 -> low_copy_b(S1);
                WinsA + 1 >= MG -> low_gallop(S1#low{min_gallop = MG + 1}, WinsA + 1, 0, true, Compare);
                true -> low_straight(S1, WinsA + 1, 0, Compare)
            end
    end.

low_gallop(S, WinsA, WinsB, First, Compare) when WinsA >= ?MIN_GALLOP; WinsB >= ?MIN_GALLOP; First ->
    MG = max(1, S#low.min_gallop - 1),
    S0 = S#low{min_gallop = MG, state = MG},
    #low{a = A, b = B, cursor_a = CA, length_a = LA, cursor_b = CB} = S0,
    GotA = gallop_right(element(CB + 1, B), A, CA, LA, 0, Compare),
    S1 = take_a(S0, GotA),
    if
        GotA > 0, S1#low.length_a =:= 1 -> low_copy_b(S1);
        GotA > 0, S1#low.length_a =:= 0 -> low_done(S1);
        true -> low_gallop_b(take_b(S1, 1), GotA, Compare)
    end;
low_gallop(S, _WinsA, _WinsB, _First, Compare) ->
    MG = S#low.min_gallop + 1,
    low_straight(S#low{min_gallop = MG, state = MG}, 0, 0, Compare).

low_gallop_b(#low{length_b = 0} = S, _GotA, _Compare) ->
    low_done(S);
low_gallop_b(S, GotA, Compare) ->
    #low{a = A, b = B, cursor_a = CA, cursor_b = CB, length_b = LB} = S,
    GotB = gallop_left(element(CA + 1, A), B, CB, LB, 0, Compare),
    S1 = take_b(S, GotB),
    case GotB > 0 andalso S1#low.length_b =:= 0 of
        true ->
            low_done(S1);
        false ->
            S2 = take_a(S1, 1),
            case S2#low.length_a =:= 1 of
                true -> low_copy_b(S2);
                false -> low_gallop(S2, GotA, GotB, false, Compare)
            end
    end.

take_a(#low{a = A, cursor_a = CA, length_a = LA, out = Out} = S, Count) ->
    S#low{cursor_a = CA + Count, length_a = LA - Count, out = lists:reverse(slice(A, CA, Count), Out)}.

take_b(#low{b = B, cursor_b = CB, length_b = LB, out = Out} = S, Count) ->
    S#low{cursor_b = CB + Count, length_b = LB - Count, out = lists:reverse(slice(B, CB, Count), Out)}.

%% One run is used up. With a consistent comparator it is B, and the rest of
%% A follows; otherwise the rest of B stays in place after the merge.
low_done(#low{a = A, cursor_a = CA, length_a = LA, b = B, cursor_b = CB, length_b = LB, out = Out, state = State}) ->
    {lists:reverse(Out, slice(A, CA, LA) ++ slice(B, CB, LB)), State}.

%% The last item of A belongs after the rest of B.
low_copy_b(#low{a = A, cursor_a = CA, b = B, cursor_b = CB, length_b = LB, out = Out, state = State}) ->
    {lists:reverse(Out, slice(B, CB, LB) ++ [element(CA + 1, A)]), State}.

%% V8's MergeHigh: the same merge back to front, for a shorter B. Out
%% holds the merged tail in order, and run A is its first LengthA items
%% from index Skip, run B its first LengthB items.
-record(high, {a, skip, length_a, b, length_b, out = [], min_gallop, state}).

merge_high(A, Skip, RestA, B, Keep, MinGallop, Compare) ->
    S = #high{a = A, skip = Skip, length_a = RestA, b = B, length_b = Keep, min_gallop = MinGallop, state = MinGallop},
    S1 = give_a(S, 1),
    if
        S1#high.length_a =:= 0 -> high_done(S1);
        S1#high.length_b =:= 1 -> high_copy_a(S1);
        true -> high_straight(S1, 0, 0, Compare)
    end.

high_straight(#high{a = A, skip = Skip, length_a = LA, b = B, length_b = LB, min_gallop = MG} = S, WinsA, WinsB, Compare) ->
    case Compare(element(LB, B), element(Skip + LA, A)) < 0 of
        true ->
            S1 = give_a(S, 1),
            if
                S1#high.length_a =:= 0 -> high_done(S1);
                WinsA + 1 >= MG -> high_gallop(S1#high{min_gallop = MG + 1}, WinsA + 1, 0, true, Compare);
                true -> high_straight(S1, WinsA + 1, 0, Compare)
            end;
        false ->
            S1 = give_b(S, 1),
            if
                S1#high.length_b =:= 1 -> high_copy_a(S1);
                WinsB + 1 >= MG -> high_gallop(S1#high{min_gallop = MG + 1}, 0, WinsB + 1, true, Compare);
                true -> high_straight(S1, 0, WinsB + 1, Compare)
            end
    end.

high_gallop(S, WinsA, WinsB, First, Compare) when WinsA >= ?MIN_GALLOP; WinsB >= ?MIN_GALLOP; First ->
    MG = max(1, S#high.min_gallop - 1),
    S0 = S#high{min_gallop = MG, state = MG},
    #high{a = A, skip = Skip, length_a = LA, b = B, length_b = LB} = S0,
    GotA = LA - gallop_right(element(LB, B), A, Skip, LA, LA - 1, Compare),
    S1 = give_a(S0, GotA),
    case GotA > 0 andalso S1#high.length_a =:= 0 of
        true ->
            high_done(S1);
        false ->
            S2 = give_b(S1, 1),
            case S2#high.length_b =:= 1 of
                true -> high_copy_a(S2);
                false -> high_gallop_b(S2, GotA, Compare)
            end
    end;
high_gallop(S, _WinsA, _WinsB, _First, Compare) ->
    MG = S#high.min_gallop + 1,
    high_straight(S#high{min_gallop = MG, state = MG}, 0, 0, Compare).

high_gallop_b(S, GotA, Compare) ->
    #high{a = A, skip = Skip, length_a = LA, b = B, length_b = LB} = S,
    GotB = LB - gallop_left(element(Skip + LA, A), B, 0, LB, LB - 1, Compare),
    S1 = give_b(S, GotB),
    if
        GotB > 0, S1#high.length_b =:= 1 -> high_copy_a(S1);
        GotB > 0, S1#high.length_b =:= 0 -> high_done(S1);
        true ->
            S2 = give_a(S1, 1),
            case S2#high.length_a =:= 0 of
                true -> high_done(S2);
                false -> high_gallop(S2, GotA, GotB, false, Compare)
            end
    end.

%% Moves the last Count items of A or B to the front of the merged tail.
give_a(#high{a = A, skip = Skip, length_a = LA, out = Out} = S, Count) ->
    S#high{length_a = LA - Count, out = slice(A, Skip + LA - Count, Count) ++ Out}.

give_b(#high{b = B, length_b = LB, out = Out} = S, Count) ->
    S#high{length_b = LB - Count, out = slice(B, LB - Count, Count) ++ Out}.

%% One run is used up. With a consistent comparator it is A, and the rest of
%% B goes first; otherwise the rest of A stays in place before the merge.
high_done(#high{a = A, skip = Skip, length_a = LA, b = B, length_b = LB, out = Out, state = State}) ->
    {slice(A, Skip, LA) ++ slice(B, 0, LB) ++ Out, State}.

%% The first item of B belongs before the rest of A.
high_copy_a(#high{a = A, skip = Skip, length_a = LA, b = B, out = Out, state = State}) ->
    {[element(1, B) | slice(A, Skip, LA)] ++ Out, State}.
