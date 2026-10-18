%% The native built-ins: the NIF library of crates/buoy-nif, which the CLI writes next to
%% the runtime's .beam files (contract, section 1). Each NIF runs in time slices and
%% returns a continuation when its slice ends, so its caller loops until it is done.
%%
%% The library is an accelerator. When it is missing, as in the EUnit tests of the
%% runtime, available/0 is false and every caller runs its Erlang implementation, which
%% has the same results.
-module(buoy_nif).

-export([available/0, json_parse/5]).

-nifs([json_parse/5]).

-on_load(load/0).

-spec load() -> ok.
load() ->
    Library = filename:join(filename:dirname(code:which(?MODULE)), "buoy_nif"),
    persistent_term:put(?MODULE, erlang:load_nif(Library, 0) =:= ok),
    ok.

%% Whether the library is loaded.
-spec available() -> boolean().
available() -> persistent_term:get(?MODULE, false).

%% JSON.parse without a reviver (crates/buoy-nif/src/json.rs).
-spec json_parse(binary(), boolean(), {term(), term()}, pos_integer(), start | reference()) ->
          {done, term(), [pos_integer()], [tuple()], pos_integer()}
        | {more, reference(), [pos_integer()], [tuple()], pos_integer()}
        | error.
json_parse(_Text, _Wide, _Protos, _Next, _State) -> erlang:nif_error(not_loaded).
