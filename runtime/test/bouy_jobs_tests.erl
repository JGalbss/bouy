-module(bouy_jobs_tests).

%% Classic event-loop puzzles. Each expected order is what Node 25 printed
%% for the same JavaScript, which the comment above each test holds.

-include_lib("eunit/include/eunit.hrl").

%% Runs Body as the top-level code of a fresh realm and returns the log.
run(Body) ->
    Self = self(),
    Pid = spawn(fun() ->
                        bouy_jobs:run_main(fun() -> erlang:put(log, []), Body() end),
                        Self ! {self(), lists:reverse(erlang:get(log))}
                end),
    receive
        {Pid, Log} -> Log
    after 5000 -> erlang:error(timeout)
    end.

log(X) -> erlang:put(log, [X | erlang:get(log)]), undefined.

fn(F) -> bouy_heap:function(fun(_This, Args) -> F(case Args of [V | _] -> V; [] -> undefined end) end).

then(P, F) -> then(P, fn(F), undefined).

%% Promise.prototype.then on a promise of the intrinsic constructor.
then(P, OnFulfilled, OnRejected) ->
    {P2, _, _} = Capability = bouy_jobs:capability(),
    bouy_jobs:perform_then(P, OnFulfilled, OnRejected, Capability),
    P2.

resolved() -> bouy_jobs:promise_resolve(undefined).

timeout(F, Ms) -> bouy_jobs:set_timer(fn(fun(_) -> F() end), Ms, [], false).

%% An async function: Body(Await, Return) with await as CPS.
async(Body) ->
    bouy_jobs:async_call(fun(Resolve, Reject) ->
                                 Await = fun(V, K) -> bouy_jobs:await(V, K, Reject) end,
                                 Body(Await, Resolve)
                         end).

%% console.log("script start"); setTimeout(() => log("setTimeout"), 0);
%% Promise.resolve().then(() => log("promise1")).then(() => log("promise2"));
%% queueMicrotask(() => log("microtask")); console.log("script end");
microtasks_before_timers_test() ->
    ?assertEqual([start, 'end', promise1, microtask, promise2, timeout],
                 run(fun() ->
                             log(start),
                             timeout(fun() -> log(timeout) end, 0),
                             then(then(resolved(), fun(_) -> log(promise1) end), fun(_) -> log(promise2) end),
                             bouy_jobs:enqueue(fun() -> log(microtask) end),
                             log('end')
                     end)).

%% async function async1() { log("async1 start"); await async2(); log("async1 end"); }
%% async function async2() { log("async2"); }
%% log("script start"); setTimeout(() => log("setTimeout"), 0); async1();
%% new Promise(r => { log("promise1"); r(); }).then(() => log("promise2")); log("script end");
async_await_order_test() ->
    Async2 = fun() -> async(fun(_Await, Return) -> log(async2), Return(undefined) end) end,
    Async1 = fun() ->
                     async(fun(Await, Return) ->
                                   log(async1_start),
                                   Await(Async2(), fun(_) -> log(async1_end), Return(undefined) end)
                           end)
             end,
    ?assertEqual([script_start, async1_start, async2, promise1, script_end, async1_end, promise2, timeout],
                 run(fun() ->
                             log(script_start),
                             timeout(fun() -> log(timeout) end, 0),
                             Async1(),
                             {P, Resolve, _} = bouy_jobs:capability(),
                             log(promise1),
                             Resolve(undefined),
                             then(P, fun(_) -> log(promise2) end),
                             log(script_end)
                     end)).

%% Promise.resolve().then(() => { log(1); Promise.resolve().then(() => log(2)).then(() => log(3)); }).then(() => log(4));
%% Promise.resolve().then(() => log(5)).then(() => log(6));
nested_thens_test() ->
    ?assertEqual([1, 5, 2, 4, 6, 3],
                 run(fun() ->
                             then(then(resolved(), fun(_) ->
                                                           log(1),
                                                           then(then(resolved(), fun(_) -> log(2) end), fun(_) -> log(3) end),
                                                           undefined
                                                   end), fun(_) -> log(4) end),
                             then(then(resolved(), fun(_) -> log(5) end), fun(_) -> log(6) end)
                     end)).

