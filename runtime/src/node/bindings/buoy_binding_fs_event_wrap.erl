%% internalBinding('fs_event_wrap') (src/fs_event_wrap.cc): FSEvent, the
%% handle of fs.watch.
%%
%% shortcut: ERTS exposes no kqueue, inotify, or FSEvents, so the handle
%% polls: every 100 ms it compares a snapshot of the path (the stat of a
%% file, or the entries of a directory and, when recursive, of its
%% subdirectories) and reports each difference as libuv would, 'rename' for
%% an entry that appeared, vanished, or changed inode, and 'change' for one
%% whose stat changed. An entry that came and went between two polls leaves
%% only the times of the directory changed, which gives 'rename' with a null
%% filename, as libuv reports an event that it cannot name. prim_file gives
%% whole seconds, so two writes of the same size within one second look the
%% same. Bun watches with kqueue,
%% inotify, and FSEvents; a NIF of crates/buoy-nif that registers the
%% watch with enif_select brings that here.
-module(buoy_binding_fs_event_wrap).

-include_lib("kernel/include/file.hrl").

-export([binding/0]).

-define(STATE, {'#', ?MODULE, <<"state">>}).
-define(INTERVAL, 100).

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
    case snapshot(Path, Recursive =:= true) of
        {error, Reason} ->
            buoy_binding_fs:uv_errno(Reason);
        Snapshot ->
            Token = make_ref(),
            Refed = Persistent =:= true,
            Refed andalso buoy_node_loop:ref_handle(),
            erlang:put({?MODULE, Token}, This),
            save(This, State#{active => true, token => Token, path => Path, recursive => Recursive =:= true,
                              encoding => Encoding, refed => Refed, snapshot => Snapshot}),
            schedule(Token),
            0
    end.

close(This) ->
    case state(This) of
        #{active := true, token := Token, refed := Refed} = State ->
            erlang:erase({?MODULE, Token}),
            Refed andalso buoy_node_loop:unref_handle(),
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
        #{active := true, token := Token, path := Path, recursive := Recursive, snapshot := Old} = State ->
            New = snapshot(Path, Recursive),
            save(This, State#{snapshot => New}),
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
    case buoy_binding_fs:read_info(Path, follow) of
        {ok, #file_info{type = directory, mtime = M, ctime = C}} -> {dir, {M, C}, entries(Path, <<>>, Recursive, #{})};
        {ok, Info} -> {file, key(Info)};
        {error, Reason} -> {error, Reason}
    end.

entries(Dir, Prefix, Recursive, Acc) ->
    case prim_file:list_dir_all(Dir) of
        {ok, Names} ->
            lists:foldl(fun(Name0, Map) ->
                Name = name(Name0),
                Path = filename:join(Dir, Name),
                Rel = <<Prefix/binary, Name/binary>>,
                case buoy_binding_fs:read_info(Path, nofollow) of
                    {ok, #file_info{type = directory} = Info} when Recursive ->
                        entries(Path, <<Rel/binary, "/">>, true, Map#{Rel => key(Info)});
                    {ok, Info} ->
                        Map#{Rel => key(Info)};
                    {error, _} ->
                        Map
                end
            end, Acc, Names);
        {error, _} ->
            Acc
    end.

%% A directory changes with each entry that it holds, which the entries
%% report themselves, so its key is its identity alone.
key(#file_info{type = directory, inode = Inode}) -> {Inode, directory};
key(#file_info{} = I) ->
    {I#file_info.inode, I#file_info.type, I#file_info.mtime, I#file_info.ctime, I#file_info.size,
     I#file_info.mode, I#file_info.links}.

events({file, Key}, {file, Key}, _) -> [];
events({file, {Inode, _, _, _, _, _, _}}, {file, {Inode, _, _, _, _, _, _}}, Base) -> [{<<"change">>, Base}];
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
