%% The HTTP/1 parser of llhttp 9.3.1, the version that Node 25.9.0 vendors in
%% deps/llhttp: the state machine of src/llhttp/http.ts and url.ts, and the
%% helpers of src/native/http.c and api.c. Each clause of node/4 is a node of
%% http.ts, with the same transitions, errors, reasons, and error positions,
%% so `bytesParsed` and the codes of Node's parse errors match.
%%
%% Bun vendors llhttp as C and ports node_http_parser.cc over it
%% (src/jsc/bindings/node/http). BEAM loads no C into the VM here, so this is
%% the same state machine in Erlang: binary matching keeps each node a tail
%% call, and the bulk of a body or a header value moves as one sub-binary.
%%
%% execute/3 resumes the parse with the next bytes; the callback fun gets the
%% events that node_http_parser.cc registers: message_begin,
%% {headers_complete, Info}, message_complete, chunk_header, chunk_complete,
%% and the spans {url | status | header_field | header_value | body |
%% chunk_extension, Bytes}. A span callback returns ok, or {user, Code,
%% Reason} for HPE_USER; an event callback returns its integer result; error
%% stands for a callback that threw.
-module(buoy_llhttp).

-export([init/2, execute/3, finish/2, pause/1, resume/1, resume_after_upgrade/1]).
-export([error_of/1, upgrade/1, should_keep_alive/1, methods/0, all_methods/0]).

-export_type([parser/0, event/0]).

