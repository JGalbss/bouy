%% The process object of Node, as its C++ side makes it before the bootstrap
%% runs (src/node_process_object.cc: CreateProcessObject and
%% PatchProcessObject), and process.env (src/node_env_var.cc). The bootstrap
%% (internal/bootstrap/node) then makes it an EventEmitter and adds the
%% methods of the process_methods binding.
-module(bouy_node_process).

-include("bouy_ref.hrl").

-export([create/0, patch/1, exit_info/0, exec_path/0, version/0, arch/0, platform/0]).

-define(VERSION, <<"v25.9.0">>).
%% The fields of Environment::ExitInfoField: kExiting, kExitCode, kHasExitCode.
-define(EXIT_INFO, '$bouy_node_exit_info').

-spec version() -> binary().
version() -> ?VERSION.

%% The object that internal/bootstrap/realm receives as process.
-spec create() -> term().
create() ->
    Constructor = bouy_node:constructor(<<"process">>, 0, fun(_, _) -> undefined end),
    Proto = bouy_heap:get(Constructor, <<"prototype">>),
    Process = bouy_node:object(Proto, []),
    ExitInfo = bouy_node:typed_array(<<"Int32Array">>, 3),
    erlang:put(?EXIT_INFO, ExitInfo),
    bouy_heap:define(Process, bouy_node:private_symbol(<<"exit_info_private_symbol">>),
                     #{value => ExitInfo, writable => true, enumerable => false, configurable => true}),
    readonly(Process, <<"version">>, ?VERSION),
    readonly(Process, <<"versions">>, versions()),
    readonly(Process, <<"arch">>, arch()),
    readonly(Process, <<"platform">>, platform()),
    Release = bouy_node:object([]),
    readonly(Release, <<"name">>, <<"node">>),
    readonly(Release, <<"sourceUrl">>, <<"https://nodejs.org/download/release/v25.9.0/node-v25.9.0.tar.gz">>),
    readonly(Release, <<"headersUrl">>, <<"https://nodejs.org/download/release/v25.9.0/node-v25.9.0-headers.tar.gz">>),
    readonly(Process, <<"release">>, Release),
    bouy_heap:set(Process, <<"_rawDebug">>, bouy_node:fn(<<"_rawDebug">>, 0, fun raw_debug/2)),
    %% src/node_realm.cc sets env before the bootstrap runs.
    bouy_heap:set(Process, <<"env">>, env()),
    Process.

%% The Int32Array of Environment::ExitInfoField.
-spec exit_info() -> term().
exit_info() -> erlang:get(?EXIT_INFO).

%% patchProcessObject of the process_methods binding.
-spec patch(term()) -> undefined.
patch(Process) ->
    Title = bouy_node:fn(<<"get title">>, 0, fun(_, _) -> <<"node">> end),
    bouy_heap:define(Process, <<"title">>, #{get => Title, set => bouy_node:fn(<<"set title">>, 1, fun(_, _) -> undefined end),
                                             enumerable => true, configurable => true}),
    [_ | Argv] = persistent_term:get({bouy, argv}, [<<"bouy">>]),
    bouy_heap:set(Process, <<"argv">>, bouy_heap:new_array([exec_path() | [bouy_ref_string:from_utf8(A) || A <- Argv]])),
    bouy_heap:set(Process, <<"execArgv">>, bouy_heap:new_array([])),
    readonly(Process, <<"pid">>, list_to_integer(os:getpid())),
    Ppid = bouy_node:fn(<<"get ppid">>, 0, fun(_, _) -> parent_pid() end),
    bouy_heap:define(Process, <<"ppid">>, #{get => Ppid, enumerable => true, configurable => true}),
    bouy_heap:set(Process, <<"execPath">>, exec_path()),
    Port = bouy_node:fn(<<"get debugPort">>, 0, fun(_, _) -> 9229 end),
    bouy_heap:define(Process, <<"debugPort">>, #{get => Port, set => bouy_node:fn(<<"set debugPort">>, 1, fun(_, _) -> undefined end),
                                                 enumerable => true, configurable => true}),
    undefined.

%% The path of the bouy binary, which Node's tests start as process.execPath.
-spec exec_path() -> term().
exec_path() ->
    case os:getenv("BOUY_COMPILER") of
        false -> <<"bouy">>;
        Path -> bouy_ref_string:from_utf8(unicode:characters_to_binary(Path))
    end.

parent_pid() ->
    try list_to_integer(string:trim(os:cmd("ps -o ppid= -p " ++ os:getpid())))
    catch _:_ -> 0
    end.

