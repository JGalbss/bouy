-module(bouy_schedule_tests).

-include_lib("eunit/include/eunit.hrl").

-import(bouy_test_runtime, [thrown/1]).

%% The decisions of Policy for the first N attempts.
decisions(Policy, N) ->
    Decide = bouy_schedule:policy(Policy),
    [Decide(Attempt, failure) || Attempt <- lists:seq(1, N)].

schedules_decide_each_attempt_test() ->
    ?assertEqual([{delay, 0}, {delay, 0}, done], decisions(bouy_schedule:recurs([2]), 3)),
    ?assertEqual([{delay, 50}, {delay, 50}], decisions(bouy_schedule:spaced([<<"50 millis">>]), 2)),
    ?assertEqual([{delay, 10}, {delay, 20}, {delay, 40}], decisions(bouy_schedule:exponential([10]), 3)),
    ?assertEqual([{delay, 10}, {delay, 30}], decisions(bouy_schedule:exponential([10, 3]), 2)).

options_bound_a_schedule_test() ->
    ?assertEqual([{delay, 0}, done], decisions(#{<<"times">> => 1}, 2)),
    Spaced = #{<<"schedule">> => bouy_schedule:spaced([5]), <<"times">> => 2},
    ?assertEqual([{delay, 5}, {delay, 5}, done], decisions(Spaced, 3)),
    ?assertEqual([done], decisions(#{<<"while">> => fun([F]) -> F =/= failure end}, 1)),
    ?assertEqual([done], decisions(#{<<"until">> => fun([F]) -> F =:= failure end}, 1)),
    ?assertMatch(#{<<"name">> := <<"TypeError">>}, thrown(fun() -> bouy_schedule:policy(3) end)).
