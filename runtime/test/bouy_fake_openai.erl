-module(bouy_fake_openai).

%% A fake OpenAI Chat Completions server for the tests of `ai` and
%% `@ai-sdk/openai` (contract section 14). Node with the real packages and
%% Bouy talk to the same server, so their outputs can be compared.
%%
%% Start it from a shell or a test:
%%   erlc -o Dir runtime/test/bouy_fake_openai.erl
%%   erl -noshell -pa Dir -eval 'bouy_fake_openai:main()' -extra stdin
%% It prints its port on the first line of stdout and serves until its stdin
%% ends. With `-extra <os pid>` instead, it serves until that OS process
%% ends, and with no argument, until it is killed. Point the programs at it
%% with OPENAI_BASE_URL=http://127.0.0.1:<port>/v1 and
%% OPENAI_API_KEY=sk-fake-key. EUnit starts it in the test VM with start/0.
%%
%% The model of a request picks the answer:
%% - `fake-500`: HTTP 500 with an OpenAI error body and `retry-after-ms: 0`.
%% - a model whose name ends in `echo`, such as `fake-echo` or `o4-mini-echo`:
%%   the text is `{"body": ..., "headers": ..., "path": ...}` as JSON with
%%   sorted keys: the request body, the request headers that do not name the
%%   client (`user-agent` and the transport headers are left out), and the
%%   request path.
%% - `fake-length`: the scripted answer below, with finish reason `length`.
%% - any other model: the scripted answer. When the last user message holds
%%   `CALLS <json>`, a JSON array of steps, each an array of
%%   `{"name": ..., "input": ...}`, step k of the turn answers with the tool
%%   calls of entry k. A call with `"arguments": "<text>"` sends the text as
%%   the arguments instead of the JSON of `input`. After the last entry, or
%%   without tools, the answer is text: the tool results of the turn, or a
%%   greeting that repeats the system and user text.
%% A key other than sk-fake-key gets HTTP 401. Every answer depends only on
%% the request, so two clients that send the same request get the same bytes.

-export([main/0, start/0, stop/1]).

-define(KEY, "sk-fake-key").
-define(EPOCH, 1767225600).

-spec main() -> no_return().
main() ->
    {_Server, Port} = start(),
    io:format("~b~n", [Port]),
    watch(init:get_plain_arguments()).

%% Halts when the process that started the server ends, so a test that dies
%% cannot leave the server behind.
watch(["stdin"]) ->
    case io:get_line("") of
        Line when is_list(Line); is_binary(Line) -> watch(["stdin"]);
        _End -> erlang:halt(0)
    end;
watch([OsPid]) ->
    timer:sleep(500),
    case os:cmd("kill -0 " ++ OsPid ++ " 2>/dev/null && echo alive") of
        "alive" ++ _ -> watch([OsPid]);
        _ -> erlang:halt(0)
    end;
watch(_) ->
    receive
    after infinity -> ok
    end.

-spec start() -> {pid(), inet:port_number()}.
start() ->
    Parent = self(),
    Server = spawn(fun() ->
        {ok, Listen} = gen_tcp:listen(0, [binary, {packet, http_bin}, {active, false},
                                          {ip, {127, 0, 0, 1}}, {reuseaddr, true}, {backlog, 128}]),
        {ok, Port} = inet:port(Listen),
        Parent ! {self(), Port},
        accept(Listen)
    end),
    receive
        {Server, Port} -> {Server, Port}
    end.

-spec stop(pid()) -> ok.
stop(Server) ->
    exit(Server, kill),
    ok.

accept(Listen) ->
    {ok, Socket} = gen_tcp:accept(Listen),
    Connection = spawn(fun() ->
        receive
            go -> serve(Socket)
        end
    end),
    ok = gen_tcp:controlling_process(Socket, Connection),
    Connection ! go,
    accept(Listen).

