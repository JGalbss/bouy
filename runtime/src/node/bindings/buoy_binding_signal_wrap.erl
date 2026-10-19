%% internalBinding('signal_wrap') (src/signal_wrap.cc): Signal, the handle of
%% process.on('SIGTERM') and the other signal events. OTP's os:set_signal
%% hands the signals that it supports to erl_signal_server, where this
%% module is the event handler that runs onsignal in the realm. SIGINT, which
%% OTP cannot catch, comes from the handler of buoy_native as the same event
%% while a listener or a watchdog of node:vm waits for it. Another signal
%% that OTP cannot catch reaches its listeners only when the program sends it
%% to itself with process.kill (emulate/1); SIGKILL and SIGSTOP fail with
%% EINVAL, as in Node.
-module(buoy_binding_signal_wrap).

-behaviour(gen_event).

-export([binding/0, emulate/1, watch_sigint/0, unwatch_sigint/1, has_pending_sigint/1]).
-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2, code_change/3]).

-define(STATE, {'#', ?MODULE, <<"state">>}).
-define(UV_EINVAL, -22).

%% The signals of os:set_signal/2, by their numbers on this OS.
signals() ->
    Usr = case os:type() of
        {unix, darwin} -> [{30, sigusr1}, {31, sigusr2}, {20, sigchld}, {18, sigtstp}];
        _ -> [{10, sigusr1}, {12, sigusr2}, {17, sigchld}, {20, sigtstp}]
    end,
    [{1, sighup}, {2, sigint}, {3, sigquit}, {6, sigabrt}, {14, sigalrm}, {15, sigterm} | Usr].

