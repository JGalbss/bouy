%% internalBinding('wasi') (src/node_wasi.cc): the WASI class, whose
%% methods are the system calls of wasi_snapshot_preview1 that lib/wasi.js
%% hands a WebAssembly instance as its imports. Node runs them on uvwasi;
%% this module ports uvwasi's semantics onto Erlang's raw files.
%%
%% Each WASI object has a table of descriptors in the process dictionary.
%% 0, 1, and 2 name the descriptors of the realm that the options gave, and
%% each preopen is a directory from 3 on, with the path that the program
%% sees and the path of the host. A path resolves against the directory of
%% its descriptor and must stay inside it, as uvwasi's path resolver
%% decides, following up to 32 symbolic links of the last component.
%%
%% A call reads and writes the linear memory that _setMemory named through
%% buoy_ref_wasm, and returns the errno of WASI. A pointer outside the
%% memory gives EOVERFLOW, as CHECK_BOUNDS_OR_RETURN does.
-module(buoy_binding_wasi).

-include_lib("kernel/include/file.hrl").

-export([binding/0]).

-define(STATE, '$buoy_wasi').

%% errno
-define(ESUCCESS, 0).
-define(E2BIG, 1).
-define(EBADF, 8).
-define(EEXIST, 20).
-define(EINVAL, 28).
-define(EIO, 29).
-define(EISDIR, 31).
-define(ELOOP, 32).
-define(ENOBUFS, 42).
-define(ENOENT, 44).
-define(ENOSYS, 52).
-define(ENOTDIR, 54).
-define(ENOTSUP, 58).
-define(EOVERFLOW, 61).
-define(ESPIPE, 70).
-define(ENOTCAPABLE, 76).

%% filetype
-define(UNKNOWN, 0).
-define(BLOCK_DEVICE, 1).
-define(CHARACTER_DEVICE, 2).
-define(DIRECTORY, 3).
-define(REGULAR_FILE, 4).
-define(SOCKET_STREAM, 6).
-define(SYMBOLIC_LINK, 7).

