%% internalBinding('blob') (src/node_blob.cc): the handles behind Blob, their
%% readers, the object URLs of URL.createObjectURL, and concat.
%%
%% A handle holds its parts: binaries, and ranges of files, which a reader
%% reads when it pulls them. Node's DataQueue fails the read of a file that
%% changed since the blob took it, and so does a reader here.
-module(buoy_binding_blob).

-include_lib("kernel/include/file.hrl").
-include("buoy_ref.hrl").

-export([binding/0]).

-define(STATE, {'#', ?MODULE, <<"state">>}).
-define(OBJECTS, {?MODULE, objects}).
%% bob::Status of src/node_bob.h.
-define(STATUS_EOS, 0).
-define(STATUS_CONTINUE, 1).
%% The bytes that one pull reads from a file.
-define(FILE_CHUNK, 65536).

-type part() :: binary() | {file, file:filename_all(), #file_info{}, non_neg_integer(), non_neg_integer()}.

-spec binding() -> term().
binding() ->
    F = fun buoy_node:fn/3,
    A = fun buoy_node:arg/2,
    Handle = handle_class(),
    Reader = reader_class(),
    erlang:put({?MODULE, classes}, {Handle, Reader}),
    buoy_node:object([
        {<<"createBlob">>, F(<<"createBlob">>, 2, fun(_, Args) -> new(lists:flatmap(fun parts/1, buoy_heap:array_items(A(1, Args)))) end)},
        {<<"storeDataObject">>, F(<<"storeDataObject">>, 4, fun(_, Args) -> store(A(1, Args), A(2, Args), A(3, Args), A(4, Args)) end)},
        {<<"getDataObject">>, F(<<"getDataObject">>, 1, fun(_, Args) -> lookup(A(1, Args)) end)},
        {<<"revokeObjectURL">>, F(<<"revokeObjectURL">>, 1, fun(_, Args) -> revoke(A(1, Args)) end)},
        {<<"concat">>, F(<<"concat">>, 1, fun(_, Args) -> concat(A(1, Args)) end)},
        {<<"createBlobFromFilePath">>, F(<<"createBlobFromFilePath">>, 1, fun(_, Args) -> from_file(A(1, Args)) end)}]).

handle_class() ->
    Class = buoy_node:constructor(<<"BlobHandle">>, 0, fun(_, _) -> undefined end),
    methods(Class, [
        {<<"getReader">>, 0, fun(This, _) -> reader(This) end},
        {<<"slice">>, 2, fun(This, Args) -> slice(This, buoy_node:arg(1, Args), buoy_node:arg(2, Args)) end}]).

reader_class() ->
    Class = buoy_node:constructor(<<"BlobReader">>, 0, fun(_, _) -> undefined end),
    methods(Class, [{<<"pull">>, 1, fun(This, Args) -> pull(This, buoy_node:arg(1, Args)) end}]).

methods(Class, Methods) ->
    Proto = buoy_heap:get(Class, <<"prototype">>),
    [buoy_heap:define(Proto, Name, #{value => buoy_node:fn(Name, Length, Fun), writable => true,
                                     enumerable => true, configurable => true})
     || {Name, Length, Fun} <- Methods],
    Class.

%% A new handle of the class Index of the binding (1 for a blob, 2 for a
%% reader) with the state State.
instance(Index, State) ->
    Class = element(Index, erlang:get({?MODULE, classes})),
    Object = buoy_node:object(buoy_heap:get(Class, <<"prototype">>), []),
    buoy_heap:private_put(Object, ?STATE, State),
    Object.

state(Object) ->
    case ?IS_OBJECT(Object) andalso buoy_heap:private_find(Object, ?STATE) of
        {ok, State} -> State;
        _ -> buoy_node:throw_code('TypeError', <<"ERR_INVALID_THIS">>, <<"Illegal invocation">>)
    end.

%%% Blobs

%% A file part stays when it is empty: a read still checks that the file has
%% not changed.
-spec new([part()]) -> term().
new(Parts) -> instance(1, {blob, [P || P <- Parts, P =/= <<>>]}).

%% The parts of a source of createBlob: an ArrayBuffer, a view, or a handle.
parts(Source) ->
    case buoy_heap:private_find(Source, ?STATE) of
        {ok, {blob, Parts}} -> Parts;
        _ -> [buoy_node_encoding:view_bytes(Source)]
    end.

size_of(Bytes) when is_binary(Bytes) -> byte_size(Bytes);
size_of({file, _, _, _, Length}) -> Length.

%% slice(start, end): the bytes of [start, end), which lib/internal/blob.js
%% has clamped to the blob.
slice(This, Start, End) ->
    {blob, Parts} = state(This),
    From = to_index(Start),
    new(take(drop(Parts, From), max(0, to_index(End) - From))).

drop(Parts, 0) -> Parts;
drop([], _) -> [];
drop([Part | Rest], N) ->
    Size = size_of(Part),
    case N >= Size of
        true -> drop(Rest, N - Size);
        false -> [range(Part, N, Size - N) | Rest]
    end.

take(_, 0) -> [];
take([], _) -> [];
take([Part | Rest], N) ->
    Size = size_of(Part),
    case N >= Size of
        true -> [Part | take(Rest, N - Size)];
        false -> [range(Part, 0, N)]
    end.

range(Bytes, At, Length) when is_binary(Bytes) -> binary:part(Bytes, At, Length);
range({file, Path, Info, Offset, _}, At, Length) -> {file, Path, Info, Offset + At, Length}.