serve(Socket) ->
    {ok, {http_request, _Method, {abs_path, Path}, _Version}} = gen_tcp:recv(Socket, 0),
    Headers = headers(Socket, #{}),
    ok = inet:setopts(Socket, [{packet, raw}]),
    Body = body(Socket, binary_to_integer(maps:get(<<"content-length">>, Headers, <<"0">>))),
    {Status, Extra, Json} = answer(Path, Headers, Body),
    Text = iolist_to_binary(Json),
    Lines = [{<<"content-type">>, <<"application/json">>},
             {<<"content-length">>, integer_to_binary(byte_size(Text))},
             {<<"connection">>, <<"close">>} | Extra],
    ok = gen_tcp:send(Socket, [<<"HTTP/1.1 ">>, integer_to_binary(Status), <<" ">>, reason(Status), <<"\r\n">>,
                               [[Name, <<": ">>, Value, <<"\r\n">>] || {Name, Value} <- Lines],
                               <<"\r\n">>, Text]),
    gen_tcp:close(Socket).

headers(Socket, Headers) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, {http_header, _, Name, _, Value}} -> headers(Socket, Headers#{string:lowercase(name(Name)) => Value});
        {ok, http_eoh} -> Headers
    end.

name(Name) when is_atom(Name) -> atom_to_binary(Name);
name(Name) -> Name.

body(_Socket, 0) -> <<>>;
body(Socket, Length) ->
    {ok, Body} = gen_tcp:recv(Socket, Length),
    Body.

reason(200) -> <<"OK">>;
reason(401) -> <<"Unauthorized">>;
reason(404) -> <<"Not Found">>;
reason(500) -> <<"Internal Server Error">>.

%%% Answers

answer(Path, Headers, Body) ->
    case {lists:last(binary:split(Path, <<"/">>, [global])), maps:get(<<"authorization">>, Headers, <<>>)} of
        {<<"completions">>, <<"Bearer ", ?KEY>>} -> chat(json:decode(Body), Headers, Path);
        {<<"completions">>, <<"Bearer ", Key/binary>>} ->
            failure(401, [], <<"Incorrect API key provided: ", Key/binary, ".">>, <<"invalid_request_error">>, <<"invalid_api_key">>);
        _ -> failure(404, [], <<"Unknown path: ", Path/binary>>, <<"invalid_request_error">>, <<"unknown_url">>)
    end.

failure(Status, Extra, Message, Type, Code) ->
    {Status, Extra, json:encode(#{<<"error">> => #{<<"message">> => Message, <<"type">> => Type,
                                                  <<"param">> => null, <<"code">> => Code}})}.

