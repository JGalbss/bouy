%% internalBinding('fs_event_wrap') (src/fs_event_wrap.cc): FSEvent, the
%% handle of fs.watch.
%%
%% On Linux the handle watches with inotify, as libuv does: the inotify NIF
%% of buoy_native sends each event to a relay process of the handle, which
%% hands it to the realm as a job. Node's lib watches a tree on Linux with
%% one non-recursive handle for each file (internal/fs/recursive_watch).
%%
%% shortcut: elsewhere the handle polls, as ERTS exposes no kqueue or
%% FSEvents: every 100 ms it compares a snapshot of the path (the stat of a
%% file, or the entries of a directory and, when recursive, of its
%% subdirectories) and reports each difference as libuv would, 'rename' for
%% an entry that appeared, vanished, or changed inode, and 'change' for one
%% whose stat changed. An entry that came and went between two polls leaves
%% only the times of the directory changed, which gives 'rename' with a null
%% filename, as libuv reports an event that it cannot name. Bun watches
%% macOS with FSEvents and kqueue; NIFs of buoy_native for them replace the
%% poll.
-module(buoy_binding_fs_event_wrap).

-export([binding/0]).

-define(STATE, {'#', ?MODULE, <<"state">>}).
-define(INTERVAL, 100).
-define(IN_MODIFY, 16#2).
-define(IN_ATTRIB, 16#4).
-define(S_IFMT, 8#170000).
-define(S_IFDIR, 8#040000).

-spec binding() -> term().
binding() ->
    Class = buoy_node:constructor(<<"FSEvent">>, 0, fun(This, _) ->
        save(This, #{active => false, refed => true}),
        undefined
    end),
    Proto = buoy_heap:get(Class, <<"prototype">>),
    A = fun buoy_node:arg/2,
    Methods = [{<<"start">>, fun(This, Args) -> start(This, A(1, Args), A(2, Args), A(3, Args), A(4, Args)) end},
               {<<"close">>, fun(This, _) -> close(This) end},
               {<<"ref">>, fun(This, _) -> set_ref(This, true) end},
               {<<"unref">>, fun(This, _) -> set_ref(This, false) end},
               {<<"hasRef">>, fun(This, _) -> maps:get(refed, state(This)) end},
               {<<"getAsyncId">>, fun(_, _) -> -1 end}],
    [buoy_heap:define(Proto, Name, #{value => buoy_node:fn(Name, 0, Fun), writable => true, enumerable => false,
                                     configurable => true}) || {Name, Fun} <- Methods],
    Initialized = buoy_node:fn(<<"get initialized">>, 0, fun(This, _) -> maps:get(active, state(This)) end),
    buoy_heap:define(Proto, <<"initialized">>, #{get => Initialized, set => undefined, enumerable => false,
                                                 configurable => false}),
    buoy_node:object([{<<"FSEvent">>, Class}]).

%% A receiver that is not an FSEvent acts as a closed one, as the methods
%% return when Unwrap finds nothing.
state(This) ->
    case buoy_heap:private_find(This, ?STATE) of
        {ok, S} -> S;
        error -> #{active => false, refed => false}
    end.

save(This, State) -> buoy_heap:private_put(This, ?STATE, State).

%% start(path, persistent, recursive, encoding): 0, or the negative errno
%% of a path that cannot be watched.
start(This, Path0, Persistent, Recursive, Encoding) ->
    State = state(This),
    Path = buoy_binding_fs:path(Path0),
    Token = make_ref(),
    case watch(Path, Recursive =:= true, Token) of
        {error, Code} ->
            Code;
        {ok, Watch} ->
            Refed = Persistent =:= true,
            Refed andalso buoy_node_loop:ref_handle(),
            erlang:put({?MODULE, Token}, This),
            save(This, State#{active => true, token => Token, path => Path, recursive => Recursive =:= true,
                              encoding => Encoding, refed => Refed, watch => Watch}),
            0
    end.

%% {relay, Pid} for an inotify watch, or {poll, Snapshot}.
watch(Path, false, Token) ->
    case os:type() of
        {unix, linux} -> inotify(Path, Token);
        _ -> poll_start(Path, false, Token)
    end;
watch(Path, true, Token) ->
    poll_start(Path, true, Token).

poll_start(Path, Recursive, Token) ->
    case snapshot(Path, Recursive) of
        {error, Reason} -> {error, buoy_binding_fs:uv_errno(Reason)};
        Snapshot -> schedule(Token), {ok, {poll, Snapshot}}
    end.

%% The relay adds the watch, so the NIF sends the events to it, and it ends
%% the watch when the handle closes or the realm ends.
inotify(Path, Token) ->
    Realm = self(),
    Ref = make_ref(),
    Relay = spawn(fun() -> relay(Realm, Ref, Token, Path) end),
    receive
        {Ref, {ok, _Wd}} -> {ok, {relay, Relay}};
        {Ref, {error, Code}} -> {error, Code}
    end.

relay(Realm, Ref, Token, Path) ->
    Watch = buoy_native:fs_watch(Path),
    Realm ! {Ref, Watch},
    case Watch of
        {ok, Wd} -> forward(Realm, Token, Wd, erlang:monitor(process, Realm));
        {error, _} -> ok
    end.

forward(Realm, Token, Wd, Monitor) ->
    receive
        {'$buoy_fs_event', Mask, Name} ->
            Realm ! {'$buoy_node_call', fun() -> inotify_event(Token, Mask, Name) end},
            forward(Realm, Token, Wd, Monitor);
        stop ->
            buoy_native:fs_unwatch(Wd);
        {'DOWN', Monitor, process, _, _} ->
            buoy_native:fs_unwatch(Wd)
    end.

%% uv__inotify_read: IN_ATTRIB and IN_MODIFY are a change, any other bit a
%% rename, and an event without a name names the watched path.
inotify_event(Token, Mask, Name) ->
    case erlang:get({?MODULE, Token}) of
        undefined ->
            ok;
        This ->
            #{path := Path, encoding := Encoding} = state(This),
            Event = case Mask band bnot (?IN_ATTRIB bor ?IN_MODIFY) of
                0 -> <<"change">>;
                _ -> <<"rename">>
            end,
            Filename = case Name of
                nil -> filename:basename(Path);
                _ -> Name
            end,
            emit(This, Token, [{Event, Filename}], Encoding)
    end.

close(This) ->
    case state(This) of
        #{active := true, token := Token, refed := Refed, watch := Watch} = State ->
            erlang:erase({?MODULE, Token}),
            Refed andalso buoy_node_loop:unref_handle(),
            case Watch of
                {relay, Relay} -> Relay ! stop;
                {poll, _} -> ok
            end,
            save(This, State#{active => false, closed => true});
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

schedule(Token) ->
    erlang:send_after(?INTERVAL, self(), {'$buoy_node_call', fun() -> poll(Token) end}),
    ok.

%% The timer names the watcher by its token, since a closed watcher is no
%% root of the heap any more.
poll(Token) ->
    case erlang:get({?MODULE, Token}) of
        undefined -> ok;
        This -> poll(This, Token)
    end.

poll(This, Token) ->
    case state(This) of
        #{active := true, token := Token, path := Path, recursive := Recursive, watch := {poll, Old}} = State ->
            New = snapshot(Path, Recursive),
            save(This, State#{watch => {poll, New}}),
            Events = events(Old, New, filename:basename(Path)),
            emit(This, Token, Events, maps:get(encoding, State)),
            schedule(Token);
        _ ->
            ok
    end.

emit(_This, _Token, [], _Encoding) ->
    ok;
emit(This, Token, [{Event, Name} | Rest], Encoding) ->
    case state(This) of
        #{active := true, token := Token} ->
            Filename = case Name of
                null -> null;
                _ -> buoy_binding_fs:encoded(Name, Encoding)
            end,
            buoy_heap:call(buoy_heap:get(This, <<"onchange">>), This, [0, Event, Filename]),
            emit(This, Token, Rest, Encoding);
        _ ->
            ok
    end.

%% The state of a watched path: {file, Key} for a file, {dir, Times,
%% Entries} for a directory, with Entries from relative name to key, and
%% {error, Reason}.
snapshot(Path, Recursive) ->
    case buoy_binding_fs:read_stats(Path, follow) of
        {ok, Stats} ->
            case is_directory(Stats) of
                true -> {dir, lists:nthtail(12, Stats), entries(Path, <<>>, Recursive, #{})};
                false -> {file, key(Stats)}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

is_directory([_Dev, Mode | _]) -> Mode band ?S_IFMT =:= ?S_IFDIR.

entries(Dir, Prefix, Recursive, Acc) ->
    case prim_file:list_dir_all(Dir) of
        {ok, Names} ->
            lists:foldl(fun(Name0, Map) ->
                Name = name(Name0),
                Path = filename:join(Dir, Name),
                Rel = <<Prefix/binary, Name/binary>>,
                case buoy_binding_fs:read_stats(Path, nofollow) of
                    {ok, Stats} when Recursive ->
                        Key = key(Stats),
                        case is_directory(Stats) of
                            true -> entries(Path, <<Rel/binary, "/">>, true, Map#{Rel => Key});
                            false -> Map#{Rel => Key}
                        end;
                    {ok, Stats} ->
                        Map#{Rel => key(Stats)};
                    {error, _} ->
                        Map
                end
            end, Acc, Names);
        {error, _} ->
            Acc
    end.

%% The inode first, then what a change alters. A directory changes with
%% each entry that it holds, which the entries report themselves, so its
%% key is its identity alone.
key([_Dev, Mode, Nlink, _Uid, _Gid, _Rdev, _Blksize, Ino, Size, _Blocks, _, _ | Times] = Stats) ->
    case is_directory(Stats) of
        true -> {Ino, directory};
        false -> {Ino, Mode, Nlink, Size, Times}
    end.

events({file, Key}, {file, Key}, _) -> [];
events({file, Old}, {file, New}, Base) when element(1, Old) =:= element(1, New) -> [{<<"change">>, Base}];
events({file, _}, _, Base) -> [{<<"rename">>, Base}];
events({dir, OldTimes, Old}, {dir, NewTimes, New}, _) ->
    Names = lists:usort(maps:keys(Old) ++ maps:keys(New)),
    case [{Event, Name} || Name <- Names, Event <- entry_event(maps:find(Name, Old), maps:find(Name, New))] of
        [] when OldTimes =/= NewTimes -> [{<<"rename">>, null}];
        Events -> Events
    end;
events({dir, _, _}, {error, _}, Base) -> [{<<"rename">>, Base}];
events({error, _}, {error, _}, _) -> [];
events(_, _, Base) -> [{<<"rename">>, Base}].

entry_event(Same, Same) -> [];
entry_event({ok, Old}, {ok, New}) when element(1, Old) =:= element(1, New) -> [<<"change">>];
entry_event(_, _) -> [<<"rename">>].

name(Name) when is_binary(Name) -> Name;
name(Name) -> unicode:characters_to_binary(Name).