%% rights
-define(FD_DATASYNC, 16#1).
-define(FD_READ, 16#2).
-define(FD_SEEK, 16#4).
-define(FD_FDSTAT_SET_FLAGS, 16#8).
-define(FD_SYNC, 16#10).
-define(FD_TELL, 16#20).
-define(FD_WRITE, 16#40).
-define(FD_ADVISE, 16#80).
-define(FD_ALLOCATE, 16#100).
-define(PATH_CREATE_DIRECTORY, 16#200).
-define(PATH_CREATE_FILE, 16#400).
-define(PATH_LINK_SOURCE, 16#800).
-define(PATH_LINK_TARGET, 16#1000).
-define(PATH_OPEN, 16#2000).
-define(FD_READDIR, 16#4000).
-define(PATH_READLINK, 16#8000).
-define(PATH_RENAME_SOURCE, 16#10000).
-define(PATH_RENAME_TARGET, 16#20000).
-define(PATH_FILESTAT_GET, 16#40000).
-define(PATH_FILESTAT_SET_SIZE, 16#80000).
-define(PATH_FILESTAT_SET_TIMES, 16#100000).
-define(FD_FILESTAT_GET, 16#200000).
-define(FD_FILESTAT_SET_SIZE, 16#400000).
-define(FD_FILESTAT_SET_TIMES, 16#800000).
-define(PATH_SYMLINK, 16#1000000).
-define(PATH_REMOVE_DIRECTORY, 16#2000000).
-define(PATH_UNLINK_FILE, 16#4000000).
-define(POLL_FD_READWRITE, 16#8000000).
-define(SOCK_SHUTDOWN, 16#10000000).
-define(SOCK_ACCEPT, 16#20000000).

-define(RIGHTS_ALL, 16#3FFFFFFF).
-define(REGULAR_FILE_BASE, (?FD_DATASYNC bor ?FD_READ bor ?FD_SEEK bor ?FD_FDSTAT_SET_FLAGS bor ?FD_SYNC bor ?FD_TELL
                            bor ?FD_WRITE bor ?FD_ADVISE bor ?FD_ALLOCATE bor ?FD_FILESTAT_GET bor ?FD_FILESTAT_SET_SIZE
                            bor ?FD_FILESTAT_SET_TIMES bor ?POLL_FD_READWRITE)).
-define(DIRECTORY_BASE, (?FD_FDSTAT_SET_FLAGS bor ?FD_SYNC bor ?FD_ADVISE bor ?PATH_CREATE_DIRECTORY bor ?PATH_CREATE_FILE
                         bor ?PATH_LINK_SOURCE bor ?PATH_LINK_TARGET bor ?PATH_OPEN bor ?FD_READDIR bor ?PATH_READLINK
                         bor ?PATH_RENAME_SOURCE bor ?PATH_RENAME_TARGET bor ?PATH_FILESTAT_GET bor ?PATH_FILESTAT_SET_SIZE
                         bor ?PATH_FILESTAT_SET_TIMES bor ?FD_FILESTAT_GET bor ?FD_FILESTAT_SET_TIMES bor ?PATH_SYMLINK
                         bor ?PATH_UNLINK_FILE bor ?PATH_REMOVE_DIRECTORY bor ?POLL_FD_READWRITE)).
-define(DIRECTORY_INHERITING, (?DIRECTORY_BASE bor ?REGULAR_FILE_BASE)).
-define(TTY_BASE, (?FD_READ bor ?FD_FDSTAT_SET_FLAGS bor ?FD_WRITE bor ?FD_FILESTAT_GET bor ?POLL_FD_READWRITE)).
-define(SOCKET_BASE, (?FD_READ bor ?FD_FDSTAT_SET_FLAGS bor ?FD_WRITE bor ?FD_FILESTAT_GET bor ?POLL_FD_READWRITE
                      bor ?SOCK_SHUTDOWN bor ?SOCK_ACCEPT)).

%% oflags, fdflags, lookupflags, fstflags, and whence
-define(O_CREAT, 1).
-define(O_DIRECTORY, 2).
-define(O_EXCL, 4).
-define(O_TRUNC, 8).
-define(FDFLAG_APPEND, 1).
-define(SYMLINK_FOLLOW, 1).
-define(FILESTAT_SET_ATIM, 1).
-define(FILESTAT_SET_ATIM_NOW, 2).
-define(FILESTAT_SET_MTIM, 4).
-define(FILESTAT_SET_MTIM_NOW, 8).
-define(MAX_SYMLINK_FOLLOWS, 32).

%% A descriptor: what it is, its rights, and, for a file, the raw file;
%% Host is the descriptor of the realm for stdio. Path is the path that the
%% program sees, and Real the path of the host.
-record(fd, {kind :: stdio | file | dir,
             type :: non_neg_integer(),
             base :: non_neg_integer(),
             inheriting :: non_neg_integer(),
             host = none :: none | integer(),
             file = none :: term(),
             path = <<>> :: binary(),
             real = <<>> :: binary(),
             preopen = none :: none | binary(),
             append = false :: boolean()}).

-spec binding() -> term().
binding() ->
    Class = buoy_node:constructor(<<"WASI">>, 4, fun construct/2),
    Proto = buoy_heap:get(Class, <<"prototype">>),
    [buoy_heap:define(Proto, Name, #{value => method(Name, Types), writable => true, enumerable => true, configurable => true})
     || {Name, Types} <- calls()],
    buoy_node:object([{<<"WASI">>, Class}]).

%% The calls of preview1 and the types of their arguments after the memory,
%% from the signatures of src/node_wasi.cc.
calls() ->
    [{<<"args_get">>, [u32, u32]}, {<<"args_sizes_get">>, [u32, u32]},
     {<<"clock_res_get">>, [u32, u32]}, {<<"clock_time_get">>, [u32, u64, u32]},
     {<<"environ_get">>, [u32, u32]}, {<<"environ_sizes_get">>, [u32, u32]},
     {<<"fd_advise">>, [u32, u64, u64, u32]}, {<<"fd_allocate">>, [u32, u64, u64]},
     {<<"fd_close">>, [u32]}, {<<"fd_datasync">>, [u32]},
     {<<"fd_fdstat_get">>, [u32, u32]}, {<<"fd_fdstat_set_flags">>, [u32, u32]},
     {<<"fd_fdstat_set_rights">>, [u32, u64, u64]}, {<<"fd_filestat_get">>, [u32, u32]},
     {<<"fd_filestat_set_size">>, [u32, u64]}, {<<"fd_filestat_set_times">>, [u32, u64, u64, u32]},
     {<<"fd_pread">>, [u32, u32, u32, u64, u32]}, {<<"fd_prestat_get">>, [u32, u32]},
     {<<"fd_prestat_dir_name">>, [u32, u32, u32]}, {<<"fd_pwrite">>, [u32, u32, u32, u64, u32]},
     {<<"fd_read">>, [u32, u32, u32, u32]}, {<<"fd_readdir">>, [u32, u32, u32, u64, u32]},
     {<<"fd_renumber">>, [u32, u32]}, {<<"fd_seek">>, [u32, i64, u32, u32]},
     {<<"fd_sync">>, [u32]}, {<<"fd_tell">>, [u32, u32]}, {<<"fd_write">>, [u32, u32, u32, u32]},
     {<<"path_create_directory">>, [u32, u32, u32]}, {<<"path_filestat_get">>, [u32, u32, u32, u32, u32]},
     {<<"path_filestat_set_times">>, [u32, u32, u32, u32, u64, u64, u32]},
     {<<"path_link">>, [u32, u32, u32, u32, u32, u32, u32]},
     {<<"path_open">>, [u32, u32, u32, u32, u32, u64, u64, u32, u32]},
     {<<"path_readlink">>, [u32, u32, u32, u32, u32, u32]}, {<<"path_remove_directory">>, [u32, u32, u32]},
     {<<"path_rename">>, [u32, u32, u32, u32, u32, u32]}, {<<"path_symlink">>, [u32, u32, u32, u32, u32]},
     {<<"path_unlink_file">>, [u32, u32, u32]}, {<<"poll_oneoff">>, [u32, u32, u32, u32]},
     {<<"proc_exit">>, [u32]}, {<<"proc_raise">>, [u32]}, {<<"random_get">>, [u32, u32]},
     {<<"sched_yield">>, []}, {<<"sock_accept">>, [u32, u32, u32]},
     {<<"sock_recv">>, [u32, u32, u32, u32, u32, u32]}, {<<"sock_send">>, [u32, u32, u32, u32, u32]},
     {<<"sock_shutdown">>, [u32, u32]},
     {<<"_setMemory">>, memory}].

%% new WASI(args, env, preopens, stdio)
construct(This, Args) ->
    [Argv, Env, Preopens, Stdio] = [buoy_node:arg(I, Args) || I <- [1, 2, 3, 4]],
    Strings = fun(A) -> [buoy_ref_string:to_utf8(buoy_ref:to_string(V)) || V <- buoy_heap:array_items(A)] end,
    [In, Out, Err] = [trunc(buoy_ref:to_number(V)) || V <- buoy_heap:array_items(Stdio)],
    Table = maps:from_list([{0, stdio(In)}, {1, stdio(Out)}, {2, stdio(Err)}]),
    Fds = preopens(pairs(Strings(Preopens)), 3, Table),
    put_state(This, #{args => Strings(Argv), env => Strings(Env), fds => Fds, memory => none}),
    undefined.

pairs([Mapped, Real | Rest]) -> [{Mapped, Real} | pairs(Rest)];
pairs(_) -> [].

stdio(Host) ->
    Type = case buoy_binding_util_type(Host) of
        tty -> ?CHARACTER_DEVICE;
        _ when Host =< 2 -> ?CHARACTER_DEVICE;
        _ -> ?REGULAR_FILE
    end,
    Base = case Type of
        ?CHARACTER_DEVICE -> ?RIGHTS_ALL;
        _ -> ?REGULAR_FILE_BASE
    end,
    #fd{kind = stdio, type = Type, base = Base, inheriting = 0, host = Host}.

%% The kind of a descriptor of the realm, as guessHandleType sees it.
buoy_binding_util_type(Host) ->
    Util = buoy_node:binding(<<"util">>),
    case buoy_heap:call(buoy_heap:get(Util, <<"guessHandleType">>), Util, [Host]) of
        1 -> tty;
        _ -> other
    end.

%% uvwasi_fd_table_insert_preopen: each real path must be a directory.
preopens([], _Fd, Table) -> Table;
preopens([{Mapped, Real} | Rest], Fd, Table) ->
    case prim_file:read_file_info(Real) of
        {ok, #file_info{type = directory}} ->
            Entry = #fd{kind = dir, type = ?DIRECTORY, base = ?DIRECTORY_BASE, inheriting = ?DIRECTORY_INHERITING,
                        path = normalize(Mapped), real = Real, preopen = Mapped},
            preopens(Rest, Fd + 1, Table#{Fd => Entry});
        {ok, _} ->
            init_error(?ENOTDIR, <<"ENOTDIR">>);
        {error, Reason} ->
            init_error(errno(Reason), string:uppercase(atom_to_binary(Reason)))
    end.

%% WASIException of node_wasi.cc for a failed uvwasi_init: "UVWASI_<code>,
%% uvwasi_init", with the errno, the code, and the syscall.
init_error(Errno, Name) ->
    Code = <<"UVWASI_", Name/binary>>,
    Message = <<Code/binary, ", uvwasi_init">>,
    E = buoy_heap:error_object('Error', Message, <<"Error: ", Message/binary>>),
    [buoy_heap:set(E, Key, Value) || {Key, Value} <- [{<<"errno">>, Errno}, {<<"code">>, Code}, {<<"syscall">>, <<"uvwasi_init">>}]],
    erlang:error({'$throw', E}).

state(This) -> maps:get(This, erlang:get(?STATE)).

put_state(This, State) ->
    All = case erlang:get(?STATE) of
        undefined -> #{};
        M -> M
    end,
    erlang:put(?STATE, All#{This => State}).

%%% Calls

%% A method of the prototype. The slow callback of node_wasi.cc returns
%% EINVAL for a wrong count or type of arguments, and throws when no memory
%% is set.
method(<<"_setMemory">> = Name, memory) ->
    buoy_node:fn(Name, 1, fun(This, Args) ->
        Memory = buoy_node:arg(1, Args),
        case buoy_ref_wasm:memory_handle(Memory) of
            none ->
                buoy_node:throw_code('TypeError', <<"ERR_INVALID_ARG_TYPE">>,
                                     <<"\"instance.exports.memory\" property must be a WebAssembly.Memory object">>);
            H ->
                put_state(This, (state(This))#{memory => H}),
                undefined
        end
    end);
method(Name, Types) ->
    buoy_node:fn(Name, length(Types), fun(This, Args) -> call(This, Name, Types, Args) end).

call(This, Name, Types, Args) ->
    case length(Args) =:= length(Types) andalso convert(Types, Args) of
        false ->
            ?EINVAL;
        Values ->
            State = state(This),
            maps:get(memory, State) =:= none andalso
                buoy_node:throw_code('Error', <<"ERR_WASI_NOT_STARTED">>, <<"wasi.start() has not been called">>),
            try run(Name, State, This, Values) of
                ok -> ?ESUCCESS;
                {ok, State1} -> put_state(This, State1), ?ESUCCESS;
                Errno when is_integer(Errno) -> Errno
            catch
                throw:{wasi, Errno} -> Errno
            end
    end.

%% The arguments as integers, or false when one has the wrong type: a number
%% for u32, which an i32 of WebAssembly passes signed, and a BigInt for u64
%% and i64.
convert(Types, Args) ->
    Values = [convert_one(T, A) || {T, A} <- lists:zip(Types, Args)],
    case lists:member(false, Values) of
        true -> false;
        false -> Values
    end.

convert_one(u32, N) when is_integer(N), N >= -16#80000000, N =< 16#FFFFFFFF -> N band 16#FFFFFFFF;
convert_one(u64, {'$bigint', N}) -> N band 16#FFFFFFFFFFFFFFFF;
convert_one(i64, {'$bigint', N}) -> N;
convert_one(_, _) -> false.

-spec fail(non_neg_integer()) -> no_return().
fail(Errno) -> throw({wasi, Errno}).

run(<<"args_get">>, S, _, [Argv, Buf]) -> strings_get(S, maps:get(args, S), Argv, Buf);
run(<<"args_sizes_get">>, S, _, [Count, Size]) -> strings_sizes(S, maps:get(args, S), Count, Size);
run(<<"environ_get">>, S, _, [Environ, Buf]) -> strings_get(S, maps:get(env, S), Environ, Buf);
run(<<"environ_sizes_get">>, S, _, [Count, Size]) -> strings_sizes(S, maps:get(env, S), Count, Size);
run(<<"clock_res_get">>, S, _, [Clock, Ptr]) ->
    write(S, Ptr, <<(resolution(Clock)):64/little>>);
run(<<"clock_time_get">>, S, _, [Clock, _Precision, Ptr]) ->
    write(S, Ptr, <<(now(Clock)):64/little>>);
run(<<"fd_advise">>, S, _, [Fd, _Offset, _Len, Advice]) ->
    _ = fd(S, Fd, ?FD_ADVISE, 0),
    Advice =< 5 orelse fail(?EINVAL),
    ok;
run(<<"fd_allocate">>, S, _, [Fd, Offset, Len]) ->
    #fd{file = File} = file_fd(S, Fd, ?FD_ALLOCATE),
    {ok, #file_info{size = Size}} = info(prim_file:read_handle_info(File, [{time, posix}])),
    case Offset + Len > Size of
        true -> posix(file:allocate(File, Size, Offset + Len - Size), fun() -> extend(File, Offset + Len) end);
        false -> ok
    end;
run(<<"fd_close">>, S = #{fds := Fds}, _, [Fd]) ->
    Entry = fd(S, Fd, 0, 0),
    close(Entry),
    {ok, S#{fds => maps:remove(Fd, Fds)}};
run(<<"fd_datasync">>, S, _, [Fd]) ->
    #fd{file = File} = file_fd(S, Fd, ?FD_DATASYNC),
    posix(file:datasync(File));
run(<<"fd_sync">>, S, _, [Fd]) ->
    #fd{file = File} = file_fd(S, Fd, ?FD_SYNC),
    posix(file:sync(File));
run(<<"fd_fdstat_get">>, S, _, [Fd, Buf]) ->
    #fd{type = Type, base = Base, inheriting = Inheriting, append = Append} = fd(S, Fd, 0, 0),
    Flags = case Append of true -> ?FDFLAG_APPEND; false -> 0 end,
    write(S, Buf, <<Type:8, 0:8, Flags:16/little, 0:32, Base:64/little, Inheriting:64/little>>);
run(<<"fd_fdstat_set_flags">>, S = #{fds := Fds}, _, [Fd, Flags]) ->
    Entry = fd(S, Fd, ?FD_FDSTAT_SET_FLAGS, 0),
    {ok, S#{fds => Fds#{Fd => Entry#fd{append = Flags band ?FDFLAG_APPEND =/= 0}}}};
run(<<"fd_fdstat_set_rights">>, S = #{fds := Fds}, _, [Fd, Base, Inheriting]) ->
    Entry = fd(S, Fd, 0, 0),
    (Base bor Entry#fd.base =:= Entry#fd.base andalso Inheriting bor Entry#fd.inheriting =:= Entry#fd.inheriting)
        orelse fail(?ENOTCAPABLE),
    {ok, S#{fds => Fds#{Fd => Entry#fd{base = Base, inheriting = Inheriting}}}};
run(<<"fd_filestat_get">>, S, _, [Fd, Buf]) ->
    Entry = fd(S, Fd, ?FD_FILESTAT_GET, 0),
    write(S, Buf, filestat(fd_info(Entry)));
run(<<"fd_filestat_set_size">>, S, _, [Fd, Size]) ->
    #fd{file = File} = file_fd(S, Fd, ?FD_FILESTAT_SET_SIZE),
    truncate(File, Size);
run(<<"fd_filestat_set_times">>, S, _, [Fd, Atim, Mtim, Flags]) ->
    Entry = fd(S, Fd, ?FD_FILESTAT_SET_TIMES, 0),
    set_times(Entry#fd.real, Atim, Mtim, Flags);
run(<<"fd_pread">>, S, _, [Fd, Iovs, Count, Offset, Nread]) ->
    #fd{file = File} = file_fd(S, Fd, ?FD_READ bor ?FD_SEEK),
    Lengths = iovecs(S, Iovs, Count),
    Data = case file:pread(File, Offset, lists:sum([L || {_, L} <- Lengths])) of
        {ok, D} -> D;
        eof -> <<>>;
        {error, Reason} -> fail(errno(Reason))
    end,
    scatter(S, Lengths, Data),
    write(S, Nread, <<(byte_size(Data)):32/little>>);
run(<<"fd_pwrite">>, S, _, [Fd, Iovs, Count, Offset, Nwritten]) ->
    #fd{file = File} = file_fd(S, Fd, ?FD_WRITE bor ?FD_SEEK),
    Data = gather(S, Iovs, Count),
    posix(file:pwrite(File, Offset, Data)),
    write(S, Nwritten, <<(byte_size(Data)):32/little>>);
run(<<"fd_read">>, S, _, [Fd, Iovs, Count, Nread]) ->
    Entry = fd(S, Fd, ?FD_READ, 0),
    Lengths = iovecs(S, Iovs, Count),
    Data = read_fd(Entry, lists:sum([L || {_, L} <- Lengths])),
    scatter(S, Lengths, Data),
    write(S, Nread, <<(byte_size(Data)):32/little>>);
run(<<"fd_write">>, S, _, [Fd, Iovs, Count, Nwritten]) ->
    Entry = fd(S, Fd, ?FD_WRITE, 0),
    Data = gather(S, Iovs, Count),
    write_fd(Entry, Data),
    write(S, Nwritten, <<(byte_size(Data)):32/little>>);
run(<<"fd_prestat_get">>, S, _, [Fd, Buf]) ->
    case fd(S, Fd, 0, 0) of
        #fd{preopen = none} -> fail(?EBADF);
        #fd{preopen = Name} -> write(S, Buf, <<0:8, 0:24, (byte_size(Name)):32/little>>)
    end;
run(<<"fd_prestat_dir_name">>, S, _, [Fd, Ptr, Len]) ->
    case fd(S, Fd, 0, 0) of
        #fd{preopen = none} -> fail(?EBADF);
        #fd{preopen = Name} when byte_size(Name) > Len -> fail(?ENOBUFS);
        #fd{preopen = Name} -> write(S, Ptr, Name)
    end;
run(<<"fd_readdir">>, S, _, [Fd, Buf, Len, Cookie, Used]) ->
    #fd{real = Real} = fd(S, Fd, ?FD_READDIR, 0),
    Names = case prim_file:list_dir(Real) of
        {ok, L} -> L;
        {error, Reason} -> fail(errno(Reason))
    end,
    Entries = lists:nthtail(min(Cookie, length(Names)), [list_to_binary(N) || N <- Names]),
    Bytes = iolist_to_binary(dirents(Real, Entries, Cookie)),
    Out = binary:part(Bytes, 0, min(Len, byte_size(Bytes))),
    ok = write(S, Buf, Out),
    write(S, Used, <<(byte_size(Out)):32/little>>);
run(<<"fd_renumber">>, _S, _, [Same, Same]) -> ok;
run(<<"fd_renumber">>, S = #{fds := Fds}, _, [From, To]) ->
    Entry = fd(S, From, 0, 0),
    Target = fd(S, To, 0, 0),
    close(Target),
    {ok, S#{fds => maps:remove(From, Fds#{To => Entry})}};
run(<<"fd_seek">>, S, _, [Fd, Offset, Whence, Ptr]) ->
    Right = case {Offset, Whence} of
        {0, 1} -> ?FD_TELL;
        _ -> ?FD_SEEK bor ?FD_TELL
    end,
    Entry = fd(S, Fd, Right, 0),
    Entry#fd.kind =:= file orelse fail(?ESPIPE),
    Location = case Whence of
        0 -> {bof, Offset};
        1 -> {cur, Offset};
        2 -> {eof, Offset};
        _ -> fail(?EINVAL)
    end,
    case file:position(Entry#fd.file, Location) of
        {ok, New} -> write(S, Ptr, <<New:64/little>>);
        {error, Reason} -> fail(errno(Reason))
    end;
run(<<"fd_tell">>, S, _, [Fd, Ptr]) ->
    Entry = fd(S, Fd, ?FD_TELL, 0),
    Entry#fd.kind =:= file orelse fail(?ESPIPE),
    {ok, Position} = file:position(Entry#fd.file, cur),
    write(S, Ptr, <<Position:64/little>>);
run(<<"path_create_directory">>, S, _, [Fd, Ptr, Len]) ->
    Path = resolve(S, Fd, ?PATH_CREATE_DIRECTORY, Ptr, Len, 0),
    posix(prim_file:make_dir(Path));
run(<<"path_filestat_get">>, S, _, [Fd, Flags, Ptr, Len, Buf]) ->
    Path = resolve(S, Fd, ?PATH_FILESTAT_GET, Ptr, Len, Flags),
    write(S, Buf, filestat(info(prim_file:read_link_info(Path, [{time, posix}]))));
run(<<"path_filestat_set_times">>, S, _, [Fd, Flags, Ptr, Len, Atim, Mtim, FstFlags]) ->
    Path = resolve(S, Fd, ?PATH_FILESTAT_SET_TIMES, Ptr, Len, Flags),
    set_times(Path, Atim, Mtim, FstFlags);
run(<<"path_link">>, S, _, [OldFd, OldFlags, OldPtr, OldLen, NewFd, NewPtr, NewLen]) ->
    Old = resolve(S, OldFd, ?PATH_LINK_SOURCE, OldPtr, OldLen, OldFlags),
    New = resolve(S, NewFd, ?PATH_LINK_TARGET, NewPtr, NewLen, 0),
    posix(prim_file:make_link(Old, New));
run(<<"path_open">>, S, _, [DirFd, DirFlags, Ptr, Len, OFlags, Base, Inheriting, FdFlags, FdPtr]) ->
    path_open(S, DirFd, DirFlags, Ptr, Len, OFlags, Base, Inheriting, FdFlags, FdPtr);
run(<<"path_readlink">>, S, _, [Fd, Ptr, Len, Buf, BufLen, Used]) ->
    Path = resolve(S, Fd, ?PATH_READLINK, Ptr, Len, 0),
    Target = case prim_file:read_link(Path) of
        {ok, T} -> unicode:characters_to_binary(T);
        {error, Reason} -> fail(errno(Reason))
    end,
    Out = binary:part(Target, 0, min(BufLen, byte_size(Target))),
    ok = write(S, Buf, Out),
    write(S, Used, <<(byte_size(Out)):32/little>>);
run(<<"path_remove_directory">>, S, _, [Fd, Ptr, Len]) ->
    Path = resolve(S, Fd, ?PATH_REMOVE_DIRECTORY, Ptr, Len, 0),
    posix(prim_file:del_dir(Path));
run(<<"path_rename">>, S, _, [OldFd, OldPtr, OldLen, NewFd, NewPtr, NewLen]) ->
    Old = resolve(S, OldFd, ?PATH_RENAME_SOURCE, OldPtr, OldLen, 0),
    New = resolve(S, NewFd, ?PATH_RENAME_TARGET, NewPtr, NewLen, 0),
    posix(prim_file:rename(Old, New));
run(<<"path_symlink">>, S, _, [OldPtr, OldLen, Fd, NewPtr, NewLen]) ->
    Target = read(S, OldPtr, OldLen),
    New = resolve(S, Fd, ?PATH_SYMLINK, NewPtr, NewLen, 0),
    posix(prim_file:make_symlink(Target, New));
run(<<"path_unlink_file">>, S, _, [Fd, Ptr, Len]) ->
    Path = resolve(S, Fd, ?PATH_UNLINK_FILE, Ptr, Len, 0),
    case prim_file:read_link_info(Path) of
        {ok, #file_info{type = directory}} -> fail(?EISDIR);
        _ -> posix(prim_file:delete(Path))
    end;
run(<<"poll_oneoff">>, S, _, [In, Out, Count, Nevents]) ->
    poll_oneoff(S, In, Out, Count, Nevents);
run(<<"proc_exit">>, _S, _, [Code]) ->
    buoy_node_loop:really_exit(Code);
run(<<"proc_raise">>, _S, _, [_Signal]) ->
    ?ENOSYS;
run(<<"random_get">>, S, _, [Ptr, Len]) ->
    write(S, Ptr, crypto:strong_rand_bytes(Len));
run(<<"sched_yield">>, _S, _, []) ->
    erlang:yield(),
    ok;
run(<<"sock_accept">>, S, _, [Fd, Flags, _Ptr]) ->
    Flags band (bnot 4) =:= 0 orelse fail(?ENOTSUP),
    _ = fd(S, Fd, ?SOCKET_BASE, 0),
    ?ENOTSUP;
run(<<"sock_recv">>, S, _, [Fd, _Iovs, _Count, Flags, _Len, _OutFlags]) ->
    Flags =:= 0 orelse fail(?ENOTSUP),
    _ = fd(S, Fd, ?SOCKET_BASE, 0),
    ?ENOTSUP;
run(<<"sock_send">>, S, _, [Fd, _Iovs, _Count, Flags, _Len]) ->
    Flags =:= 0 orelse fail(?EINVAL),
    _ = fd(S, Fd, ?SOCKET_BASE, 0),
    ?ENOTSUP;
run(<<"sock_shutdown">>, S, _, [Fd, How]) ->
    How band (bnot 2) =:= 0 orelse fail(?ENOTSUP),
    _ = fd(S, Fd, ?SOCKET_BASE, 0),
    ?ENOTSUP.

%%% Descriptors

%% uvwasi_fd_table_get: the descriptor Fd with the rights Base and Inheriting.
fd(#{fds := Fds}, Fd, Base, Inheriting) ->
    case Fds of
        #{Fd := Entry = #fd{base = B, inheriting = I}} ->
            (B band Base =:= Base andalso I band Inheriting =:= Inheriting) orelse fail(?ENOTCAPABLE),
            Entry;
        _ ->
            fail(?EBADF)
    end.

%% A descriptor of an open file: the calls on a file need its raw file.
file_fd(S, Fd, Rights) ->
    case fd(S, Fd, Rights, 0) of
        #fd{kind = file} = Entry -> Entry;
        #fd{kind = dir} -> fail(?EISDIR);
        #fd{} -> fail(?EBADF)
    end.

close(#fd{kind = file, file = File}) -> _ = file:close(File), ok;
close(_) -> ok.

read_fd(#fd{kind = file, file = File}, Count) ->
    case file:read(File, Count) of
        {ok, Data} -> Data;
        eof -> <<>>;
        {error, Reason} -> fail(errno(Reason))
    end;
read_fd(#fd{kind = dir}, _Count) -> fail(?EISDIR);
read_fd(#fd{kind = stdio, host = 0}, Count) -> buoy_node_stdin:read(Count);
read_fd(#fd{kind = stdio, host = Host}, Count) ->
    Buffer = buoy_node_encoding:new_buffer(binary:copy(<<0>>, Count)),
    Read = fs_call(<<"read">>, [Host, Buffer, 0, Count, -1]),
    buoy_node_encoding:view_bytes(Buffer, 0, trunc(buoy_ref:to_number(Read))).

write_fd(#fd{kind = file, file = File, append = Append}, Data) ->
    Append andalso file:position(File, eof),
    posix(file:write(File, Data));
write_fd(#fd{kind = dir}, _Data) -> fail(?EISDIR);
write_fd(#fd{kind = stdio, host = 1}, Data) -> put_bytes(standard_io, Data);
write_fd(#fd{kind = stdio, host = 2}, Data) -> put_bytes(buoy_ref:stderr(), Data);
write_fd(#fd{kind = stdio, host = Host}, Data) ->
    _ = fs_call(<<"writeBuffer">>, [Host, buoy_node_encoding:new_buffer(Data), 0, byte_size(Data), null]),
    ok.

%% A call of internalBinding('fs') on a descriptor of the realm, which
%% lib/fs opened: its errno becomes WASI's.
fs_call(Name, Args) ->
    Fs = buoy_node:binding(<<"fs">>),
    try buoy_heap:call(buoy_heap:get(Fs, Name), Fs, Args)
    catch
        error:{'$throw', E} ->
            Code = buoy_heap:get(E, <<"code">>),
            fail(case is_binary(Code) of
                     true -> errno(binary_to_atom(string:lowercase(Code)));
                     false -> ?EIO
                 end)
    end.

%% The device is in unicode mode: valid UTF-8 goes through as text, and
%% other bytes as latin1 characters in a latin1 window.
put_bytes(Device, Bytes) ->
    case unicode:characters_to_list(Bytes, utf8) of
        L when is_list(L) ->
            io:put_chars(Device, Bytes);
        _ ->
            ok = io:setopts(Device, [{encoding, latin1}]),
            io:put_chars(Device, Bytes),
            ok = io:setopts(Device, [{encoding, unicode}])
    end.

fd_info(#fd{kind = file, file = File}) -> info(prim_file:read_handle_info(File, [{time, posix}]));
fd_info(#fd{kind = dir, real = Real}) -> info(prim_file:read_file_info(Real, [{time, posix}]));
fd_info(#fd{kind = stdio, type = Type}) ->
    {ok, #file_info{type = case Type of ?REGULAR_FILE -> regular; _ -> device end, size = 0, links = 1,
                    major_device = 0, minor_device = 0, inode = 0, atime = 0, mtime = 0, ctime = 0}}.

%%% path_open

path_open(S = #{fds := Fds}, DirFd, DirFlags, Ptr, Len, OFlags, Base, Inheriting, FdFlags, FdPtr) ->
    Read = Base band (?FD_READ bor ?FD_READDIR) =/= 0,
    Write = Base band (?FD_DATASYNC bor ?FD_WRITE bor ?FD_ALLOCATE bor ?FD_FILESTAT_SET_SIZE) =/= 0,
    NeededBase = ?PATH_OPEN
        bor flag(OFlags, ?O_CREAT, ?PATH_CREATE_FILE)
        bor flag(OFlags, ?O_TRUNC, ?PATH_FILESTAT_SET_SIZE),
    Append = FdFlags band ?FDFLAG_APPEND =/= 0,
    NeededInheriting = Base bor Inheriting
        bor flag(FdFlags, 2, ?FD_DATASYNC) bor flag(FdFlags, 8 bor 16, ?FD_SYNC)
        bor case Write andalso not Append andalso OFlags band ?O_TRUNC =:= 0 of
                true -> ?FD_SEEK;
                false -> 0
            end,
    Dir = fd(S, DirFd, NeededBase, NeededInheriting),
    {Path, Fake} = resolve_entry(S, Dir, Ptr, Len, DirFlags),
    Info = prim_file:read_file_info(Path, [{time, posix}]),
    Exists = element(1, Info) =:= ok,
    (OFlags band ?O_EXCL =/= 0 andalso OFlags band ?O_CREAT =/= 0 andalso Exists) andalso fail(?EEXIST),
    IsDir = case Info of
        {ok, #file_info{type = directory}} -> true;
        _ -> false
    end,
    (not IsDir andalso (OFlags band ?O_DIRECTORY =/= 0 orelse binary:last(Path) =:= $/)) andalso
        (Exists orelse OFlags band ?O_CREAT =:= 0) andalso fail(case Exists of true -> ?ENOTDIR; false -> ?ENOENT end),
    Entry = case IsDir of
        true ->
            Write andalso fail(?EISDIR),
            #fd{kind = dir, type = ?DIRECTORY, base = Base band ?DIRECTORY_BASE,
                inheriting = Inheriting band ?DIRECTORY_INHERITING, path = Fake, real = Path};
        false ->
            Modes = [raw, binary]
                ++ case {Read, Write} of
                       {_, false} -> [read];
                       {false, true} -> [write];
                       {true, true} -> [read, write]
                   end,
            File = open(Path, Modes, OFlags, Write, Exists),
            Type = case Info of
                {ok, #file_info{type = device}} -> ?CHARACTER_DEVICE;
                _ -> ?REGULAR_FILE
            end,
            Max = case {Read, Write} of
                {_, false} -> ?REGULAR_FILE_BASE band bnot ?FD_WRITE;
                {false, true} -> ?REGULAR_FILE_BASE band bnot ?FD_READ;
                _ -> ?REGULAR_FILE_BASE
            end,
            #fd{kind = file, type = Type, base = Base band Max, inheriting = 0, file = File, path = Fake, real = Path,
                append = Append}
    end,
    New = next_fd(Fds, 3),
    ok = write(S, FdPtr, <<New:32/little>>),
    {ok, S#{fds => Fds#{New => Entry}}}.

flag(Flags, Bit, Right) when Flags band Bit =/= 0 -> Right;
flag(_, _, _) -> 0.

%% Opens a regular file with uv_fs_open's flags: O_CREAT and O_TRUNC through
%% the modes of file:open, which creates a file only in a write mode.
open(Path, Modes, OFlags, Write, Exists) ->
    Create = OFlags band ?O_CREAT =/= 0,
    Truncate = OFlags band ?O_TRUNC =/= 0,
    (not Exists andalso not Create) andalso fail(?ENOENT),
    Opened = case {Exists, Create, Write, Truncate} of
        {false, true, false, _} ->
            %% O_CREAT without a write right still creates the file.
            ok = posix(prim_file:write_file(Path, <<>>)),
            file:open(Path, Modes);
        {_, _, true, false} ->
            %% A write mode of file:open truncates unless read is also given.
            file:open(Path, lists:usort([read | Modes]));
        _ ->
            file:open(Path, Modes)
    end,
    case Opened of
        {ok, File} ->
            Truncate andalso posix(file:truncate(File)),
            File;
        {error, Reason} ->
            fail(errno(Reason))
    end.

next_fd(Fds, N) ->
    case Fds of
        #{N := _} -> next_fd(Fds, N + 1);
        _ -> N
    end.

%%% Paths

%% The host path of the path at Ptr, relative to the directory Fd, which
%% needs the rights Rights.
resolve(S, Fd, Rights, Ptr, Len, Flags) ->
    Dir = fd(S, Fd, Rights, 0),
    {Path, _} = resolve_entry(S, Dir, Ptr, Len, Flags),
    Path.

resolve_entry(S, #fd{kind = dir} = Dir, Ptr, Len, Flags) ->
    Input = read(S, Ptr, Len),
    binary:match(Input, <<0>>) =:= nomatch orelse fail(?EINVAL),
    is_absolute(Input) andalso fail(?ENOTCAPABLE),
    follow(Dir, Input, Flags band ?SYMLINK_FOLLOW =/= 0, 0);
resolve_entry(_S, _Fd, _Ptr, _Len, _Flags) ->
    fail(?ENOTDIR).

%% uvwasi__resolve_path: normalize against the fake path of the directory,
%% check that it stays inside, map it to the host, and follow a symbolic
%% link of the last component.
follow(_Dir, _Input, _Follow, Count) when Count >= ?MAX_SYMLINK_FOLLOWS -> fail(?ELOOP);
follow(Dir = #fd{path = Base, real = Real}, Input, Follow, Count) ->
    Normalized = case is_absolute(Input) of
        true -> normalize(Input);
        false -> normalize(<<Base/binary, "/", Input/binary>>)
    end,
    is_sandboxed(Normalized, Base) orelse fail(?ENOTCAPABLE),
    Host = host_path(Normalized, Base, Real, Input),
    case Follow andalso prim_file:read_link(Host) of
        {ok, Target} ->
            Link = unicode:characters_to_binary(Target),
            Next = case is_absolute(Link) of
                true -> Link;
                false -> <<Normalized/binary, "/../", Link/binary>>
            end,
            follow(Dir, Next, Follow, Count + 1);
        _ ->
            {Host, Normalized}
    end.

is_absolute(<<"/", _/binary>>) -> true;
is_absolute(_) -> false.

%% uvwasi__normalize_path: drops empty and . components and applies ..,
%% keeping a leading .. of a relative path.
normalize(Path) ->
    Parts = binary:split(Path, <<"/">>, [global]),
    Absolute = is_absolute(Path),
    Kept = lists:foldl(fun(<<>>, Acc) -> Acc;
                          (<<".">>, Acc) -> Acc;
                          (<<"..">>, [Last | Rest]) when Last =/= <<"..">> -> Rest;
                          (<<"..">>, []) when Absolute -> [];
                          (Part, Acc) -> [Part | Acc]
                       end, [], Parts),
    Joined = iolist_to_binary(lists:join(<<"/">>, lists:reverse(Kept))),
    case {Absolute, Joined} of
        {true, _} -> <<"/", Joined/binary>>;
        {false, <<>>} -> <<".">>;
        {false, _} -> Joined
    end.

is_sandboxed(Path, Base) ->
    case {Base, Path} of
        {<<"/">>, <<"/", _/binary>>} -> true;
        {<<".">>, _} -> not is_absolute(Path) andalso binary:part(<<Path/binary, "/">>, 0, 3) =/= <<"../">>;
        _ ->
            Size = byte_size(Base),
            Path =:= Base orelse
                (byte_size(Path) > Size andalso binary:part(Path, 0, Size + 1) =:= <<Base/binary, "/">>)
    end.

%% The host path of a normalized path: the real path of the directory, then
%% the rest. A trailing slash of the input stays, so that path_open sees it.
host_path(Normalized, Base, Real, Input) ->
    Rest = case Base of
        <<".">> -> <<"/", Normalized/binary>>;
        _ -> binary:part(Normalized, byte_size(Base), byte_size(Normalized) - byte_size(Base))
    end,
    Slash = case binary:last(<<"x", Input/binary>>) of
        $/ when Rest =/= <<>> -> <<"/">>;
        _ -> <<>>
    end,
    <<Real/binary, Rest/binary, Slash/binary>>.

%%% Files

info({ok, Info}) -> {ok, Info};
info({error, Reason}) -> fail(errno(Reason)).

%% The filestat of WASI: dev, ino, filetype, nlink, size, and the times in
%% nanoseconds.
filestat({ok, #file_info{type = Type, size = Size, links = Links, major_device = Dev, inode = Ino,
                         atime = A, mtime = M, ctime = C}}) ->
    <<Dev:64/little, Ino:64/little, (filetype(Type)):8, 0:56, Links:64/little, Size:64/little,
      (A * 1000000000):64/little, (M * 1000000000):64/little, (C * 1000000000):64/little>>.

filetype(regular) -> ?REGULAR_FILE;
filetype(directory) -> ?DIRECTORY;
filetype(symlink) -> ?SYMBOLIC_LINK;
filetype(device) -> ?CHARACTER_DEVICE;
filetype(_) -> ?UNKNOWN.

%% fd_readdir entries from the cookie Cookie: d_next, d_ino (0, as libuv
%% gives none), d_namlen, d_type, then the name.
dirents(_Real, [], _Cookie) -> [];
dirents(Real, [Name | Rest], Cookie) ->
    Type = case prim_file:read_link_info(<<Real/binary, "/", Name/binary>>) of
        {ok, #file_info{type = T}} -> filetype(T);
        _ -> ?UNKNOWN
    end,
    [<<(Cookie + 1):64/little, 0:64, (byte_size(Name)):32/little, Type:8, 0:24>>, Name | dirents(Real, Rest, Cookie + 1)].

truncate(File, Size) ->
    {ok, Position} = file:position(File, cur),
    Result = case file:position(File, {bof, Size}) of
        {ok, _} -> file:truncate(File);
        Error -> Error
    end,
    _ = file:position(File, {bof, Position}),
    case Result of
        ok -> extend(File, Size);
        {error, Reason} -> fail(errno(Reason))
    end.

%% Grows a file with zero bytes to Size, as ftruncate does.
extend(File, Size) ->
    {ok, #file_info{size = Now}} = prim_file:read_handle_info(File, [{time, posix}]),
    case Now < Size of
        true -> posix(file:pwrite(File, Size - 1, <<0>>));
        false -> ok
    end.

set_times(Path, Atim, Mtim, Flags) ->
    (Flags band (?FILESTAT_SET_ATIM bor ?FILESTAT_SET_ATIM_NOW) =:= (?FILESTAT_SET_ATIM bor ?FILESTAT_SET_ATIM_NOW)
     orelse Flags band (?FILESTAT_SET_MTIM bor ?FILESTAT_SET_MTIM_NOW) =:= (?FILESTAT_SET_MTIM bor ?FILESTAT_SET_MTIM_NOW))
        andalso fail(?EINVAL),
    {ok, #file_info{atime = A0, mtime = M0}} = info(prim_file:read_file_info(Path, [{time, posix}])),
    Now = os:system_time(second),
    A = pick(Flags, ?FILESTAT_SET_ATIM, ?FILESTAT_SET_ATIM_NOW, Atim, A0, Now),
    M = pick(Flags, ?FILESTAT_SET_MTIM, ?FILESTAT_SET_MTIM_NOW, Mtim, M0, Now),
    posix(prim_file:write_file_info(Path, #file_info{atime = A, mtime = M}, [{time, posix}])).

pick(Flags, Set, _Now, Value, _Old, _Time) when Flags band Set =/= 0 -> Value div 1000000000;
pick(Flags, _Set, NowBit, _Value, _Old, Now) when Flags band NowBit =/= 0 -> Now;
pick(_, _, _, _, Old, _) -> Old.

posix(ok) -> ok;
posix({ok, _}) -> ok;
posix({error, Reason}) -> fail(errno(Reason)).

posix({error, enotsup}, Fallback) -> Fallback();
posix(Result, _Fallback) -> posix(Result).

%%% Clocks

resolution(0) -> 1000;
resolution(1) -> 1;
resolution(2) -> 1000;
resolution(3) -> 1000;
resolution(_) -> fail(?EINVAL).

now(0) -> os:system_time(nanosecond);
now(1) -> erlang:monotonic_time(nanosecond) - erlang:system_info(start_time) + 1;
now(C) when C =:= 2; C =:= 3 ->
    {Runtime, _} = erlang:statistics(runtime),
    Runtime * 1000000;
now(_) -> fail(?EINVAL).

%%% poll_oneoff

%% uvwasi_poll_oneoff: the events of the subscriptions that are ready, or,
%% when none is, the first that becomes ready: the earliest clock, or stdin
%% once it has bytes or ends. Files and the other descriptors are always
%% ready, as uv_poll finds them.
poll_oneoff(_S, _In, _Out, 0, _Nevents) -> ?EINVAL;
poll_oneoff(S, In, Out, Count, Nevents) ->
    Subs = [decode_subscription(read(S, In + I * 48, 48)) || I <- lists:seq(0, Count - 1)],
    Clocks = lists:sort([{Timeout, User} || {clock, User, Timeout} <- Subs]),
    Fds = [fd_ready(S, Sub) || {Type, _, _} = Sub <- Subs, Type =/= clock],
    Events = case [Event || {ready, Event} <- Fds] of
        [] -> wait([Sub || {waiting, Sub} <- Fds], Clocks);
        Ready -> Ready
    end,
    ok = write(S, Out, iolist_to_binary(Events)),
    write(S, Nevents, <<(length(Events)):32/little>>).

%% Waits for stdin or the earliest clock, whichever comes first.
wait([], []) -> [];
wait([], [{Timeout, User} | _]) ->
    timer:sleep(ceil_ms(Timeout)),
    [clock_event(User)];
wait(Stdin, Clocks) ->
    Limit = case Clocks of
        [] -> infinity;
        [{Timeout, _} | _] -> ceil_ms(Timeout)
    end,
    case buoy_node_stdin:poll(Limit) of
        timeout -> [clock_event(User) || {_, User} <- lists:sublist(Clocks, 1)];
        {Bytes, Ended} -> [fd_event(User, ?ESUCCESS, Type, Bytes, Ended) || {Type, User, _} <- Stdin]
    end.

ceil_ms(Nanoseconds) -> (Nanoseconds + 999999) div 1000000.

clock_event(User) -> <<User:64/little, 0:16, 0:8, 0:40, 0:64, 0:16, 0:48>>.

decode_subscription(<<User:64/little, 0:8, _:56, _Id:32/little, _:32, Timeout:64/little, _Precision:64/little,
                      Flags:16/little, _/binary>>) ->
    Delay = case Flags band 1 of
        1 -> max(0, Timeout - os:system_time(nanosecond));
        0 -> Timeout
    end,
    {clock, User, Delay};
decode_subscription(<<User:64/little, Tag:8, _:56, Fd:32/little, _/binary>>) when Tag =:= 1; Tag =:= 2 ->
    {Tag, User, Fd};
decode_subscription(_) -> fail(?EINVAL).

%% The event of a descriptor subscription when it is ready now: a read of
%% stdin is ready once bytes wait or stdin ended, which sets the hangup
%% flag.
fd_ready(#{fds := Fds}, {Type, User, Fd} = Sub) ->
    case Fds of
        #{Fd := #fd{kind = stdio, host = 0, base = B}} when Type =:= 1, B band ?POLL_FD_READWRITE =/= 0 ->
            case buoy_node_stdin:poll(0) of
                timeout -> {waiting, Sub};
                {Bytes, Ended} -> {ready, fd_event(User, ?ESUCCESS, Type, Bytes, Ended)}
            end;
        #{Fd := #fd{base = B}} when B band ?POLL_FD_READWRITE =/= 0 -> {ready, fd_event(User, ?ESUCCESS, Type, 0, false)};
        #{Fd := _} -> {ready, fd_event(User, ?ENOTCAPABLE, Type, 0, false)};
        _ -> {ready, fd_event(User, ?EBADF, Type, 0, false)}
    end.

fd_event(User, Error, Type, Bytes, Hangup) ->
    Flags = case Hangup of true -> 1; false -> 0 end,
    <<User:64/little, Error:16/little, Type:8, 0:40, Bytes:64/little, Flags:16/little, 0:48>>.

%%% Strings and memory

strings_get(S, Strings, Pointers, Buf) ->
    {Offsets, _} = lists:mapfoldl(fun(Str, At) -> {<<At:32/little>>, At + byte_size(Str) + 1} end, Buf, Strings),
    ok = write(S, Pointers, iolist_to_binary(Offsets)),
    write(S, Buf, iolist_to_binary([[Str, 0] || Str <- Strings])).

strings_sizes(S, Strings, CountPtr, SizePtr) ->
    ok = write(S, CountPtr, <<(length(Strings)):32/little>>),
    write(S, SizePtr, <<(lists:sum([byte_size(Str) + 1 || Str <- Strings])):32/little>>).

%% The iovecs at Ptr: [{Buf, Len}].
iovecs(S, Ptr, Count) ->
    [{Buf, Len} || <<Buf:32/little, Len:32/little>> <= read(S, Ptr, Count * 8)].

gather(S, Ptr, Count) -> iolist_to_binary([read(S, Buf, Len) || {Buf, Len} <- iovecs(S, Ptr, Count)]).

scatter(_S, _Lengths, <<>>) -> ok;
scatter(_S, [], _Data) -> ok;
scatter(S, [{Buf, Len} | Rest], Data) ->
    Take = min(Len, byte_size(Data)),
    <<Part:Take/binary, More/binary>> = Data,
    ok = write(S, Buf, Part),
    scatter(S, Rest, More).

read(#{memory := H}, Ptr, Len) ->
    in_bounds(H, Ptr, Len),
    buoy_ref_wasm:read(H, Ptr, Len).

write(#{memory := H}, Ptr, Bytes) ->
    in_bounds(H, Ptr, byte_size(Bytes)),
    buoy_ref_wasm:write(H, Ptr, Bytes).

in_bounds(H, Ptr, Len) ->
    Ptr + Len =< buoy_ref_wasm:size(H) orelse fail(?EOVERFLOW).

%%% Errors

%% uvwasi__translate_uv_error for the reasons of Erlang's file calls.
errno(eacces) -> 2;
errno(eagain) -> 6;
errno(ebadf) -> ?EBADF;
errno(ebusy) -> 10;
errno(eexist) -> ?EEXIST;
errno(efault) -> 21;
errno(efbig) -> 22;
errno(eintr) -> 27;
errno(einval) -> ?EINVAL;
errno(eio) -> ?EIO;
errno(eisdir) -> ?EISDIR;
errno(eloop) -> ?ELOOP;
errno(emfile) -> 33;
errno(emlink) -> 34;
errno(enametoolong) -> 37;
errno(enfile) -> 41;
errno(enodev) -> 43;
errno(enoent) -> ?ENOENT;
errno(enomem) -> 48;
errno(enospc) -> 51;
errno(enosys) -> ?ENOSYS;
errno(enotdir) -> ?ENOTDIR;
errno(enotempty) -> 55;
errno(enotsup) -> ?ENOTSUP;
errno(eperm) -> 63;
errno(epipe) -> 64;
errno(erofs) -> 69;
errno(espipe) -> ?ESPIPE;
errno(exdev) -> 75;
errno(_) -> ?EIO.
