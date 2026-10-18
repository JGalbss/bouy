%% internalBinding('fs_dir') (src/node_dir.cc): opendir and DirHandle, the
%% handle of fs.Dir. prim_file lists a directory in one call, so opendir
%% reads the names, and each read hands out the next bufferSize of them in
%% the order of the directory, as uv_fs_readdir does.
-module(buoy_binding_fs_dir).

-export([binding/0]).

-define(STATE, {?MODULE, state}).

-spec binding() -> term().
binding() ->
    Class = buoy_node:constructor(<<"DirHandle">>, 0, fun(_, _) -> undefined end),
    Proto = buoy_heap:get(Class, <<"prototype">>),
    erlang:put({?MODULE, proto}, Proto),
    A = fun buoy_node:arg/2,
    Methods = [{<<"read">>, fun(This, Args) -> read(This, A(1, Args), A(2, Args), A(3, Args)) end},
               {<<"close">>, fun(This, Args) -> close(This, A(1, Args)) end}],
    [buoy_heap:define(Proto, Name, #{value => buoy_node:fn(Name, 0, Fun), writable => true, enumerable => false,
                                     configurable => true}) || {Name, Fun} <- Methods],
    buoy_node:object([
        {<<"opendir">>, buoy_node:fn(<<"opendir">>, 0, fun(_, Args) ->
            Path = buoy_binding_fs:path(A(1, Args)),
            buoy_binding_fs:request(A(3, Args), fun() -> open(Path, Path) end)
        end)},
        {<<"opendirSync">>, buoy_node:fn(<<"opendirSync">>, 0, fun(_, Args) ->
            open(buoy_binding_fs:path(A(1, Args)), undefined)
        end)},
        {<<"DirHandle">>, Class}]).

%% A DirHandle with the names of Path. opendirSync throws without the path,
%% as OpenDirSync does.
open(Path, ErrorPath) ->
    case prim_file:list_dir_all(Path) of
        {ok, Names} ->
            Handle = buoy_node:object(erlang:get({?MODULE, proto}), []),
            buoy_heap:private_put(Handle, ?STATE, {Path, [name(N) || N <- Names]}),
            Handle;
        {error, Reason} ->
            buoy_binding_fs:uv_error(Reason, <<"opendir">>, ErrorPath)
    end.

%% read(encoding, bufferSize, req): [name, type, ...] of the next entries,
%% or null at the end.
read(This, Encoding, Size, Req) ->
    buoy_binding_fs:request(Req, fun() ->
        {ok, {Path, Names}} = buoy_heap:private_find(This, ?STATE),
        case lists:split(min(max(1, buoy_binding_fs:int(Size)), length(Names)), Names) of
            {[], _} ->
                null;
            {Batch, Rest} ->
                buoy_heap:private_put(This, ?STATE, {Path, Rest}),
                buoy_heap:new_array(lists:append([[buoy_binding_fs:encoded(N, Encoding),
                                                   buoy_binding_fs:dirent_type(filename:join(Path, N))]
                                                  || N <- Batch]))
        end
    end).

close(This, Req) ->
    buoy_binding_fs:request(Req, fun() ->
        {ok, {Path, _}} = buoy_heap:private_find(This, ?STATE),
        buoy_heap:private_put(This, ?STATE, {Path, []}),
        undefined
    end).

name(Name) when is_binary(Name) -> Name;
name(Name) -> unicode:characters_to_binary(Name).
