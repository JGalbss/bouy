%% The Atomics namespace over integer typed arrays. A read-modify-write is
%% a compare-and-swap loop on the 64-bit word of the atomics array that
%% holds the element, so it is atomic even when actors share the memory of
%% a SharedArrayBuffer.
%%
%% Atomics.wait, waitAsync, and notify use the waiter lists of
%% bouy_ref_waiters. A sync wait blocks the realm process in a receive. An
%% async wait keeps its promise under '$bouy_async_waiters' until the realm
%% loop hands over its wake message or the end of its timeout
%% (async_event/1). As in Node, a pending async wait does not keep the
%% realm alive, so its timeout is a plain BEAM timer and not a realm timer.
-module(bouy_ref_atomics).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, async_event/1]).

-define(ASYNC_WAITERS, '$bouy_async_waiters').
%% The longest timeout that a receive and a BEAM timer take here, in ms; a longer one waits forever.
-define(MAX_TIMEOUT, 2147483647).

-import(bouy_ref_realm, [arg/2, record/4]).

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    [{'Atomics', record(object, ?OBJECT_PROTO, ?METHODS(<<"Atomics">>, [{<<"add">>, 3}, {<<"and">>, 3}, {<<"compareExchange">>, 4},
                                                                       {<<"exchange">>, 3}, {<<"isLockFree">>, 1}, {<<"load">>, 2},
                                                                       {<<"notify">>, 3}, {<<"or">>, 3}, {<<"pause">>, 0},
                                                                       {<<"store">>, 3}, {<<"sub">>, 3}, {<<"wait">>, 4},
                                                                       {<<"waitAsync">>, 4}, {<<"xor">>, 3}])
         ++ [{?SYM(toStringTag), <<"Atomics">>, 4}], none)}].

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"Atomics">>, {'$o', 'Atomics'}}].

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"Atomics">>, <<"isLockFree">>, _This, Args) ->
    case bouy_ref_number:to_integer_or_infinity(bouy_ref:to_number(arg(1, Args))) of
        N when N =:= 1; N =:= 2; N =:= 4; N =:= 8 -> true;
        _ -> false
    end;
method(<<"Atomics">>, <<"pause">>, _This, Args) ->
    case arg(1, Args) of
        undefined -> undefined;
        N when is_integer(N) -> undefined;
        F when is_float(F), F == trunc(F) -> undefined;
        _ -> bouy_ref:type_error(<<"Atomics.pause requires an integral number of iterations">>)
    end;
method(<<"Atomics">>, <<"load">>, _This, Args) ->
    {TA, _} = validate(arg(1, Args), false),
    I = access(TA, arg(2, Args)),
    revalidate(TA, I),
    value_at(TA, I);
method(<<"Atomics">>, <<"store">>, _This, Args) ->
    {TA, {Kind, _, _, _}} = validate(arg(1, Args), false),
    I = access(TA, arg(2, Args)),
    V = convert(Kind, arg(3, Args)),
    revalidate(TA, I),
    modify(TA, I, fun(_Old) -> V end),
    V;
method(<<"Atomics">>, <<"compareExchange">>, _This, Args) ->
    {TA, {Kind, _, _, _}} = validate(arg(1, Args), false),
    I = access(TA, arg(2, Args)),
    Expected = convert(Kind, arg(3, Args)),
    Replacement = convert(Kind, arg(4, Args)),
    revalidate(TA, I),
    ExpectedBytes = bouy_ref_buffer:encode(Kind, Expected),
    modify_bytes(TA, I, fun(OldBytes) ->
                                case OldBytes =:= ExpectedBytes of
                                    true -> bouy_ref_buffer:encode(Kind, Replacement);
                                    false -> OldBytes
                                end
                        end);
method(<<"Atomics">>, Op, _This, Args) when Op =:= <<"add">>; Op =:= <<"sub">>; Op =:= <<"and">>; Op =:= <<"or">>;
                                            Op =:= <<"xor">>; Op =:= <<"exchange">> ->
    {TA, {Kind, _, _, _}} = validate(arg(1, Args), false),
    I = access(TA, arg(2, Args)),
    V = convert(Kind, arg(3, Args)),
    revalidate(TA, I),
    modify(TA, I, fun(Old) -> operate(Op, Old, V) end);
