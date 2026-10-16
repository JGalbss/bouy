%% `Duration` from "effect" (contract section 13). A duration is the object
%% that Effect prints for it: `{ _id: "Duration", _tag: "Millis", millis }`,
%% or `{ _id: "Duration", _tag: "Infinity" }`. Every Effect function that
%% takes a duration also takes a DurationInput: a number of milliseconds, a
%% string such as "100 millis" or "1.5 seconds", or a duration.
-module(bouy_duration).

-export(['$member'/1, millis/1, seconds/1, minutes/1, hours/1, toMillis/1, format/1]).
-export([to_millis/1, text/1]).

-define(FUNCTIONS, [<<"millis">>, <<"seconds">>, <<"minutes">>, <<"hours">>, <<"toMillis">>, <<"format">>]).
-define(INPUT, "^(-?\\d+(?:\\.\\d+)?)\\s+(nanos?|micros?|millis?|seconds?|minutes?|hours?|days?|weeks?)$").

-spec '$member'(binary()) -> term().
'$member'(Name) -> bouy_rt:member_function(?MODULE, Name, ?FUNCTIONS).

-spec millis(list()) -> map().
millis(Args) -> duration(bouy_rt:to_number(bouy_rt:arg(1, Args))).

-spec seconds(list()) -> map().
seconds(Args) -> duration(bouy_rt:mul(bouy_rt:arg(1, Args), 1000)).

-spec minutes(list()) -> map().
minutes(Args) -> duration(bouy_rt:mul(bouy_rt:arg(1, Args), 60000)).

-spec hours(list()) -> map().
hours(Args) -> duration(bouy_rt:mul(bouy_rt:arg(1, Args), 3600000)).

-spec toMillis(list()) -> bouy_rt:js_number().
toMillis(Args) -> to_millis(bouy_rt:arg(1, Args)).

-spec format(list()) -> binary().
format(Args) -> text(to_millis(bouy_rt:arg(1, Args))).

%% NaN is a zero duration, as in Effect.
duration('NaN') -> duration(0);
duration(Infinite) when Infinite =:= 'Infinity'; Infinite =:= '-Infinity' ->
    #{<<"_id">> => <<"Duration">>, <<"_tag">> => atom_to_binary(Infinite)};
duration(Millis) ->
    #{<<"_id">> => <<"Duration">>, <<"_tag">> => <<"Millis">>, <<"millis">> => Millis}.

%% The milliseconds of a DurationInput. Input that is none throws the Error
%% of Effect.
-spec to_millis(term()) -> bouy_rt:js_number().
to_millis(#{<<"_id">> := <<"Duration">>, <<"_tag">> := <<"Millis">>, <<"millis">> := Millis}) -> Millis;
to_millis(#{<<"_id">> := <<"Duration">>, <<"_tag">> := <<"Infinity">>}) -> 'Infinity';
to_millis(#{<<"_id">> := <<"Duration">>, <<"_tag">> := <<"-Infinity">>}) -> '-Infinity';
to_millis('NaN') -> 0;
to_millis(Millis) when is_number(Millis); Millis =:= 'Infinity'; Millis =:= '-Infinity' -> Millis;
to_millis(<<"Infinity">>) -> 'Infinity';
to_millis(<<"-Infinity">>) -> '-Infinity';
to_millis(Text) when is_binary(Text) ->
    case re:run(Text, ?INPUT, [{capture, all_but_first, binary}]) of
        {match, [Value, Unit]} -> bouy_rt:mul(bouy_number:from_string(Value), unit(Unit));
        nomatch -> invalid(Text)
    end;
to_millis(Other) ->
    invalid(Other).

unit(<<"nano", _/binary>>) -> 1.0e-6;
unit(<<"micro", _/binary>>) -> 1.0e-3;
unit(<<"milli", _/binary>>) -> 1;
unit(<<"second", _/binary>>) -> 1000;
unit(<<"minute", _/binary>>) -> 60000;
unit(<<"hour", _/binary>>) -> 3600000;
unit(<<"day", _/binary>>) -> 86400000;
unit(<<"week", _/binary>>) -> 604800000.

-spec invalid(term()) -> no_return().
invalid(Input) ->
    bouy_error:throw(<<"Error">>, <<"Invalid Input: ", (bouy_rt:to_string(Input))/binary>>).

%% Duration.format: "1s 500ms", "0", or "Infinity".
-spec text(bouy_rt:js_number()) -> binary().
text('Infinity') -> <<"Infinity">>;
text('-Infinity') -> <<"-Infinity">>;
text('NaN') -> <<"0">>;
text(Millis) when Millis < 0 -> <<"-", (text(-Millis))/binary>>;
text(Millis) when Millis == 0 -> <<"0">>;
text(Millis) ->
    Nanos = round(Millis * 1000000),
    Ms = Nanos div 1000000,
    Units = [
        {Ms div 86400000, <<"d">>},
        {Ms div 3600000 rem 24, <<"h">>},
        {Ms div 60000 rem 60, <<"m">>},
        {Ms div 1000 rem 60, <<"s">>},
        {Ms rem 1000, <<"ms">>},
        {Nanos rem 1000000, <<"ns">>}
    ],
    iolist_to_binary(lists:join(<<" ">>, [[integer_to_binary(N), Suffix] || {N, Suffix} <- Units, N =/= 0])).
