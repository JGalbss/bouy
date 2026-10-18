%% internalBinding('locks') (src/node_locks.cc): the Web Locks of
%% navigator.locks. Node keeps one LockManager for the process, under a
%% mutex, and each Environment runs ProcessQueue for its own requests. Here
%% the manager is one process of the VM that holds the queue and the held
%% locks, and each realm runs the callbacks of its own requests, so the locks
%% of every realm, such as the actors and the workers, exclude each other.
-module(buoy_binding_locks).

-export([binding/0, request/2, query/2, process_queue/0, stolen/1]).

-define(MANAGER, ?MODULE).
-define(STOLEN, <<"LOCK_STOLEN">>).

-spec binding() -> term().
binding() ->
    F = fun buoy_node:fn/3,
    buoy_node:object([
        {<<"request">>, F(<<"request">>, 0, fun ?MODULE:request/2)},
        {<<"query">>, F(<<"query">>, 0, fun ?MODULE:query/2)},
        {<<"LOCK_MODE_SHARED">>, <<"shared">>},
        {<<"LOCK_MODE_EXCLUSIVE">>, <<"exclusive">>},
        {<<"LOCK_STOLEN_ERROR">>, ?STOLEN}]).

%%% The realm

%% LockManager::Request(name, clientId, mode, steal, ifAvailable, callback):
%% the request joins the queue, at its front when it steals, and the
%% promise that settles when the lock is released returns.
-spec request(term(), list()) -> term().
request(_This, Args) ->
    [Name, Client, Mode, Steal, IfAvailable, Callback] = [buoy_node:arg(I, Args) || I <- lists:seq(1, 6)],
    Released = buoy_jobs:new_promise(),
    Ref = make_ref(),
    Request = #{ref => Ref, owner => self(), name => utf8(Name), mode => mode(Mode), client => utf8(Client),
                steal => Steal =:= true, if_available => IfAvailable =:= true},
    %% The promise and the callback stay roots of the heap until the lock ends.
    erlang:put({?MODULE, Ref}, {pending, Released, Callback, Request}),
    ok = call({enqueue, Request}),
    process_queue(),
    Released.

%% LockManager::Query: the held and pending locks of this realm.
-spec query(term(), list()) -> term().
query(_This, _Args) ->
    {Held, Pending} = call({query, self()}),
    Snapshot = buoy_node:object([{<<"held">>, buoy_heap:new_array([info(L) || L <- Held])},
                                 {<<"pending">>, buoy_heap:new_array([info(R) || R <- Pending])}]),
    buoy_jobs:promise_resolve(Snapshot).

%% ProcessQueue: grants each request of this realm that can be granted, and
%% answers each ifAvailable request that cannot with null, in queue order.
-spec process_queue() -> ok.
process_queue() ->
    case call({next, self()}) of
        none ->
            ok;
        {miss, Ref} ->
            {pending, Released, Callback, _} = erlang:erase({?MODULE, Ref}),
            case invoke(Callback, null) of
                {ok, Result} -> buoy_jobs:resolve_promise(Released, Result), process_queue();
                {error, Error} -> buoy_jobs:reject_promise(Released, Error)
            end;
        {grant, Ref, Stolen} ->
            [stolen(S) || S <- Stolen],
            {pending, Released, Callback, Request} = erlang:get({?MODULE, Ref}),
            erlang:put({?MODULE, Ref}, {held, Released, false}),
            case invoke(Callback, info(Request)) of
                {ok, Result} ->
                    %% The lock ends when the result of the callback settles.
                    Waiting = buoy_jobs:new_promise(),
                    buoy_jobs:resolve_promise(Waiting, Result),
                    buoy_jobs:perform_then(Waiting, fun(V) -> release(Ref, fun buoy_jobs:resolve_promise/2, V) end,
                                           fun(E) -> release(Ref, fun buoy_jobs:reject_promise/2, E) end, undefined),
                    process_queue();
                {error, Error} ->
                    release(Ref, fun buoy_jobs:reject_promise/2, Error)
            end
    end.

invoke(Callback, Argument) ->
    try {ok, buoy_heap:call(Callback, undefined, [Argument])}
    catch
        error:Reason:Stack -> {error, buoy_ref:caught(Reason, Stack)}
    end.

%% OnLockCallbackFulfilled and OnLockCallbackRejected: the lock goes, the
%% queue moves, and the released promise settles unless a steal rejected it.
release(Ref, Settle, Value) ->
    ok = call({release, Ref}),
    case erlang:erase({?MODULE, Ref}) of
        {held, Released, false} -> Settle(Released, Value);
        _ -> ok
    end,
    process_queue(),
    undefined.

%% A request that stole the lock rejects the released promise of its holder.
-spec stolen(reference()) -> ok.
stolen(Ref) ->
    case erlang:get({?MODULE, Ref}) of
        {held, Released, false} ->
            erlang:put({?MODULE, Ref}, {held, Released, true}),
            Error = buoy_heap:error_object('Error', ?STOLEN, <<"Error: ", ?STOLEN/binary, "\n    at <buoy>">>),
            buoy_jobs:reject_promise(Released, Error);
        _ ->
            ok
    end.

