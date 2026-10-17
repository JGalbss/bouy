%% The URL Standard (https://url.spec.whatwg.org), which ada implements for
%% Node: the basic URL parser with its state overrides for the setters, the
%% host parser with IPv4, IPv6, and opaque hosts, domain to ASCII with
%% punycode, and the serializer. A URL is a map; each string in it is a list
%% of code points.
-module(bouy_node_url).

-export([parse/2, set/3, href/1, components/1, origin/1, scheme_type/1]).
-export([domain_to_ascii/1, domain_to_unicode/1, hostname/1, percent_encode/2]).

-export_type([url/0]).

-type url() :: #{scheme := string(), username := string(), password := string(),
                 host := null | string(), port := null | non_neg_integer(),
                 path := {opaque, string()} | [string()], query := null | string(),
                 fragment := null | string()}.

%% buf is the buffer of the standard, reversed, so an append takes constant time.
-record(p, {url, base, override, input, buf = [], at = false, brackets = false, pw = false}).

-define(IS_ALPHA(C), ((C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z))).
-define(IS_DIGIT(C), (C >= $0 andalso C =< $9)).
-define(IS_HEX(C), (?IS_DIGIT(C) orelse (C >= $a andalso C =< $f) orelse (C >= $A andalso C =< $F))).

%%% The API

%% The URL of Input, against Base (a URL or null), or failure.
-spec parse(string(), url() | null) -> {ok, url()} | failure.
parse(Input, Base) ->
    case basic(Input, Base, empty(), none) of
        {ok, Url} -> {ok, Url};
        {failure, _} -> failure
    end.

empty() ->
    #{scheme => "", username => "", password => "", host => null, port => null, path => [], query => null, fragment => null}.

%% The setters of the URL class: Field is protocol, username, password,
%% host, hostname, port, pathname, search, hash, or href. A setter that the
%% standard ignores keeps the URL; only href fails.
-spec set(atom(), url(), string()) -> {ok, url()} | failure.
set(href, _Url, Value) ->
    parse(Value, null);
set(protocol, Url, Value) ->
    keep(Url, basic(Value ++ ":", null, Url, scheme_start));