%% createBlobFromFilePath(path): [handle, length] of a regular file, or
%% undefined.
from_file(Path) ->
    Name = buoy_ref_string:to_utf8(buoy_ref:to_string(Path)),
    case file:read_file_info(Name, [{time, posix}]) of
        {ok, #file_info{type = regular, size = Size} = Info} ->
            buoy_heap:new_array([new([{file, Name, Info, 0, Size}]), Size]);
        _ ->
            undefined
    end.

%%% Readers

reader(This) ->
    {blob, Parts} = state(This),
    instance(2, {reader, Parts, false}).

%% pull(callback): the next bytes as (CONTINUE, ArrayBuffer), then (EOS,
%% undefined); after that, (EOS) alone. A file that changed since the blob
%% took it gives a negative status.
pull(This, Callback) ->
    case state(This) of
        {reader, _, true} ->
            buoy_heap:call(Callback, This, [?STATUS_EOS]),
            ?STATUS_EOS;
        {reader, Parts, false} ->
            case next(Parts) of
                {ok, Bytes, Rest} ->
                    buoy_heap:private_put(This, ?STATE, {reader, Rest, false}),
                    Buffer = buoy_ref_buffer:allocate(byte_size(Bytes)),
                    buoy_ref_buffer:write(Buffer, 0, Bytes),
                    buoy_heap:call(Callback, This, [?STATUS_CONTINUE, Buffer]),
                    ?STATUS_CONTINUE;
                {Status, _} ->
                    buoy_heap:private_put(This, ?STATE, {reader, [], true}),
                    buoy_heap:call(Callback, This, [Status, undefined]),
                    Status
            end
    end.

%% The next bytes and the parts after them, {EOS, []}, or {Status, []} for a
%% failed read. A file part gives at most ?FILE_CHUNK bytes at a time.
next([]) -> {?STATUS_EOS, []};
next([Bytes | Rest]) when is_binary(Bytes) -> {ok, Bytes, Rest};
next([{file, Path, Info, Offset, Length} | Rest]) ->
    Chunk = min(Length, ?FILE_CHUNK),
    case read(Path, Info, Offset, Chunk) of
        {ok, _} when Length =:= 0 -> next(Rest);
        {ok, Bytes} when Chunk =:= Length -> {ok, Bytes, Rest};
        {ok, Bytes} -> {ok, Bytes, [{file, Path, Info, Offset + Chunk, Length - Chunk} | Rest]};
        {error, Status} -> {Status, []}
    end.

read(Path, #file_info{size = Size, mtime = Mtime}, Offset, Length) ->
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, #file_info{size = Size, mtime = Mtime}} ->
            case file:open(Path, [read, raw, binary]) of
                {ok, Fd} ->
                    Read = file:pread(Fd, Offset, Length),
                    _ = file:close(Fd),
                    case Read of
                        {ok, Bytes} when byte_size(Bytes) =:= Length -> {ok, Bytes};
                        eof when Length =:= 0 -> {ok, <<>>};
                        _ -> {error, -5}
                    end;
                {error, Reason} ->
                    {error, errno(Reason)}
            end;
        _ ->
            %% UV_EINVAL, as Node's FdEntry gives for a modified file.
            {error, -22}
    end.

%% The libuv code of a POSIX error, or UV_EIO.
errno(Reason) ->
    Name = string:uppercase(atom_to_binary(Reason)),
    case lists:keyfind(Name, 2, buoy_binding_uv:errors()) of
        {Code, _, _} -> Code;
        false -> -5
    end.

%%% Object URLs

store(Id, Handle, Length, Type) ->
    _ = state(Handle),
    erlang:put(?OBJECTS, maps:put(key(Id), {Handle, Length, Type}, objects())),
    undefined.

lookup(Id) ->
    case maps:find(key(Id), objects()) of
        {ok, {Handle, Length, Type}} -> buoy_heap:new_array([Handle, Length, Type]);
        error -> undefined
    end.

%% revokeObjectURL(url): forgets the id after the scheme and the first ':'
%% of the path, as in blob:nodedata:<id>.
revoke(Url) ->
    Text = unicode:characters_to_list(buoy_ref_string:to_utf8(buoy_ref:to_string(Url))),
    case buoy_node_url:parse(Text, null) of
        {ok, #{path := Path}} ->
            Pathname = case Path of
                {opaque, Opaque} -> Opaque;
                Segments -> lists:append(["/" ++ S || S <- Segments])
            end,
            case string:split(Pathname, ":") of
                [_, Id] when Id =/= "" ->
                    case lists:member($:, Id) of
                        true -> ok;
                        false -> erlang:put(?OBJECTS, maps:remove(unicode:characters_to_binary(Id), objects()))
                    end;
                _ ->
                    ok
            end;
        failure ->
            ok
    end,
    undefined.

objects() ->
    case erlang:get(?OBJECTS) of
        undefined -> #{};
        Objects -> Objects
    end.

key(Id) -> buoy_ref_string:to_utf8(buoy_ref:to_string(Id)).

%%% concat

%% concat(parts): an ArrayBuffer of the bytes of the ArrayBuffers and views.
concat(Parts) ->
    Bytes = iolist_to_binary([buoy_node_encoding:view_bytes(P) || P <- buoy_heap:array_items(Parts)]),
    Buffer = buoy_ref_buffer:allocate(byte_size(Bytes)),
    buoy_ref_buffer:write(Buffer, 0, Bytes),
    Buffer.

to_index(V) ->
    case buoy_ref:to_number(V) of
        N when is_integer(N), N >= 0 -> N;
        N when is_float(N), N >= 0 -> trunc(N);
        _ -> 0
    end.
