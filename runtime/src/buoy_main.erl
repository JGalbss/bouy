-module(buoy_main).

%% Boots a compiled program (section 1 of docs/design/beam-runtime.md).
%%
%% The CLI starts one VM with
%%   erl +Bd -noshell -noinput -mode minimal -boot no_dot_erlang -pa <runtime ebin>
%%       -eval 'buoy_main:start()' -extra <build dir> <entry module> <entry path> <module,...> [args...]
%% start/0 compiles each changed module of <build dir>/src into <build dir>/ebin,
%% starts the buoy application, runs the top-level code of the entry module, and halts.
%% When BUOY_RESULT_FILE names a path, the VM writes the facts of the run there before
%% it halts (section 1 of the contract).

-export([start/0, import/1, finish/2]).

-include_lib("kernel/include/file.hrl").

-spec start() -> no_return().
start() ->
    %% A failure before the program runs, such as an unwritable build directory,
    %% would otherwise end the boot and write erl_crash.dump to the working directory.
    try boot()
    catch
        Class:Reason ->
            stop(1, io_lib:format("buoy: cannot start the program: ~tp~n", [{Class, Reason}]))
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
    ok = buoy_guard:start(),
    persistent_term:put({buoy, stdout}, group_leader()),
    case init:get_plain_arguments() of
        [Build, Entry, EntryPath, Modules | Args] ->
            persistent_term:put({buoy, argv}, [<<"buoy">> | [unicode:characters_to_binary(Arg) || Arg <- [EntryPath | Args]]]),
            case compile_modules(Build, split(Modules)) of
                ok -> run(list_to_atom(Entry));
                {error, Report} -> stop(2, Report)
            end;
        _ ->
            stop(2, "buoy: usage: -extra <build dir> <entry module> <entry path> <modules> [args...]\n")
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
    %% Many workers reply to the top-level code at once, as in Promise.all over actor
    %% calls. Off the heap, their messages need no lock of this process.
    _ = process_flag(message_queue_data, off_heap),
    try import(Entry) of
        ok -> finish(0, #{})
    catch
        Class:Reason:Stack ->
            {Report, Facts} = uncaught(Class, Reason, Stack),
            io:put_chars(standard_error, Report),
            finish(1, Facts)
    end.

%% Section 8: buoy_app:start/2 directly. The application controller would also load
%% buoy.app and the apps it names, and start application masters, which the program does
%% not need. The root supervisor is unlinked so that its exit cannot kill this process.
start_runtime() ->
    case buoy_app:start(normal, []) of
        {ok, Pid} ->
            true = unlink(Pid),
            ok;
        {error, Reason} ->
            stop(1, io_lib:format("buoy: cannot start the runtime: ~p~n", [Reason]))
    end.

%% The uncaught-error line, and the facts of the result file: `uncaught` for a
%% JavaScript value, and `erlang` for an Erlang reason that is not one.
uncaught(error, Reason, Stack) ->
    try buoy_rt:caught(Reason, Stack) of
        Value -> {describe(Value), #{uncaught => value_facts(Value)}}
    catch
        _:_ -> {io_lib:format("Uncaught ~p~n", [Reason]), #{erlang => format(Reason)}}
    end;
uncaught(throw, {'$fail', Value}, _Stack) ->
    {describe(Value), #{uncaught => value_facts(Value)}};
uncaught(Class, Reason, _Stack) ->
    {io_lib:format("Uncaught ~p: ~p~n", [Class, Reason]), #{erlang => format({Class, Reason})}}.

%% The fields of a thrown value that tell one error from another. An error that the
%% runtime made from an Erlang reason keeps that reason in `erlang`.
value_facts(Value) when is_map(Value) ->
    maps:filter(
        fun(Key, Field) -> lists:member(Key, [<<"name">>, <<"message">>, <<"code">>, <<"erlang">>]) andalso is_binary(Field) end,
        Value
    );
value_facts(Value) ->
    try #{<<"message">> => buoy_rt:to_string(Value)}
    catch
        _:_ -> #{}
    end.

format(Term) ->
    unicode:characters_to_binary(io_lib:format("~0tp", [Term])).

%% Halts the VM with Status. When BUOY_RESULT_FILE names a path, it first writes Facts
%% and the status there as one JSON object.
-spec finish(non_neg_integer(), map()) -> no_return().
finish(Status, Facts) ->
    buoy_binding_tty_wrap:reset_mode(),
    %% An actor prints its crash line without waiting (buoy_actor), so the VM waits
    %% for the standard_error server to write the lines that reached it first.
    try io:put_chars(standard_error, <<>>)
    catch
        _:_ -> ok
    end,
    case os:getenv("BUOY_RESULT_FILE", "") of
        "" -> ok;
        Path -> _ = file:write_file(Path, json:encode(Facts#{status => Status}))
    end,
    erlang:halt(Status).

describe(#{'$error' := _, <<"name">> := Name, <<"message">> := Message}) when is_binary(Name), is_binary(Message) ->
    io_lib:format("Uncaught ~ts: ~ts~n", [Name, Message]);
describe(Value) ->
    try buoy_rt:to_string(Value) of
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
        {error, Reason} -> stop(1, io_lib:format("buoy: cannot write ~ts: ~ts~n", [Ebin, file:format_error(Reason)]))
    end,
    true = code:add_patha(Ebin),
    case compile_parallel(Build, Ebin, Modules) of
        [] -> ok;
        Errors -> {error, Errors}
    end.

%% A program that loads packages from node_modules has hundreds of modules, so up to
%% eight processes compile them, each a share of the list.
compile_parallel(Build, Ebin, Modules) ->
    Jobs = max(1, min(8, erlang:system_info(schedulers_online))),
    Shares = [[M || {I, M} <- lists:enumerate(0, Modules), I rem Jobs =:= J] || J <- lists:seq(0, Jobs - 1)],
    Workers = [spawn_monitor(fun() -> exit({compiled, lists:flatmap(fun(M) -> compile_module(Build, Ebin, M) end, Share)}) end)
               || Share <- Shares, Share =/= []],
    lists:flatmap(fun({Pid, Ref}) ->
                          receive
                              {'DOWN', Ref, process, Pid, {compiled, Errors}} -> Errors;
                              {'DOWN', Ref, process, Pid, Reason} ->
                                  [io_lib:format("buoy: compiling the program failed: ~tp~n", [Reason])]
                          end
                  end, Workers).

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
            [io_lib:format("buoy: the Erlang compiler crashed on ~ts (a compiler bug)~n", [Source])]
    end.

%% Writes File through a temporary file and a rename, so a concurrent reader never sees
%% a partial file.
replace(File, Contents) ->
    Temporary = File ++ "." ++ os:getpid(),
    ok = file:write_file(Temporary, Contents),
    file:rename(Temporary, File).

format_error(File, {Location, Module, Descriptor}) ->
    io_lib:format("buoy: generated Erlang does not compile (a compiler bug): ~ts:~w: ~ts~n",
                  [File, line(Location), Module:format_error(Descriptor)]).

line({Line, _Column}) -> Line;
line(Line) -> Line.

%% A failure of the VM before or around the program: the facts record the report as
%% the Erlang reason.
-spec stop(non_neg_integer(), unicode:chardata()) -> no_return().
stop(Status, Report) ->
    io:put_chars(standard_error, Report),
    finish(Status, #{erlang => unicode:characters_to_binary(Report)}).
