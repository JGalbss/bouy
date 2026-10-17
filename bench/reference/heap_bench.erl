%% Step 1 of the reference-semantics spike: the cost of heap operations.
%% Compares bouy_heap (reference semantics) with the value-semantics core
%% (bouy_rt on maps). Each case runs in a fresh process, which is a realm.
%% Run: bench/reference/run.sh heap
-module(heap_bench).
-export([main/0]).

-define(N, 1000000).
-define(P, {'$o', 'Object.prototype'}).

main() ->
    {L1, L5, L15} = load(),
    io:format("load ~.2f ~.2f ~.2f~n", [L1, L5, L15]),
    Cases = [
        {"empty loop", fun empty/1},
        {"ref: get own property", fun ref_get/1},
        {"value: bouy_rt:get on a map", fun value_get/1},
        {"ref: set existing property", fun ref_set/1},
        {"value: bouy_rt:set on a map (rebind)", fun value_set/1},
        {"ref: method call via prototype (2 levels)", fun ref_method/1},
        {"value: bouy_rt:call_method on a map with a fun field", fun value_method/1},
        {"value: direct 'C#m'(This, Args) call", fun value_direct/1},
        {"ref: allocate {x, y} object (live until gc)", fun ref_alloc/1},
        {"ref: allocate {x, y}, gc every 10k (short-lived)", fun ref_alloc_gc/1},
        {"value: build #{x, y} map (garbage at once)", fun value_alloc/1},
        {"value: build #{x, y} map (kept live in a list)", fun value_alloc_live/1},
        {"ref: cell increment (captured counter)", fun ref_cell/1},
        {"value: SSA counter in loop state", fun value_counter/1},
        {"ref: array push", fun ref_push/1},
        {"ref: array index read", fun ref_index/1}
    ],
    [report(Name, realm(fun() -> Fun(?N) end)) || {Name, Fun} <- Cases],
    gc_cases(),
    {A1, A5, A15} = load(),
    io:format("load ~.2f ~.2f ~.2f~n", [A1, A5, A15]),
    ok.

report(Name, Ns) -> io:format("~-55s ~8.1f ns/op~n", [Name, Ns / ?N]).

load() ->
    Out = os:cmd("sysctl -n vm.loadavg"),
    [A, B, C] = [list_to_float(X) || X <- string:lexemes(Out, "{} \n")],
    {A, B, C}.

realm(F) ->
    Self = self(),
    Pid = spawn(fun() -> Self ! {self(), F()} end),
    receive {Pid, R} -> R end.

time(F) ->
    T0 = erlang:monotonic_time(nanosecond),
    _ = F(),
    erlang:monotonic_time(nanosecond) - T0.

empty(N) -> time(fun() -> loop(N, 0, fun(_, Acc) -> Acc end) end).

loop(0, Acc, _F) -> Acc;
loop(N, Acc, F) -> loop(N - 1, F(N, Acc), F).

ref_get(N) ->
    O = bouy_heap:object(?P, [{<<"x">>, 1}, {<<"y">>, 2}, {<<"z">>, 3}]),
    time(fun() -> loop(N, 0, fun(_, Acc) -> Acc + bouy_heap:get(O, <<"y">>) end) end).

value_get(N) ->
    O = #{<<"x">> => 1, <<"y">> => 2, <<"z">> => 3},
    time(fun() -> loop(N, 0, fun(_, Acc) -> Acc + bouy_rt:get(O, <<"y">>) end) end).

ref_set(N) ->
    O = bouy_heap:object(?P, [{<<"x">>, 1}, {<<"y">>, 2}, {<<"z">>, 3}]),
    time(fun() -> loop(N, 0, fun(I, Acc) -> bouy_heap:set(O, <<"y">>, I), Acc end) end).

value_set(N) ->
    O = #{<<"x">> => 1, <<"y">> => 2, <<"z">> => 3},
    time(fun() -> loop(N, O, fun(I, M) -> bouy_rt:set(M, <<"y">>, I) end) end).

