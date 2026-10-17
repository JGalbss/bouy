-module(bouy_ref_temporal_tests).

-include_lib("eunit/include/eunit.hrl").

-define(P, {'$o', 'Object.prototype'}).

%% Each test runs in a fresh process, which is a fresh realm.
realm(Test) ->
    Self = self(),
    Pid = spawn(fun() ->
                        ok = bouy_ref_realm:install(),
                        Result = try {ok, Test()} catch C:R:S -> {C, R, S} end,
                        Self ! {self(), Result}
                end),
    receive
        {Pid, {ok, Value}} -> Value;
        {Pid, Failure} -> erlang:error(Failure)
    end.

format(Options) ->
    Constructor = bouy_ref_realm:constructor(bouy_ref_temporal, <<"Intl.DateTimeFormat">>),
    bouy_ref:construct(Constructor, [<<"en-u-hc-h23">>, bouy_heap:object(?P, Options)]).

parts(Format, Time) ->
    [{bouy_heap:get(Part, <<"type">>), bouy_heap:get(Part, <<"value">>)}
     || Part <- bouy_heap:array_items(bouy_ref:call_method(Format, <<"formatToParts">>, [Time]))].

%% The polyfill finds the offset of a named zone from the wall-clock fields
%% of formatToParts, and its canonical identifier from resolvedOptions.
format_to_parts_test() ->
    realm(fun() ->
                  Format = format([{<<"timeZone">>, <<"US/EASTERN">>}]),
                  Resolved = bouy_ref:call_method(Format, <<"resolvedOptions">>, []),
                  ?assertEqual(<<"America/New_York">>, bouy_heap:get(Resolved, <<"timeZone">>)),
                  %% 2021-07-01T12:00:00Z is 08:00 EDT.
                  ?assertEqual([{<<"month">>, <<"7">>}, {<<"day">>, <<"1">>}, {<<"year">>, <<"2021">>}, {<<"era">>, <<"AD">>},
                                {<<"hour">>, <<"8">>}, {<<"minute">>, <<"0">>}, {<<"second">>, <<"0">>}],
                               parts(Format, 1625140800000)),
                  %% ISO year 0 is 1 BC.
                  Utc = format([{<<"timeZone">>, <<"UTC">>}]),
                  ?assertMatch([_, _, {<<"year">>, <<"1">>}, {<<"era">>, <<"BC">>} | _], parts(Utc, -62162035200000.0)),
                  %% An offset zone, as ZonedDateTime.prototype.toLocaleString passes it.
                  ?assertMatch([_, _, _, _, {<<"hour">>, <<"6">>}, {<<"minute">>, <<"30">>} | _],
                               parts(format([{<<"timeZone">>, <<"-05:30">>}]), 1625140800000))
          end).

an_unknown_zone_is_a_range_error_test() ->
    realm(fun() ->
                  ?assertError({'$throw', _}, format([{<<"timeZone">>, <<"Mars/Olympus_Mons">>}])),
                  Format = fun(Options) -> bouy_ref:call_method(format([{<<"timeZone">>, <<"UTC">>} | Options]), <<"format">>, [1577977445000]) end,
                  ?assertEqual(<<"1/2/2020">>, Format([])),
                  ?assertEqual(<<"1/2020, 3:04 PM">>, Format([{<<"year">>, <<"numeric">>}, {<<"month">>, <<"numeric">>}, {<<"hour">>, <<"numeric">>}, {<<"minute">>, <<"2-digit">>}])),
                  ?assertEqual(<<"1/2/2020, 3:04:05 PM">>, Format([{<<"dateStyle">>, <<"short">>}, {<<"timeStyle">>, <<"short">>}]))
          end).

%% A runtime without the compiled polyfill throws a TypeError on the first
%% read of Temporal, and a later read tries again.
a_runtime_without_the_polyfill_throws_test() ->
    realm(fun() ->
                  false = code:which(bouy_temporal) =/= non_existing,
                  ?assertError({'$throw', _}, bouy_heap:get({'$o', 'Temporal'}, <<"Instant">>)),
                  ?assertEqual(undefined, get('Temporal')),
                  ?assertError({'$throw', _}, bouy_heap:get({'$o', 'Temporal'}, <<"Instant">>))
          end).
