%% The waiter lists of Atomics.wait, Atomics.waitAsync, and Atomics.notify
%% (ECMA-262 §25.4.3). One process per VM holds every list, so the order in
%% which it takes requests is the critical section of the specification: a
%% waiter that saw the expected value is in its list before any later
%% notify runs. A list belongs to one element of the memory of a
%% SharedArrayBuffer, the atomics array and a byte index, so every realm
%% that shares the buffer shares the list.
%%
%% A notify sends {'$buoy_atomics_wake', Tag} to each waiter that it
%% removes. The process starts on first use, as the eval compiler does, so
%% any VM and any test can wait.
-module(buoy_ref_waiters).

-behaviour(gen_server).

-export([wait/3, notify/2, cancel/2, holds/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% An element of shared memory: the atomics array, the byte index of the
%% element, and its size in bytes.
-type cell() :: {atomics:atomics_ref(), non_neg_integer(), 4 | 8}.

-export_type([cell/0]).

%% Adds the calling process to the end of the list of Cell, under Tag, when
%% the element holds the bytes Expected.
-spec wait(cell(), binary(), reference()) -> waiting | not_equal.
wait(Cell, Expected, Tag) -> call({wait, Cell, Expected, Tag}).

%% Wakes up to Count waiters from the front of the list of Cell, and
%% returns how many it woke.
-spec notify(cell(), non_neg_integer() | infinity) -> non_neg_integer().
notify(Cell, Count) -> call({notify, Cell, Count}).

%% Removes the waiter Tag of the calling process when its timeout ends:
%% removed, or gone when a notify woke it first.
-spec cancel(cell(), reference()) -> removed | gone.
cancel(Cell, Tag) -> call({cancel, Cell, Tag}).

%% Whether the element of Cell holds the bytes Expected.
-spec holds(cell(), binary()) -> boolean().
holds({Ref, Byte, Size}, Expected) ->
    Start = Byte rem 8,
    <<_:Start/binary, Bytes:Size/binary, _/binary>> = <<(atomics:get(Ref, Byte div 8 + 1)):64/little>>,
    Bytes =:= Expected.

call(Request) ->
    _ = whereis(?MODULE) =:= undefined andalso gen_server:start({local, ?MODULE}, ?MODULE, [], []),
    gen_server:call(?MODULE, Request, infinity).

%%% The process. Its state maps {Ref, Byte} to the waiters of that element,
%%% oldest first, as {Pid, Tag, Monitor}: a waiter that exits leaves its list.

-spec init([]) -> {ok, map()}.
init([]) -> {ok, #{}}.

-spec handle_call(term(), gen_server:from(), map()) -> {reply, term(), map()}.
handle_call({wait, {Ref, Byte, _} = Cell, Expected, Tag}, {Pid, _}, Lists) ->
    case holds(Cell, Expected) of
        true ->
            Waiter = {Pid, Tag, erlang:monitor(process, Pid)},
            {reply, waiting, maps:update_with({Ref, Byte}, fun(Waiters) -> Waiters ++ [Waiter] end, [Waiter], Lists)};
        false ->
            {reply, not_equal, Lists}
    end;
handle_call({notify, {Ref, Byte, _}, Count}, _From, Lists) ->
    Waiters = maps:get({Ref, Byte}, Lists, []),
    {Woken, Rest} = lists:split(min(Count, length(Waiters)), Waiters),
    [wake(Waiter) || Waiter <- Woken],
    {reply, length(Woken), store({Ref, Byte}, Rest, Lists)};
handle_call({cancel, {Ref, Byte, _}, Tag}, {Pid, _}, Lists) ->
    Waiters = maps:get({Ref, Byte}, Lists, []),
    case lists:keytake(Tag, 2, Waiters) of
        {value, {Pid, Tag, Monitor}, Rest} ->
            erlang:demonitor(Monitor, [flush]),
            {reply, removed, store({Ref, Byte}, Rest, Lists)};
        _ ->
            {reply, gone, Lists}
    end.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_Request, Lists) -> {noreply, Lists}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info({'DOWN', Monitor, process, _, _}, Lists) ->
    {noreply, maps:filtermap(fun(_, Waiters) ->
                                     case lists:keydelete(Monitor, 3, Waiters) of
                                         [] -> false;
                                         Rest -> {true, Rest}
                                     end
                             end, Lists)};
handle_info(_Message, Lists) ->
    {noreply, Lists}.

wake({Pid, Tag, Monitor}) ->
    erlang:demonitor(Monitor, [flush]),
    Pid ! {'$buoy_atomics_wake', Tag}.

store(Key, [], Lists) -> maps:remove(Key, Lists);
store(Key, Waiters, Lists) -> Lists#{Key => Waiters}.