ref_method(N) ->
    Base = bouy_heap:object(?P, [{<<"get">>, bouy_heap:function(fun(This, []) -> bouy_heap:get(This, <<"v">>) end)}]),
    Proto = bouy_heap:new_object(Base),
    O = bouy_heap:object(Proto, [{<<"v">>, 1}]),
    time(fun() -> loop(N, 0, fun(_, Acc) -> Acc + bouy_heap:call(bouy_heap:get(O, <<"get">>), O, []) end) end).

value_method(N) ->
    O = #{<<"v">> => 1, <<"get">> => fun([]) -> 1 end},
    time(fun() -> loop(N, 0, fun(_, Acc) -> Acc + bouy_rt:call_method(O, <<"get">>, []) end) end).

value_direct(N) ->
    This = #{<<"v">> => 1},
    time(fun() -> loop(N, 0, fun(_, Acc) -> Acc + element(1, method(This, [])) end) end).

method(This, []) -> {maps:get(<<"v">>, This), This}.

ref_alloc(N) ->
    time(fun() -> loop(N, 0, fun(I, Acc) -> _ = bouy_heap:literal(?P, #{<<"x">> => I, <<"y">> => I}, [<<"y">>, <<"x">>]), Acc end) end).

ref_alloc_gc(N) ->
    time(fun() -> loop(N, 0, fun(I, Acc) ->
        _ = bouy_heap:literal(?P, #{<<"x">> => I, <<"y">> => I}, [<<"y">>, <<"x">>]),
        case I rem 10000 of 0 -> bouy_heap:gc([]); _ -> ok end,
        Acc end) end).

value_alloc_live(N) ->
    time(fun() -> length(loop(N, [], fun(I, Acc) -> [#{<<"x">> => I, <<"y">> => I} | Acc] end)) end).

value_alloc(N) ->
    time(fun() -> loop(N, [], fun(I, _) -> #{<<"x">> => I, <<"y">> => I} end) end).

ref_cell(N) ->
    C = bouy_heap:cell(0),
    time(fun() -> loop(N, 0, fun(_, Acc) -> bouy_heap:cell_set(C, bouy_heap:cell_get(C) + 1), Acc end) end).

value_counter(N) ->
    time(fun() -> loop(N, 0, fun(_, Acc) -> bouy_rt:add(Acc, 1) end) end).

ref_push(N) ->
    A = bouy_heap:new_array([]),
    time(fun() -> loop(N, 0, fun(I, Acc) -> bouy_heap:set(A, bouy_heap:get(A, <<"length">>), I), Acc end) end).

ref_index(N) ->
    A = bouy_heap:new_array(lists:seq(1, 1000)),
    time(fun() -> loop(N, 0, fun(I, Acc) -> Acc + bouy_heap:get(A, I rem 1000) end) end).

%% GC pause: L live objects in a linked list, plus G garbage objects.
gc_cases() ->
    [gc_case(L, G) || {L, G} <- [{100000, 0}, {100000, 900000}, {1000000, 0}]],
    ok.

gc_case(Live, Garbage) ->
    {Us, Stats, Bytes} = realm(fun() ->
        Root = build(Live, null),
        [bouy_heap:new_object(?P) || _ <- lists:seq(1, Garbage)],
        erlang:garbage_collect(),
        T0 = erlang:monotonic_time(microsecond),
        S = bouy_heap:gc([Root]),
        T1 = erlang:monotonic_time(microsecond),
        erlang:garbage_collect(),
        {memory, B} = erlang:process_info(self(), memory),
        {T1 - T0, S, B}
    end),
    io:format("gc: ~7w live + ~7w garbage: pause ~8.1f ms (~.2f us per live object), live ~w freed ~w, process memory after ~.1f MB (~w B per live object)~n",
              [Live, Garbage, Us / 1000, Us / Live, maps:get(live, Stats), maps:get(freed, Stats), Bytes / 1048576, round(Bytes / Live)]).

build(0, Next) -> Next;
build(N, Next) -> build(N - 1, bouy_heap:literal(?P, #{<<"id">> => N, <<"next">> => Next}, [<<"next">>, <<"id">>])).