info(#{name := Name, mode := Mode, client := Client}) ->
    buoy_node:object([{<<"name">>, buoy_ref_string:from_utf8(Name)}, {<<"mode">>, Mode},
                      {<<"clientId">>, buoy_ref_string:from_utf8(Client)}]).

mode(<<"shared">>) -> <<"shared">>;
mode(_) -> <<"exclusive">>.

utf8(Value) -> buoy_ref_string:to_utf8(buoy_ref:to_string(Value)).

call(Message) ->
    Manager = manager(),
    Ref = monitor(process, Manager),
    Manager ! {Message, self(), Ref},
    receive
        {Ref, Reply} -> demonitor(Ref, [flush]), Reply;
        {'DOWN', Ref, _, _, Reason} -> erlang:error({locks_manager, Reason})
    end.

manager() ->
    case whereis(?MANAGER) of
        undefined ->
            Pid = spawn(fun() -> manager_loop(#{held => [], pending => [], owners => #{}}) end),
            try register(?MANAGER, Pid) of
                true -> Pid
            catch
                error:badarg -> exit(Pid, kill), manager()
            end;
        Pid ->
            Pid
    end.

%%% The manager

manager_loop(State) ->
    receive
        {Message, From, Ref} when is_pid(From) ->
            {Reply, State1} = handle(Message, State),
            From ! {Ref, Reply},
            manager_loop(State1);
        {'DOWN', _, process, Owner, _} ->
            %% LockManager::CleanupEnvironment: the locks and the requests of
            %% a realm that ended go, and the other realms try again.
            #{held := Held, pending := Pending, owners := Owners} = State,
            State1 = State#{held := [L || #{owner := O} = L <- Held, O =/= Owner],
                            pending := [R || #{owner := O} = R <- Pending, O =/= Owner],
                            owners := maps:remove(Owner, Owners)},
            wake(none, State1),
            manager_loop(State1)
    end.

handle({enqueue, #{owner := Owner, steal := Steal} = Request}, #{pending := Pending, owners := Owners} = State) ->
    Owners1 = case Owners of
        #{Owner := _} -> Owners;
        _ -> Owners#{Owner => monitor(process, Owner)}
    end,
    Pending1 = case Steal of
        true -> [Request | Pending];
        false -> Pending ++ [Request]
    end,
    {ok, State#{pending := Pending1, owners := Owners1}};
handle({next, Owner}, #{pending := Pending} = State) ->
    next(Owner, Pending, [], State);
handle({release, Ref}, #{held := Held} = State) ->
    State1 = State#{held := [L || #{ref := R} = L <- Held, R =/= Ref]},
    wake(self_of(Ref, Held), State1),
    {ok, State1};
handle({query, Owner}, #{held := Held, pending := Pending} = State) ->
    {{[L || #{owner := O} = L <- Held, O =:= Owner], [R || #{owner := O} = R <- Pending, O =:= Owner]}, State}.

%% The first request of Owner in queue order that can be granted, or that
%% asks only if available.
next(_Owner, [], _Before, State) ->
    {none, State};
next(Owner, [#{owner := Other} = Request | Rest], Before, State) when Other =/= Owner ->
    next(Owner, Rest, [Request | Before], State);
next(Owner, [#{ref := Ref, name := Name, steal := Steal} = Request | Rest], Before, #{held := Held} = State) ->
    Pending = lists:reverse(Before, Rest),
    case grantable(Request, Held, Pending) of
        true when Steal ->
            {Taken, Kept} = lists:partition(fun(#{name := N}) -> N =:= Name end, Held),
            %% The holders in other realms learn of the steal in their loop.
            [buoy_node_stream:call(O, fun() -> ?MODULE:stolen(R) end) || #{owner := O, ref := R} <- Taken, O =/= Owner],
            Own = [R || #{owner := O, ref := R} <- Taken, O =:= Owner],
            {{grant, Ref, Own}, State#{held := Kept ++ [Request], pending := Pending}};
        true ->
            {{grant, Ref, []}, State#{held := Held ++ [Request], pending := Pending}};
        false ->
            case Request of
                #{if_available := true} -> {{miss, Ref}, State#{pending := Pending}};
                _ -> next(Owner, Rest, [Request | Before], State)
            end
    end.

%% LockManager::IsGrantable.
grantable(#{steal := true}, _Held, _Pending) ->
    true;
grantable(#{name := Name, mode := Mode}, Held, Pending) ->
    Holders = [M || #{name := N, mode := M} <- Held, N =:= Name],
    case {Holders, Mode} of
        {[], _} -> true;
        {_, <<"exclusive">>} -> false;
        {_, <<"shared">>} ->
            not lists:member(<<"exclusive">>, Holders) andalso
                not lists:any(fun(#{name := N, mode := M}) -> N =:= Name andalso M =:= <<"exclusive">> end, Pending)
    end.

self_of(Ref, Held) ->
    case [O || #{ref := R, owner := O} <- Held, R =:= Ref] of
        [Owner | _] -> Owner;
        [] -> none
    end.

%% A release or a cleanup can make the requests of other realms grantable:
%% each runs its ProcessQueue again. The realm that released runs its own.
wake(Except, #{pending := Pending}) ->
    Owners = lists:usort([O || #{owner := O} <- Pending, O =/= Except]),
    [buoy_node_stream:call(O, fun ?MODULE:process_queue/0) || O <- Owners],
    ok.
