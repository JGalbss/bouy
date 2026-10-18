%% The native built-ins: the NIF library of crates/buoy-nif, which the CLI writes next to
%% the runtime's .beam files (contract, section 1). Each NIF runs in time slices and
%% returns a continuation when its slice ends, so its caller loops until it is done.
%%
%% The library is an accelerator. When it is missing, as in the EUnit tests of the
%% runtime, available/0 is false and every caller runs its Erlang implementation, which
%% has the same results.
-module(buoy_nif).

-export([available/0, json_parse/5, regexp_compile/3, regexp_search/6, regexp_search_all/5]).

-nifs([json_parse/5, regexp_compile/3, regexp_search/6, regexp_search_all/5]).

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

%% The program of a regular expression from the tree of buoy_regexp_match:lower/2, its
%% count of groups, and whether it reads code points (crates/buoy-nif/src/regexp.rs).
-spec regexp_compile(term(), non_neg_integer(), boolean()) -> {ok, reference()} | error.
regexp_compile(_Tree, _Groups, _Unicode) -> erlang:nif_error(not_loaded).

%% buoy_regexp_match:search/4 with a program of regexp_compile/3, on the code units of a
%% string, two bytes each when Wide. State is start or the state of a more result.
-spec regexp_search(reference(), binary(), boolean(), non_neg_integer(), boolean(), start | reference()) ->
          {match, non_neg_integer(), non_neg_integer(), tuple()} | nomatch | {more, reference()} | overflow.
regexp_search(_Program, _Text, _Wide, _From, _Sticky, _State) -> erlang:nif_error(not_loaded).

%% buoy_regexp_match:search_all/3 with a program of regexp_compile/3: each slice gives the
%% matches that it found.
-spec regexp_search_all(reference(), binary(), boolean(), boolean(), start | reference()) ->
          {done, [{match, non_neg_integer(), non_neg_integer(), tuple()}]}
        | {more, reference(), [{match, non_neg_integer(), non_neg_integer(), tuple()}]}
        | overflow.
regexp_search_all(_Program, _Text, _Wide, _Sticky, _State) -> erlang:nif_error(not_loaded).
