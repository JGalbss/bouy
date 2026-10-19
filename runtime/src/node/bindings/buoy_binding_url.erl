%% internalBinding('url') (src/node_url.cc): the WHATWG URL parser that
%% lib/internal/url calls. Each call that makes a URL writes its ada
%% url_components into urlComponents and returns the href.
-module(buoy_binding_url).

-export([binding/0]).

-dialyzer({no_return, [invalid_url/2]}).

-define(COMPONENTS, {?MODULE, components}).

-spec binding() -> term().
binding() ->
    Components = buoy_node:typed_array(<<"Uint32Array">>, 9),
    erlang:put(?COMPONENTS, Components),
    F = fun buoy_node:fn/3,
    A = fun buoy_node:arg/2,
    buoy_node:object([
        {<<"urlComponents">>, Components},
        {<<"parse">>, F(<<"parse">>, 0, fun(_, Args) -> parse(A(1, Args), A(2, Args), buoy_ref:truthy(A(3, Args))) end)},
        {<<"canParse">>, F(<<"canParse">>, 0, fun(_, Args) -> can_parse(A(1, Args), A(2, Args)) end)},
        {<<"pathToFileURL">>, F(<<"pathToFileURL">>, 0, fun(_, Args) ->
            path_to_file_url(A(1, Args), buoy_ref:truthy(A(2, Args)), A(3, Args))
        end)},
        {<<"update">>, F(<<"update">>, 0, fun(_, Args) -> update(A(1, Args), A(2, Args), A(3, Args)) end)},
        {<<"format">>, F(<<"format">>, 0, fun(_, Args) ->
            format(A(1, Args), [buoy_ref:truthy(A(I, Args)) || I <- [2, 3, 4, 5]])
        end)},
        {<<"getOrigin">>, F(<<"getOrigin">>, 0, fun(_, Args) ->
            case buoy_node_url:parse(text(A(1, Args)), null) of
                {ok, Url} -> js(buoy_node_url:origin(Url));
                failure -> invalid_url(text(A(1, Args)), undefined)
            end
        end)},
        {<<"domainToASCII">>, F(<<"domainToASCII">>, 0, fun(_, Args) -> domain(A(1, Args), ascii) end)},
        {<<"domainToUnicode">>, F(<<"domainToUnicode">>, 0, fun(_, Args) -> domain(A(1, Args), unicode) end)}
    ]).

%% A JavaScript string as code points, each lone surrogate as U+FFFD, as
%% Utf8Value converts it.
text(V) ->
    [case C of
         S when S >= 16#D800, S =< 16#DFFF -> 16#FFFD;
         _ -> C
     end || C <- buoy_ref_string:code_points(buoy_ref:to_string(V))].

js(Text) -> buoy_ref_string:from_utf8(unicode:characters_to_binary(Text)).

parse(Input, Base, Raise) ->
    Text = text(Input),
    case parse_with_base(Text, Base) of
        {ok, Url} -> publish(Url);
        failure when Raise -> invalid_url(Text, Base);
        failure -> undefined
    end.

parse_with_base(Text, undefined) ->
    buoy_node_url:parse(Text, null);
parse_with_base(Text, Base) ->
    case buoy_node_url:parse(text(Base), null) of
        {ok, BaseUrl} -> buoy_node_url:parse(Text, BaseUrl);
        failure -> failure
    end.

can_parse(Input, Base) ->
    parse_with_base(text(Input), Base) =/= failure.

%% Writes the components of Url to urlComponents and returns its href.
publish(Url) ->
    {Href, Components} = buoy_node_url:components(Url),
    View = erlang:get(?COMPONENTS),
    [buoy_heap:set(View, I, V) || {I, V} <- lists:enumerate(0, Components)],
    js(Href).

%% Node's ThrowInvalidURL: ERR_INVALID_URL with the input and the base.
-spec invalid_url(string(), term()) -> no_return().
invalid_url(Text, Base) ->
    E = buoy_heap:error_object('TypeError', <<"Invalid URL">>, <<"TypeError: Invalid URL">>),
    Props = [{<<"code">>, <<"ERR_INVALID_URL">>}, {<<"input">>, js(Text)}]
        ++ [{<<"base">>, buoy_ref:to_string(Base)} || Base =/= undefined],
    [buoy_heap:define(E, K, #{value => V, writable => true, enumerable => true, configurable => true}) || {K, V} <- Props],
    erlang:error({'$throw', E}).

-define(ACTIONS, {protocol, host, hostname, port, username, password, pathname, search, hash, href}).

update(Href, Action, Value) ->
    {ok, Url} = buoy_node_url:parse(text(Href), null),
    Field = element(trunc(buoy_ref:to_number(Action)) + 1, ?ACTIONS),
    case buoy_node_url:set(Field, Url, text(Value)) of
        {ok, New} -> publish(New);
        failure -> false
    end.

%% url.format of a URL object: hash, unicode, search, and auth choose the parts.
format(Href, [Hash, Unicode, Search, Auth]) ->
    {ok, Url0} = buoy_node_url:parse(text(Href), null),
    Url1 = case Hash of true -> Url0; false -> Url0#{fragment := null} end,
    Url2 = case Unicode andalso maps:get(host, Url1) =/= null of
        true -> Url1#{host := buoy_node_url:domain_to_unicode(maps:get(host, Url1))};
        false -> Url1
    end,
    Url3 = case Search of true -> Url2; false -> Url2#{query := null} end,
    Url4 = case Auth of true -> Url3; false -> Url3#{username := "", password := ""} end,
    js(buoy_node_url:href(Url4)).

%% domainToASCII and domainToUnicode: the hostname setter on ws://x, or ''.
domain(Domain, Kind) ->
    case buoy_node_url:hostname(text(Domain)) of
        failure -> <<>>;
        {ok, Host} when Kind =:= ascii -> js(Host);
        {ok, Host} -> js(buoy_node_url:domain_to_unicode(Host))
    end.

%% pathToFileURL: the path with the characters that the pathname setter would
%% change percent-encoded, after file://.
path_to_file_url(Path, Windows, Hostname) ->
    Text = text(Path),
    Encoded = lists:flatmap(fun
        ($\\) when Windows -> "/";
        (C) -> case lists:member(C, [0, $\t, $\n, $\r, $\s, $", $#, $%, $?, $[, $\\, $], $^, $|, $~]) of
                   true -> lists:flatten(io_lib:format("%~2.16.0B", [C]));
                   false -> [C]
               end
    end, Text),
    case buoy_node_url:parse("file://" ++ Encoded, null) of
        failure ->
            invalid_url(Text, undefined);
        {ok, Url} when Windows, Hostname =/= undefined ->
            {ok, WithHost} = buoy_node_url:set(hostname, Url, text(Hostname)),
            publish(WithHost);
        {ok, Url} ->
            publish(Url)
    end.
