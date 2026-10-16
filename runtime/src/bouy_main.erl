-module(bouy_main).

%% Boots a compiled program (section 1 of docs/design/beam-runtime.md).
%%
%% The CLI starts one VM with
%%   erl +Bd -noshell -noinput -mode minimal -boot no_dot_erlang -pa <runtime ebin>
%%       -eval 'bouy_main:start()' -extra <build dir> <entry module> <entry path> <module,...> [args...]
%% start/0 compiles each changed module of <build dir>/src into <build dir>/ebin,
%% starts the bouy application, runs the top-level code of the entry module, and halts.

-export([start/0, import/1]).

-include_lib("kernel/include/file.hrl").

-spec start() -> no_return().
start() ->
    %% A failure before the program runs, such as an unwritable build directory,
    %% would otherwise end the boot and write erl_crash.dump to the working directory.
    try boot()
    catch
        Class:Reason ->
            stop(1, io_lib:format("bouy: cannot start the program: ~tp~n", [{Class, Reason}]))
    end.

-spec boot() -> no_return().
boot() ->
    %% SIGTERM ends the VM as it ends Node, with status 128 + 15 and no shutdown
    %% report, and the OTP reports that remain go to stderr, never into the output.
    ok = os:set_signal(sigterm, default),
    _ = logger:remove_handler(default),
    _ = logger:add_handler(default, logger_std_h, #{config => #{type => standard_error}}),
    %% Node writes UTF-8 under any locale. A device in latin1 mode would escape or
    %% mangle the characters outside latin1.
    ok = io:setopts(standard_io, [{encoding, unicode}]),
    ok = io:setopts(standard_error, [{encoding, unicode}]),
    persistent_term:put({bouy, stdout}, group_leader()),
    case init:get_plain_arguments() of
        [Build, Entry, EntryPath, Modules | Args] ->
            persistent_term:put({bouy, argv}, [<<"bouy">> | [unicode:characters_to_binary(Arg) || Arg <- [EntryPath | Args]]]),
            case compile_modules(Build, split(Modules)) of
                ok -> run(list_to_atom(Entry));
                {error, Report} -> stop(2, Report)
            end;
        _ ->
            stop(2, "bouy: usage: -extra <build dir> <entry module> <entry path> <modules> [args...]\n")
    end.

%% Runs the top-level code of Module once, and records that it ran.
-spec import(module()) -> ok.
import(Module) ->
    Key = {?MODULE, imported, Module},
    case persistent_term:get(Key, false) of
        true ->
            ok;
        false ->
            persistent_term:put(Key, true),
            _ = Module:'__init__'(),
            ok
    end.

%% The -eval process traps exits, so every worker that the top-level code
%% links would leave an EXIT message behind, and each receive would scan
%% them. Workers end normally, so the program does not trap exits.
-spec run(module()) -> no_return().
run(Entry) ->
    ok = start_runtime(),
    _ = process_flag(trap_exit, false),
    try import(Entry) of
        ok -> erlang:halt(0)
    catch
        Class:Reason:Stack -> stop(1, uncaught(Class, Reason, Stack))
    end.

%% Section 8: bouy_app:start/2 directly. The application controller would also load
%% bouy.app and the apps it names, and start application masters, which the program does
%% not need. The root supervisor is unlinked so that its exit cannot kill this process.
start_runtime() ->
    case bouy_app:start(normal, []) of
        {ok, Pid} ->
            true = unlink(Pid),
            ok;
        {error, Reason} ->
            stop(1, io_lib:format("bouy: cannot start the runtime: ~p~n", [Reason]))
    end.

uncaught(error, Reason, Stack) ->
    try bouy_rt:caught(Reason, Stack) of
        Value -> describe(Value)
    catch
        _:_ -> io_lib:format("Uncaught ~p~n", [Reason])
    end;
uncaught(throw, {'$fail', Value}, _Stack) ->
    describe(Value);
uncaught(Class, Reason, _Stack) ->
    io_lib:format("Uncaught ~p: ~p~n", [Class, Reason]).

describe(#{'$error' := _, <<"name">> := Name, <<"message">> := Message}) when is_binary(Name), is_binary(Message) ->
    io_lib:format("Uncaught ~ts: ~ts~n", [Name, Message]);
describe(Value) ->
    try bouy_rt:to_string(Value) of
        Text -> io_lib:format("Uncaught ~ts~n", [Text])
    catch
        _:_ -> io_lib:format("Uncaught ~p~n", [Value])
    end.

%% The module names of the `,`-separated list. The string module would load
%% unicode_util, a large module, on each start.
split(Modules) ->
    Names = lists:foldr(
        fun
            ($,, Later) -> [[] | Later];
            (Char, [Name | Later]) -> [[Char | Name] | Later]
        end,
        [[]],
        Modules
    ),
    [Name || Name <- Names, Name =/= []].

%% The CLI has written <build dir>/src, so only ebin may be missing. The file
%% module is loaded at boot, and filelib is not.
compile_modules(Build, Modules) ->
    Ebin = filename:join(Build, "ebin"),
    case file:make_dir(Ebin) of
        ok -> ok;
        {error, eexist} -> ok;
        {error, Reason} -> stop(1, io_lib:format("bouy: cannot write ~ts: ~ts~n", [Ebin, file:format_error(Reason)]))
    end,
    true = code:add_patha(Ebin),
    case lists:flatmap(fun(Module) -> compile_module(Build, Ebin, Module) end, Modules) of
        [] -> ok;
        Errors -> {error, Errors}
    end.

%% Compiles one module when its source changed since the last build, and loads it.
compile_module(Build, Ebin, Module) ->
    Source = filename:join([Build, "src", Module ++ ".erl"]),
    Beam = filename:join(Ebin, Module ++ ".beam"),
    Stamp = filename:join(Ebin, Module ++ ".md5"),
    {ok, Text} = file:read_file(Source),
    Hash = erlang:md5([Text, erlang:system_info(otp_release)]),
    case file:read_file(Stamp) of
        {ok, Hash} ->
            case file:read_file_info(Beam) of
                {ok, #file_info{type = regular}} -> [];
                _ -> compile_source(Source, Beam, Stamp, Hash)
            end;
        _ ->
            compile_source(Source, Beam, Stamp, Hash)
    end.

compile_source(Source, Beam, Stamp, Hash) ->
    case compile:file(Source, [binary, return_errors, nowarn_unused_vars]) of
        {ok, Module, Binary} ->
            ok = replace(Beam, Binary),
            ok = replace(Stamp, Hash),
            {module, Module} = code:load_binary(Module, Beam, Binary),
            [];
        {error, Errors, _Warnings} ->
            [format_error(File, Error) || {File, FileErrors} <- Errors, Error <- FileErrors];
        error ->
            [io_lib:format("bouy: the Erlang compiler crashed on ~ts (a compiler bug)~n", [Source])]
    end.

%% Writes File through a temporary file and a rename, so a concurrent reader never sees
%% a partial file.
replace(File, Contents) ->
    Temporary = File ++ "." ++ os:getpid(),
    ok = file:write_file(Temporary, Contents),
    file:rename(Temporary, File).

format_error(File, {Location, Module, Descriptor}) ->
    io_lib:format("bouy: generated Erlang does not compile (a compiler bug): ~ts:~w: ~ts~n",
                  [File, line(Location), Module:format_error(Descriptor)]).

line({Line, _Column}) -> Line;
line(Line) -> Line.

-spec stop(non_neg_integer(), unicode:chardata()) -> no_return().
stop(Status, Report) ->
    io:put_chars(standard_error, Report),
    erlang:halt(Status).
