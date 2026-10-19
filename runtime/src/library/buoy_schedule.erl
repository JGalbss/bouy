%% `Schedule` from "effect" (contract section 13): the policies of
%% Effect.retry. A schedule is `{'$schedule', Policy}`, which `console.log`
%% prints as `[Schedule]`. A decision answers whether the attempt after a
%% failure runs, and after which delay: attempt 1 follows the first failure.
-module(buoy_schedule).

-export(['$member'/1, recurs/1, spaced/1, exponential/1, fixed/1]).
-export([policy/1]).

-define(FUNCTIONS, [<<"recurs">>, <<"spaced">>, <<"exponential">>, <<"fixed">>]).

-type policy() ::
    forever
    | {recurs, buoy_rt:js_number()}
    | {spaced, buoy_rt:js_number()}
    | {exponential, buoy_rt:js_number(), buoy_rt:js_number()}.
-type schedule() :: {'$schedule', policy()}.
-type decision() :: fun((pos_integer(), term()) -> {delay, buoy_rt:js_number()} | done).
-export_type([schedule/0, decision/0]).

-spec '$member'(binary()) -> term().
'$member'(Name) -> buoy_rt:member_function(?MODULE, Name, ?FUNCTIONS).

%% Retries `times` times without a delay.
-spec recurs(list()) -> schedule().
recurs(Args) -> {'$schedule', {recurs, buoy_rt:to_number(buoy_rt:arg(1, Args))}}.

%% Retries forever, the same delay after each failure.
-spec spaced(list()) -> schedule().
spaced(Args) -> {'$schedule', {spaced, buoy_duration:to_millis(buoy_rt:arg(1, Args))}}.

%% Retries forever after `base * factor ** (attempt - 1)`; the factor
%% defaults to 2.
-spec exponential(list()) -> schedule().
exponential(Args) ->
    Factor =
        case buoy_rt:arg(2, Args) of
            undefined -> 2;
            Value -> buoy_rt:to_number(Value)
        end,
    {'$schedule', {exponential, buoy_duration:to_millis(buoy_rt:arg(1, Args)), Factor}}.

%% Retries forever on a fixed cadence. shortcut: it waits the whole interval
%% after each failure, as `spaced` does, where Effect subtracts the time the
%% attempt took; upgrade when a program needs the exact cadence.
-spec fixed(list()) -> schedule().
fixed(Args) -> {'$schedule', {spaced, buoy_duration:to_millis(buoy_rt:arg(1, Args))}}.

%% The decision of a retry policy: a schedule, or the options
%% `{ schedule?, times?, while?, until? }`, which bound a schedule that
%% otherwise retries forever.
-spec policy(term()) -> decision().
policy({'$schedule', Policy}) ->
    fun(Attempt, _Failure) -> delay(Policy, Attempt) end;
policy(#{} = Options) ->
    {'$schedule', Policy} =
        case option(<<"schedule">>, Options) of
            undefined -> {'$schedule', forever};
            {'$schedule', _} = Schedule -> Schedule;
            Other -> not_a_policy(Other)
        end,
    Times = option(<<"times">>, Options),
    While = option(<<"while">>, Options),
    Until = option(<<"until">>, Options),
    fun(Attempt, Failure) ->
        Allowed =
            (Times =:= undefined orelse buoy_rt:le(Attempt, Times))
            andalso (While =:= undefined orelse buoy_rt:truthy(buoy_rt:call(While, [Failure])))
            andalso (Until =:= undefined orelse not buoy_rt:truthy(buoy_rt:call(Until, [Failure]))),
        case Allowed of
            true -> delay(Policy, Attempt);
            false -> done
        end
    end;
policy(Other) ->
    not_a_policy(Other).

option(Key, Options) -> maps:get(Key, Options, undefined).

delay(forever, _Attempt) -> {delay, 0};
delay({recurs, Times}, Attempt) ->
    case buoy_rt:le(Attempt, Times) of
        true -> {delay, 0};
        false -> done
    end;
delay({spaced, Millis}, _Attempt) -> {delay, Millis};
delay({exponential, Base, Factor}, Attempt) -> {delay, buoy_rt:mul(Base, buoy_rt:power(Factor, Attempt - 1))}.

-spec not_a_policy(term()) -> no_return().
not_a_policy(Value) ->
    buoy_error:throw(<<"TypeError">>, <<"Effect.retry needs a Schedule or retry options, not ", (buoy_rt:describe(Value))/binary>>).
