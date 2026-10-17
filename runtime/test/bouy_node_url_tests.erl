-module(bouy_node_url_tests).

-include_lib("eunit/include/eunit.hrl").

%% The URL parser against the WPT fixtures that Node vendors with its tests.
-define(WPT, "../tests/node/test/fixtures/wpt/url/resources/").

url_test_() ->
    [{"each case of urltestdata.json parses as WPT says", fun parses_urltestdata/0},
     {"each case of setters_tests.json sets as WPT says", fun sets_setters_tests/0},
     {"a long path parses in linear time", fun parses_long_path/0}].

parses_urltestdata() ->
    Cases = [T || T <- fixture("urltestdata.json"), is_map(T)],
    ?assertEqual([], [Case || Case <- Cases, not parses(Case)]).

sets_setters_tests() ->
    Cases = [{binary_to_atom(Field), T} || Field := Tests <- fixture("setters_tests.json"), Field =/= <<"comment">>,
                                           T <- Tests, is_map(T)],
    ?assertEqual([], [Case || Case <- Cases, not sets(Case)]).

parses_long_path() ->
    Path = lists:duplicate(200000, $a),
    {Micros, {ok, Url}} = timer:tc(fun() -> bouy_node_url:parse("file:///" ++ Path, null) end),
    ?assertEqual("file:///" ++ Path, bouy_node_url:href(Url)),
    ?assert(Micros < 2000000).

fixture(Name) ->
    {ok, Bin} = file:read_file(filename:join(root(), ?WPT ++ Name)),
    json:decode(Bin).

%% rebar3 runs the tests from runtime/ or from its _build copy.
root() ->
    case filelib:is_dir("../tests/node") of
        true -> ".";
        false -> filename:join(filename:dirname(code:which(?MODULE)), "../../../../..")
    end.

text(B) -> unicode:characters_to_list(B).

parses(#{<<"input">> := Input} = Case) ->
    Parsed = case maps:get(<<"base">>, Case, null) of
        null -> bouy_node_url:parse(text(Input), null);
        Base ->
            case bouy_node_url:parse(text(Base), null) of
                {ok, BaseUrl} -> bouy_node_url:parse(text(Input), BaseUrl);
                failure -> failure
            end
    end,
    case {maps:get(<<"failure">>, Case, false), Parsed} of
        {true, failure} -> true;
        {false, {ok, Url}} -> matches(Url, Case);
        _ -> false
    end.

sets({Field, #{<<"href">> := Href, <<"new_value">> := Value, <<"expected">> := Expected}}) ->
    {ok, Url} = bouy_node_url:parse(text(Href), null),
    {ok, New} = bouy_node_url:set(Field, Url, text(Value)),
    matches(New, Expected).

matches(Url, Expected) ->
    lists:all(fun({Key, Got}) -> not is_map_key(Key, Expected) orelse maps:get(Key, Expected) =:= unicode:characters_to_binary(Got) end,
              getters(Url)).

%% The getters of lib/internal/url.js over the href and the components.
getters(Url) ->
    {Href, [ProtocolEnd, UsernameEnd, HostStart0, HostEnd, Port, PathnameStart, SearchStart, HashStart, _]} =
        bouy_node_url:components(Url),
    Omitted = 16#FFFFFFFF,
    Slice = fun(From, To) -> lists:sublist(Href, From + 1, To - From) end,
    HostStart = case lists:nth(HostStart0 + 1, Href ++ " ") of $@ -> HostStart0 + 1; _ -> HostStart0 end,
    PathEnd = case {SearchStart, HashStart} of
        {Omitted, Omitted} -> length(Href);
        {Omitted, _} -> HashStart;
        _ -> SearchStart
    end,
    SearchEnd = case HashStart of Omitted -> length(Href); _ -> HashStart end,
    [{<<"href">>, Href},
     {<<"protocol">>, Slice(0, ProtocolEnd)},
     {<<"username">>, case ProtocolEnd + 2 < UsernameEnd of true -> Slice(ProtocolEnd + 2, UsernameEnd); false -> "" end},
     {<<"password">>, case HostStart0 > UsernameEnd of true -> Slice(UsernameEnd + 1, HostStart0); false -> "" end},
     {<<"hostname">>, Slice(HostStart, HostEnd)},
     {<<"host">>, case HostStart =:= HostEnd of true -> ""; false -> Slice(HostStart, PathnameStart) end},
     {<<"port">>, case Port of Omitted -> ""; _ -> integer_to_list(Port) end},
     {<<"pathname">>, Slice(PathnameStart, PathEnd)},
     {<<"search">>, case SearchStart =/= Omitted andalso SearchEnd - SearchStart > 1 of
                        true -> Slice(SearchStart, SearchEnd);
                        false -> ""
                    end},
     {<<"hash">>, case HashStart =/= Omitted andalso length(Href) - HashStart > 1 of
                      true -> Slice(HashStart, length(Href));
                      false -> ""
                  end},
     {<<"origin">>, bouy_node_url:origin(Url)}].