-spec binding() -> term().
binding() ->
    Signal = buoy_node:constructor(<<"Signal">>, 0, fun(_, _) -> undefined end),
    Proto = buoy_heap:get(Signal, <<"prototype">>),
    F = fun buoy_node:fn/3,
    A = fun buoy_node:arg/2,
    Methods = [{<<"start">>, fun(This, Args) -> start(This, A(1, Args)) end},
               {<<"stop">>, fun(This, _) -> stop(This), 0 end},
               {<<"close">>, fun(This, Args) -> close(This, A(1, Args)) end},
               {<<"ref">>, fun(This, _) -> set_ref(This, true) end},
               {<<"unref">>, fun(This, _) -> set_ref(This, false) end},
               {<<"hasRef">>, fun(This, _) -> maps:get(refed, state(This), true) end},
               {<<"getAsyncId">>, fun(_, _) -> erlang:unique_integer([positive]) end}],
    [buoy_heap:define(Proto, Name, #{value => F(Name, 0, Fun), writable => true, enumerable => true, configurable => true})
     || {Name, Fun} <- Methods],
    buoy_node:object([{<<"Signal">>, Signal}]).

state(This) ->
    case buoy_heap:private_find(This, ?STATE) of
        {ok, S} -> S;
        error -> #{refed => true, signal => none}
    end.

save(This, S) -> buoy_heap:private_put(This, ?STATE, S).

%% start(signum): 0, or EINVAL for a signal that OTP cannot catch. A started
%% handle is ref'd until unref, and stays a root of the heap while it listens.
start(This, Number) ->
    Signum0 = case buoy_ref:to_number(Number) of
        N when is_integer(N) -> N;
        _ -> -1
    end,
    case lists:keyfind(Signum0, 1, signals()) of
        false when Signum0 >= 1, Signum0 =< 31, Signum0 =/= 9, Signum0 =/= 17, Signum0 =/= 19 ->
            Key = {?MODULE, listening, erlang:unique_integer([positive])},
            erlang:put(Key, This),
            erlang:put({?MODULE, emulated, Key}, Signum0),
            S = state(This),
            save(This, S#{signal => {emulated, Key}}),
            maps:get(refed, S, true) andalso buoy_node_loop:ref_handle(),
            0;
        {Signum, Name} ->
            ok = install(),
            Key = {?MODULE, listening, erlang:unique_integer([positive])},
            erlang:put(Key, This),
            ok = gen_event:call(erl_signal_server, ?MODULE, {listen, Name, self(), Key, Signum}),
            ok = catch_signal(Name),
            S = state(This),
            save(This, S#{signal => {Name, Key}}),
            maps:get(refed, S, true) andalso buoy_node_loop:ref_handle(),
            0;
        false ->
            ?UV_EINVAL
    end.

%% Catches Name: SIGINT through buoy_native, the others through OTP.
catch_signal(sigint) ->
    _ = counter(),
    true = buoy_native:sigint_handle(whereis(erl_signal_server)),
    ok;
catch_signal(Name) ->
    os:set_signal(Name, handle).

default_signal(sigint) ->
    _ = buoy_native:sigint_default(),
    ok;
default_signal(Name) ->
    os:set_signal(Name, default).

%% The count of the SIGINTs that the VM got, which a watchdog compares.
counter() ->
    case persistent_term:get({?MODULE, sigints}, undefined) of
        undefined ->
            Counter = atomics:new(1, []),
            persistent_term:put({?MODULE, sigints}, Counter),
            Counter;
        Counter ->
            Counter
    end.

%% The SigintWatchdog of Node: catches SIGINT while it lasts, also with no
%% listener, and counts the ones that come. Its key listens as a listener
%% that delivers nothing, so the last listener to stop keeps SIGINT caught.
-spec watch_sigint() -> {term(), non_neg_integer()}.
watch_sigint() ->
    ok = install(),
    Counter = counter(),
    Key = {?MODULE, watchdog, erlang:unique_integer([positive])},
    Start = atomics:get(Counter, 1),
    ok = gen_event:call(erl_signal_server, ?MODULE, {listen, sigint, self(), Key, 2}),
    ok = catch_signal(sigint),
    {Key, Start}.

%% Ends a watch: whether a SIGINT came. The SIGINTs of the watch are the
%% watchdog's, so the listeners of the realm do not get them later.
-spec unwatch_sigint({term(), non_neg_integer()}) -> boolean().
unwatch_sigint({Key, Start}) ->
    Now = atomics:get(counter(), 1),
    Left = gen_event:call(erl_signal_server, ?MODULE, {unlisten, sigint, Key}),
    Left =:= 0 andalso default_signal(sigint),
    erlang:put({?MODULE, consumed}, max(Now, consumed())),
    Now > Start.

-spec has_pending_sigint({term(), non_neg_integer()}) -> boolean().
has_pending_sigint({_Key, Start}) -> atomics:get(counter(), 1) > Start.

consumed() ->
    case erlang:get({?MODULE, consumed}) of
        undefined -> 0;
        N -> N
    end.

%% Joins erl_signal_server once, in place of OTP's default handler, which
%% would stop the VM on SIGTERM that the program now handles.
install() ->
    case lists:member(?MODULE, gen_event:which_handlers(erl_signal_server)) of
        true -> ok;
        false -> gen_event:swap_handler(erl_signal_server, {erl_signal_handler, []}, {?MODULE, []})
    end.

stop(This) ->
    S = state(This),
    case maps:get(signal, S, none) of
        {emulated, Key} ->
            erlang:erase(Key),
            erlang:erase({?MODULE, emulated, Key}),
            maps:get(refed, S, true) andalso buoy_node_loop:unref_handle(),
            save(This, S#{signal => none});
        {Name, Key} ->
            erlang:erase(Key),
            Left = gen_event:call(erl_signal_server, ?MODULE, {unlisten, Name, Key}),
            Left =:= 0 andalso default_signal(Name),
            maps:get(refed, S, true) andalso buoy_node_loop:unref_handle(),
            save(This, S#{signal => none});
        none ->
            ok
    end.

close(This, Callback) ->
    stop(This),
    buoy_heap:is_callable(Callback) andalso
        buoy_node_loop:defer(fun() -> buoy_heap:call(Callback, This, []) end),
    undefined.

set_ref(This, Refed) ->
    S = state(This),
    Listening = maps:get(signal, S, none) =/= none,
    case {maps:get(refed, S, true), Refed, Listening} of
        {false, true, true} -> buoy_node_loop:ref_handle();
        {true, false, true} -> buoy_node_loop:unref_handle();
        _ -> ok
    end,
    save(This, S#{refed => Refed}),
    undefined.

%%% The handler of erl_signal_server: the listeners of each signal.

-spec init(term()) -> {ok, map()}.
init(_) -> {ok, #{}}.

-spec handle_event(term(), map()) -> {ok, map()}.
handle_event(Name, Listeners) ->
    Seq = case Name of
        sigint -> atomics:add_get(counter(), 1, 1);
        _ -> none
    end,
    [buoy_node_stream:call(Realm, fun() -> deliver(Key, Signum, Seq) end)
     || {Realm, Key, Signum} <- maps:get(Name, Listeners, [])],
    {ok, Listeners}.

-spec handle_call(term(), map()) -> {ok, term(), map()}.
handle_call({listen, Name, Realm, Key, Signum}, Listeners) ->
    {ok, ok, Listeners#{Name => [{Realm, Key, Signum} | maps:get(Name, Listeners, [])]}};
handle_call({unlisten, Name, Key}, Listeners) ->
    Left = [L || {_, K, _} = L <- maps:get(Name, Listeners, []), K =/= Key],
    {ok, length(Left), Listeners#{Name => Left}}.

-spec handle_info(term(), map()) -> {ok, map()}.
handle_info(_, Listeners) -> {ok, Listeners}.

-spec terminate(term(), map()) -> ok.
terminate(_, _) -> ok.

-spec code_change(term(), map(), term()) -> {ok, map()}.
code_change(_, Listeners, _) -> {ok, Listeners}.

%% A SIGINT that a watchdog of the realm took goes to no listener.
deliver(Key, Signum, Seq) when is_integer(Seq) ->
    Seq > consumed() andalso deliver(Key, Signum);
deliver(Key, Signum, none) ->
    deliver(Key, Signum).

deliver(Key, Signum) ->
    case erlang:get(Key) of
        undefined -> ok;
        This ->
            Onsignal = buoy_heap:get(This, <<"onsignal">>),
            buoy_heap:is_callable(Onsignal) andalso buoy_heap:call(Onsignal, This, [Signum])
    end.

%% A signal that the program sends to itself and that OTP cannot catch: its
%% listeners run as later callbacks. False when none listens.
-spec emulate(integer()) -> boolean().
emulate(Signum) ->
    Keys = [Key || {{?MODULE, emulated, Key}, S} <- erlang:get(), S =:= Signum],
    Realm = self(),
    [buoy_node_stream:call(Realm, fun() -> deliver(Key, Signum) end) || Key <- Keys],
    Keys =/= [].