readonly(O, Key, Value) ->
    bouy_heap:define(O, Key, #{value => Value, writable => false, enumerable => true, configurable => false}).

-spec arch() -> binary().
arch() ->
    case erlang:system_info(system_architecture) of
        "aarch64" ++ _ -> <<"arm64">>;
        "arm" ++ _ -> <<"arm">>;
        "x86_64" ++ _ -> <<"x64">>;
        "amd64" ++ _ -> <<"x64">>;
        "i" ++ [_, $8, $6 | _] -> <<"ia32">>;
        _ -> <<"x64">>
    end.

-spec platform() -> binary().
platform() ->
    case os:type() of
        {unix, darwin} -> <<"darwin">>;
        {unix, linux} -> <<"linux">>;
        {unix, freebsd} -> <<"freebsd">>;
        {unix, openbsd} -> <<"openbsd">>;
        {unix, sunos} -> <<"sunos">>;
        {unix, aix} -> <<"aix">>;
        {win32, _} -> <<"win32">>;
        {unix, Other} -> atom_to_binary(Other)
    end.

%% process.versions of Node 25.9.0, without the libraries that Bouy does not
%% have: openssl, so that Node's tests skip the crypto cases, and sqlite.
versions() ->
    bouy_node:object([{K, V} || {K, V} <- [
        {<<"node">>, <<"25.9.0">>}, {<<"acorn">>, <<"8.16.0">>}, {<<"ada">>, <<"3.4.4">>},
        {<<"ares">>, <<"1.34.6">>}, {<<"brotli">>, <<"1.2.0">>}, {<<"cldr">>, <<"48.0">>},
        {<<"icu">>, <<"78.3">>}, {<<"llhttp">>, <<"9.3.1">>}, {<<"modules">>, <<"141">>},
        {<<"napi">>, <<"10">>}, {<<"nghttp2">>, <<"1.68.1">>}, {<<"simdjson">>, <<"4.6.1">>},
        {<<"simdutf">>, <<"7.3.3">>}, {<<"tz">>, <<"2026a">>}, {<<"undici">>, <<"7.24.4">>},
        {<<"unicode">>, <<"17.0">>}, {<<"uv">>, <<"1.52.1">>}, {<<"uvwasi">>, <<"0.0.23">>},
        {<<"v8">>, <<"14.1.146.11-node.25">>}, {<<"zlib">>, <<"1.2.12">>}, {<<"zstd">>, <<"1.5.7">>},
        {<<"bouy">>, <<"0.1.0">>}]]).

raw_debug(_This, Args) ->
    Text = lists:join(<<" ">>, [bouy_ref_string:to_utf8(bouy_ref:to_string(A)) || A <- Args]),
    io:put_chars(bouy_ref:stderr(), [Text, <<"\n">>]),
    undefined.

%%% process.env

%% A proxy over the environment of the OS process: a read gives the string or
%% undefined, a write stores the value as a string, and the keys are the
%% names of the variables, as the interceptors of node_env_var.cc do.
env() ->
    Handler = bouy_node:object([
        {<<"get">>, bouy_node:fn(<<"get">>, 3, fun(_, Args) -> env_get(bouy_ref_realm:arg(2, Args)) end)},
        {<<"set">>, bouy_node:fn(<<"set">>, 4, fun(_, Args) -> env_set(bouy_ref_realm:arg(2, Args), bouy_ref_realm:arg(3, Args)) end)},
        {<<"has">>, bouy_node:fn(<<"has">>, 2, fun(_, Args) -> env_get(bouy_ref_realm:arg(2, Args)) =/= undefined end)},
        {<<"deleteProperty">>, bouy_node:fn(<<"deleteProperty">>, 2, fun(_, Args) -> env_delete(bouy_ref_realm:arg(2, Args)) end)},
        {<<"ownKeys">>, bouy_node:fn(<<"ownKeys">>, 1, fun(_, _) -> bouy_heap:new_array(env_keys()) end)},
        {<<"getOwnPropertyDescriptor">>, bouy_node:fn(<<"getOwnPropertyDescriptor">>, 2, fun(_, Args) -> env_descriptor(bouy_ref_realm:arg(2, Args)) end)},
        {<<"defineProperty">>, bouy_node:fn(<<"defineProperty">>, 3, fun(_, Args) -> env_define(bouy_ref_realm:arg(2, Args), bouy_ref_realm:arg(3, Args)) end)}
    ]),
    bouy_heap:proxy(bouy_node:object([]), Handler).

env_name(Key) when ?IS_STRING(Key) -> {ok, unicode:characters_to_list(bouy_ref_string:to_utf8(Key))};
env_name(_) -> error.

env_get(Key) ->
    case env_name(Key) of
        {ok, Name} ->
            case os:getenv(Name) of
                false -> undefined;
                Value -> bouy_node:string(Value)
            end;
        error ->
            undefined
    end.

env_set(Key, Value) ->
    case env_name(Key) of
        {ok, Name} ->
            Text = bouy_ref_string:to_utf8(bouy_ref:to_string(Value)),
            true = os:putenv(Name, unicode:characters_to_list(Text)),
            true;
        error ->
            true
    end.

env_delete(Key) ->
    case env_name(Key) of
        {ok, Name} -> _ = os:unsetenv(Name), true;
        error -> true
    end.

env_define(Key, Desc) ->
    Get = bouy_heap:get(Desc, <<"get">>),
    Set = bouy_heap:get(Desc, <<"set">>),
    Accessor = Get =/= undefined orelse Set =/= undefined,
    Accessor andalso bouy_node:throw_code('TypeError', <<"ERR_INVALID_OBJECT_DEFINE_PROPERTY">>,
                                          <<"'process.env' does not accept an accessor(getter/setter) descriptor">>),
    Flags = [bouy_ref:truthy(bouy_heap:get(Desc, F)) || F <- [<<"configurable">>, <<"writable">>, <<"enumerable">>]],
    lists:all(fun(F) -> F end, Flags) orelse bouy_node:throw_code('TypeError', <<"ERR_INVALID_OBJECT_DEFINE_PROPERTY">>,
                                                                  <<"'process.env' only accepts a configurable, writable, and enumerable data descriptor">>),
    env_set(Key, bouy_heap:get(Desc, <<"value">>)).

env_keys() ->
    [bouy_node:string(Name) || Entry <- os:getenv(), [Name | _] <- [string:split(Entry, "=")], Name =/= ""].

env_descriptor(Key) ->
    case env_get(Key) of
        undefined -> undefined;
        Value -> bouy_node:object([{<<"value">>, Value}, {<<"writable">>, true}, {<<"enumerable">>, true}, {<<"configurable">>, true}])
    end.
