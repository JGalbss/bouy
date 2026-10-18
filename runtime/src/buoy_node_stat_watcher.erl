%% StatWatcher of internalBinding('fs') (src/node_stat_watcher.cc), the
%% handle of fs.watchFile. It polls as uv_fs_poll does: it stats the path
%% every interval, calls onchange(status, stats) when the stat changes or a
%% new error appears, and passes the current stat and the previous one in
%% the shared stat array. Bun's StatWatcher polls too, on a timer and its
%% thread pool; here an Erlang timer message runs each poll in the realm.
-module(buoy_node_stat_watcher).

-include_lib("kernel/include/file.hrl").

-export([class/0]).

-define(STATE, {?MODULE, state}).

-spec class() -> term().
class() ->
    Class = buoy_node:constructor(<<"StatWatcher">>, 0, fun(This, Args) ->
        save(This, #{bigint => buoy_node:arg(1, Args) =:= true, active => false, refed => true}),
        undefined
    end),
    Proto = buoy_heap:get(Class, <<"prototype">>),
    Methods = [{<<"start">>, fun(This, Args) -> start(This, buoy_node:arg(1, Args), buoy_node:arg(2, Args)) end},
               {<<"close">>, fun(This, _) -> close(This) end},
               {<<"ref">>, fun(This, _) -> set_ref(This, true) end},
               {<<"unref">>, fun(This, _) -> set_ref(This, false) end},
               {<<"hasRef">>, fun(This, _) -> maps:get(refed, state(This)) end},
               {<<"getAsyncId">>, fun(_, _) -> -1 end}],
    [buoy_heap:define(Proto, Name, #{value => buoy_node:fn(Name, 0, Fun), writable => true, enumerable => false,
                                     configurable => true}) || {Name, Fun} <- Methods],
    Class.

state(This) ->
    case buoy_heap:private_find(This, ?STATE) of
        {ok, S} -> S;
        error -> #{bigint => false, active => false, refed => false}
    end.

save(This, State) -> buoy_heap:private_put(This, ?STATE, State).

%% start(path, interval): undefined; the first poll, in a later job,
%% records the stat.
start(This, Path, Interval) ->
    case state(This) of
        #{active := true} ->
            undefined;
        State ->
            Token = make_ref(),
            maps:get(refed, State) andalso buoy_node_loop:ref_handle(),
            %% The watcher stays a root of the heap while its timer runs.
            erlang:put({?MODULE, Token}, This),
            save(This, State#{active => true, token => Token, path => buoy_binding_fs:path(Path),
                              interval => max(1, buoy_binding_fs:int(Interval)), last => none}),
            self() ! {'$buoy_node_call', fun() -> poll(This, Token) end},
            undefined
    end.

close(This) ->
    case state(This) of
        #{active := true, token := Token, refed := Refed} = State ->
            erlang:erase({?MODULE, Token}),
            Refed andalso buoy_node_loop:unref_handle(),
            save(This, State#{active => false});
        _ ->
            ok
    end,
    undefined.

set_ref(This, Refed) ->
    State = state(This),
    case State of
        #{active := true, refed := Old} when Old =/= Refed ->
            case Refed of
                true -> buoy_node_loop:ref_handle();
                false -> buoy_node_loop:unref_handle()
            end;
        _ ->
            ok
    end,
    save(This, State#{refed => Refed}),
    undefined.

%% One poll: stat, compare with the last result, and schedule the next.
poll(This, Token) ->
    case state(This) of
        #{active := true, token := Token, path := Path, interval := Interval, last := Last, bigint := BigInt} = State ->
            Now = buoy_binding_fs:read_info(Path, follow),
            report(This, Last, Now, BigInt),
            Next = case Now of
                {ok, _} -> Now;
                {error, _} when element(1, Last) =:= ok -> {Now, element(2, Last)};
                {error, _} -> {Now, prev_info(Last)}
            end,
            save(This, State#{last => Next}),
            Self = self(),
            erlang:send_after(Interval, Self, {'$buoy_node_call', fun() -> poll(This, Token) end}),
            ok;
        _ ->
            ok
    end.

%% Last is none before the first poll, {ok, Info} after a stat, and
%% {{error, Reason}, Info} after an error, with the last good stat.
prev_info(none) -> #file_info{};
prev_info({{error, _}, Info}) -> Info.

report(_This, none, {ok, _}, _) ->
    ok;
report(This, {ok, Prev}, {ok, Curr}, BigInt) ->
    same(Prev, Curr) orelse onchange(This, 0, Curr, Prev, BigInt);
report(This, {{error, _}, Prev}, {ok, Curr}, BigInt) ->
    onchange(This, 0, Curr, Prev, BigInt);
report(_This, {{error, Reason}, _}, {error, Reason}, _) ->
    ok;
report(This, Last, {error, Reason}, BigInt) ->
    Prev = case Last of
        {ok, Info} -> Info;
        _ -> prev_info(Last)
    end,
    onchange(This, buoy_binding_fs:uv_errno(Reason), #file_info{}, Prev, BigInt).

%% statbuf_eq of libuv, over the fields that prim_file gives.
same(A, B) ->
    Key = fun(#file_info{} = I) ->
        {I#file_info.ctime, I#file_info.mtime, I#file_info.size, I#file_info.mode, I#file_info.uid,
         I#file_info.gid, I#file_info.inode, I#file_info.major_device}
    end,
    Key(A) =:= Key(B).

onchange(This, Status, Curr, Prev, BigInt) ->
    Array = buoy_binding_fs:stat_pair(Curr, Prev, BigInt),
    buoy_heap:call(buoy_heap:get(This, <<"onchange">>), This, [Status, Array]),
    ok.
