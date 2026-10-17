-module(mapset_typed).

%% Map and Set as a typed compilation on Erlang maps. A JavaScript Map keeps insertion
%% order, so `counts`, whose key order the program reads, maps each key to {Seq, Count}
%% and sorts by Seq when it iterates. Whole-program analysis drops the order where nothing
%% observes it: the program never iterates `seen`, and it folds `accounts` into an integer
%% sum, which does not depend on order. The Account objects never escape the map, so they
%% are tuples that each update replaces.

-export([main/1]).

-define(OPERATIONS, 200000).
-define(MODULUS, 100003).
-define(WORD_COUNT, 5000).

-spec main([string()]) -> no_return().
main(Args) ->
    Words = list_to_tuple([
        <<"w", (string:lowercase(integer_to_binary(I, 36)))/binary>>
     || I <- lists:seq(0, ?WORD_COUNT - 1)
    ]),
    speed_harness:bench(<<"mapset">>, 1, fun(Size) -> iteration(Size, Words, 0) end, Args).

iteration(0, _Words, Check) -> Check;
iteration(Size, Words, Check) -> iteration(Size - 1, Words, Check + scan(Words)).

scan(Words) ->
    Counts = count(0, Words, #{}, 0),
    {Seen, Duplicates} = track(0, #{}, 0),
    Seen1 = delete_every_third(0, Seen),
    Accounts = group(0, #{}),
    Sum = maps:fold(fun(_, {_, Count}, Acc) -> Acc + Count end, 0, Counts),
    Visits = maps:fold(fun(_, {Total, Visits}, Acc) -> Acc + Visits + Total end, 0, Accounts),
    FirstKeys = iolist_size(lists:join(<<",">>, lists:sublist(ordered_keys(Counts), 3))),
    Sum + Duplicates + map_size(Seen1) + Visits + FirstKeys.

count(?OPERATIONS, _Words, Counts, _Next) ->
    Counts;
count(I, Words, Counts, Next) ->
    Word = element((I * 7919) rem ?WORD_COUNT + 1, Words),
    case Counts of
        #{Word := {Seq, Count}} -> count(I + 1, Words, Counts#{Word := {Seq, Count + 1}}, Next);
        #{} -> count(I + 1, Words, Counts#{Word => {Next, 1}}, Next + 1)
    end.

ordered_keys(Counts) -> [Key || {_, Key} <- lists:sort([{Seq, Key} || Key := {Seq, _} <- Counts])].

track(?OPERATIONS, Seen, Duplicates) ->
    {Seen, Duplicates};
track(I, Seen, Duplicates) ->
    Key = (I * 2654435761) rem ?MODULUS,
    case Seen of
        #{Key := _} -> track(I + 1, Seen, Duplicates + 1);
        #{} -> track(I + 1, Seen#{Key => []}, Duplicates)
    end.

delete_every_third(Key, Seen) when Key >= ?MODULUS -> Seen;
delete_every_third(Key, Seen) -> delete_every_third(Key + 3, maps:remove(Key, Seen)).

group(?OPERATIONS, Accounts) ->
    Accounts;
group(I, Accounts) ->
    Id = (I * 31) rem 20011,
    case Accounts of
        #{Id := {Total, Visits}} -> group(I + 1, Accounts#{Id := {Total + I rem 100, Visits + 1}});
        #{} -> group(I + 1, Accounts#{Id => {I rem 100, 1}})
    end.
