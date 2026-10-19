-module(buoy_build_tests).
-include_lib("eunit/include/eunit.hrl").

%% The modules of one build: the entry requires `buoy_build_t_required`, and nothing
%% loads `buoy_build_t_unused`. `buoy_build_t_broken` holds a fun that captures more
%% variables than a BEAM function takes as arguments, so its Erlang does not compile.
-define(ENTRY, buoy_build_t_entry).
-define(REQUIRED, buoy_build_t_required).
-define(UNUSED, buoy_build_t_unused).
-define(BROKEN, buoy_build_t_broken).

build_test_() ->
    {setup, fun start/0, fun stop/1, fun(Build) ->
        [{"the entry compiles at the start", ?_assert(erlang:module_loaded(?ENTRY))},
         {"a module that nothing loads never compiles",
          ?_assertNot(filelib:is_regular(beam(Build, ?UNUSED)))},
         {"a module that a ready module requires compiles ahead",
          ?_assertEqual(ok, wait_for(fun() -> erlang:module_loaded(?REQUIRED) end))},
         {"a dependency whose Erlang does not compile throws its errors when it loads",
          fun() ->
              ok = buoy_build:ensure(?BROKEN),
              #{error := {<<"Error">>, <<"ERR_BUOY_COMPILE">>, Message}, loaded := false} = ?BROKEN:'$module'(),
              ?assertMatch({_, _}, binary:match(Message, <<"too many arguments">>)),
              ?assertEqual(none, ?BROKEN:'$resolve'(<<"x">>, require))
          end}]
    end}.

start() ->
    Build = filename:join(os:getenv("TMPDIR", "/tmp"), "buoy_build_tests_" ++ os:getpid()),
    ok = filelib:ensure_path(filename:join(Build, "src")),
    write(Build, ?ENTRY, ["'$module'() -> #{kind => cjs, requests => [], requires => [", atom_to_list(?REQUIRED), "]}.\n"]),
    write(Build, ?REQUIRED, ["'$module'() -> #{kind => cjs, requests => [], requires => []}.\n"]),
    write(Build, ?UNUSED, ["'$module'() -> #{kind => cjs, requests => [], requires => []}.\n"]),
    Vars = ["V" ++ integer_to_list(I) || I <- lists:seq(1, 300)],
    write(Build, ?BROKEN, [
        "'$module'() -> #{kind => cjs, path => <<\"broken.js\">>, requests => [], requires => [],\n"
        "    async => false, error => none, loaded => true}.\n"
        "'$resolve'(_, _) -> none.\n"
        "'$cjs'() ->\n",
        [[V, " = erlang:unique_integer(),\n"] || V <- Vars],
        "    fun() -> [", lists:join(", ", Vars), "] end.\n"]),
    ok = buoy_build:start(Build, ?ENTRY, [?ENTRY, ?REQUIRED, ?UNUSED, ?BROKEN]),
    Build.

stop(Build) ->
    Server = whereis(buoy_build),
    true = unregister(buoy_build),
    exit(Server, kill),
    _ = code:del_path(filename:join(Build, "ebin")),
    [begin code:purge(M), code:delete(M), code:purge(M) end || M <- [?ENTRY, ?REQUIRED, ?UNUSED, ?BROKEN]],
    ok = file:del_dir_r(Build).

write(Build, Module, Body) ->
    Name = atom_to_list(Module),
    Source = ["-module(", Name, ").\n-compile([export_all, nowarn_export_all]).\n", Body],
    ok = file:write_file(filename:join([Build, "src", Name ++ ".erl"]), Source).

beam(Build, Module) ->
    filename:join([Build, "ebin", atom_to_list(Module) ++ ".beam"]).

wait_for(Condition) ->
    case Condition() of
        true -> ok;
        false -> receive after 10 -> wait_for(Condition) end
    end.