%% A then handler that returns a promise adopts it two ticks later:
%% Promise.resolve().then(() => { log("a"); return Promise.resolve("b"); }).then(v => log(v));
%% Promise.resolve().then(() => log(1)).then(() => log(2)).then(() => log(3)).then(() => log(4));
thenable_adoption_test() ->
    ?assertEqual([a, 1, 2, 3, b, 4],
                 run(fun() ->
                             then(then(resolved(), fun(_) -> log(a), bouy_jobs:promise_resolve(b) end), fun(V) -> log(V) end),
                             lists:foldl(fun(N, P) -> then(P, fun(_) -> log(N) end) end, resolved(), [1, 2, 3, 4])
                     end)).

%% setTimeout(() => log("a"), 10);
%% setTimeout(() => { log("b"); Promise.resolve().then(() => log("b-micro")); }, 0);
%% setTimeout(() => log("c"), 0); clearTimeout(setTimeout(() => log("never"), 5));
%% let n = 0; const iv = setInterval(() => { log("tick" + ++n); if (n === 3) clearInterval(iv); }, 1);
timers_test() ->
    ?assertEqual([b, b_micro, c, {tick, 1}, {tick, 2}, {tick, 3}, a],
                 run(fun() ->
                             timeout(fun() -> log(a) end, 10),
                             timeout(fun() -> log(b), then(resolved(), fun(_) -> log(b_micro) end) end, 0),
                             timeout(fun() -> log(c) end, 0),
                             bouy_jobs:clear_timer(timeout(fun() -> log(never) end, 5)),
                             erlang:put(n, 0),
                             Self = bouy_heap:cell(undefined),
                             Interval = bouy_jobs:set_timer(fn(fun(_) ->
                                                                       N = erlang:get(n) + 1,
                                                                       erlang:put(n, N),
                                                                       log({tick, N}),
                                                                       N =:= 3 andalso bouy_jobs:clear_timer(bouy_heap:cell_get(Self))
                                                               end), 1, [], true),
                             bouy_heap:cell_set(Self, Interval)
                     end)).

%% async function a() { log("a1"); await null; log("a2"); await b(); log("a3"); return "ra"; }
%% async function b() { log("b1"); await null; log("b2"); }
%% a().then(v => log(v));
%% Promise.resolve().then(() => log("p1")).then(() => log("p2"))... to p5
interleaved_async_test() ->
    B = fun() ->
                async(fun(Await, Return) ->
                              log(b1),
                              Await(null, fun(_) -> log(b2), Return(undefined) end)
                      end)
        end,
    A = fun() ->
                async(fun(Await, Return) ->
                              log(a1),
                              Await(null, fun(_) ->
                                                  log(a2),
                                                  Await(B(), fun(_) -> log(a3), Return(ra) end)
                                          end)
                      end)
        end,
    ?assertEqual([a1, a2, b1, p1, b2, p2, a3, p3, ra, p4, p5],
                 run(fun() ->
                             then(A(), fun(V) -> log(V) end),
                             lists:foldl(fun(N, P) -> then(P, fun(_) -> log(N) end) end, resolved(), [p1, p2, p3, p4, p5])
                     end)).

%% A rejection reaches the handler of a later then, and a throw in a
%% handler rejects the derived promise.
rejection_test() ->
    ?assertEqual([{caught, boom}, {caught, again}],
                 run(fun() ->
                             P = bouy_jobs:rejected(boom),
                             Q = then(P, undefined, fn(fun(E) -> log({caught, E}), erlang:error({'$throw', again}) end)),
                             then(Q, undefined, fn(fun(E) -> log({caught, E}) end))
                     end)).

%% The heap of a realm is collected between jobs.
collects_between_jobs_test() ->
    Self = self(),
    spawn(fun() ->
                  bouy_jobs:run_main(fun() ->
                                             [bouy_heap:new_object({'$o', 'Object.prototype'}) || _ <- lists:seq(1, 50000)],
                                             timeout(fun() -> ok end, 1)
                                     end),
                  Self ! {done, bouy_heap:gc_stats(), bouy_heap:heap_size()}
          end),
    receive
        {done, #{runs := Runs}, Size} ->
            ?assert(Runs >= 1),
            ?assert(Size < 1000)
    after 5000 -> erlang:error(timeout)
    end.