method(<<"Atomics">>, <<"notify">>, _This, Args) ->
    {TA, {_, Buffer, _, _}} = validate(arg(1, Args), true),
    I = access(TA, arg(2, Args)),
    Count = case arg(3, Args) of
        undefined -> infinity;
        C ->
            case bouy_ref_number:to_integer_or_infinity(bouy_ref:to_number(C)) of
                'Infinity' -> infinity;
                N when is_integer(N) -> max(N, 0);
                _ -> 0
            end
    end,
    case bouy_heap:class_of(Buffer) of
        shared_array_buffer -> bouy_ref_waiters:notify(cell(TA, I), Count);
        _ -> 0
    end;
method(<<"Atomics">>, Name, _This, Args) when Name =:= <<"wait">>; Name =:= <<"waitAsync">> ->
    {TA, {Kind, Buffer, _, _}} = validate(arg(1, Args), true),
    bouy_heap:class_of(Buffer) =:= shared_array_buffer orelse bouy_ref:type_error(<<"Atomics.wait requires a shared typed array">>),
    I = access(TA, arg(2, Args)),
    V = case Kind of
        bigint64 -> bouy_ref_bigint:to_big_int(arg(3, Args));
        _ -> bouy_ref_number:to_int32(bouy_ref:to_number(arg(3, Args)))
    end,
    Timeout = case bouy_ref:to_number(arg(4, Args)) of
        'NaN' -> infinity;
        'Infinity' -> infinity;
        '-Infinity' -> 0;
        Q -> max(0, Q)
    end,
    Expected = bouy_ref_buffer:encode(Kind, V),
    do_wait(Name, cell(TA, I), Expected, Timeout).

%% DoWait after the conversions: Timeout is infinity or a number of ms.
do_wait(<<"wait">>, Cell, Expected, Timeout) ->
    Tag = make_ref(),
    case bouy_ref_waiters:wait(Cell, Expected, Tag) of
        not_equal -> <<"not-equal">>;
        waiting ->
            receive
                {'$bouy_atomics_wake', Tag} -> <<"ok">>
            after receive_timeout(Timeout) ->
                case bouy_ref_waiters:cancel(Cell, Tag) of
                    removed -> <<"timed-out">>;
                    gone -> receive {'$bouy_atomics_wake', Tag} -> <<"ok">> end
                end
            end
    end;
do_wait(<<"waitAsync">>, Cell, Expected, Timeout) when Timeout == 0 ->
    %% An async wait without time to wait adds no waiter.
    case bouy_ref_waiters:holds(Cell, Expected) of
        true -> async_result(false, <<"timed-out">>);
        false -> async_result(false, <<"not-equal">>)
    end;