chat(#{<<"model">> := <<"fake-500">>}, _Headers, _Path) ->
    failure(500, [{<<"retry-after-ms">>, <<"0">>}], <<"The server had an error while processing your request.">>,
            <<"server_error">>, null);
chat(#{<<"model">> := Model} = Request, Headers, Path) when byte_size(Model) >= 4, binary_part(Model, byte_size(Model), -4) =:= <<"echo">> ->
    Named = maps:without([<<"user-agent">>, <<"host">>, <<"connection">>, <<"content-length">>, <<"accept">>,
                          <<"accept-encoding">>, <<"accept-language">>, <<"sec-fetch-mode">>, <<"te">>], Headers),
    completion(Request, {text, canonical(#{<<"body">> => Request, <<"headers">> => Named, <<"path">> => Path})});
chat(Request, _Headers, _Path) ->
    completion(Request, script(Request)).

%% The answer of the scripted model: tool calls or text.
script(#{<<"messages">> := Messages} = Request) ->
    {User, Turn} = turn(Messages),
    Step = length([Message || #{<<"role">> := <<"assistant">>} = Message <- Turn]),
    Steps = calls(text(User)),
    case maps:is_key(<<"tools">>, Request) andalso Step < length(Steps) of
        true -> {calls, Step, lists:nth(Step + 1, Steps)};
        false -> {text, reply(Messages, User, Turn)}
    end.

%% The last user message and the messages after it.
turn(Messages) ->
    {Before, After} = lists:splitwith(fun(#{<<"role">> := Role}) -> Role =/= <<"user">> end, lists:reverse(Messages)),
    case After of
        [User | _] -> {User, lists:reverse(Before)};
        [] -> {#{<<"content">> => <<>>}, Messages}
    end.

text(#{<<"content">> := Text}) when is_binary(Text) -> Text;
text(#{<<"content">> := Parts}) when is_list(Parts) -> iolist_to_binary([Text || #{<<"text">> := Text} <- Parts]);
text(_) -> <<>>.

calls(Text) ->
    case binary:split(Text, <<"CALLS ">>) of
        [_, Script] -> json:decode(Script);
        [_] -> []
    end.

reply(Messages, User, Turn) ->
    case [Message || #{<<"role">> := <<"tool">>} = Message <- Turn] of
        [] ->
            Systems = [text(Message) || #{<<"role">> := Role} = Message <- Messages, Role =:= <<"system">> orelse Role =:= <<"developer">>],
            iolist_to_binary(["Hello! ", [["System: ", System, ". "] || System <- Systems], "You said: ", text(User)]);
        Results ->
            Names = maps:from_list([{Id, Name} || #{<<"role">> := <<"assistant">>, <<"tool_calls">> := Calls} <- Turn,
                                                  #{<<"id">> := Id, <<"function">> := #{<<"name">> := Name}} <- Calls]),
            iolist_to_binary(["Results: ", lists:join(", ", [[maps:get(Id, Names, Id), " -> ", Content]
                                                             || #{<<"tool_call_id">> := Id, <<"content">> := Content} <- Results])])
    end.

completion(#{<<"model">> := Model, <<"messages">> := Messages} = Request, Answer) ->
    N = length(Messages),
    {Message, Finish, Completion} = message(Model, Answer),
    Prompt = 10 * N + 5 * length(maps:get(<<"tools">>, Request, [])),
    Body = #{
        <<"id">> => <<"chatcmpl-fake-", (integer_to_binary(N))/binary>>,
        <<"object">> => <<"chat.completion">>,
        <<"created">> => ?EPOCH + N,
        <<"model">> => <<Model/binary, "-2026-01-01">>,
        <<"choices">> => [#{<<"index">> => 0, <<"message">> => Message, <<"finish_reason">> => Finish, <<"logprobs">> => null}],
        <<"usage">> => #{
            <<"prompt_tokens">> => Prompt,
            <<"completion_tokens">> => Completion,
            <<"total_tokens">> => Prompt + Completion,
            <<"prompt_tokens_details">> => #{<<"cached_tokens">> => 0},
            <<"completion_tokens_details">> => #{<<"reasoning_tokens">> => 0}
        }
    },
    {200, [{<<"x-request-id">>, <<"req_fake_", (integer_to_binary(N))/binary>>}], json:encode(Body)}.

message(_Model, {calls, Step, Calls}) ->
    ToolCalls = [#{<<"id">> => iolist_to_binary(io_lib:format("call_~b_~b", [Step + 1, I])),
                   <<"type">> => <<"function">>,
                   <<"function">> => #{<<"name">> => Name, <<"arguments">> => arguments(Call)}}
                 || {I, #{<<"name">> := Name} = Call} <- lists:enumerate(Calls)],
    {#{<<"role">> => <<"assistant">>, <<"content">> => null, <<"tool_calls">> => ToolCalls}, <<"tool_calls">>, 3 * length(Calls)};
message(Model, {text, Text}) ->
    Finish = case Model of
        <<"fake-length">> -> <<"length">>;
        _ -> <<"stop">>
    end,
    {#{<<"role">> => <<"assistant">>, <<"content">> => Text}, Finish, length(binary:split(Text, <<" ">>, [global]))}.

arguments(#{<<"arguments">> := Text}) -> Text;
arguments(#{<<"input">> := Input}) -> iolist_to_binary(json:encode(Input)).

%% JSON with sorted object keys, so a key order difference between two clients
%% does not show.
canonical(Value) ->
    iolist_to_binary(json:encode(Value, fun encode/2)).

encode(Map, Encode) when is_map(Map) -> json:encode_key_value_list(lists:sort(maps:to_list(Map)), Encode);
encode(Value, Encode) -> json:encode_value(Value, Encode).