-define(F_CONNECTION_KEEP_ALIVE, 16#1).
-define(F_CONNECTION_CLOSE, 16#2).
-define(F_CONNECTION_UPGRADE, 16#4).
-define(F_CHUNKED, 16#8).
-define(F_UPGRADE, 16#10).
-define(F_CONTENT_LENGTH, 16#20).
-define(F_SKIPBODY, 16#40).
-define(F_TRAILING, 16#80).
-define(F_TRANSFER_ENCODING, 16#200).

-define(L_HEADERS, 16#1).
-define(L_CHUNKED_LENGTH, 16#2).
-define(L_KEEP_ALIVE, 16#4).
-define(L_TRANSFER_ENCODING, 16#8).
-define(L_VERSION, 16#10).
-define(L_DATA_AFTER_CLOSE, 16#20).
-define(L_OPTIONAL_LF_AFTER_CR, 16#40).
-define(L_OPTIONAL_CRLF_AFTER_CHUNK, 16#80).
-define(L_OPTIONAL_CR_BEFORE_LF, 16#100).
-define(L_SPACES_AFTER_CHUNK_SIZE, 16#200).

-define(H_GENERAL, 0).
-define(H_CONNECTION, 1).
-define(H_CONTENT_LENGTH, 2).
-define(H_TRANSFER_ENCODING, 3).
-define(H_UPGRADE, 4).
-define(H_CONNECTION_KEEP_ALIVE, 5).
-define(H_CONNECTION_CLOSE, 6).
-define(H_CONNECTION_UPGRADE, 7).
-define(H_TRANSFER_ENCODING_CHUNKED, 8).

-define(FINISH_SAFE, 0).
-define(FINISH_SAFE_WITH_CB, 1).
-define(FINISH_UNSAFE, 2).

-define(CONNECT, 5).
-define(PRI, 34).
-define(MAX_U64, 16#FFFFFFFFFFFFFFFF).

-define(IS_ALPHA(C), ((C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z))).
-define(IS_DIGIT(C), (C >= $0 andalso C =< $9)).
%% URL_CHAR: VCHAR without '#' and '?'.
-define(IS_URL_CHAR(C), (C >= 16#21 andalso C =< 16#7e andalso C =/= $# andalso C =/= $?)).
%% HTAB, SP, VCHAR, and obs-text.
-define(IS_HEADER_CHAR(C), (C =:= $\t orelse (C >= 16#20 andalso C =/= 16#7f))).
-define(IS_CONNECTION_TOKEN_CHAR(C), (?IS_HEADER_CHAR(C) andalso C =/= $,)).
-define(IS_QDTEXT(C), (?IS_HEADER_CHAR(C) andalso C =/= $" andalso C =/= $\\)).

-record(ll, {type :: request | response,
             node = start :: term(),
             method = 0 :: non_neg_integer(),
             major = 0 :: non_neg_integer(),
             minor = 0 :: non_neg_integer(),
             status = 0 :: non_neg_integer(),
             content_length = 0 :: non_neg_integer(),
             flags = 0 :: non_neg_integer(),
             header_state = 0 :: non_neg_integer(),
             lenient = 0 :: non_neg_integer(),
             upgrade = 0 :: 0 | 1,
             finish = ?FINISH_SAFE :: 0 | 1 | 2,
             initial = 0 :: 0 | 1,
             error = ok :: ok | binary(),
             reason = <<>> :: binary(),
             error_pos = 0 :: non_neg_integer(),
             span = none :: none | {atom(), non_neg_integer()}}).

-record(c, {data :: binary(), len :: non_neg_integer(), cb :: fun((event()) -> term())}).

-opaque parser() :: #ll{}.
-type event() :: message_begin | message_complete | chunk_header | chunk_complete
               | {headers_complete, map()} | {atom(), binary()}.

%%% The API of api.c

%% llhttp_init with the lenient flags of llhttp_set_lenient_*.
-spec init(request | response, non_neg_integer()) -> parser().
init(Type, Lenient) -> #ll{type = Type, lenient = Lenient}.

%% llhttp_execute: {ok, Parser}, or {error, Parser} with error_of/1 set.
-spec execute(parser(), binary(), fun((event()) -> term())) -> {ok | error, parser()}.
execute(#ll{error = E} = LL, _, _) when E =/= ok ->
    {error, LL};
execute(LL0, Data, Cb) ->
    %% A span open at the end of the last call restarts at the new data.
    LL = case LL0#ll.span of
        none -> LL0;
        {Kind, _} -> LL0#ll{span = {Kind, 0}}
    end,
    C = #c{data = Data, len = byte_size(Data), cb = Cb},
    case node(LL#ll.node, Data, LL, C) of
        {more, #ll{span = {_, _} = Span} = LL1} ->
            %% The span stays open: the next call continues it.
            case span_end(<<>>, LL1, C) of
                {ok, LL2} -> {ok, LL2#ll{span = Span}};
                Error -> Error
            end;
        {more, LL1} ->
            {ok, LL1};
        {error, _} = Error ->
            Error
    end.

%% llhttp_finish, at the end of the input.
-spec finish(parser(), fun((event()) -> term())) -> {ok | error, parser()}.
finish(#ll{error = E} = LL, _) when E =/= ok -> {ok, LL};
finish(#ll{finish = ?FINISH_SAFE} = LL, _) -> {ok, LL};
finish(#ll{finish = ?FINISH_SAFE_WITH_CB} = LL, Cb) ->
    case Cb(message_complete) of
        0 -> {ok, LL};
        _ -> {error, LL#ll{error = <<"HPE_CB_MESSAGE_COMPLETE">>, reason = <<"`on_message_complete` callback error">>}}
    end;
finish(LL, _) ->
    {error, LL#ll{error = <<"HPE_INVALID_EOF_STATE">>, reason = <<"Invalid EOF state">>, error_pos = 0}}.

-spec pause(parser()) -> parser().
pause(#ll{error = ok} = LL) -> LL#ll{error = <<"HPE_PAUSED">>, reason = <<"Paused">>};
pause(LL) -> LL.

-spec resume(parser()) -> parser().
resume(#ll{error = <<"HPE_PAUSED">>} = LL) -> LL#ll{error = ok};
resume(LL) -> LL.

-spec resume_after_upgrade(parser()) -> parser().
resume_after_upgrade(#ll{error = <<"HPE_PAUSED_UPGRADE">>} = LL) -> LL#ll{error = ok};
resume_after_upgrade(LL) -> LL.

%% The error code, its reason, and the offset in the last data where it
%% happened, or ok.
-spec error_of(parser()) -> ok | {binary(), binary(), non_neg_integer()}.
error_of(#ll{error = ok}) -> ok;
error_of(#ll{error = E, reason = R, error_pos = P}) -> {E, R, P}.

-spec upgrade(parser()) -> boolean().
upgrade(#ll{upgrade = U}) -> U =:= 1.

%% llhttp_should_keep_alive of src/native/http.c.
-spec should_keep_alive(parser()) -> boolean().
should_keep_alive(#ll{major = Major, minor = Minor, flags = Flags} = LL) ->
    Persistent = case Major > 0 andalso Minor > 0 of
        true -> Flags band ?F_CONNECTION_CLOSE =:= 0;
        false -> Flags band ?F_CONNECTION_KEEP_ALIVE =/= 0
    end,
    Persistent andalso not needs_eof(LL).

%% HTTP_METHOD_MAP: the methods of HTTP, in the order of their numbers.
-spec methods() -> [binary()].
methods() ->
    [M || {M, N} <- method_numbers(), N =< 33 orelse N =:= 46].

%% HTTP_ALL_METHOD_MAP: every method, indexed by its number.
-spec all_methods() -> [binary()].
all_methods() ->
    [M || {M, _} <- lists:keysort(2, method_numbers())].

method_numbers() ->
    [{<<"DELETE">>, 0}, {<<"GET">>, 1}, {<<"HEAD">>, 2}, {<<"POST">>, 3}, {<<"PUT">>, 4}, {<<"CONNECT">>, 5},
     {<<"OPTIONS">>, 6}, {<<"TRACE">>, 7}, {<<"COPY">>, 8}, {<<"LOCK">>, 9}, {<<"MKCOL">>, 10}, {<<"MOVE">>, 11},
     {<<"PROPFIND">>, 12}, {<<"PROPPATCH">>, 13}, {<<"SEARCH">>, 14}, {<<"UNLOCK">>, 15}, {<<"BIND">>, 16},
     {<<"REBIND">>, 17}, {<<"UNBIND">>, 18}, {<<"ACL">>, 19}, {<<"REPORT">>, 20}, {<<"MKACTIVITY">>, 21},
     {<<"CHECKOUT">>, 22}, {<<"MERGE">>, 23}, {<<"M-SEARCH">>, 24}, {<<"NOTIFY">>, 25}, {<<"SUBSCRIBE">>, 26},
     {<<"UNSUBSCRIBE">>, 27}, {<<"PATCH">>, 28}, {<<"PURGE">>, 29}, {<<"MKCALENDAR">>, 30}, {<<"LINK">>, 31},
     {<<"UNLINK">>, 32}, {<<"SOURCE">>, 33}, {<<"PRI">>, 34}, {<<"DESCRIBE">>, 35}, {<<"ANNOUNCE">>, 36},
     {<<"SETUP">>, 37}, {<<"PLAY">>, 38}, {<<"PAUSE">>, 39}, {<<"TEARDOWN">>, 40}, {<<"GET_PARAMETER">>, 41},
     {<<"SET_PARAMETER">>, 42}, {<<"REDIRECT">>, 43}, {<<"RECORD">>, 44}, {<<"FLUSH">>, 45}, {<<"QUERY">>, 46}].

%%% The nodes of http.ts

node(start, <<>>, LL, _) -> more(start, LL);
node(start, <<Ch, R/binary>>, LL, C) when Ch =:= $\r; Ch =:= $\n -> node(start, R, LL, C);
node(start, Rest, LL, C) ->
    %% after_start
    case cb(C, message_begin) of
        0 ->
            LL1 = LL#ll{finish = ?FINISH_UNSAFE},
            case LL1#ll.type of
                request -> node({method, <<>>}, Rest, LL1, C);
                response -> node({res_protocol, <<>>}, Rest, LL1, C)
            end;
        _ ->
            cb_error(<<"HPE_CB_MESSAGE_BEGIN">>, <<"on_message_begin">>, Rest, LL, C)
    end;

%% Response line
node({res_protocol, Prefix}, Rest, LL, C) ->
    case select(protocols, Prefix, Rest, none) of
        {match, _, R} -> node(res_after_protocol, R, LL, C);
        {partial, P} -> more({res_protocol, P}, LL);
        {nomatch, R} -> error(<<"HPE_INVALID_CONSTANT">>, <<"Expected HTTP/, RTSP/ or ICE/">>, R, LL, C)
    end;
node(res_after_protocol, <<>>, LL, _) -> more(res_after_protocol, LL);
node(res_after_protocol, <<$/, R/binary>>, LL, C) -> node(res_http_major, R, LL, C);
node(res_after_protocol, Rest, LL, C) ->
    error(<<"HPE_INVALID_CONSTANT">>, <<"Expected HTTP/, RTSP/ or ICE/">>, Rest, LL, C);
node(res_http_major, <<>>, LL, _) -> more(res_http_major, LL);
node(res_http_major, <<D, R/binary>>, LL, C) when ?IS_DIGIT(D) -> node(res_http_dot, R, LL#ll{major = D - $0}, C);
node(res_http_major, Rest, LL, C) -> error(<<"HPE_INVALID_VERSION">>, <<"Invalid major version">>, Rest, LL, C);
node(res_http_dot, <<>>, LL, _) -> more(res_http_dot, LL);
node(res_http_dot, <<$., R/binary>>, LL, C) -> node(res_http_minor, R, LL, C);
node(res_http_dot, Rest, LL, C) -> error(<<"HPE_INVALID_VERSION">>, <<"Expected dot">>, Rest, LL, C);
node(res_http_minor, <<>>, LL, _) -> more(res_http_minor, LL);
node(res_http_minor, <<D, R/binary>>, LL, C) when ?IS_DIGIT(D) ->
    LL1 = LL#ll{minor = D - $0},
    case valid_version(LL1) of
        true -> node(res_after_version, R, LL1, C);
        false -> error(<<"HPE_INVALID_VERSION">>, <<"Invalid HTTP version">>, R, LL1, C)
    end;
node(res_http_minor, Rest, LL, C) -> error(<<"HPE_INVALID_VERSION">>, <<"Invalid minor version">>, Rest, LL, C);
node(res_after_version, <<>>, LL, _) -> more(res_after_version, LL);
node(res_after_version, <<$\s, R/binary>>, LL, C) -> node({res_status_code, 3}, R, LL#ll{status = 0}, C);
node(res_after_version, Rest, LL, C) -> error(<<"HPE_INVALID_VERSION">>, <<"Expected space after version">>, Rest, LL, C);
node({res_status_code, 0}, Rest, LL, C) -> node(res_status_code_otherwise, Rest, LL, C);
node({res_status_code, _} = N, <<>>, LL, _) -> more(N, LL);
node({res_status_code, K}, <<D, R/binary>>, LL, C) when ?IS_DIGIT(D) ->
    node({res_status_code, K - 1}, R, LL#ll{status = LL#ll.status * 10 + D - $0}, C);
node({res_status_code, _}, Rest, LL, C) -> error(<<"HPE_INVALID_STATUS">>, <<"Invalid status code">>, Rest, LL, C);
node(res_status_code_otherwise, <<>>, LL, _) -> more(res_status_code_otherwise, LL);
node(res_status_code_otherwise, <<$\s, R/binary>>, LL, C) -> node(res_status_start, R, LL, C);
node(res_status_code_otherwise, <<$\r, R/binary>>, LL, C) -> node(res_line_almost_done, R, LL, C);
node(res_status_code_otherwise, <<$\n, R/binary>>, LL, C) ->
    case lenient(LL, ?L_OPTIONAL_CR_BEFORE_LF) of
        true -> node(headers_start, R, LL, C);
        false -> error(<<"HPE_INVALID_STATUS">>, <<"Invalid response status">>, R, LL, C)
    end;
node(res_status_code_otherwise, Rest, LL, C) -> error(<<"HPE_INVALID_STATUS">>, <<"Invalid response status">>, Rest, LL, C);
node(res_status_start, <<>>, LL, _) -> more(res_status_start, LL);
node(res_status_start, Rest, LL, C) -> node(res_status, Rest, span_start(status, Rest, LL, C), C);
node(res_status, Rest, LL, C) ->
    case scan_status(Rest) of
        <<>> -> more(res_status, LL);
        <<$\r, R/binary>> = At ->
            then(span_end(At, LL, C), fun(LL1) -> node(res_line_almost_done, R, LL1, C) end);
        <<$\n, R/binary>> = At ->
            then(span_end(At, LL, C), fun(LL1) ->
                case lenient(LL1, ?L_OPTIONAL_CR_BEFORE_LF) of
                    true -> node(headers_start, R, LL1, C);
                    false -> error(<<"HPE_CR_EXPECTED">>, <<"Missing expected CR after response line">>, R, LL1, C)
                end
            end)
    end;
node(res_line_almost_done, <<>>, LL, _) -> more(res_line_almost_done, LL);
node(res_line_almost_done, <<Ch, R/binary>>, LL, C) when Ch =:= $\r; Ch =:= $\n -> node(headers_start, R, LL, C);
node(res_line_almost_done, Rest, LL, C) ->
    case lenient(LL, ?L_OPTIONAL_LF_AFTER_CR) of
        true -> node(headers_start, Rest, LL, C);
        false -> error(<<"HPE_STRICT">>, <<"Expected LF after CR">>, Rest, LL, C)
    end;

%% Request line
node({method, Prefix}, Rest, LL, C) ->
    case select(methods, Prefix, Rest, none) of
        {match, M, R} -> node(req_first_space_before_url, R, LL#ll{method = M}, C);
        {partial, P} -> more({method, P}, LL);
        {nomatch, R} -> error(<<"HPE_INVALID_METHOD">>, <<"Invalid method encountered">>, R, LL, C)
    end;
node(req_first_space_before_url, <<>>, LL, _) -> more(req_first_space_before_url, LL);
node(req_first_space_before_url, <<$\s, R/binary>>, LL, C) -> node(req_spaces_before_url, R, LL, C);
node(req_first_space_before_url, Rest, LL, C) -> error(<<"HPE_INVALID_METHOD">>, <<"Expected space after method">>, Rest, LL, C);
node(req_spaces_before_url, <<>>, LL, _) -> more(req_spaces_before_url, LL);
node(req_spaces_before_url, <<$\s, R/binary>>, LL, C) -> node(req_spaces_before_url, R, LL, C);
node(req_spaces_before_url, Rest, #ll{method = ?CONNECT} = LL, C) -> node(url_server, Rest, span_start(url, Rest, LL, C), C);
node(req_spaces_before_url, Rest, LL, C) -> node(url_start, Rest, span_start(url, Rest, LL, C), C);

%% URL (url.ts): each node rejects HTAB and FF.
node(Url, <<Ch, R/binary>>, LL, C)
  when (Ch =:= $\t orelse Ch =:= $\f),
       (Url =:= url_start orelse Url =:= url_schema orelse Url =:= url_server orelse Url =:= url_server_with_at
        orelse Url =:= url_path orelse Url =:= url_query_or_fragment orelse Url =:= url_query
        orelse Url =:= url_fragment orelse (is_tuple(Url) andalso element(1, Url) =:= url_schema_delim)) ->
    error(<<"HPE_INVALID_URL">>, <<"Invalid characters in url">>, R, LL, C);
node(url_start, <<>>, LL, _) -> more(url_start, LL);
node(url_start, <<Ch, R/binary>>, LL, C) when Ch =:= $/; Ch =:= $* -> node(url_path, R, LL, C);
node(url_start, <<Ch, _/binary>> = Rest, LL, C) when ?IS_ALPHA(Ch) -> node(url_schema, Rest, LL, C);
node(url_start, <<Ch, R/binary>>, LL, C) when Ch =:= $\s; Ch =:= $\r; Ch =:= $\n ->
    error(<<"HPE_INVALID_URL">>, <<"Invalid characters in url">>, R, LL, C);
node(url_start, Rest, LL, C) -> error(<<"HPE_INVALID_URL">>, <<"Unexpected start char in url">>, Rest, LL, C);
node(url_schema, <<>>, LL, _) -> more(url_schema, LL);
node(url_schema, <<Ch, R/binary>>, LL, C) when ?IS_ALPHA(Ch) -> node(url_schema, R, LL, C);
node(url_schema, <<$:, R/binary>>, LL, C) -> node({url_schema_delim, <<>>}, R, LL, C);
node(url_schema, <<Ch, R/binary>>, LL, C) when Ch =:= $\s; Ch =:= $\r; Ch =:= $\n ->
    error(<<"HPE_INVALID_URL">>, <<"Invalid characters in url">>, R, LL, C);
node(url_schema, Rest, LL, C) -> error(<<"HPE_INVALID_URL">>, <<"Unexpected char in url schema">>, Rest, LL, C);
node({url_schema_delim, <<>>}, <<Ch, R/binary>>, LL, C) when Ch =:= $\s; Ch =:= $\r; Ch =:= $\n ->
    error(<<"HPE_INVALID_URL">>, <<"Invalid characters in url">>, R, LL, C);
node({url_schema_delim, Prefix}, Rest, LL, C) ->
    case select(double_slash, Prefix, Rest, none) of
        {match, _, R} -> node(url_server, R, LL, C);
        {partial, P} -> more({url_schema_delim, P}, LL);
        {nomatch, R} -> error(<<"HPE_INVALID_URL">>, <<"Unexpected char in url schema">>, R, LL, C)
    end;
node(Server, <<>>, LL, _) when Server =:= url_server; Server =:= url_server_with_at -> more(Server, LL);
node(Server, <<$/, R/binary>>, LL, C) when Server =:= url_server; Server =:= url_server_with_at -> node(url_path, R, LL, C);
node(Server, <<$?, R/binary>>, LL, C) when Server =:= url_server; Server =:= url_server_with_at -> node(url_query, R, LL, C);
node(url_server, <<$@, R/binary>>, LL, C) -> node(url_server_with_at, R, LL, C);
node(url_server_with_at, <<$@, R/binary>>, LL, C) -> error(<<"HPE_INVALID_URL">>, <<"Double @ in url">>, R, LL, C);
node(Server, <<Ch, R/binary>>, LL, C) when Server =:= url_server; Server =:= url_server_with_at ->
    case is_userinfo(Ch) orelse Ch =:= $[ orelse Ch =:= $] of
        true -> node(url_server, R, LL, C);
        false -> url_end(Server, <<Ch, R/binary>>, LL, C, <<"Unexpected char in url server">>)
    end;
node(url_path, Rest, LL, C) ->
    case scan_url(Rest) of
        <<>> -> more(url_path, LL);
        R -> node(url_query_or_fragment, R, LL, C)
    end;
node(url_query_or_fragment, <<>>, LL, _) -> more(url_query_or_fragment, LL);
node(url_query_or_fragment, <<$?, R/binary>>, LL, C) -> node(url_query, R, LL, C);
node(url_query_or_fragment, <<$#, R/binary>>, LL, C) -> node(url_fragment, R, LL, C);
node(url_query_or_fragment, Rest, LL, C) -> url_end(url_query_or_fragment, Rest, LL, C, <<"Invalid char in url path">>);
node(url_query, Rest, LL, C) ->
    case scan_query(Rest) of
        <<>> -> more(url_query, LL);
        <<$#, R/binary>> -> node(url_fragment, R, LL, C);
        R -> url_end(url_query, R, LL, C, <<"Invalid char in url query">>)
    end;
node(url_fragment, Rest, LL, C) ->
    case scan_fragment(Rest) of
        <<>> -> more(url_fragment, LL);
        R -> url_end(url_fragment, R, LL, C, <<"Invalid char in url fragment start">>)
    end;
node(url_skip_to_http, <<>>, LL, _) -> more(url_skip_to_http, LL);
node(url_skip_to_http, <<_, R/binary>>, LL, C) -> node(req_http_start, R, LL, C);
node(url_skip_to_http09, <<>>, LL, _) -> more(url_skip_to_http09, LL);
node(url_skip_to_http09, <<_, R/binary>>, LL, C) -> node(headers_start, R, LL#ll{major = 0, minor = 9}, C);
node({url_skip_lf_to_http09, Prefix}, Rest, LL, C) ->
    case select(crlf, Prefix, Rest, none) of
        {match, _, R} -> node(headers_start, R, LL#ll{major = 0, minor = 9}, C);
        {partial, P} -> more({url_skip_lf_to_http09, P}, LL);
        {nomatch, R} -> error(<<"HPE_INVALID_URL">>, <<"Expected CRLF">>, R, LL, C)
    end;

node(req_http_start, <<>>, LL, _) -> more(req_http_start, LL);
node(req_http_start, <<$\s, R/binary>>, LL, C) -> node(req_http_start, R, LL, C);
node(req_http_start, Rest, LL, C) -> node({req_protocol, <<>>}, Rest, LL, C);
node({req_protocol, Prefix}, Rest, LL, C) ->
    case select(protocols, Prefix, Rest, none) of
        {match, Protocol, R} ->
            case lists:member(LL#ll.method, protocol_methods(Protocol)) of
                true -> node(req_after_protocol, R, LL, C);
                false -> error(<<"HPE_INVALID_CONSTANT">>, protocol_error(Protocol), R, LL, C)
            end;
        {partial, P} -> more({req_protocol, P}, LL);
        {nomatch, R} -> error(<<"HPE_INVALID_CONSTANT">>, <<"Expected HTTP/, RTSP/ or ICE/">>, R, LL, C)
    end;
node(req_after_protocol, <<>>, LL, _) -> more(req_after_protocol, LL);
node(req_after_protocol, <<$/, R/binary>>, LL, C) -> node(req_http_major, R, LL, C);
node(req_after_protocol, Rest, LL, C) -> error(<<"HPE_INVALID_CONSTANT">>, <<"Expected HTTP/, RTSP/ or ICE/">>, Rest, LL, C);
node(req_http_major, <<>>, LL, _) -> more(req_http_major, LL);
node(req_http_major, <<D, R/binary>>, LL, C) when ?IS_DIGIT(D) -> node(req_http_dot, R, LL#ll{major = D - $0}, C);
node(req_http_major, Rest, LL, C) -> error(<<"HPE_INVALID_VERSION">>, <<"Invalid major version">>, Rest, LL, C);
node(req_http_dot, <<>>, LL, _) -> more(req_http_dot, LL);
node(req_http_dot, <<$., R/binary>>, LL, C) -> node(req_http_minor, R, LL, C);
node(req_http_dot, Rest, LL, C) -> error(<<"HPE_INVALID_VERSION">>, <<"Expected dot">>, Rest, LL, C);
node(req_http_minor, <<>>, LL, _) -> more(req_http_minor, LL);
node(req_http_minor, <<D, R/binary>>, LL, C) when ?IS_DIGIT(D) ->
    LL1 = LL#ll{minor = D - $0},
    case {valid_version(LL1), LL1#ll.method} of
        {false, _} -> error(<<"HPE_INVALID_VERSION">>, <<"Invalid HTTP version">>, R, LL1, C);
        {true, ?PRI} -> node({req_pri_upgrade, <<>>}, R, LL1, C);
        {true, _} -> node(req_http_complete, R, LL1, C)
    end;
node(req_http_minor, Rest, LL, C) -> error(<<"HPE_INVALID_VERSION">>, <<"Invalid minor version">>, Rest, LL, C);
node(req_http_complete, <<>>, LL, _) -> more(req_http_complete, LL);
node(req_http_complete, <<$\r, R/binary>>, LL, C) -> node(req_http_complete_crlf, R, LL, C);
node(req_http_complete, <<$\n, R/binary>>, LL, C) ->
    case lenient(LL, ?L_OPTIONAL_CR_BEFORE_LF) of
        true -> node(req_http_complete_crlf, R, LL, C);
        false -> error(<<"HPE_INVALID_VERSION">>, <<"Expected CRLF after version">>, R, LL, C)
    end;
node(req_http_complete, Rest, LL, C) -> error(<<"HPE_INVALID_VERSION">>, <<"Expected CRLF after version">>, Rest, LL, C);
node(req_http_complete_crlf, <<>>, LL, _) -> more(req_http_complete_crlf, LL);
node(req_http_complete_crlf, <<$\n, R/binary>>, LL, C) -> node(headers_start, R, LL, C);
node(req_http_complete_crlf, Rest, LL, C) ->
    case lenient(LL, ?L_OPTIONAL_LF_AFTER_CR) of
        true -> node(headers_start, Rest, LL, C);
        false -> error(<<"HPE_STRICT">>, <<"Expected CRLF after version">>, Rest, LL, C)
    end;
node({req_pri_upgrade, Prefix}, Rest, LL, C) ->
    case select(h2_preface, Prefix, Rest, none) of
        {match, _, R} -> error(<<"HPE_PAUSED_H2_UPGRADE">>, <<"Pause on PRI/Upgrade">>, R, LL, C);
        {partial, P} -> more({req_pri_upgrade, P}, LL);
        {nomatch, R} -> error(<<"HPE_INVALID_VERSION">>, <<"Expected HTTP/2 Connection Preface">>, R, LL, C)
    end;

%% Header fields
node(headers_start, <<>>, LL, _) -> more(headers_start, LL);
node(headers_start, <<$\s, R/binary>>, LL, C) ->
    case lenient(LL, ?L_HEADERS) of
        true -> node(header_field_start, R, LL, C);
        false -> error(<<"HPE_UNEXPECTED_SPACE">>, <<"Unexpected space after start line">>, R, LL, C)
    end;
node(headers_start, Rest, LL, C) -> node(header_field_start, Rest, LL, C);
node(header_field_start, <<>>, LL, _) -> more(header_field_start, LL);
node(header_field_start, <<$\r, R/binary>>, LL, C) -> node(headers_almost_done, R, LL, C);
node(header_field_start, <<$\n, R/binary>>, LL, C) ->
    case lenient(LL, ?L_OPTIONAL_CR_BEFORE_LF) of
        true -> headers_end(R, LL, C);
        false -> error(<<"HPE_INVALID_HEADER_TOKEN">>, <<"Invalid header field char">>, R, LL, C)
    end;
node(header_field_start, <<$:, _/binary>> = Rest, LL, C) ->
    error(<<"HPE_INVALID_HEADER_TOKEN">>, <<"Invalid header token">>, Rest, LL, C);
node(header_field_start, Rest, LL, C) ->
    node({header_field, <<>>}, Rest, span_start(header_field, Rest, LL, C), C);
node({header_field, Prefix}, Rest, LL, C) ->
    case select(special_headers, Prefix, Rest, lower) of
        {match, State, R} -> node(header_field_colon, R, LL#ll{header_state = State}, C);
        {partial, P} -> more({header_field, P}, LL);
        {nomatch, R} -> node(header_field_general, R, LL#ll{header_state = ?H_GENERAL}, C)
    end;
node(header_field_colon, <<>>, LL, _) -> more(header_field_colon, LL);
node(header_field_colon, <<$\s, R/binary>> = Rest, LL, C) ->
    case lenient(LL, ?L_HEADERS) of
        true -> node(header_field_colon_discard_ws, Rest, LL, C);
        false -> then(span_end(Rest, LL, C), fun(LL1) ->
                     error(<<"HPE_INVALID_HEADER_TOKEN">>, <<"Invalid header field char">>, R, LL1, C)
                 end)
    end;
node(header_field_colon, <<$:, R/binary>> = Rest, LL, C) ->
    then(span_end(Rest, LL, C), fun(LL1) -> header_field_complete(R, LL1, C) end);
node(header_field_colon, Rest, LL, C) -> node(header_field_general, Rest, LL#ll{header_state = ?H_GENERAL}, C);
node(header_field_colon_discard_ws, <<>>, LL, _) -> more(header_field_colon_discard_ws, LL);
node(header_field_colon_discard_ws, <<$\s, R/binary>>, LL, C) -> node(header_field_colon_discard_ws, R, LL, C);
node(header_field_colon_discard_ws, Rest, LL, C) -> node(header_field_colon, Rest, LL, C);
node(header_field_general, Rest, LL, C) ->
    case scan_token(Rest) of
        <<>> -> more(header_field_general, LL);
        <<$:, R/binary>> = At -> then(span_end(At, LL, C), fun(LL1) -> header_field_complete(R, LL1, C) end);
        At -> error(<<"HPE_INVALID_HEADER_TOKEN">>, <<"Invalid header token">>, At, LL, C)
    end;

%% Header values
node(header_value_discard_ws, <<>>, LL, _) -> more(header_value_discard_ws, LL);
node(header_value_discard_ws, <<Ch, R/binary>>, LL, C) when Ch =:= $\s; Ch =:= $\t -> node(header_value_discard_ws, R, LL, C);
node(header_value_discard_ws, <<$\r, R/binary>>, LL, C) -> node(header_value_discard_ws_almost_done, R, LL, C);
node(header_value_discard_ws, <<$\n, R/binary>>, LL, C) ->
    case lenient(LL, ?L_OPTIONAL_CR_BEFORE_LF) of
        true -> node(header_value_discard_lws, R, LL, C);
        false -> error(<<"HPE_INVALID_HEADER_TOKEN">>, <<"Invalid header value char">>, R, LL, C)
    end;
node(header_value_discard_ws, Rest, LL, C) -> header_value_start(Rest, span_start(header_value, Rest, LL, C), C);
node(header_value_discard_ws_almost_done, <<>>, LL, _) -> more(header_value_discard_ws_almost_done, LL);
node(header_value_discard_ws_almost_done, <<$\n, R/binary>>, LL, C) -> node(header_value_discard_lws, R, LL, C);
node(header_value_discard_ws_almost_done, Rest, LL, C) ->
    case lenient(LL, ?L_HEADERS) of
        true -> node(header_value_discard_lws, Rest, LL, C);
        false -> error(<<"HPE_STRICT">>, <<"Expected LF after CR">>, Rest, LL, C)
    end;
node(header_value_discard_lws, <<>>, LL, _) -> more(header_value_discard_lws, LL);
node(header_value_discard_lws, <<Ch, R/binary>>, LL, C) when Ch =:= $\s; Ch =:= $\t ->
    case lenient(LL, ?L_HEADERS) of
        true -> node(header_value_discard_ws, R, LL, C);
        false -> error(<<"HPE_INVALID_HEADER_TOKEN">>, <<"Invalid header value char">>, R, LL, C)
    end;
node(header_value_discard_lws, Rest, #ll{header_state = ?H_CONTENT_LENGTH} = LL, C) ->
    error(<<"HPE_INVALID_CONTENT_LENGTH">>, <<"Empty Content-Length">>, Rest, LL, C);
node(header_value_discard_lws, Rest, LL, C) ->
    LL1 = set_header_flags(LL),
    then(span_end(Rest, span_start(header_value, Rest, LL1, C), C), fun(LL2) -> node(header_field_start, Rest, LL2, C) end);

%% Transfer-Encoding
node({header_value_te_chunked, Prefix}, Rest, LL, C) ->
    case select(chunked, Prefix, Rest, unsafe) of
        {match, _, R} -> node(header_value_te_chunked_last, R, LL, C);
        {partial, P} -> more({header_value_te_chunked, P}, LL);
        {nomatch, R} -> node(header_value_te_token, R, LL, C)
    end;
node(header_value_te_chunked_last, <<>>, LL, _) -> more(header_value_te_chunked_last, LL);
node(header_value_te_chunked_last, <<$\s, R/binary>>, LL, C) -> node(header_value_te_chunked_last, R, LL, C);
node(header_value_te_chunked_last, <<Ch, _/binary>> = Rest, LL, C) when Ch =:= $\r; Ch =:= $\n ->
    node(header_value_otherwise, Rest, LL#ll{header_state = ?H_TRANSFER_ENCODING_CHUNKED}, C);
node(header_value_te_chunked_last, <<$,, _/binary>> = Rest, LL, C) ->
    forbid_after_chunked(Rest, LL, C, fun(LL1) -> node({header_value_te_chunked, <<>>}, Rest, LL1, C) end);
node(header_value_te_chunked_last, Rest, LL, C) -> node(header_value_te_token, Rest, LL, C);
node(header_value_te_token, <<>>, LL, _) -> more(header_value_te_token, LL);
node(header_value_te_token, <<$,, R/binary>>, LL, C) -> node(header_value_te_token_ows, R, LL, C);
node(header_value_te_token, <<Ch, R/binary>>, LL, C) when ?IS_CONNECTION_TOKEN_CHAR(Ch) -> node(header_value_te_token, R, LL, C);
node(header_value_te_token, Rest, LL, C) -> node(header_value, Rest, LL#ll{header_state = ?H_GENERAL}, C);
node(header_value_te_token_ows, <<>>, LL, _) -> more(header_value_te_token_ows, LL);
node(header_value_te_token_ows, <<Ch, R/binary>>, LL, C) when Ch =:= $\s; Ch =:= $\t -> node(header_value_te_token_ows, R, LL, C);
node(header_value_te_token_ows, Rest, LL, C) -> node({header_value_te_chunked, <<>>}, Rest, LL, C);

%% Content-Length
node(header_value_content_length, <<>>, LL, _) -> more(header_value_content_length, LL);
node(header_value_content_length, <<D, R/binary>>, LL, C) when ?IS_DIGIT(D) ->
    case LL#ll.content_length * 10 + D - $0 of
        N when N > ?MAX_U64 ->
            then(span_end(R, LL, C), fun(LL1) ->
                error(<<"HPE_INVALID_CONTENT_LENGTH">>, <<"Content-Length overflow">>, R, LL1, C)
            end);
        N ->
            node(header_value_content_length, R, LL#ll{content_length = N}, C)
    end;
node(header_value_content_length, Rest, LL, C) -> node(header_value_content_length_ws, Rest, LL, C);
node(header_value_content_length_ws, <<>>, LL, _) -> more(header_value_content_length_ws, LL);
node(header_value_content_length_ws, <<$\s, R/binary>>, LL, C) -> node(header_value_content_length_ws, R, LL, C);
node(header_value_content_length_ws, <<Ch, _/binary>> = Rest, LL, C) when Ch =:= $\r; Ch =:= $\n ->
    node(header_value_otherwise, Rest, set_flag(LL, ?F_CONTENT_LENGTH), C);
node(header_value_content_length_ws, Rest, LL, C) ->
    then(span_end(Rest, LL, C), fun(LL1) ->
        error(<<"HPE_INVALID_CONTENT_LENGTH">>, <<"Invalid character in Content-Length">>, Rest, LL1, C)
    end);

%% Connection
node({header_value_connection, <<>>}, <<Ch, R/binary>>, LL, C) when Ch =:= $\s; Ch =:= $\t ->
    node({header_value_connection, <<>>}, R, LL, C);
node({header_value_connection, Prefix}, Rest, LL, C) ->
    case select(connection, Prefix, Rest, lower) of
        {match, State, R} -> node(header_value_connection_ws, R, LL#ll{header_state = State}, C);
        {partial, P} -> more({header_value_connection, P}, LL);
        {nomatch, R} -> node(header_value_connection_token, R, LL, C)
    end;
node(header_value_connection_ws, <<>>, LL, _) -> more(header_value_connection_ws, LL);
node(header_value_connection_ws, <<$,, R/binary>>, LL, C) ->
    node({header_value_connection, <<>>}, R, set_header_flags(LL), C);
node(header_value_connection_ws, <<$\s, R/binary>>, LL, C) -> node(header_value_connection_ws, R, LL, C);
node(header_value_connection_ws, <<Ch, _/binary>> = Rest, LL, C) when Ch =:= $\r; Ch =:= $\n ->
    node(header_value_otherwise, Rest, LL, C);
node(header_value_connection_ws, Rest, LL, C) ->
    node(header_value_connection_token, Rest, LL#ll{header_state = ?H_GENERAL}, C);
node(header_value_connection_token, <<>>, LL, _) -> more(header_value_connection_token, LL);
node(header_value_connection_token, <<$,, R/binary>>, LL, C) -> node({header_value_connection, <<>>}, R, LL, C);
node(header_value_connection_token, <<Ch, R/binary>>, LL, C) when ?IS_CONNECTION_TOKEN_CHAR(Ch) ->
    node(header_value_connection_token, R, LL, C);
node(header_value_connection_token, Rest, LL, C) -> node(header_value_otherwise, Rest, LL, C);

node(header_value, Rest, LL, C) ->
    case scan_header_value(Rest) of
        <<>> -> more(header_value, LL);
        R -> node(header_value_otherwise, R, LL, C)
    end;
node(header_value_otherwise, <<>>, LL, _) -> more(header_value_otherwise, LL);
node(header_value_otherwise, <<$\r, R/binary>> = Rest, LL, C) ->
    then(span_end(Rest, LL, C), fun(LL1) -> node(header_value_almost_done, R, LL1, C) end);
node(header_value_otherwise, <<$\n, _/binary>> = Rest, LL, C) ->
    then(span_end(Rest, LL, C), fun(LL1) ->
        case lenient(LL1, ?L_OPTIONAL_CR_BEFORE_LF) of
            true -> node(header_value_almost_done, Rest, LL1, C);
            false -> error(<<"HPE_CR_EXPECTED">>, <<"Missing expected CR after header value">>, Rest, LL1, C)
        end
    end);
node(header_value_otherwise, Rest, LL, C) ->
    case lenient(LL, ?L_HEADERS) of
        true -> node(header_value_lenient, Rest, LL, C);
        false -> then(span_end(Rest, LL, C), fun(LL1) ->
                     error(<<"HPE_INVALID_HEADER_TOKEN">>, <<"Invalid header value char">>, Rest, LL1, C)
                 end)
    end;
node(header_value_lenient, <<>>, LL, _) -> more(header_value_lenient, LL);
node(header_value_lenient, <<$\r, R/binary>> = Rest, LL, C) ->
    then(span_end(Rest, LL, C), fun(LL1) -> node(header_value_almost_done, R, LL1, C) end);
node(header_value_lenient, <<$\n, _/binary>> = Rest, LL, C) ->
    then(span_end(Rest, LL, C), fun(LL1) -> node(header_value_almost_done, Rest, LL1, C) end);
node(header_value_lenient, <<_, R/binary>>, LL, C) -> node(header_value_lenient, R, LL, C);
node(header_value_almost_done, <<>>, LL, _) -> more(header_value_almost_done, LL);
node(header_value_almost_done, <<$\n, R/binary>>, LL, C) -> node(header_value_lws, R, LL, C);
node(header_value_almost_done, Rest, LL, C) ->
    error(<<"HPE_LF_EXPECTED">>, <<"Missing expected LF after header value">>, Rest, LL, C);
node(header_value_lws, <<>>, LL, _) -> more(header_value_lws, LL);
node(header_value_lws, <<Ch, _/binary>> = Rest, LL, C) when Ch =:= $\s; Ch =:= $\t ->
    case lenient(LL, ?L_HEADERS) of
        true ->
            LL1 = case LL#ll.header_state of
                ?H_TRANSFER_ENCODING_CHUNKED -> LL#ll{header_state = ?H_GENERAL};
                _ -> LL
            end,
            header_value_start(Rest, span_start(header_value, Rest, LL1, C), C);
        false ->
            error(<<"HPE_INVALID_HEADER_TOKEN">>, <<"Unexpected whitespace after header value">>, Rest, LL, C)
    end;
node(header_value_lws, Rest, LL, C) -> node(header_field_start, Rest, set_header_flags(LL), C);

node(headers_almost_done, <<>>, LL, _) -> more(headers_almost_done, LL);
node(headers_almost_done, <<$\n, R/binary>>, LL, C) -> headers_end(R, LL, C);
node(headers_almost_done, Rest, LL, C) ->
    case lenient(LL, ?L_OPTIONAL_LF_AFTER_CR) of
        true -> headers_end(Rest, LL, C);
        false -> error(<<"HPE_STRICT">>, <<"Expected LF after headers">>, Rest, LL, C)
    end;

%% Bodies
node(body_identity, <<>>, LL, _) -> more(body_identity, LL);
node(body_identity, Rest, LL, C) -> node(consume_body, Rest, span_start(body, Rest, LL, C), C);
node(consume_body, Rest, #ll{content_length = N} = LL, C) when byte_size(Rest) >= N ->
    <<_:N/binary, R/binary>> = Rest,
    then(span_end(R, LL#ll{content_length = 0}, C), fun(LL1) -> message_done(R, LL1, C) end);
node(consume_body, Rest, #ll{content_length = N} = LL, _) ->
    more(consume_body, LL#ll{content_length = N - byte_size(Rest)});
node(body_identity_eof, <<>>, LL, _) -> more(body_identity_eof, LL);
node(body_identity_eof, Rest, LL, C) -> node(eof, <<>>, span_start(body, Rest, LL, C), C);
node(eof, _, LL, _) -> more(eof, LL);

node(chunk_size_digit, <<>>, LL, _) -> more(chunk_size_digit, LL);
node(chunk_size_digit, <<H, _/binary>> = Rest, LL, C) ->
    case hex(H) of
        error -> error(<<"HPE_INVALID_CHUNK_SIZE">>, <<"Invalid character in chunk size">>, Rest, LL, C);
        _ -> node(chunk_size, Rest, LL, C)
    end;
node(chunk_size, <<>>, LL, _) -> more(chunk_size, LL);
node(chunk_size, <<H, R/binary>> = Rest, LL, C) ->
    case hex(H) of
        error -> node(chunk_size_otherwise, Rest, LL, C);
        V ->
            case LL#ll.content_length * 16 + V of
                N when N > ?MAX_U64 -> error(<<"HPE_INVALID_CHUNK_SIZE">>, <<"Chunk size overflow">>, R, LL, C);
                N -> node(chunk_size, R, LL#ll{content_length = N}, C)
            end
    end;
node(chunk_size_otherwise, <<>>, LL, _) -> more(chunk_size_otherwise, LL);
node(chunk_size_otherwise, <<Ch, R/binary>>, LL, C) when Ch =:= $\s; Ch =:= $\t ->
    case lenient(LL, ?L_SPACES_AFTER_CHUNK_SIZE) of
        true -> node(chunk_size_otherwise, R, LL, C);
        false -> error(<<"HPE_INVALID_CHUNK_SIZE">>, <<"Invalid character in chunk size">>, R, LL, C)
    end;
node(chunk_size_otherwise, <<$\r, R/binary>>, LL, C) -> node(chunk_size_almost_done, R, LL, C);
node(chunk_size_otherwise, <<$\n, R/binary>>, LL, C) ->
    case lenient(LL, ?L_OPTIONAL_CR_BEFORE_LF) of
        true -> node(chunk_size_almost_done, R, LL, C);
        false -> error(<<"HPE_CR_EXPECTED">>, <<"Missing expected CR after chunk size">>, R, LL, C)
    end;
node(chunk_size_otherwise, <<$;, R/binary>>, LL, C) -> node(chunk_extensions, R, LL, C);
node(chunk_size_otherwise, Rest, LL, C) ->
    error(<<"HPE_INVALID_CHUNK_SIZE">>, <<"Invalid character in chunk size">>, Rest, LL, C);
node(chunk_extensions, <<>>, LL, _) -> more(chunk_extensions, LL);
node(chunk_extensions, <<Ch, R/binary>>, LL, C) when Ch =:= $\s; Ch =:= $\r ->
    error(<<"HPE_STRICT">>, <<"Invalid character in chunk extensions">>, R, LL, C);
node(chunk_extensions, Rest, LL, C) -> node(chunk_extension_name, Rest, span_start(chunk_extension, Rest, LL, C), C);
node(chunk_extension_name, Rest, LL, C) ->
    case scan_token(Rest) of
        <<>> -> more(chunk_extension_name, LL);
        <<$=, R/binary>> = At ->
            then(span_end(At, LL, C), fun(LL1) -> chunk_extension_value_start(R, LL1, C) end);
        <<$;, R/binary>> = At ->
            then(span_end(At, LL, C), fun(LL1) -> node(chunk_extensions, R, LL1, C) end);
        <<$\r, R/binary>> = At ->
            then(span_end(At, LL, C), fun(LL1) -> node(chunk_size_almost_done, R, LL1, C) end);
        <<$\n, _/binary>> = At ->
            then(span_end(At, LL, C), fun(LL1) -> chunk_lf(At, LL1, C, <<"Missing expected CR after chunk extension name">>) end);
        <<_, R/binary>> = At ->
            then(span_end(At, LL, C), fun(LL1) ->
                error(<<"HPE_STRICT">>, <<"Invalid character in chunk extensions name">>, R, LL1, C)
            end)
    end;
node(chunk_extension_value, <<>>, LL, _) -> more(chunk_extension_value, LL);
node(chunk_extension_value, <<$", R/binary>>, LL, C) -> node(chunk_extension_quoted_value, R, LL, C);
node(chunk_extension_value, Rest, LL, C) ->
    case scan_token(Rest) of
        <<>> -> more(chunk_extension_value, LL);
        <<$", _/binary>> = At -> node(chunk_extension_value, At, LL, C);
        <<$;, R/binary>> = At ->
            then(span_end(At, LL, C), fun(LL1) -> node(chunk_extensions, R, LL1, C) end);
        <<$\r, R/binary>> = At ->
            then(span_end(At, LL, C), fun(LL1) -> node(chunk_size_almost_done, R, LL1, C) end);
        <<$\n, _/binary>> = At ->
            then(span_end(At, LL, C), fun(LL1) -> chunk_lf(At, LL1, C, <<"Missing expected CR after chunk extension value">>) end);
        <<_, R/binary>> = At ->
            then(span_end(At, LL, C), fun(LL1) ->
                error(<<"HPE_STRICT">>, <<"Invalid character in chunk extensions value">>, R, LL1, C)
            end)
    end;
node(chunk_extension_quoted_value, <<>>, LL, _) -> more(chunk_extension_quoted_value, LL);
node(chunk_extension_quoted_value, <<Ch, R/binary>>, LL, C) when ?IS_QDTEXT(Ch) -> node(chunk_extension_quoted_value, R, LL, C);
node(chunk_extension_quoted_value, <<$", R/binary>>, LL, C) ->
    then(span_end(R, LL, C), fun(LL1) -> node(chunk_extension_quoted_value_done, R, LL1, C) end);
node(chunk_extension_quoted_value, <<$\\, R/binary>>, LL, C) -> node(chunk_extension_quoted_value_quoted_pair, R, LL, C);
node(chunk_extension_quoted_value, <<_, R/binary>> = Rest, LL, C) ->
    then(span_end(Rest, LL, C), fun(LL1) ->
        error(<<"HPE_STRICT">>, <<"Invalid character in chunk extensions quoted value">>, R, LL1, C)
    end);
node(chunk_extension_quoted_value_quoted_pair, <<>>, LL, _) -> more(chunk_extension_quoted_value_quoted_pair, LL);
node(chunk_extension_quoted_value_quoted_pair, <<Ch, R/binary>>, LL, C) when ?IS_HEADER_CHAR(Ch) ->
    node(chunk_extension_quoted_value, R, LL, C);
node(chunk_extension_quoted_value_quoted_pair, <<_, R/binary>> = Rest, LL, C) ->
    then(span_end(Rest, LL, C), fun(LL1) ->
        error(<<"HPE_STRICT">>, <<"Invalid quoted-pair in chunk extensions quoted value">>, R, LL1, C)
    end);
node(chunk_extension_quoted_value_done, <<>>, LL, _) -> more(chunk_extension_quoted_value_done, LL);
node(chunk_extension_quoted_value_done, <<$;, R/binary>>, LL, C) -> node(chunk_extensions, R, LL, C);
node(chunk_extension_quoted_value_done, <<$\r, R/binary>>, LL, C) -> node(chunk_size_almost_done, R, LL, C);
node(chunk_extension_quoted_value_done, <<$\n, _/binary>> = Rest, LL, C) ->
    chunk_lf(Rest, LL, C, <<"Missing expected CR after chunk extension value">>);
node(chunk_extension_quoted_value_done, Rest, LL, C) ->
    error(<<"HPE_STRICT">>, <<"Invalid character in chunk extensions quote value">>, Rest, LL, C);
node(chunk_size_almost_done, <<>>, LL, _) -> more(chunk_size_almost_done, LL);
node(chunk_size_almost_done, <<$\n, R/binary>>, LL, C) -> chunk_header(R, LL, C);
node(chunk_size_almost_done, Rest, LL, C) ->
    case lenient(LL, ?L_OPTIONAL_LF_AFTER_CR) of
        true -> chunk_header(Rest, LL, C);
        false -> error(<<"HPE_STRICT">>, <<"Expected LF after chunk size">>, Rest, LL, C)
    end;
node(chunk_data, <<>>, LL, _) -> more(chunk_data, LL);
node(chunk_data, Rest, LL, C) -> node(consume_chunk, Rest, span_start(body, Rest, LL, C), C);
node(consume_chunk, Rest, #ll{content_length = N} = LL, C) when byte_size(Rest) >= N ->
    <<_:N/binary, R/binary>> = Rest,
    then(span_end(R, LL#ll{content_length = 0}, C), fun(LL1) -> node({chunk_data_almost_done, <<>>}, R, LL1, C) end);
node(consume_chunk, Rest, #ll{content_length = N} = LL, _) ->
    more(consume_chunk, LL#ll{content_length = N - byte_size(Rest)});
node({chunk_data_almost_done, Prefix}, Rest, LL, C) ->
    case select(chunk_end, Prefix, Rest, none) of
        {match, crlf, R} -> chunk_complete(R, LL, C);
        {match, lf, R} ->
            case lenient(LL, ?L_OPTIONAL_CR_BEFORE_LF) of
                true -> chunk_complete(R, LL, C);
                false -> error(<<"HPE_CR_EXPECTED">>, <<"Missing expected CR after chunk data">>, R, LL, C)
            end;
        {partial, P} -> more({chunk_data_almost_done, P}, LL);
        {nomatch, R} ->
            case lenient(LL, ?L_OPTIONAL_CRLF_AFTER_CHUNK) of
                true -> chunk_complete(R, LL, C);
                false -> error(<<"HPE_STRICT">>, <<"Expected LF after chunk data">>, R, LL, C)
            end
    end;

node(closed, <<>>, LL, _) -> more(closed, LL);
node(closed, <<Ch, R/binary>>, LL, C) when Ch =:= $\r; Ch =:= $\n -> node(closed, R, LL, C);
node(closed, <<_, R/binary>>, LL, C) ->
    case lenient(LL, ?L_DATA_AFTER_CLOSE) of
        true -> node(closed, R, LL, C);
        false -> error(<<"HPE_CLOSED_CONNECTION">>, <<"Data after `Connection: close`">>, R, LL, C)
    end;
node(cleanup, Rest, LL, C) ->
    cleanup(Rest, LL, C).

%%% The invoke nodes

%% on_header_field_complete, and the checks of Transfer-Encoding against
%% Content-Length.
header_field_complete(Rest, #ll{header_state = ?H_TRANSFER_ENCODING, flags = F} = LL, C)
  when F band ?F_CONTENT_LENGTH =/= 0 ->
    case lenient(LL, ?L_CHUNKED_LENGTH) of
        false -> error(<<"HPE_INVALID_TRANSFER_ENCODING">>, <<"Transfer-Encoding can't be present with Content-Length">>, Rest, LL, C);
        true -> node(header_value_discard_ws, Rest, LL, C)
    end;
header_field_complete(Rest, #ll{header_state = ?H_CONTENT_LENGTH, flags = F} = LL, C)
  when F band ?F_TRANSFER_ENCODING =/= 0 ->
    case lenient(LL, ?L_CHUNKED_LENGTH) of
        false -> error(<<"HPE_INVALID_CONTENT_LENGTH">>, <<"Content-Length can't be present with Transfer-Encoding">>, Rest, LL, C);
        true -> node(header_value_discard_ws, Rest, LL, C)
    end;
header_field_complete(Rest, LL, C) ->
    node(header_value_discard_ws, Rest, LL, C).

header_value_start(Rest, #ll{header_state = ?H_UPGRADE} = LL, C) ->
    node(header_value, Rest, (set_flag(LL, ?F_UPGRADE))#ll{header_state = ?H_GENERAL}, C);
header_value_start(Rest, #ll{header_state = ?H_TRANSFER_ENCODING, flags = F} = LL, C) ->
    ToTransferEncoding = fun(LL1) ->
        LL2 = set_flag(LL1, ?F_TRANSFER_ENCODING),
        node({header_value_te_chunked, <<>>}, Rest, LL2#ll{flags = LL2#ll.flags band bnot ?F_CHUNKED}, C)
    end,
    case F band ?F_CHUNKED of
        0 -> ToTransferEncoding(LL);
        _ -> forbid_after_chunked(Rest, LL, C, ToTransferEncoding)
    end;
header_value_start(Rest, #ll{header_state = ?H_CONTENT_LENGTH, flags = F} = LL, C) ->
    case F band ?F_CONTENT_LENGTH of
        0 -> node(header_value_content_length, Rest, LL, C);
        _ -> error(<<"HPE_UNEXPECTED_CONTENT_LENGTH">>, <<"Duplicate Content-Length">>, Rest, LL, C)
    end;
header_value_start(Rest, #ll{header_state = ?H_CONNECTION} = LL, C) ->
    node({header_value_connection, <<>>}, Rest, LL, C);
header_value_start(Rest, LL, C) ->
    node(header_value, Rest, LL, C).

%% Once chunked is set, a request takes no other transfer coding.
forbid_after_chunked(Rest, #ll{type = request} = LL, C, Otherwise) ->
    case lenient(LL, ?L_TRANSFER_ENCODING) of
        false ->
            <<_, R/binary>> = Rest,
            then(span_end(Rest, LL, C), fun(LL1) ->
                error(<<"HPE_INVALID_TRANSFER_ENCODING">>, <<"Invalid `Transfer-Encoding` header value">>, R, LL1, C)
            end);
        true ->
            Otherwise(LL)
    end;
forbid_after_chunked(_, LL, _, Otherwise) ->
    Otherwise(LL).

%% The end of the headers, or of the trailers of a chunked body.
headers_end(Rest, #ll{flags = F} = LL, C) when F band ?F_TRAILING =/= 0 ->
    case cb(C, chunk_complete) of
        0 -> message_done(Rest, LL, C);
        _ -> cb_error(<<"HPE_CB_CHUNK_COMPLETE">>, <<"on_chunk_complete">>, Rest, LL, C)
    end;
headers_end(Rest, LL, C) ->
    LL1 = before_headers_complete(LL),
    Info = #{major => LL1#ll.major, minor => LL1#ll.minor, method => LL1#ll.method, status => LL1#ll.status,
             upgrade => LL1#ll.upgrade =:= 1, keep_alive => should_keep_alive(LL1)},
    case cb(C, {headers_complete, Info}) of
        0 -> after_headers_complete(Rest, LL1, C);
        1 -> after_headers_complete(Rest, set_flag(LL1, ?F_SKIPBODY), C);
        2 -> after_headers_complete(Rest, set_flag(LL1#ll{upgrade = 1}, ?F_SKIPBODY), C);
        _ -> error(<<"HPE_CB_HEADERS_COMPLETE">>, <<"User callback error">>, Rest, LL1, C)
    end.

before_headers_complete(#ll{flags = F} = LL) when F band ?F_UPGRADE =/= 0, F band ?F_CONNECTION_UPGRADE =/= 0 ->
    LL#ll{upgrade = bool(LL#ll.type =:= request orelse LL#ll.status =:= 101)};
before_headers_complete(LL) ->
    LL#ll{upgrade = bool(LL#ll.method =:= ?CONNECT)}.

after_headers_complete(Rest, LL, C) ->
    case body_kind(LL) of
        upgrade ->
            case cb(C, message_complete) of
                0 -> pause_upgrade(Rest, LL, C);
                _ -> cb_error(<<"HPE_CB_MESSAGE_COMPLETE">>, <<"on_message_complete">>, Rest, LL, C)
            end;
        none ->
            case cb(C, message_complete) of
                0 -> cleanup(Rest, LL, C);
                _ -> cb_error(<<"HPE_CB_MESSAGE_COMPLETE">>, <<"on_message_complete">>, Rest, LL, C)
            end;
        chunked -> node(chunk_size_digit, Rest, LL#ll{content_length = 0}, C);
        identity -> node(body_identity, Rest, LL, C);
        eof -> node(body_identity_eof, Rest, LL#ll{finish = ?FINISH_SAFE_WITH_CB}, C);
        invalid -> error(<<"HPE_INVALID_TRANSFER_ENCODING">>, <<"Request has invalid `Transfer-Encoding`">>, Rest, LL, C)
    end.

%% llhttp__after_headers_complete of src/native/http.c.
body_kind(#ll{type = Type, status = Status, flags = F, upgrade = Upgrade, method = Method} = LL) ->
    HasBody = F band ?F_CHUNKED =/= 0 orelse LL#ll.content_length > 0,
    if
        (Upgrade =:= 1 andalso (Method =:= ?CONNECT orelse F band ?F_SKIPBODY =/= 0 orelse not HasBody))
            orelse (Type =:= response andalso Status =:= 101) -> upgrade;
        Type =:= response, Status =:= 100 -> none;
        F band ?F_SKIPBODY =/= 0 -> none;
        Type =:= response, Status =:= 102; Type =:= response, Status =:= 103;
        Type =:= response, Status =:= 204; Type =:= response, Status =:= 304 -> none;
        F band ?F_CHUNKED =/= 0 -> chunked;
        F band ?F_TRANSFER_ENCODING =/= 0 ->
            case Type =:= request andalso LL#ll.lenient band (?L_CHUNKED_LENGTH bor ?L_TRANSFER_ENCODING) =:= 0 of
                true -> invalid;
                false -> eof
            end;
        F band ?F_CONTENT_LENGTH =:= 0 ->
            case needs_eof(LL) of
                true -> eof;
                false -> none
            end;
        LL#ll.content_length =:= 0 -> none;
        true -> identity
    end.

%% llhttp_message_needs_eof.
needs_eof(#ll{type = request}) -> false;
needs_eof(#ll{status = S, flags = F}) when S div 100 =:= 1; S =:= 204; S =:= 304; F band ?F_SKIPBODY =/= 0 -> false;
needs_eof(#ll{flags = F}) when F band ?F_TRANSFER_ENCODING =/= 0, F band ?F_CHUNKED =:= 0 -> true;
needs_eof(#ll{flags = F}) -> F band (?F_CHUNKED bor ?F_CONTENT_LENGTH) =:= 0.

chunk_extension_value_start(Rest, LL, C) ->
    node(chunk_extension_value, Rest, span_start(chunk_extension, Rest, LL, C), C).

chunk_lf(Rest, LL, C, Reason) ->
    case lenient(LL, ?L_OPTIONAL_CR_BEFORE_LF) of
        true -> node(chunk_size_almost_done, Rest, LL, C);
        false -> error(<<"HPE_CR_EXPECTED">>, Reason, Rest, LL, C)
    end.

chunk_header(Rest, LL, C) ->
    case cb(C, chunk_header) of
        0 when LL#ll.content_length =:= 0 -> node(header_field_start, Rest, set_flag(LL, ?F_TRAILING), C);
        0 -> node(chunk_data, Rest, LL, C);
        _ -> cb_error(<<"HPE_CB_CHUNK_HEADER">>, <<"on_chunk_header">>, Rest, LL, C)
    end.

chunk_complete(Rest, LL, C) ->
    case cb(C, chunk_complete) of
        0 -> node(chunk_size_digit, Rest, LL#ll{content_length = 0}, C);
        _ -> cb_error(<<"HPE_CB_CHUNK_COMPLETE">>, <<"on_chunk_complete">>, Rest, LL, C)
    end.

message_done(Rest, LL, C) ->
    case cb(C, message_complete) of
        0 when LL#ll.upgrade =:= 1 -> pause_upgrade(Rest, LL, C);
        0 -> cleanup(Rest, LL, C);
        _ -> cb_error(<<"HPE_CB_MESSAGE_COMPLETE">>, <<"on_message_complete">>, Rest, LL, C)
    end.

pause_upgrade(Rest, LL, C) ->
    {error, LL#ll{error = <<"HPE_PAUSED_UPGRADE">>, reason = <<"Pause on CONNECT/Upgrade">>,
                  error_pos = pos(Rest, C), node = cleanup}}.

%% llhttp__after_message_complete, then restart or closed.
cleanup(Rest, LL, C) ->
    LL1 = LL#ll{finish = ?FINISH_SAFE, flags = 0},
    case {should_keep_alive(LL), lenient(LL1, ?L_KEEP_ALIVE)} of
        {true, _} -> node(start, Rest, LL1#ll{content_length = 0, initial = 1}, C);
        {false, true} -> node(start, Rest, LL1#ll{initial = 1}, C);
        {false, false} -> node(closed, Rest, LL1, C)
    end.

url_end(_, <<$\s, _/binary>> = Rest, LL, C, _) ->
    then(span_end(Rest, LL, C), fun(LL1) -> node(url_skip_to_http, Rest, LL1, C) end);
url_end(_, <<$\r, _/binary>> = Rest, LL, C, _) ->
    then(span_end(Rest, LL, C), fun(LL1) -> node({url_skip_lf_to_http09, <<>>}, Rest, LL1, C) end);
url_end(_, <<$\n, _/binary>> = Rest, LL, C, _) ->
    then(span_end(Rest, LL, C), fun(LL1) -> node(url_skip_to_http09, Rest, LL1, C) end);
url_end(_, Rest, LL, C, Reason) ->
    error(<<"HPE_INVALID_URL">>, Reason, Rest, LL, C).

%%% Spans, errors, and flags

pos(Rest, #c{len = Len}) -> Len - byte_size(Rest).

more(Node, LL) -> {more, LL#ll{node = Node}}.

span_start(Kind, Rest, LL, C) -> LL#ll{span = {Kind, pos(Rest, C)}}.

span_end(Rest, #ll{span = {Kind, Start}} = LL, #c{data = Data} = C) ->
    Pos = pos(Rest, C),
    LL1 = LL#ll{span = none},
    case cb(C, {Kind, binary_part(Data, Start, Pos - Start)}) of
        ok -> {ok, LL1};
        {user, Code, Reason} -> {error, LL1#ll{error = Code, reason = Reason, error_pos = Pos}};
        _ -> {error, LL1#ll{error = <<"HPE_USER">>, reason = <<"Span callback error">>, error_pos = Pos}}
    end;
span_end(_, LL, _) ->
    {ok, LL}.

then({ok, LL}, Next) -> Next(LL);
then(Error, _) -> Error.

cb(#c{cb = Cb}, Event) -> Cb(Event).

error(Code, Reason, Rest, LL, C) ->
    {error, LL#ll{error = Code, reason = Reason, error_pos = pos(Rest, C)}}.

cb_error(Code, Name, Rest, LL, C) ->
    error(Code, <<"`", Name/binary, "` callback error">>, Rest, LL, C).

lenient(#ll{lenient = L}, Flag) -> L band Flag =/= 0.

set_flag(#ll{flags = F} = LL, Flag) -> LL#ll{flags = F bor Flag}.

%% setHeaderFlags of http.ts: a Connection token or chunked sets its flag.
set_header_flags(#ll{header_state = ?H_CONNECTION_KEEP_ALIVE} = LL) ->
    (set_flag(LL, ?F_CONNECTION_KEEP_ALIVE))#ll{header_state = ?H_CONNECTION};
set_header_flags(#ll{header_state = ?H_CONNECTION_CLOSE} = LL) ->
    (set_flag(LL, ?F_CONNECTION_CLOSE))#ll{header_state = ?H_CONNECTION};
set_header_flags(#ll{header_state = ?H_CONNECTION_UPGRADE} = LL) ->
    (set_flag(LL, ?F_CONNECTION_UPGRADE))#ll{header_state = ?H_CONNECTION};
set_header_flags(#ll{header_state = ?H_TRANSFER_ENCODING_CHUNKED} = LL) ->
    set_flag(LL, ?F_CHUNKED);
set_header_flags(LL) ->
    LL.

valid_version(#ll{lenient = L}) when L band ?L_VERSION =/= 0 -> true;
valid_version(#ll{major = 0, minor = 9}) -> true;
valid_version(#ll{major = 1, minor = M}) -> M =:= 0 orelse M =:= 1;
valid_version(#ll{major = 2, minor = 0}) -> true;
valid_version(_) -> false.

bool(true) -> 1;
bool(false) -> 0.

protocol_methods(http) -> lists:seq(0, 34) ++ [46];
protocol_methods(rtsp) -> [1, 3, 6 | lists:seq(35, 45)];
protocol_methods(ice) -> [33].

protocol_error(http) -> <<"Invalid method for HTTP/x.x request">>;
protocol_error(rtsp) -> <<"Invalid method for RTSP/x.x request">>;
protocol_error(ice) -> <<"Expected SOURCE method for ICE/x.x request">>.

hex(D) when ?IS_DIGIT(D) -> D - $0;
hex(H) when H >= $a, H =< $f -> H - $a + 10;
hex(H) when H >= $A, H =< $F -> H - $A + 10;
hex(_) -> error.

is_token(Ch) when ?IS_ALPHA(Ch); ?IS_DIGIT(Ch) -> true;
is_token(Ch) -> lists:member(Ch, "!#$%&'*+-.^_`|~").

is_userinfo(Ch) when ?IS_ALPHA(Ch); ?IS_DIGIT(Ch) -> true;
is_userinfo(Ch) -> lists:member(Ch, "-_.!~*'()%;:&=+$,").

%%% Scans: the longest run of one class, as a self-loop of a node consumes it.

scan_token(<<Ch, R/binary>> = Rest) ->
    case is_token(Ch) of
        true -> scan_token(R);
        false -> Rest
    end;
scan_token(<<>>) -> <<>>.

scan_header_value(<<Ch, R/binary>>) when ?IS_HEADER_CHAR(Ch) -> scan_header_value(R);
scan_header_value(Rest) -> Rest.

scan_url(<<Ch, R/binary>>) when ?IS_URL_CHAR(Ch) -> scan_url(R);
scan_url(Rest) -> Rest.

scan_query(<<Ch, R/binary>>) when ?IS_URL_CHAR(Ch); Ch =:= $? -> scan_query(R);
scan_query(Rest) -> Rest.

scan_fragment(<<Ch, R/binary>>) when ?IS_URL_CHAR(Ch); Ch =:= $?; Ch =:= $# -> scan_fragment(R);
scan_fragment(Rest) -> Rest.

scan_status(<<Ch, R/binary>>) when Ch =/= $\r, Ch =/= $\n -> scan_status(R);
scan_status(Rest) -> Rest.

%%% Sequences and selects: a trie of byte strings that a match can leave and
%%% resume at any byte. A shorter candidate wins once no longer one continues.

select(Name, Prefix, Rest, Transform) ->
    select_loop(trie(Name), Prefix, Rest, Transform).

select_loop(_, Prefix, <<>>, _) ->
    {partial, Prefix};
select_loop(Trie, Prefix, <<Ch, R/binary>> = Rest, Transform) ->
    P1 = <<Prefix/binary, (transform(Transform, Ch))>>,
    case Trie of
        #{P1 := {Value, false}} -> {match, Value, R};
        #{P1 := _} -> select_loop(Trie, P1, R, Transform);
        #{Prefix := {Value, _}} when Value =/= none -> {match, Value, Rest};
        #{} -> {nomatch, Rest}
    end.

transform(lower, Ch) when Ch >= $A, Ch =< $Z -> Ch + 32;
transform(unsafe, Ch) -> Ch bor 16#20;
transform(_, Ch) -> Ch.

trie(Name) ->
    Key = {?MODULE, Name},
    case persistent_term:get(Key, undefined) of
        undefined ->
            Trie = build_trie(candidates(Name)),
            persistent_term:put(Key, Trie),
            Trie;
        Trie ->
            Trie
    end.

%% Each prefix of a candidate maps to {the value of the candidate that it
%% is, or none; whether a longer candidate continues it}.
build_trie(Candidates) ->
    lists:foldl(fun({Bytes, Value}, Acc) ->
        Prefixes = [binary:part(Bytes, 0, N) || N <- lists:seq(1, byte_size(Bytes))],
        lists:foldl(fun(P, A) ->
            {Exact, Longer} = maps:get(P, A, {none, false}),
            case P =:= Bytes of
                true -> A#{P => {Value, Longer}};
                false -> A#{P => {Exact, true}}
            end
        end, Acc, Prefixes)
    end, #{}, Candidates).

candidates(methods) -> method_numbers();
candidates(protocols) -> [{<<"HTTP">>, http}, {<<"RTSP">>, rtsp}, {<<"ICE">>, ice}];
candidates(double_slash) -> [{<<"//">>, ok}];
candidates(crlf) -> [{<<"\r\n">>, ok}];
candidates(chunk_end) -> [{<<"\r\n">>, crlf}, {<<"\n">>, lf}];
candidates(h2_preface) -> [{<<"\r\n\r\nSM\r\n\r\n">>, ok}];
candidates(chunked) -> [{<<"chunked">>, ok}];
candidates(special_headers) ->
    [{<<"connection">>, ?H_CONNECTION}, {<<"content-length">>, ?H_CONTENT_LENGTH},
     {<<"proxy-connection">>, ?H_CONNECTION}, {<<"transfer-encoding">>, ?H_TRANSFER_ENCODING},
     {<<"upgrade">>, ?H_UPGRADE}];
candidates(connection) ->
    [{<<"close">>, ?H_CONNECTION_CLOSE}, {<<"upgrade">>, ?H_CONNECTION_UPGRADE},
     {<<"keep-alive">>, ?H_CONNECTION_KEEP_ALIVE}].