set(username, Url, Value) ->
    case cannot_have_credentials(Url) of
        true -> {ok, Url};
        false -> {ok, Url#{username := percent_encode(Value, userinfo)}}
    end;
set(password, Url, Value) ->
    case cannot_have_credentials(Url) of
        true -> {ok, Url};
        false -> {ok, Url#{password := percent_encode(Value, userinfo)}}
    end;
set(host, #{path := {opaque, _}} = Url, _Value) ->
    {ok, Url};
set(host, Url, Value) ->
    keep(Url, basic(Value, null, Url, host));
set(hostname, #{path := {opaque, _}} = Url, _Value) ->
    {ok, Url};
set(hostname, Url, Value) ->
    keep(Url, basic(Value, null, Url, hostname));
set(port, Url, Value) ->
    case cannot_have_credentials(Url) of
        true -> {ok, Url};
        false when Value =:= "" -> {ok, Url#{port := null}};
        false -> keep(Url, basic(Value, null, Url, port))
    end;
set(pathname, #{path := {opaque, _}} = Url, _Value) ->
    {ok, Url};
set(pathname, Url, Value) ->
    keep(Url, basic(Value, null, Url#{path := []}, path_start));
set(search, Url, "") ->
    {ok, strip_opaque(Url#{query := null})};
set(search, Url, Value) ->
    Input = case Value of [$? | Rest] -> Rest; _ -> Value end,
    keep(Url, basic(Input, null, Url#{query := ""}, query));
set(hash, Url, "") ->
    {ok, strip_opaque(Url#{fragment := null})};
set(hash, Url, Value) ->
    Input = case Value of [$# | Rest] -> Rest; _ -> Value end,
    keep(Url, basic(Input, null, Url#{fragment := ""}, fragment)).

%% The parser changes the URL in place, so a setter keeps what it set before
%% the parser failed.
%% The host that the hostname setter of a special URL parses from Text, as
%% Node's domainToASCII uses it.
-spec hostname(string()) -> {ok, string()} | failure.
hostname(Text) ->
    {ok, Url} = parse("ws://x", null),
    case Text =/= "" andalso basic(Text, null, Url, hostname) of
        {ok, #{host := Host}} -> {ok, Host};
        _ -> failure
    end.

keep(_Url, {ok, New}) -> {ok, New};
keep(_Url, {failure, Changed}) -> {ok, Changed}.

cannot_have_credentials(#{host := null}) -> true;
cannot_have_credentials(#{host := ""}) -> true;
cannot_have_credentials(#{scheme := "file"}) -> true;
cannot_have_credentials(_) -> false.

%% Potentially strip trailing spaces from an opaque path.
strip_opaque(#{path := {opaque, Path}, query := null, fragment := null} = Url) ->
    Url#{path := {opaque, string:trim(Path, trailing, " ")}};
strip_opaque(Url) ->
    Url.

%% The URL serializer.
-spec href(url()) -> string().
href(Url) ->
    {Href, _} = components(Url),
    Href.

%% The href and ada's url_components: protocol_end, username_end, host_start,
%% host_end, port, pathname_start, search_start, hash_start, and the scheme
%% type. An omitted value is 2^32 - 1.
-spec components(url()) -> {string(), [non_neg_integer()]}.
components(#{scheme := Scheme, username := User, password := Password, host := Host, port := Port,
             path := Path, query := Query, fragment := Fragment}) ->
    Protocol = Scheme ++ ":",
    ProtocolEnd = length(Protocol),
    {Authority, UsernameEnd, HostStart, HostEnd, PortText} = case Host of
        null ->
            {"", ProtocolEnd, ProtocolEnd, ProtocolEnd, ""};
        _ ->
            Credentials = case {User, Password} of
                {"", ""} -> "";
                {_, ""} -> User ++ "@";
                _ -> User ++ ":" ++ Password ++ "@"
            end,
            UEnd = ProtocolEnd + 2 + length(User),
            HStart = case Credentials of
                "" -> UEnd;
                _ -> ProtocolEnd + 2 + length(Credentials) - 1
            end,
            P = case Port of null -> ""; _ -> ":" ++ integer_to_list(Port) end,
            {"//" ++ Credentials ++ Host ++ P, UEnd, HStart, HStart + length(Host) + bool(Credentials =/= ""), P}
    end,
    PathText = path_text(Host, Path),
    Head = Protocol ++ Authority ++ PathText,
    PathnameStart = HostEnd + length(PortText) + case {Host, Path} of
        {null, [[], _ | _]} -> 2;
        _ -> 0
    end,
    {WithQuery, SearchStart} = case Query of
        null -> {Head, omitted};
        _ -> {Head ++ "?" ++ Query, length(Head)}
    end,
    {Href, HashStart} = case Fragment of
        null -> {WithQuery, omitted};
        _ -> {WithQuery ++ "#" ++ Fragment, length(WithQuery)}
    end,
    {Href, [ProtocolEnd, UsernameEnd, HostStart, HostEnd, omit(Port), PathnameStart, omit(SearchStart), omit(HashStart),
            scheme_type(Scheme)]}.

bool(true) -> 1;
bool(false) -> 0.

omit(null) -> 16#FFFFFFFF;
omit(omitted) -> 16#FFFFFFFF;
omit(N) -> N.

path_text(_Host, {opaque, Path}) -> Path;
path_text(null, [[], _ | _] = Segments) -> "/." ++ lists:append(["/" ++ S || S <- Segments]);
path_text(_Host, Segments) -> lists:append(["/" ++ S || S <- Segments]).

%% ada::scheme::type.
-spec scheme_type(string()) -> 0..6.
scheme_type("http") -> 0;
scheme_type("https") -> 2;
scheme_type("ws") -> 3;
scheme_type("ftp") -> 4;
scheme_type("wss") -> 5;
scheme_type("file") -> 6;
scheme_type(_) -> 1.

%% The ASCII serialization of the origin of a URL.
-spec origin(url()) -> string().
origin(#{scheme := "blob", path := Path} = Url) ->
    case parse(path_text(maps:get(host, Url), Path), null) of
        {ok, #{scheme := S} = Inner} when S =:= "http"; S =:= "https" -> origin(Inner);
        _ -> "null"
    end;
origin(#{scheme := Scheme, host := Host, port := Port}) ->
    case scheme_type(Scheme) of
        Type when Type =:= 1; Type =:= 6 -> "null";
        _ -> Scheme ++ "://" ++ Host ++ case Port of null -> ""; _ -> ":" ++ integer_to_list(Port) end
    end.

is_special(Scheme) -> default_port(Scheme) =/= none.

default_port("ftp") -> 21;
default_port("file") -> null;
default_port("http") -> 80;
default_port("https") -> 443;
default_port("ws") -> 80;
default_port("wss") -> 443;
default_port(_) -> none.

%%% The basic URL parser

basic(Input0, Base, Url, Override) ->
    Input1 = case Override of
        none -> lists:reverse(lists:dropwhile(fun(C) -> C =< 32 end, lists:reverse(lists:dropwhile(fun(C) -> C =< 32 end, Input0))));
        _ -> Input0
    end,
    Input = [C || C <- Input1, C =/= $\t, C =/= $\n, C =/= $\r],
    State = case Override of none -> scheme_start; _ -> Override end,
    loop(State, Input, #p{url = Url, base = Base, override = Override, input = Input}).

loop(State, Rest, P) ->
    {C, Tail} = case Rest of
        [] -> {eof, []};
        [H | T] -> {H, T}
    end,
    case state(State, C, Tail, P) of
        {next, Next, P1} when C =:= eof -> finish(Next, P1);
        {next, Next, P1} -> loop(Next, Tail, P1);
        {again, Next, P1} -> loop(Next, Rest, P1);
        {skip, Next, P1} -> loop(Next, tl_or_empty(Tail), P1);
        {restart, Next, P1} -> loop(Next, P1#p.input, P1);
        {rewind, Next, P1} -> loop(Next, lists:reverse(P#p.buf, Rest), P1);
        {return, Url} -> {ok, Url};
        failure -> {failure, P#p.url}
    end.

finish(_State, P) -> {ok, P#p.url}.

tl_or_empty([]) -> [];
tl_or_empty([_ | T]) -> T.

url(P) -> P#p.url.
set_url(P, Fields) -> P#p{url = maps:merge(P#p.url, Fields)}.
special(P) -> is_special(maps:get(scheme, url(P))).

state(scheme_start, C, _Tail, P) when is_integer(C), ?IS_ALPHA(C) ->
    {next, scheme, P#p{buf = [lower(C)]}};
state(scheme_start, _C, _Tail, #p{override = none} = P) ->
    {again, no_scheme, P};
state(scheme_start, _C, _Tail, _P) ->
    failure;

state(scheme, C, _Tail, P) when is_integer(C), ?IS_ALPHA(C) orelse ?IS_DIGIT(C) orelse C =:= $+ orelse C =:= $- orelse C =:= $. ->
    {next, scheme, P#p{buf = [lower(C) | P#p.buf]}};
state(scheme, $:, Tail, #p{buf = Rev, override = Override} = P) ->
    Buffer = lists:reverse(Rev),
    Url = url(P),
    case Override =/= none andalso override_refuses(Url, Buffer) of
        true ->
            {return, Url};
        false ->
            P1 = set_url(P, #{scheme => Buffer}),
            case Override of
                none -> after_scheme(Tail, P1#p{buf = []});
                _ ->
                    Url1 = url(P1),
                    case default_port(Buffer) =:= maps:get(port, Url1) of
                        true -> {return, Url1#{port := null}};
                        false -> {return, Url1}
                    end
            end
    end;
state(scheme, _C, _Tail, #p{override = none} = P) ->
    {restart, no_scheme, P#p{buf = []}};
state(scheme, _C, _Tail, _P) ->
    failure;

state(no_scheme, C, _Tail, #p{base = Base} = P) ->
    case Base of
        null -> failure;
        #{path := {opaque, _}} when C =/= $# -> failure;
        #{path := {opaque, _}} ->
            {next, fragment, set_url(P, #{scheme => maps:get(scheme, Base), path => maps:get(path, Base),
                                          query => maps:get(query, Base), fragment => ""})};
        #{scheme := "file"} -> {again, file, P};
        _ -> {again, relative, P}
    end;

state(special_relative_or_authority, $/, [$/ | _], P) ->
    {skip, special_authority_ignore_slashes, P};
state(special_relative_or_authority, _C, _Tail, P) ->
    {again, relative, P};

state(path_or_authority, $/, _Tail, P) ->
    {next, authority, P};
state(path_or_authority, _C, _Tail, P) ->
    {again, path, P};

state(relative, C, _Tail, #p{base = Base} = P0) ->
    P = set_url(P0, #{scheme => maps:get(scheme, Base)}),
    case C of
        $/ -> {next, relative_slash, P};
        $\\ -> case special(P) of
                   true -> {next, relative_slash, P};
                   false -> relative_other(C, P, Base)
               end;
        _ -> relative_other(C, P, Base)
    end;

state(relative_slash, C, _Tail, P) when C =:= $/; C =:= $\\ ->
    case special(P) of
        true -> {next, special_authority_ignore_slashes, P};
        false when C =:= $/ -> {next, authority, P};
        false -> relative_slash_other(P)
    end;
state(relative_slash, _C, _Tail, P) ->
    relative_slash_other(P);

state(special_authority_slashes, $/, [$/ | _], P) ->
    {skip, special_authority_ignore_slashes, P};
state(special_authority_slashes, _C, _Tail, P) ->
    {again, special_authority_ignore_slashes, P};

state(special_authority_ignore_slashes, C, _Tail, P) when C =:= $/; C =:= $\\ ->
    {next, special_authority_ignore_slashes, P};
state(special_authority_ignore_slashes, _C, _Tail, P) ->
    {again, authority, P};

state(authority, $@, _Tail, #p{buf = Rev, at = At} = P) ->
    Buffer = case At of true -> "%40" ++ lists:reverse(Rev); false -> lists:reverse(Rev) end,
    {next, authority, credentials(Buffer, P#p{at = true, buf = []})};
state(authority, C, _Tail, #p{buf = Rev} = P) ->
    case is_authority_end(C, P) of
        true when P#p.at, Rev =:= [] -> failure;
        true -> {rewind, host, P#p{buf = []}};
        false -> {next, authority, P#p{buf = [C | Rev]}}
    end;

state(State, C, Tail, #p{override = Override} = P) when State =:= host; State =:= hostname ->
    Url = url(P),
    case Override =/= none andalso maps:get(scheme, Url) =:= "file" of
        true -> {again, file_host, P};
        false -> host_state(State, C, Tail, P)
    end;

state(port, C, _Tail, P) when is_integer(C), ?IS_DIGIT(C) ->
    {next, port, P#p{buf = [C | P#p.buf]}};
state(port, C, _Tail, #p{buf = Rev, override = Override} = P) ->
    Buffer = lists:reverse(Rev),
    case is_authority_end(C, P) orelse Override =/= none of
        false -> failure;
        true ->
            Parsed = case Buffer of
                [] when Override =/= none -> failure;
                [] -> {ok, P};
                _ ->
                    case list_to_integer(Buffer) of
                        N when N > 65535 -> failure;
                        N ->
                            Url = url(P),
                            Port = case default_port(maps:get(scheme, Url)) of
                                N -> null;
                                _ -> N
                            end,
                            {ok, set_url(P#p{buf = []}, #{port => Port})}
                    end
            end,
            case Parsed of
                failure -> failure;
                {ok, P1} when Override =/= none -> {return, url(P1)};
                {ok, P1} -> {again, path_start, P1}
            end
    end;

state(file, C, Tail, #p{base = Base} = P0) ->
    P = set_url(P0, #{scheme => "file", host => ""}),
    case C of
        _ when C =:= $/; C =:= $\\ -> {next, file_slash, P};
        _ ->
            case Base of
                #{scheme := "file"} ->
                    P1 = set_url(P, #{host => maps:get(host, Base), path => maps:get(path, Base), query => maps:get(query, Base)}),
                    case C of
                        $? -> {next, query, set_url(P1, #{query => ""})};
                        $# -> {next, fragment, set_url(P1, #{fragment => ""})};
                        eof -> {next, file, P1};
                        _ ->
                            P2 = set_url(P1, #{query => null}),
                            P3 = case starts_with_drive_letter([C | Tail]) of
                                false -> set_url(P2, #{path => shorten(url(P2))});
                                true -> set_url(P2, #{path => []})
                            end,
                            {again, path, P3}
                    end;
                _ ->
                    {again, path, P}
            end
    end;

state(file_slash, C, _Tail, P) when C =:= $/; C =:= $\\ ->
    {next, file_host, P};
state(file_slash, C, Tail, #p{base = Base} = P) ->
    P1 = case Base of
        #{scheme := "file", host := BaseHost, path := BasePath} ->
            P0 = set_url(P, #{host => BaseHost}),
            case (not starts_with_drive_letter(rest(C, Tail))) andalso BasePath of
                [First | _] -> case is_normalized_drive_letter(First) of
                                   true -> set_url(P0, #{path => maps:get(path, url(P0)) ++ [First]});
                                   false -> P0
                               end;
                _ -> P0
            end;
        _ ->
            P
    end,
    {again, path, P1};

state(file_host, C, _Tail, #p{buf = Rev, override = Override} = P) when C =:= eof; C =:= $/; C =:= $\\; C =:= $?; C =:= $# ->
    Buffer = lists:reverse(Rev),
    case Override =:= none andalso is_drive_letter(Buffer) of
        true ->
            {again, path, P};
        false when Buffer =:= [] ->
            P1 = set_url(P, #{host => ""}),
            case Override of
                none -> {again, path_start, P1};
                _ -> {return, url(P1)}
            end;
        false ->
            case host_parse(Buffer, not special(P)) of
                failure -> failure;
                {ok, Host0} ->
                    Host = case Host0 of "localhost" -> ""; _ -> Host0 end,
                    P1 = set_url(P#p{buf = []}, #{host => Host}),
                    case Override of
                        none -> {again, path_start, P1};
                        _ -> {return, url(P1)}
                    end
            end
    end;
state(file_host, C, _Tail, P) ->
    {next, file_host, P#p{buf = [C | P#p.buf]}};

state(path_start, C, _Tail, #p{override = Override} = P) ->
    case special(P) of
        true when C =:= $/; C =:= $\\ -> {next, path, P};
        true -> {again, path, P};
        false when Override =:= none, C =:= $? -> {next, query, set_url(P, #{query => ""})};
        false when Override =:= none, C =:= $# -> {next, fragment, set_url(P, #{fragment => ""})};
        false when C =:= $/ -> {next, path, P};
        false when C =/= eof -> {again, path, P};
        false ->
            Url = url(P),
            case Override =/= none andalso maps:get(host, Url) =:= null of
                true -> {next, path_start, set_url(P, #{path => maps:get(path, Url) ++ [[]]})};
                false -> {next, path_start, P}
            end
    end;

state(path, C, _Tail, #p{buf = Rev, override = Override} = P) ->
    Slash = C =:= $/ orelse (C =:= $\\ andalso special(P)),
    case C =:= eof orelse Slash orelse (Override =:= none andalso (C =:= $? orelse C =:= $#)) of
        false ->
            {next, path, P#p{buf = lists:reverse(percent_encode([C], path), Rev)}};
        true ->
            Buffer = lists:reverse(Rev),
            Url = url(P),
            Path = maps:get(path, Url),
            NewPath = case {is_double_dot(Buffer), is_single_dot(Buffer)} of
                {true, _} ->
                    Shortened = shorten(Url),
                    case Slash of true -> Shortened; false -> Shortened ++ [[]] end;
                {false, true} when not Slash -> Path ++ [[]];
                {false, true} -> Path;
                {false, false} ->
                    Segment = case maps:get(scheme, Url) =:= "file" andalso Path =:= [] andalso is_drive_letter(Buffer) of
                        true -> [hd(Buffer), $:];
                        false -> Buffer
                    end,
                    Path ++ [Segment]
            end,
            P1 = set_url(P#p{buf = []}, #{path => NewPath}),
            case C of
                $? when Override =:= none -> {next, query, set_url(P1, #{query => ""})};
                $# when Override =:= none -> {next, fragment, set_url(P1, #{fragment => ""})};
                _ -> {next, path, P1}
            end
    end;

state(opaque_path, $?, _Tail, P) ->
    {next, query, set_url(flush_opaque(P), #{query => ""})};
state(opaque_path, $#, _Tail, P) ->
    {next, fragment, set_url(flush_opaque(P), #{fragment => ""})};
state(opaque_path, $\s, Tail, #p{buf = Rev} = P) ->
    Space = case Tail of
        [Next | _] when Next =:= $?; Next =:= $# -> "02%";
        _ -> " "
    end,
    {next, opaque_path, P#p{buf = Space ++ Rev}};
state(opaque_path, eof, _Tail, P) ->
    {next, opaque_path, flush_opaque(P)};
state(opaque_path, C, _Tail, #p{buf = Rev} = P) ->
    {next, opaque_path, P#p{buf = lists:reverse(percent_encode([C], c0), Rev)}};

state(query, C, _Tail, #p{buf = Rev, override = Override} = P) when C =:= eof; C =:= $#, Override =:= none ->
    Buffer = lists:reverse(Rev),
    Set = case special(P) of true -> special_query; false -> query end,
    Url = url(P),
    P1 = set_url(P#p{buf = []}, #{query => maps:get(query, Url) ++ percent_encode(Buffer, Set)}),
    case C of
        $# -> {next, fragment, set_url(P1, #{fragment => ""})};
        eof -> {next, query, P1}
    end;
state(query, C, _Tail, P) ->
    {next, query, P#p{buf = [C | P#p.buf]}};

state(fragment, eof, _Tail, #p{buf = Rev} = P) ->
    Url = url(P),
    {next, fragment, set_url(P#p{buf = []}, #{fragment => maps:get(fragment, Url) ++ lists:reverse(Rev)})};
state(fragment, C, _Tail, #p{buf = Rev} = P) ->
    {next, fragment, P#p{buf = lists:reverse(percent_encode([C], fragment), Rev)}}.

flush_opaque(#p{buf = Rev} = P) ->
    {opaque, Path} = maps:get(path, url(P)),
    set_url(P#p{buf = []}, #{path => {opaque, Path ++ lists:reverse(Rev)}}).

rest(eof, _Tail) -> [];
rest(C, Tail) -> [C | Tail].

override_refuses(Url = #{scheme := Scheme}, Buffer) ->
    is_special(Scheme) =/= is_special(Buffer)
        orelse ((maps:get(username, Url) =/= "" orelse maps:get(password, Url) =/= "" orelse maps:get(port, Url) =/= null)
                andalso Buffer =:= "file")
        orelse (Scheme =:= "file" andalso maps:get(host, Url) =:= "").

after_scheme(Tail, #p{base = Base} = P) ->
    Url = url(P),
    Scheme = maps:get(scheme, Url),
    case Scheme of
        "file" -> {next, file, P};
        _ ->
            case is_special(Scheme) of
                true ->
                    case Base of
                        #{scheme := Scheme} -> {next, special_relative_or_authority, P};
                        _ -> {next, special_authority_slashes, P}
                    end;
                false ->
                    case Tail of
                        [$/ | _] -> {skip, path_or_authority, P};
                        _ -> {next, opaque_path, set_url(P, #{path => {opaque, ""}})}
                    end
            end
    end.

relative_other(C, P, Base) ->
    P1 = set_url(P, maps:with([username, password, host, port, path, query], Base)),
    case C of
        $? -> {next, query, set_url(P1, #{query => ""})};
        $# -> {next, fragment, set_url(P1, #{fragment => ""})};
        eof -> {next, relative, P1};
        _ ->
            P2 = set_url(P1, #{query => null}),
            {again, path, set_url(P2, #{path => shorten(url(P2))})}
    end.

relative_slash_other(#p{base = Base} = P) ->
    {again, path, set_url(P, maps:with([username, password, host, port], Base))}.

is_authority_end(C, P) ->
    C =:= eof orelse C =:= $/ orelse C =:= $? orelse C =:= $# orelse (C =:= $\\ andalso special(P)).

credentials(Buffer, P) ->
    lists:foldl(fun
        ($:, #p{pw = false} = Acc) -> Acc#p{pw = true};
        (C, #p{pw = Pw} = Acc) ->
            Encoded = percent_encode([C], userinfo),
            Url = url(Acc),
            case Pw of
                true -> set_url(Acc, #{password => maps:get(password, Url) ++ Encoded});
                false -> set_url(Acc, #{username => maps:get(username, Url) ++ Encoded})
            end
    end, P, Buffer).

host_state(_State, $:, _Tail, #p{buf = Rev, brackets = false, override = Override} = P) ->
    Buffer = lists:reverse(Rev),
    case Buffer of
        [] -> failure;
        _ when Override =:= hostname -> failure;
        _ ->
            case host_parse(Buffer, not special(P)) of
                failure -> failure;
                {ok, Host} -> {next, port, set_url(P#p{buf = []}, #{host => Host})}
            end
    end;
host_state(State, C, _Tail, #p{buf = Rev, override = Override} = P) ->
    Buffer = lists:reverse(Rev),
    case is_authority_end(C, P) of
        true ->
            Url = url(P),
            Credentials = maps:get(username, Url) =/= "" orelse maps:get(password, Url) =/= "" orelse maps:get(port, Url) =/= null,
            case Buffer of
                [] ->
                    case special(P) of
                        true -> failure;
                        false when Override =/= none, Credentials -> failure;
                        false -> host_parsed(C, Buffer, P)
                    end;
                _ ->
                    host_parsed(C, Buffer, P)
            end;
        false ->
            Brackets = case C of
                $[ -> true;
                $] -> false;
                _ -> P#p.brackets
            end,
            {next, State, P#p{buf = [C | Rev], brackets = Brackets}}
    end.

host_parsed(_C, Buffer, #p{override = Override} = P) ->
    case host_parse(Buffer, not special(P)) of
        failure -> failure;
        {ok, Host} ->
            P1 = set_url(P#p{buf = []}, #{host => Host}),
            case Override of
                none -> {again, path_start, P1};
                _ -> {return, url(P1)}
            end
    end.

shorten(#{scheme := "file", path := [Only]}) ->
    case is_normalized_drive_letter(Only) of
        true -> [Only];
        false -> []
    end;
shorten(#{path := []}) -> [];
shorten(#{path := Path}) -> lists:droplast(Path).

is_drive_letter([A, B]) -> ?IS_ALPHA(A) andalso (B =:= $: orelse B =:= $|);
is_drive_letter(_) -> false.

is_normalized_drive_letter([A, $:]) -> ?IS_ALPHA(A);
is_normalized_drive_letter(_) -> false.

starts_with_drive_letter([A, B]) -> is_drive_letter([A, B]);
starts_with_drive_letter([A, B, C | _]) -> is_drive_letter([A, B]) andalso lists:member(C, "/\\?#");
starts_with_drive_letter(_) -> false.

is_single_dot(S) -> lists:member(string:lowercase(S), [".", "%2e"]).

is_double_dot(S) -> lists:member(string:lowercase(S), ["..", ".%2e", "%2e.", "%2e%2e"]).

lower(C) when C >= $A, C =< $Z -> C + 32;
lower(C) -> C.

%%% Percent-encoding

%% UTF-8 percent-encode each code point of S that is in the set.
-spec percent_encode(string(), atom()) -> string().
percent_encode(S, Set) ->
    lists:flatmap(fun(C) ->
        case in_set(C, Set) of
            true -> lists:append([[$%, hex(B bsr 4), hex(B band 15)] || <<B>> <= utf8(C)]);
            false -> [C]
        end
    end, S).

utf8(C) when C >= 16#D800, C =< 16#DFFF -> <<16#EF, 16#BF, 16#BD>>;
utf8(C) -> <<C/utf8>>.

hex(N) when N < 10 -> $0 + N;
hex(N) -> $A + N - 10.

in_set(C, c0) -> C < 16#20 orelse C > 16#7E;
in_set(C, fragment) -> in_set(C, c0) orelse lists:member(C, " \"<>`");
in_set(C, query) -> in_set(C, c0) orelse lists:member(C, " \"#<>");
in_set(C, special_query) -> in_set(C, query) orelse C =:= $';
in_set(C, path) -> in_set(C, query) orelse lists:member(C, "?^`{}");
in_set(C, userinfo) -> in_set(C, path) orelse lists:member(C, "/:;=@[\\]|");
in_set(C, component) -> in_set(C, userinfo) orelse lists:member(C, "$%&+,");
in_set(C, form) -> in_set(C, component) orelse lists:member(C, "!'()~");
in_set(C, file_path) -> lists:member(C, [0, $\t, $\n, $\r, $\s, $", $#, $%, $?, $[, $\\, $], $^, $|, $~]).

percent_decode([$%, A, B | Rest]) when ?IS_HEX(A), ?IS_HEX(B) ->
    [list_to_integer([A, B], 16) | percent_decode(Rest)];
percent_decode([C | Rest]) when C < 128 -> [C | percent_decode(Rest)];
percent_decode([C | Rest]) -> binary_to_list(utf8(C)) ++ percent_decode(Rest);
percent_decode([]) -> [].

%%% Hosts

host_parse([$[ | Rest], _Opaque) ->
    case lists:reverse(Rest) of
        [$] | Inside] ->
            case ipv6_parse(lists:reverse(Inside)) of
                failure -> failure;
                Address -> {ok, "[" ++ ipv6_serialize(Address) ++ "]"}
            end;
        _ ->
            failure
    end;
host_parse(Input, true) ->
    case lists:any(fun is_forbidden_host/1, Input) of
        true -> failure;
        false -> {ok, percent_encode(Input, c0)}
    end;
host_parse(Input, false) ->
    Bytes = list_to_binary(percent_decode(Input)),
    Domain = case unicode:characters_to_list(Bytes) of
        L when is_list(L) -> L;
        _ -> [replace_invalid(Bytes)]
    end,
    case domain_to_ascii(Domain) of
        failure -> failure;
        {ok, Ascii} ->
            case ends_in_number(Ascii) of
                true -> ipv4_parse(Ascii);
                false -> {ok, Ascii}
            end
    end.

%% A decoding with U+FFFD for invalid bytes is a domain that domain to ASCII
%% refuses, so one replacement character stands for it.
replace_invalid(_) -> 16#FFFD.

is_forbidden_host(C) -> lists:member(C, [0, $\t, $\n, $\r, $\s, $#, $/, $:, $<, $>, $?, $@, $[, $\\, $], $^, $|]).

is_forbidden_domain(C) -> is_forbidden_host(C) orelse C =< 16#1F orelse C =:= $% orelse C =:= 16#7F.

ends_in_number(Domain) ->
    Parts0 = string:split(Domain, ".", all),
    Parts = case lists:last(Parts0) of
        "" when length(Parts0) > 1 -> lists:droplast(Parts0);
        _ -> Parts0
    end,
    Last = lists:last(Parts),
    (Last =/= "" andalso lists:all(fun(C) -> ?IS_DIGIT(C) end, Last)) orelse ipv4_number(Last) =/= failure.

ipv4_parse(Input) ->
    Parts0 = string:split(Input, ".", all),
    Parts = case lists:last(Parts0) of
        "" when length(Parts0) > 1 -> lists:droplast(Parts0);
        _ -> Parts0
    end,
    Numbers = [ipv4_number(Part) || Part <- Parts],
    case length(Parts) > 4 orelse lists:member(failure, Numbers) of
        true -> failure;
        false ->
            {Init, [Last]} = lists:split(length(Numbers) - 1, Numbers),
            case lists:any(fun(N) -> N > 255 end, Init) orelse Last >= pow256(5 - length(Numbers)) of
                true -> failure;
                false ->
                    {_, Address} = lists:foldl(fun(N, {I, Acc}) -> {I + 1, Acc + N * pow256(3 - I)} end, {0, Last}, Init),
                    {ok, lists:flatten(lists:join(".", [integer_to_list((Address bsr Shift) band 255) || Shift <- [24, 16, 8, 0]]))}
            end
    end.

pow256(N) -> 1 bsl (8 * N).

ipv4_number("") -> failure;
ipv4_number([$0, X | Rest]) when X =:= $x; X =:= $X -> radix(Rest, 16);
ipv4_number([$0, _ | _] = S) -> radix(tl(S), 8);
ipv4_number(S) -> radix(S, 10).

radix("", _) -> 0;
radix(S, Radix) ->
    case lists:all(fun(C) -> digit(C) < Radix end, S) of
        true -> list_to_integer(S, Radix);
        false -> failure
    end.

digit(C) when ?IS_DIGIT(C) -> C - $0;
digit(C) when C >= $a, C =< $f -> C - $a + 10;
digit(C) when C >= $A, C =< $F -> C - $A + 10;
digit(_) -> 99.

%% The IPv6 parser, as eight 16-bit pieces.
ipv6_parse([$:, $: | Rest]) -> ipv6_pieces(Rest, 1, 1, #{});
ipv6_parse([$: | _]) -> failure;
ipv6_parse(Input) -> ipv6_pieces(Input, 0, null, #{}).

ipv6_pieces([], Index, Compress, Address) -> ipv6_finish(Index, Compress, Address);
ipv6_pieces(_, 8, _Compress, _Address) -> failure;
ipv6_pieces([$: | Rest], Index, null, Address) -> ipv6_pieces(Rest, Index + 1, Index + 1, Address);
ipv6_pieces([$: | _], _Index, _Compress, _Address) -> failure;
ipv6_pieces(Input, Index, Compress, Address) ->
    {Hex, Rest} = take_hex(Input, 4, []),
    Value = case Hex of [] -> 0; _ -> list_to_integer(Hex, 16) end,
    case Rest of
        [$. | _] when Hex =:= [] -> failure;
        [$. | _] when Index > 6 -> failure;
        [$. | _] -> ipv6_ipv4(Hex ++ Rest, Index, Compress, Address, 0);
        [$:] -> failure;
        [$: | More] -> ipv6_pieces(More, Index + 1, Compress, Address#{Index => Value});
        [] -> ipv6_finish(Index + 1, Compress, Address#{Index => Value});
        _ -> failure
    end.

take_hex([C | Rest], N, Acc) when N > 0, ?IS_HEX(C) -> take_hex(Rest, N - 1, [C | Acc]);
take_hex(Rest, _, Acc) -> {lists:reverse(Acc), Rest}.

ipv6_ipv4([], Index, Compress, Address, 4) -> ipv6_finish(Index, Compress, Address);
ipv6_ipv4([], _Index, _Compress, _Address, _Seen) -> failure;
ipv6_ipv4(Input0, Index, Compress, Address, Seen) ->
    Input = case Seen > 0 of
        false -> {ok, Input0};
        true ->
            case Input0 of
                [$. | R] when Seen < 4 -> {ok, R};
                _ -> failure
            end
    end,
    case Input of
        failure -> failure;
        {ok, [D | _] = I} when ?IS_DIGIT(D) ->
            {Digits, Rest} = lists:splitwith(fun(C) -> ?IS_DIGIT(C) end, I),
            case Digits of
                [$0, _ | _] -> failure;
                _ ->
                    case list_to_integer(Digits) of
                        N when N > 255 -> failure;
                        N ->
                            Piece = maps:get(Index, Address, 0) * 16#100 + N,
                            Address1 = Address#{Index => Piece},
                            Index1 = case Seen + 1 of 2 -> Index + 1; 4 -> Index + 1; _ -> Index end,
                            ipv6_ipv4(Rest, Index1, Compress, Address1, Seen + 1)
                    end
            end;
        _ -> failure
    end.

ipv6_finish(Index, null, _Address) when Index =/= 8 -> failure;
ipv6_finish(_Index, null, Address) -> [maps:get(I, Address, 0) || I <- lists:seq(0, 7)];
ipv6_finish(Index, Compress, Address) ->
    Before = [maps:get(I, Address, 0) || I <- lists:seq(0, Compress - 1)],
    After = [maps:get(I, Address, 0) || I <- lists:seq(Compress, Index - 1)],
    case length(Before) + length(After) > 8 of
        true -> failure;
        false -> Before ++ lists:duplicate(8 - length(Before) - length(After), 0) ++ After
    end.

ipv6_serialize(Pieces) ->
    Compress = longest_zero_run(Pieces),
    serialize_pieces(Pieces, 0, Compress, false).

serialize_pieces([], _I, _Compress, _Ignore) -> "";
serialize_pieces([0 | Rest], I, Compress, true) -> serialize_pieces(Rest, I + 1, Compress, true);
serialize_pieces([_ | _] = Pieces, I, I, _Ignore) ->
    Separator = case I of 0 -> "::"; _ -> ":" end,
    Separator ++ serialize_pieces(tl(Pieces), I + 1, I, true);
serialize_pieces([P | Rest], I, Compress, _Ignore) ->
    Text = string:lowercase(integer_to_list(P, 16)),
    case I of
        7 -> Text;
        _ -> Text ++ ":" ++ serialize_pieces(Rest, I + 1, Compress, false)
    end.

longest_zero_run(Pieces) ->
    {_, Best, _, _} = lists:foldl(fun(P, {I, Best, Start, Len}) ->
        case P of
            0 ->
                S = case Len of 0 -> I; _ -> Start end,
                L = Len + 1,
                Best1 = case Best of
                    {_, BL} when BL >= L -> Best;
                    _ when L > 1 -> {S, L};
                    _ -> Best
                end,
                {I + 1, Best1, S, L};
            _ ->
                {I + 1, Best, I + 1, 0}
        end
    end, {0, none, 0, 0}, Pieces),
    case Best of
        none -> none;
        {S, _} -> S
    end.

%%% Domain to ASCII (UTS #46 with CheckHyphens, UseSTD3ASCIIRules, and
%%% VerifyDnsLength false, and nontransitional processing)

%% shortcut: the mapping step is NFKC of the case fold, with the ignored code
%% points of IdnaMappingTable.txt removed; the table's disallowed statuses and
%% the Bidi and joiner rules are not checked. Vendor the table when a test
%% needs an exact status.
-spec domain_to_ascii(string()) -> {ok, string()} | failure.
domain_to_ascii(Domain) ->
    Mapped = uts46_map(Domain),
    Labels = string:split(Mapped, ".", all),
    Converted = [label_to_ascii(L) || L <- Labels],
    case lists:member(failure, Converted) of
        true -> failure;
        false ->
            Result = lists:append(lists:join(".", Converted)),
            case Result =:= "" orelse lists:any(fun is_forbidden_domain/1, Result) orelse lists:any(fun is_disallowed/1, Mapped) of
                true -> failure;
                false -> {ok, Result}
            end
    end.

uts46_map(Domain) ->
    case lists:all(fun(C) -> C < 128 end, Domain) of
        true ->
            [lower(C) || C <- Domain];
        false ->
            Dots = [case C of 16#3002 -> $.; 16#FF0E -> $.; 16#FF61 -> $.; _ -> C end || C <- Domain, not is_ignored(C)],
            case nfkc(fold(nfkc(Dots))) of
                L when is_list(L) -> [case C of 16#3002 -> $.; _ -> C end || C <- L];
                _ -> [16#FFFD]
            end
    end.

%% The code points that every UTS #46 version disallows and that a decoding
%% produces: C1 controls, the replacement character, and noncharacters.
is_disallowed(C) ->
    (C >= 16#80 andalso C =< 16#9F) orelse C =:= 16#FFFD orelse (C band 16#FFFE) =:= 16#FFFE
        orelse (C >= 16#FDD0 andalso C =< 16#FDEF) orelse (C >= 16#D800 andalso C =< 16#DFFF).

nfkc(L) when is_list(L) -> unicode:characters_to_nfkc_list(L);
nfkc(Error) -> Error.

%% The case fold, except the deviation characters that nontransitional
%% processing keeps: sharp s and final sigma.
fold(L) when is_list(L) -> lists:append([case C of 16#DF -> [C]; 16#3C2 -> [C]; 16#1E9E -> [16#DF]; _ -> string:casefold([C]) end || C <- L]);
fold(Error) -> Error.

is_ignored(C) ->
    C =:= 16#AD orelse C =:= 16#34F orelse (C >= 16#180B andalso C =< 16#180F) orelse C =:= 16#200B
        orelse C =:= 16#2060 orelse (C >= 16#FE00 andalso C =< 16#FE0F) orelse C =:= 16#FEFF
        orelse (C >= 16#1BCA0 andalso C =< 16#1BCA3) orelse (C >= 16#E0100 andalso C =< 16#E01EF).

label_to_ascii([X, N, $-, $- | Encoded] = Label) when (X =:= $x orelse X =:= $X), (N =:= $n orelse N =:= $N) ->
    case punycode_decode(Encoded) of
        failure -> failure;
        Decoded ->
            Valid = Decoded =/= [] andalso lists:any(fun(C) -> C >= 128 end, Decoded)
                andalso uts46_map(Decoded) =:= Decoded
                andalso not lists:prefix("xn--", Decoded)
                andalso is_valid_label(Decoded),
            case Valid of
                true -> [lower(C) || C <- Label];
                false -> failure
            end
    end;
label_to_ascii(Label) ->
    case lists:all(fun(C) -> C < 128 end, Label) of
        true -> Label;
        false ->
            case is_valid_label(Label) of
                true -> "xn--" ++ punycode_encode(Label);
                false -> failure
            end
    end.

%% The validity criteria of UTS #46 that the general categories decide: the
%% label is in NFC, does not begin with a combining mark, holds no control,
%% format, private use, surrogate, or unassigned code point, and has each
%% zero width joiner after a virama (CheckJoiners).
is_valid_label([First | _] = Label) ->
    unicode:characters_to_nfc_list(Label) =:= Label
        andalso not is_mark(First)
        andalso is_joined(Label, 0)
        andalso not lists:any(fun(C) -> is_disallowed(C) orelse is_other(C) end, Label);
is_valid_label([]) ->
    true.

category(C) -> maps:get(category, unicode_util:lookup(C)).

is_mark(C) -> element(1, category(C)) =:= mark.

is_other(C) when C =:= 16#200C; C =:= 16#200D -> false;
is_other(C) -> element(1, category(C)) =:= other.

is_joined([C | Rest], Previous) when C =:= 16#200C; C =:= 16#200D ->
    maps:get(ccc, unicode_util:lookup(Previous)) =:= 9 andalso is_joined(Rest, C);
is_joined([C | Rest], _) -> is_joined(Rest, C);
is_joined([], _) -> true.

%% Domain to Unicode: each punycode label decoded.
-spec domain_to_unicode(string()) -> string().
domain_to_unicode(Domain) ->
    Labels = string:split(uts46_map(Domain), ".", all),
    lists:append(lists:join(".", [label_to_unicode(L) || L <- Labels])).

label_to_unicode([$x, $n, $-, $- | Encoded] = Label) ->
    case punycode_decode(Encoded) of
        failure -> Label;
        Decoded -> Decoded
    end;
label_to_unicode(Label) ->
    Label.

%%% Punycode (RFC 3492)

-define(BASE, 36).
-define(TMIN, 1).
-define(TMAX, 26).
-define(SKEW, 38).
-define(DAMP, 700).

punycode_encode(Input) ->
    Basic = [C || C <- Input, C < 128],
    B = length(Basic),
    Out = case B of 0 -> Basic; _ -> Basic ++ "-" end,
    encode_loop(Input, 128, 0, 72, B, B, Out).

encode_loop(Input, N, Delta, Bias, H, B, Out) when H < length(Input) ->
    M = lists:min([C || C <- Input, C >= N]),
    Delta1 = Delta + (M - N) * (H + 1),
    {Delta2, Bias2, H2, Out2} = lists:foldl(fun(C, {D, Bi, Hh, O}) ->
        if
            C < M -> {D + 1, Bi, Hh, O};
            C =:= M ->
                Digits = encode_digits(D, Bi, ?BASE),
                {0, adapt(D, Hh + 1, Hh =:= B), Hh + 1, O ++ Digits};
            true -> {D, Bi, Hh, O}
        end
    end, {Delta1, Bias, H, Out}, Input),
    encode_loop(Input, M + 1, Delta2 + 1, Bias2, H2, B, Out2);
encode_loop(_Input, _N, _Delta, _Bias, _H, _B, Out) ->
    Out.

encode_digits(Q, Bias, K) ->
    T = threshold(K, Bias),
    case Q < T of
        true -> [encode_digit(Q)];
        false -> [encode_digit(T + (Q - T) rem (?BASE - T)) | encode_digits((Q - T) div (?BASE - T), Bias, K + ?BASE)]
    end.

threshold(K, Bias) when K =< Bias -> ?TMIN;
threshold(K, Bias) when K >= Bias + ?TMAX -> ?TMAX;
threshold(K, Bias) -> K - Bias.

encode_digit(D) when D < 26 -> $a + D;
encode_digit(D) -> $0 + D - 26.

adapt(Delta0, NumPoints, First) ->
    Delta1 = case First of true -> Delta0 div ?DAMP; false -> Delta0 div 2 end,
    Delta2 = Delta1 + Delta1 div NumPoints,
    adapt_loop(Delta2, 0).

adapt_loop(Delta, K) when Delta > ((?BASE - ?TMIN) * ?TMAX) div 2 ->
    adapt_loop(Delta div (?BASE - ?TMIN), K + ?BASE);
adapt_loop(Delta, K) ->
    K + ((?BASE - ?TMIN + 1) * Delta) div (Delta + ?SKEW).

punycode_decode(Input) ->
    {Basic, Rest} = case string:split(Input, "-", trailing) of
        [_Only] -> {[], Input};
        [Before, After] -> {Before, After}
    end,
    case lists:all(fun(C) -> C < 128 end, Basic) of
        false -> failure;
        true -> decode_loop(Rest, 128, 0, 72, Basic)
    end.

decode_loop([], _N, _I, _Bias, Out) -> Out;
decode_loop(Input, N, I, Bias, Out) ->
    case decode_number(Input, I, 1, ?BASE, Bias) of
        failure -> failure;
        {I1, Rest} ->
            Len = length(Out) + 1,
            Bias1 = adapt(I1 - I, Len, I =:= 0),
            N1 = N + I1 div Len,
            Pos = I1 rem Len,
            case N1 > 16#10FFFF orelse (N1 >= 16#D800 andalso N1 =< 16#DFFF) of
                true -> failure;
                false ->
                    {Left, Right} = lists:split(Pos, Out),
                    decode_loop(Rest, N1, Pos + 1, Bias1, Left ++ [N1] ++ Right)
            end
    end.

decode_number([], _I, _W, _K, _Bias) -> failure;
decode_number([C | Rest], I, W, K, Bias) ->
    case decode_digit(C) of
        failure -> failure;
        D ->
            I1 = I + D * W,
            T = threshold(K, Bias),
            case D < T of
                true -> {I1, Rest};
                false -> decode_number(Rest, I1, W * (?BASE - T), K + ?BASE, Bias)
            end
    end.

decode_digit(C) when C >= $a, C =< $z -> C - $a;
decode_digit(C) when C >= $A, C =< $Z -> C - $A;
decode_digit(C) when C >= $0, C =< $9 -> C - $0 + 26;
decode_digit(_) -> failure.
