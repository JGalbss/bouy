%% The Atomics namespace over integer typed arrays. A read-modify-write is
%% a compare-and-swap loop on the 64-bit word of the atomics array that
%% holds the element, so it is atomic even when actors share the memory of
%% a SharedArrayBuffer.
%%
%% shortcut: Atomics.wait only checks the value and sleeps for its timeout,
%% and Atomics.notify wakes nobody and returns 0, because no other agent
%% can wait on the memory yet; a waiter registry per buffer would complete
%% them.
-module(bouy_ref_atomics).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0, method/4]).

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
    {TA, _} = validate(arg(1, Args), true),
    _ = access(TA, arg(2, Args)),
    case arg(3, Args) of
        undefined -> ok;
        C -> bouy_ref_number:to_integer_or_infinity(bouy_ref:to_number(C))
    end,
    0;
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
    Current = value_at(TA, I),
    Equal = case {Current, V} of
        {{'$bigint', A}, {'$bigint', B}} -> A =:= bouy_ref_bigint:as_int_n(64, B);
        _ -> Current == V
    end,
    case {Name, Equal} of
        {<<"wait">>, false} -> <<"not-equal">>;
        {<<"wait">>, true} when Timeout =:= infinity -> bouy_ref:type_error(<<"Atomics.wait would block forever: no agent can notify it">>);
        {<<"wait">>, true} ->
            timer:sleep(trunc(Timeout)),
            <<"timed-out">>;
        {_, false} -> async_result(false, <<"not-equal">>);
        {_, true} when Timeout =:= 0 -> async_result(false, <<"timed-out">>);
        {_, true} ->
            %% The promise settles with "timed-out" when the timeout ends.
            {P, Resolve, _} = bouy_jobs:capability(),
            case Timeout of
                infinity -> ok;
                _ ->
                    Settle = bouy_ref_realm:builtin(<<"Atomics.waitAsync timeout">>, fun(_, _) -> Resolve(<<"timed-out">>) end),
                    bouy_jobs:set_timer(Settle, Timeout, [], false)
            end,
            async_result(true, P)
    end.

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
