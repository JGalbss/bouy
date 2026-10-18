%% The process object of Node, as its C++ side makes it before the bootstrap
%% runs (src/node_process_object.cc: CreateProcessObject and
%% PatchProcessObject), and process.env (src/node_env_var.cc). The bootstrap
%% (internal/bootstrap/node) then makes it an EventEmitter and adds the
%% methods of the process_methods binding.
-module(buoy_node_process).

-include("buoy_ref.hrl").

-define(TITLE, '$buoy_process_title').

-export([exec_argv/0, create/0, patch/1, exit_info/0, exec_path/0, version/0, arch/0, platform/0]).

-define(VERSION, <<"v25.9.0">>).
%% The fields of Environment::ExitInfoField: kExiting, kExitCode, kHasExitCode.
-define(EXIT_INFO, '$buoy_node_exit_info').

-spec version() -> binary().
version() -> ?VERSION.

%% The object that internal/bootstrap/realm receives as process.
-spec create() -> term().
create() ->
    Constructor = buoy_node:constructor(<<"process">>, 0, fun(_, _) -> undefined end),
    Proto = buoy_heap:get(Constructor, <<"prototype">>),
    Process = buoy_node:object(Proto, []),
    ExitInfo = buoy_node:typed_array(<<"Int32Array">>, 3),
    erlang:put(?EXIT_INFO, ExitInfo),
    buoy_heap:define(Process, buoy_node:private_symbol(<<"exit_info_private_symbol">>),
                     #{value => ExitInfo, writable => true, enumerable => false, configurable => true}),
    readonly(Process, <<"version">>, ?VERSION),
    readonly(Process, <<"versions">>, versions()),
    readonly(Process, <<"arch">>, arch()),
    readonly(Process, <<"platform">>, platform()),
    Release = buoy_node:object([]),
    readonly(Release, <<"name">>, <<"node">>),
    readonly(Release, <<"sourceUrl">>, <<"https://nodejs.org/download/release/v25.9.0/node-v25.9.0.tar.gz">>),
    readonly(Release, <<"headersUrl">>, <<"https://nodejs.org/download/release/v25.9.0/node-v25.9.0-headers.tar.gz">>),
    readonly(Process, <<"release">>, Release),
    buoy_heap:set(Process, <<"_rawDebug">>, buoy_node:fn(<<"_rawDebug">>, 0, fun raw_debug/2)),
    %% src/node_realm.cc sets env before the bootstrap runs.
    buoy_heap:set(Process, <<"env">>, env()),
    Process.

%% The Int32Array of Environment::ExitInfoField.
-spec exit_info() -> term().
exit_info() -> erlang:get(?EXIT_INFO).

%% patchProcessObject of the process_methods binding.
-spec patch(term()) -> undefined.
patch(Process) ->
    %% The title starts as --title gives it, or node; the VM cannot rename its OS process.
    erlang:put(?TITLE, title(exec_argv())),
    Title = buoy_node:fn(<<"get title">>, 0, fun(_, _) -> erlang:get(?TITLE) end),
    SetTitle = buoy_node:fn(<<"set title">>, 1, fun(_, A) -> erlang:put(?TITLE, buoy_ref:to_string(buoy_node:arg(1, A))), undefined end),
    buoy_heap:define(Process, <<"title">>, #{get => Title, set => SetTitle, enumerable => true, configurable => true}),
    [_ | Argv0] = persistent_term:get({buoy, argv}, [<<"buoy">>]),
    %% The code of -e and -p is no script of process.argv.
    Argv = case {init:get_argument(buoy_eval), Argv0} of
        {{ok, _}, [_ | Args]} -> Args;
        _ -> Argv0
    end,
    buoy_heap:set(Process, <<"argv">>, buoy_heap:new_array([exec_path() | [buoy_ref_string:from_utf8(A) || A <- Argv]])),
    buoy_heap:set(Process, <<"execArgv">>, buoy_heap:new_array([buoy_ref_string:from_utf8(A) || A <- exec_argv()])),
    readonly(Process, <<"pid">>, list_to_integer(os:getpid())),
    Ppid = buoy_node:fn(<<"get ppid">>, 0, fun(_, _) -> parent_pid() end),
    buoy_heap:define(Process, <<"ppid">>, #{get => Ppid, enumerable => true, configurable => true}),
    buoy_heap:set(Process, <<"execPath">>, exec_path()),
    Port = buoy_node:fn(<<"get debugPort">>, 0, fun(_, _) -> 9229 end),
    buoy_heap:define(Process, <<"debugPort">>, #{get => Port, set => buoy_node:fn(<<"set debugPort">>, 1, fun(_, _) -> undefined end),
                                                 enumerable => true, configurable => true}),
    undefined.

title([<<"--title=", Title/binary>> | _]) -> buoy_ref_string:from_utf8(Title);
title([<<"--title">>, Title | _]) -> buoy_ref_string:from_utf8(Title);
title([_ | Rest]) -> title(Rest);
title([]) -> <<"node">>.

%% The node options of the command line: the JSON array that the CLI passes
%% with -buoy_exec_argv.
-spec exec_argv() -> [binary()].
exec_argv() ->
    case init:get_argument(buoy_exec_argv) of
        {ok, [[Json | _] | _]} ->
            try json:decode(unicode:characters_to_binary(Json)) of
                List when is_list(List) -> [A || A <- List, is_binary(A)];
                _ -> []
            catch _:_ -> []
            end;
        _ ->
            []
    end.

%% The path of the buoy binary, which Node's tests start as process.execPath.
-spec exec_path() -> term().
exec_path() ->
    case os:getenv("BUOY_COMPILER") of
        false -> <<"buoy">>;
        Path -> buoy_ref_string:from_utf8(unicode:characters_to_binary(Path))
    end.

%% The parent of the VM. A child that a Buoy program spawned has the
%% erl_child_setup of the parent's VM as its OS parent; its parent is the
%% VM of that program, as a node child's parent is node.
parent_pid() ->
    try
        [Parent, _] = ps(os:getpid()),
        [Grandparent, Command] = ps(Parent),
        case lists:suffix("erl_child_setup", Command) of
            true -> list_to_integer(Grandparent);
            false -> list_to_integer(Parent)
        end
    catch _:_ -> 0
    end.

ps(Pid) ->
    [P, C | _] = string:lexemes(os:cmd("ps -o ppid=,comm= -p " ++ Pid), " \n") ++ ["", ""],
    [P, C].

readonly(O, Key, Value) ->
    buoy_heap:define(O, Key, #{value => Value, writable => false, enumerable => true, configurable => false}).

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

%% process.versions of Node 25.9.0, without the libraries that Buoy does not
%% have: openssl, so that Node's tests skip the crypto cases. sqlite is the
%% SQLite of buoy_native.
versions() ->
    buoy_node:object([{K, V} || {K, V} <- [
        {<<"node">>, <<"25.9.0">>}, {<<"acorn">>, <<"8.16.0">>}, {<<"ada">>, <<"3.4.4">>},
        {<<"ares">>, <<"1.34.6">>}, {<<"brotli">>, <<"1.2.0">>}, {<<"cldr">>, <<"48.0">>},
        {<<"icu">>, <<"78.3">>}, {<<"llhttp">>, <<"9.3.1">>}, {<<"modules">>, <<"141">>},
        {<<"napi">>, <<"10">>}, {<<"nghttp2">>, <<"1.68.1">>}, {<<"simdjson">>, <<"4.6.1">>},
        {<<"simdutf">>, <<"7.3.3">>}, {<<"sqlite">>, <<"3.53.2">>}, {<<"tz">>, <<"2026a">>}, {<<"undici">>, <<"7.24.4">>},
        {<<"unicode">>, <<"17.0">>}, {<<"uv">>, <<"1.52.1">>}, {<<"uvwasi">>, <<"0.0.23">>},
        {<<"v8">>, <<"14.1.146.11-node.25">>}, {<<"zlib">>, <<"1.2.12">>}, {<<"zstd">>, <<"1.5.7">>},
        {<<"buoy">>, <<"0.1.0">>}]]).

raw_debug(_This, Args) ->
    Text = lists:join(<<" ">>, [buoy_ref_string:to_utf8(buoy_ref:to_string(A)) || A <- Args]),
    io:put_chars(buoy_ref:stderr(), [Text, <<"\n">>]),
    undefined.

%%% process.env

%% A proxy over the environment of the OS process: a read gives the string or
%% undefined, a write stores the value as a string, and the keys are the
%% names of the variables, as the interceptors of node_env_var.cc do.
env() ->
    Handler = buoy_node:object([
        %% A name that no variable has reads the target, so Object.prototype shows through.
        {<<"get">>, buoy_node:fn(<<"get">>, 3, fun(_, [Target, Key | _]) ->
            case env_get(Key) of
                undefined -> buoy_heap:get(Target, Key);
                Value -> Value
            end
        end)},
        {<<"set">>, buoy_node:fn(<<"set">>, 4, fun(_, Args) -> env_set(buoy_ref_realm:arg(2, Args), buoy_ref_realm:arg(3, Args)) end)},
        {<<"has">>, buoy_node:fn(<<"has">>, 2, fun(_, [Target, Key | _]) ->
            env_get(Key) =/= undefined orelse buoy_heap:has(Target, Key)
        end)},
        {<<"deleteProperty">>, buoy_node:fn(<<"deleteProperty">>, 2, fun(_, Args) -> env_delete(buoy_ref_realm:arg(2, Args)) end)},
        {<<"ownKeys">>, buoy_node:fn(<<"ownKeys">>, 1, fun(_, _) -> buoy_heap:new_array(env_keys()) end)},
        {<<"getOwnPropertyDescriptor">>, buoy_node:fn(<<"getOwnPropertyDescriptor">>, 2, fun(_, Args) -> env_descriptor(buoy_ref_realm:arg(2, Args)) end)},
        {<<"defineProperty">>, buoy_node:fn(<<"defineProperty">>, 3, fun(_, Args) -> env_define(buoy_ref_realm:arg(2, Args), buoy_ref_realm:arg(3, Args)) end)}
    ]),
    buoy_heap:proxy(buoy_node:object([]), Handler).

env_name(Key) when ?IS_STRING(Key) -> {ok, unicode:characters_to_list(buoy_ref_string:to_utf8(Key))};
env_name(_) -> error.

env_get(Key) ->
    case env_name(Key) of
        {ok, Name} ->
            case os:getenv(Name) of
                false -> undefined;
                Value -> buoy_node:string(Value)
            end;
        error ->
            undefined
    end.

%% The key and the value convert with ToString, which throws a TypeError for
%% a symbol, as V8 does in EnvSetter. A name that the OS refuses, such as one
%% with `=`, sets nothing, as uv_os_setenv fails and Node ignores it.
env_set(Key, Value) ->
    warn_non_string(Value),
    Name = unicode:characters_to_list(buoy_ref_string:to_utf8(buoy_ref:to_string(Key))),
    Text = buoy_ref_string:to_utf8(buoy_ref:to_string(Value)),
    try os:putenv(Name, unicode:characters_to_list(Text)) catch error:badarg -> true end,
    true.

%% DEP0104, once, with --pending-deprecation: a value that is no string,
%% number, or boolean, as EnvSetter warns.
warn_non_string(Value) when ?IS_STRING(Value); ?IS_NUMBER(Value); is_boolean(Value) ->
    ok;
warn_non_string(_Value) ->
    case erlang:get('$buoy_env_warned') =:= undefined andalso lists:member(<<"--pending-deprecation">>, exec_argv()) of
        true ->
            erlang:put('$buoy_env_warned', true),
            Process = buoy_node:global_get(<<"process">>),
            buoy_heap:call(buoy_heap:get(Process, <<"emitWarning">>), Process,
                           [<<"Assigning any value other than a string, number, or boolean to a process.env property is deprecated. "
                              "Please make sure to convert the value to a string before setting process.env with it.">>,
                            <<"DeprecationWarning">>, <<"DEP0104">>]),
            ok;
        false ->
            ok
    end.

env_delete(Key) ->
    case env_name(Key) of
        {ok, Name} -> _ = os:unsetenv(Name), true;
        error -> true
    end.

env_define(Key, Desc) ->
    Get = buoy_heap:get(Desc, <<"get">>),
    Set = buoy_heap:get(Desc, <<"set">>),
    Accessor = Get =/= undefined orelse Set =/= undefined,
    Accessor andalso buoy_node:throw_code('TypeError', <<"ERR_INVALID_OBJECT_DEFINE_PROPERTY">>,
                                          <<"'process.env' does not accept an accessor(getter/setter) descriptor">>),
    Flags = [buoy_ref:truthy(buoy_heap:get(Desc, F)) || F <- [<<"configurable">>, <<"writable">>, <<"enumerable">>]],
    lists:all(fun(F) -> F end, Flags) orelse buoy_node:throw_code('TypeError', <<"ERR_INVALID_OBJECT_DEFINE_PROPERTY">>,
                                                                  <<"'process.env' only accepts a configurable, writable, and enumerable data descriptor">>),
    env_set(Key, buoy_heap:get(Desc, <<"value">>)).

env_keys() ->
    [buoy_node:string(Name) || Entry <- os:getenv(), [Name | _] <- [string:split(Entry, "=")], Name =/= ""].

env_descriptor(Key) ->
    case env_get(Key) of
        undefined -> undefined;
        Value -> buoy_node:object([{<<"value">>, Value}, {<<"writable">>, true}, {<<"enumerable">>, true}, {<<"configurable">>, true}])
    end.