do_wait(<<"waitAsync">>, Cell, Expected, Timeout) ->
    Tag = make_ref(),
    case bouy_ref_waiters:wait(Cell, Expected, Tag) of
        not_equal ->
            async_result(false, <<"not-equal">>);
        waiting ->
            {P, Resolve, _} = bouy_jobs:capability(),
            _ = case receive_timeout(Timeout) of
                infinity -> none;
                Ms -> erlang:send_after(Ms, self(), {'$bouy_atomics_timeout', Tag})
            end,
            erlang:put(?ASYNC_WAITERS, (async_waiters())#{Tag => {Cell, Resolve}}),
            async_result(true, P)
    end.

%% An event of an async wait, which the realm loop hands over: the wake
%% message of a notify, or the end of the timeout. The promise settles in a
%% job of its own.
-spec async_event({'$bouy_atomics_wake' | '$bouy_atomics_timeout', reference()}) -> ok.
async_event({'$bouy_atomics_wake', Tag}) ->
    settle(Tag, <<"ok">>);
async_event({'$bouy_atomics_timeout', Tag}) ->
    case async_waiters() of
        #{Tag := {Cell, _}} ->
            %% A notify that came first sent a wake message, which settles the promise.
            case bouy_ref_waiters:cancel(Cell, Tag) of
                removed -> settle(Tag, <<"timed-out">>);
                gone -> ok
            end;
        _ ->
            ok
    end.

settle(Tag, Result) ->
    case maps:take(Tag, async_waiters()) of
        {{_, Resolve}, Rest} ->
            erlang:put(?ASYNC_WAITERS, Rest),
            bouy_jobs:run_job(fun() -> Resolve(Result) end);
        error ->
            ok
    end.

async_waiters() ->
    case erlang:get(?ASYNC_WAITERS) of
        undefined -> #{};
        Waiters -> Waiters
    end.

receive_timeout(infinity) -> infinity;
receive_timeout(Ms) when Ms > ?MAX_TIMEOUT -> infinity;
receive_timeout(Ms) -> ceil(Ms).

%% The element at index I of a shared typed array, for the waiter lists.
cell(TA, I) ->
    {Kind, Buffer, Offset, _} = bouy_heap:slots(TA),
    {Ref, _, _} = bouy_heap:slots(Buffer),
    Size = bouy_ref_buffer:element_size(Kind),
    {Ref, Offset + I * Size, Size}.

async_result(Async, Value) -> bouy_heap:object(?OBJECT_PROTO, [{<<"async">>, Async}, {<<"value">>, Value}]).

%% ValidateIntegerTypedArray.
validate(TA, Waitable) ->
    ?IS_OBJECT(TA) andalso bouy_heap:class_of(TA) =:= typed_array orelse bouy_ref:type_error(<<"Atomics operation requires an integer typed array">>),
    {Slots, _Length} = bouy_ref_typed_array:validate(TA, <<"Atomics">>),
    {Kind, _, _, _} = Slots,
    Allowed = case Waitable of
        true -> [int32, bigint64];
        false -> [int8, uint8, int16, uint16, int32, uint32, bigint64, biguint64]
    end,
    lists:member(Kind, Allowed) orelse bouy_ref:type_error(<<"Atomics operation requires an integer typed array">>),
    {TA, Slots}.

%% ValidateAtomicAccess: the index, below the length.
access(TA, Index) ->
    %% The length is read before the index converts, which can run user code.
    Length = bouy_ref:get(TA, <<"length">>),
    I = bouy_ref_buffer:to_index(Index),
    I < Length orelse bouy_heap:throw_error('RangeError', <<"Invalid atomic access index">>),
    I.

%% The checks after the conversions, which can run user code.
revalidate(TA, I) ->
    {_, Buffer, _, _} = bouy_heap:slots(TA),
    bouy_ref_buffer:is_detached(Buffer) andalso bouy_ref:type_error(<<"Cannot perform Atomics operation on a detached ArrayBuffer">>),
    I < bouy_ref:get(TA, <<"length">>) orelse bouy_heap:throw_error('RangeError', <<"Invalid atomic access index">>).

convert(Kind, V) when Kind =:= bigint64; Kind =:= biguint64 -> bouy_ref_bigint:to_big_int(V);
convert(_Kind, V) ->
    case bouy_ref_number:to_integer_or_infinity(bouy_ref:to_number(V)) of
        I when is_integer(I) -> I;
        Inf -> Inf
    end.

value_at(TA, I) -> bouy_ref:get(TA, I).

%% Replaces the element at I by F(Old), atomically; the result is Old.
modify(TA, I, F) ->
    {Kind, _, _, _} = bouy_heap:slots(TA),
    modify_bytes(TA, I, fun(OldBytes) -> bouy_ref_buffer:encode(Kind, F(bouy_ref_buffer:decode(Kind, OldBytes))) end).

%% A compare-and-swap loop on the word that holds the element at I.
modify_bytes(TA, I, F) ->
    {Kind, Buffer, Offset, _} = bouy_heap:slots(TA),
    Size = bouy_ref_buffer:element_size(Kind),
    {Ref, _, _} = bouy_heap:slots(Buffer),
    Byte = Offset + I * Size,
    Word = Byte div 8 + 1,
    Start = Byte rem 8,
    cas(Ref, Word, Start, Size, Kind, F).

cas(Ref, Word, Start, Size, Kind, F) ->
    Old = atomics:get(Ref, Word),
    <<Before:Start/binary, OldBytes:Size/binary, After/binary>> = <<Old:64/little>>,
    NewBytes = F(OldBytes),
    <<New:64/little>> = <<Before/binary, NewBytes/binary, After/binary>>,
    case atomics:compare_exchange(Ref, Word, Old, New) of
        ok -> bouy_ref_buffer:decode(Kind, OldBytes);
        _ -> cas(Ref, Word, Start, Size, Kind, F)
    end.

operate(<<"exchange">>, _Old, V) -> V;
operate(Op, {'$bigint', A}, {'$bigint', B}) ->
    {'$bigint', integer_op(Op, A, B)};
operate(Op, A, B) ->
    integer_op(Op, A, int(B)).

int(I) when is_integer(I) -> I;
int(_) -> 0.

integer_op(<<"add">>, A, B) -> A + B;
integer_op(<<"sub">>, A, B) -> A - B;
integer_op(<<"and">>, A, B) -> A band B;
integer_op(<<"or">>, A, B) -> A bor B;
integer_op(<<"xor">>, A, B) -> A bxor B.
