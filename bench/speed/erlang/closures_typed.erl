-module(closures_typed).

%% Closures and array methods as a typed compilation. No array of the kernel is indexed
%% except the group-by accumulator, so the arrays are lists, filter and map are list
%% comprehensions, and reduce is lists:foldl with the same order of float additions. An
%% Order is a tuple and its status is an atom. The accumulator of the group-by reduce is
%% indexed, so it is a map from the index to the sum. The curried adders stay closures.

-export([main/1]).

-define(CUSTOMERS, 997).

-spec main([string()]) -> no_return().
main(Args) ->
    Orders = [
        {I, I rem ?CUSTOMERS, ((I * 31) rem 10000) / 100, element(I rem 3 + 1, {open, paid, void}), 1 + I rem 5}
     || I <- lists:seq(0, 99999)
    ],
    speed_harness:bench(<<"closures">>, 3, fun(Size) -> iteration(Size, Orders, 0) end, Args).

iteration(0, _Orders, Check) -> Check;
iteration(Size, Orders, Check) -> iteration(Size - 1, Orders, Check + scan(Orders)).

make_adder(K) -> fun(X) -> X + K end.

scan(Orders) ->
    Paid = [Order || {_, _, _, paid, _} = Order <- Orders],
    Totals = [Amount * Items || {_, _, Amount, _, Items} <- Paid],
    Revenue = lists:foldl(fun(T, Sum) -> Sum + T end, 0, Totals),
    BigCustomers = [Customer || {_, Customer, Amount, _, _} <- Orders, Amount > 50],
    AnyVoidBig = lists:any(fun({_, _, Amount, Status, _}) -> Status =:= void andalso Amount > 99.9 end, Orders),
    Top = [
        Id
     || {Id, _, _, _, _} <- lists:sublist(
            lists:sort(
                fun({IdA, _, AmountA, _, _}, {IdB, _, AmountB, _, _}) ->
                    AmountA > AmountB orelse (AmountA == AmountB andalso IdA =< IdB)
                end,
                Paid
            ),
            10
        )
    ],
    ByCustomer = lists:foldl(
        fun({_, Customer, Amount, _, _}, Acc) ->
            #{Customer := Sum} = Acc,
            Acc#{Customer := Sum + Amount}
        end,
        maps:from_keys(lists:seq(0, ?CUSTOMERS - 1), 0),
        Orders
    ),
    Adders = [make_adder(K) || K <- [1, 2, 3]],
    Adjusted = [lists:foldl(fun(Add, V) -> Add(V) end, T, Adders) || T <- Totals],
    Best = lists:foldl(
        fun(I, Max) ->
            #{I := V} = ByCustomer,
            case V > Max of
                true -> V;
                false -> Max
            end
        end,
        0,
        lists:seq(0, ?CUSTOMERS - 1)
    ),
    round(Revenue) + length(BigCustomers) + bool(AnyVoidBig) + lists:sum(Top) + round(Best) +
        round(lists:foldl(fun(V, Sum) -> Sum + V end, 0, Adjusted)).

bool(true) -> 1;
bool(false) -> 0.
