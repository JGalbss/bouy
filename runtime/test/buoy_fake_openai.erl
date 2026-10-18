-module(buoy_fake_openai).

%% A fake model server for the tests of `ai`, `@ai-sdk/openai`, `openai`, and
%% `@anthropic-ai/sdk` (contract section 14, testing.md section 5.8). Node with
%% the real packages and Buoy talk to the same server, so their outputs can be
%% compared. It serves three APIs:
%% - OpenAI Chat Completions: `POST <base>/chat/completions`.
%% - OpenAI Responses: `POST <base>/responses`.
%% - Anthropic Messages: `POST <base>/messages`, with the key in `x-api-key`.
%% A request with `"stream": true` gets the answer as server-sent events, in
%% the event format of its API.
%%
%% Start it from a shell or a test:
%%   erlc -o Dir runtime/test/buoy_fake_openai.erl
%%   erl -noshell -pa Dir -eval 'buoy_fake_openai:main()' -extra stdin
%% It prints its port on the first line of stdout and serves until its stdin
%% ends. With `-extra <os pid>` instead, it serves until that OS process
%% ends, and with no argument, until it is killed. Point the programs at it
%% with OPENAI_BASE_URL=http://127.0.0.1:<port>/v1,
%% ANTHROPIC_BASE_URL=http://127.0.0.1:<port>, and the key sk-fake-key for
%% both. EUnit starts it in the test VM with start/0.
%%
%% The model of a request picks the answer:
%% - `fake-500`: HTTP 500 with an error body and `retry-after-ms: 0`.
%% - a model whose name ends in `echo`, such as `fake-echo` or `o4-mini-echo`:
%%   the text is `{"body": ..., "headers": ..., "path": ...}` as JSON with
%%   sorted keys: the request body, the request headers that do not name the
%%   client (`user-agent`, the `x-stainless-` headers, and the transport
%%   headers are left out), and the request path.
%% - `fake-length`: the scripted answer below, with finish reason `length`.
%% - any other model: the scripted answer. When the last user message holds
%%   `CALLS <json>`, a JSON array of steps, each an array of
%%   `{"name": ..., "input": ...}`, step k of the turn answers with the tool
%%   calls of entry k. A call with `"arguments": "<text>"` sends the text as
%%   the arguments instead of the JSON of `input`. After the last entry, or
%%   without tools, the answer is text: the tool results of the turn, the JSON
%%   after `JSON ` in the last user message, or a greeting that repeats the
%%   system and user text.
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
    {Status, Extra, Payload} = answer(Path, Headers, Body),
    {Type, Text} = case Payload of
        {events, Events} -> {<<"text/event-stream">>, iolist_to_binary(Events)};
        Json -> {<<"application/json">>, iolist_to_binary(Json)}
    end,
    Lines = [{<<"content-type">>, Type},
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

%%% Routes

answer(Path, Headers, Body) ->
    Route = lists:last(binary:split(hd(binary:split(Path, <<"?">>)), <<"/">>, [global])),
    case {Route, key(Route, Headers)} of
        {<<"completions">>, <<?KEY>>} -> chat(json:decode(Body), Headers, Path);
        {<<"responses">>, <<?KEY>>} -> responses(json:decode(Body), Headers, Path);
        {<<"messages">>, <<?KEY>>} -> messages(json:decode(Body), Headers, Path);
        {<<"messages">>, Key} when is_binary(Key) ->
            anthropic_failure(401, [], <<"invalid x-api-key">>, <<"authentication_error">>);
        {_, Key} when is_binary(Key) ->
            failure(401, [], <<"Incorrect API key provided: ", Key/binary, ".">>, <<"invalid_request_error">>, <<"invalid_api_key">>);
        _ -> failure(404, [], <<"Unknown path: ", Path/binary>>, <<"invalid_request_error">>, <<"unknown_url">>)
    end.

key(<<"messages">>, Headers) -> maps:get(<<"x-api-key">>, Headers, <<>>);
key(Route, Headers) when Route =:= <<"completions">>; Route =:= <<"responses">> ->
    case maps:get(<<"authorization">>, Headers, <<>>) of
        <<"Bearer ", Key/binary>> -> Key;
        _ -> none
    end;
key(_Route, _Headers) -> none.

failure(Status, Extra, Message, Type, Code) ->
    {Status, Extra, json:encode(#{<<"error">> => #{<<"message">> => Message, <<"type">> => Type,
                                                  <<"param">> => null, <<"code">> => Code}})}.

anthropic_failure(Status, Extra, Message, Type) ->
    {Status, Extra, json:encode(#{<<"type">> => <<"error">>,
                                  <<"error">> => #{<<"type">> => Type, <<"message">> => Message}})}.

server_error() ->
    {500, [{<<"retry-after-ms">>, <<"0">>}], <<"The server had an error while processing your request.">>}.

%% The answer of a request and the step of the model in its turn: the echo of
%% the request, or the scripted answer of its conversation.
pick(#{<<"model">> := Model} = Request, Headers, Path, _Entries) when byte_size(Model) >= 4, binary_part(Model, byte_size(Model), -4) =:= <<"echo">> ->
    Named = maps:filter(fun(Name, _) -> not is_client_header(Name) end, Headers),
    {{text, canonical(#{<<"body">> => Request, <<"headers">> => Named, <<"path">> => Path})}, 0};
pick(Request, _Headers, _Path, Entries) ->
    script(Entries, has_tools(Request)).

is_client_header(<<"x-stainless-", _/binary>>) -> true;
is_client_header(Name) ->
    lists:member(Name, [<<"user-agent">>, <<"host">>, <<"connection">>, <<"content-length">>, <<"accept">>,
                        <<"accept-encoding">>, <<"accept-language">>, <<"sec-fetch-mode">>, <<"te">>]).

has_tools(Request) -> maps:get(<<"tools">>, Request, []) =/= [].

is_streamed(Request) -> maps:get(<<"stream">>, Request, false) =:= true.

%%% Conversations

%% Each API turns its messages into these entries:
%% {system, Text}, {user, Text}, {assistant, [{Id, Name}]} for one step of the
%% model with its tool calls, and {result, Id, Content} for one tool result.

%% The scripted answer of the conversation: {{calls, Calls}, Step} or
%% {{text, Text}, Step}.
script(Entries, HasTools) ->
    {User, Turn} = turn(Entries),
    Step = length([Calls || {assistant, Calls} <- Turn]),
    Steps = calls(User),
    case HasTools andalso Step < length(Steps) of
        true -> {{calls, lists:nth(Step + 1, Steps)}, Step};
        false -> {{text, reply(Entries, User, Turn)}, Step}
    end.

%% The text of the last user entry and the entries after it.
turn(Entries) ->
    {Before, After} = lists:splitwith(fun(Entry) -> element(1, Entry) =/= user end, lists:reverse(Entries)),
    case After of
        [{user, User} | _] -> {User, lists:reverse(Before)};
        [] -> {<<>>, Entries}
    end.

calls(Text) ->
    case binary:split(Text, <<"CALLS ">>) of
        [_, Script] -> json:decode(Script);
        [_] -> []
    end.

reply(Entries, User, Turn) ->
    case {[Result || {result, _, _} = Result <- Turn], binary:split(User, <<"JSON ">>)} of
        {[], [_, Json]} -> Json;
        {[], [_]} ->
            iolist_to_binary(["Hello! ", [["System: ", System, ". "] || {system, System} <- Entries], "You said: ", User]);
        {Results, _} ->
            Names = maps:from_list([Call || {assistant, Calls} <- Turn, Call <- Calls]),
            iolist_to_binary(["Results: ", lists:join(", ", [[maps:get(Id, Names, Id), " -> ", Content]
                                                             || {result, Id, Content} <- Results])])
    end.

text(Text) when is_binary(Text) -> Text;
text(Parts) when is_list(Parts) -> iolist_to_binary([Text || #{<<"text">> := Text} <- Parts]);
text(_) -> <<>>.

arguments(#{<<"arguments">> := Text}) -> Text;
arguments(#{<<"input">> := Input}) -> iolist_to_binary(json:encode(Input)).

input(#{<<"arguments">> := Text}) -> json:decode(Text);
input(#{<<"input">> := Input}) -> Input.

call_id(Prefix, Step, I) -> iolist_to_binary(io_lib:format("~s~b_~b", [Prefix, Step + 1, I])).

words(Text) -> length(binary:split(Text, <<" ">>, [global])).

%% The text in pieces of one word each, with the space that follows it, so a
%% stream sends several deltas.
pieces(Text) ->
    case binary:split(Text, <<" ">>, [global]) of
        [Word] -> [Word];
        Words -> [<<Word/binary, " ">> || Word <- lists:droplast(Words)] ++ [lists:last(Words)]
    end.

finish(<<"fake-length">>, _Stop, Length) -> Length;
finish(_Model, Stop, _Length) -> Stop.

%%% OpenAI Chat Completions

chat(#{<<"model">> := <<"fake-500">>}, _Headers, _Path) ->
    {Status, Extra, Message} = server_error(),
    failure(Status, Extra, Message, <<"server_error">>, null);
chat(#{<<"messages">> := Messages} = Request, Headers, Path) ->
    Entries = lists:flatmap(fun chat_entries/1, Messages),
    {Answer, Step} = pick(Request, Headers, Path, Entries),
    completion(Request, Answer, Step).

chat_entries(#{<<"role">> := Role} = Message) when Role =:= <<"system">>; Role =:= <<"developer">> ->
    [{system, text(maps:get(<<"content">>, Message, <<>>))}];
chat_entries(#{<<"role">> := <<"user">>} = Message) -> [{user, text(maps:get(<<"content">>, Message, <<>>))}];
chat_entries(#{<<"role">> := <<"assistant">>} = Message) ->
    [{assistant, [{Id, Name} || #{<<"id">> := Id, <<"function">> := #{<<"name">> := Name}}
                                    <- maps:get(<<"tool_calls">>, Message, [])]}];
chat_entries(#{<<"role">> := <<"tool">>, <<"tool_call_id">> := Id, <<"content">> := Content}) ->
    [{result, Id, text(Content)}];
chat_entries(_Message) -> [].

completion(#{<<"model">> := Model, <<"messages">> := Messages} = Request, Answer, Step) ->
    N = length(Messages),
    {Message, Finish, Completion} = chat_message(Model, Answer, Step),
    Prompt = 10 * N + 5 * length(maps:get(<<"tools">>, Request, [])),
    Usage = #{
        <<"prompt_tokens">> => Prompt,
        <<"completion_tokens">> => Completion,
        <<"total_tokens">> => Prompt + Completion,
        <<"prompt_tokens_details">> => #{<<"cached_tokens">> => 0},
        <<"completion_tokens_details">> => #{<<"reasoning_tokens">> => 0}
    },
    Id = <<"chatcmpl-fake-", (integer_to_binary(N))/binary>>,
    Common = #{<<"id">> => Id, <<"created">> => ?EPOCH + N, <<"model">> => <<Model/binary, "-2026-01-01">>},
    Extra = [{<<"x-request-id">>, <<"req_fake_", (integer_to_binary(N))/binary>>}],
    case is_streamed(Request) of
        false ->
            Body = Common#{
                <<"object">> => <<"chat.completion">>,
                <<"choices">> => [#{<<"index">> => 0, <<"message">> => Message, <<"finish_reason">> => Finish, <<"logprobs">> => null}],
                <<"usage">> => Usage
            },
            {200, Extra, json:encode(Body)};
        true ->
            Chunk = fun(Choices) -> Common#{<<"object">> => <<"chat.completion.chunk">>, <<"choices">> => Choices} end,
            Delta = fun(Fields) -> [#{<<"index">> => 0, <<"delta">> => Fields, <<"finish_reason">> => null}] end,
            Deltas = case Message of
                #{<<"tool_calls">> := Calls} ->
                    [Chunk(Delta(#{<<"role">> => <<"assistant">>, <<"content">> => null}))]
                    ++ lists:append([[Chunk(Delta(#{<<"tool_calls">> => [#{<<"index">> => I - 1, <<"id">> => CallId, <<"type">> => <<"function">>,
                                                                         <<"function">> => #{<<"name">> => Name, <<"arguments">> => <<>>}}]})),
                                      Chunk(Delta(#{<<"tool_calls">> => [#{<<"index">> => I - 1, <<"function">> => #{<<"arguments">> => Arguments}}]}))]
                                     || {I, #{<<"id">> := CallId, <<"function">> := #{<<"name">> := Name, <<"arguments">> := Arguments}}}
                                            <- lists:enumerate(Calls)]);
                #{<<"content">> := Text} ->
                    [Chunk(Delta(#{<<"role">> => <<"assistant">>, <<"content">> => <<>>}))]
                    ++ [Chunk(Delta(#{<<"content">> => Piece})) || Piece <- pieces(Text)]
            end,
            Last = Chunk([#{<<"index">> => 0, <<"delta">> => #{}, <<"finish_reason">> => Finish}]),
            Tail = case maps:get(<<"stream_options">>, Request, #{}) of
                #{<<"include_usage">> := true} -> [(Chunk([]))#{<<"usage">> => Usage}];
                _ -> []
            end,
            {200, Extra, {events, [[<<"data: ">>, json:encode(Data), <<"\n\n">>] || Data <- Deltas ++ [Last | Tail]]
                                  ++ [<<"data: [DONE]\n\n">>]}}
    end.

chat_message(_Model, {calls, Calls}, Step) ->
    ToolCalls = [#{<<"id">> => call_id("call_", Step, I),
                   <<"type">> => <<"function">>,
                   <<"function">> => #{<<"name">> => Name, <<"arguments">> => arguments(Call)}}
                 || {I, #{<<"name">> := Name} = Call} <- lists:enumerate(Calls)],
    {#{<<"role">> => <<"assistant">>, <<"content">> => null, <<"tool_calls">> => ToolCalls}, <<"tool_calls">>, 3 * length(Calls)};
chat_message(Model, {text, Text}, _Step) ->
    {#{<<"role">> => <<"assistant">>, <<"content">> => Text}, finish(Model, <<"stop">>, <<"length">>), words(Text)}.

%%% OpenAI Responses

responses(#{<<"model">> := <<"fake-500">>}, _Headers, _Path) ->
    {Status, Extra, Message} = server_error(),
    failure(Status, Extra, Message, <<"server_error">>, null);
responses(#{<<"model">> := Model} = Request, Headers, Path) ->
    Instructions = case maps:get(<<"instructions">>, Request, null) of
        null -> [];
        Given -> [{system, text(Given)}]
    end,
    Entries = Instructions ++ response_entries(maps:get(<<"input">>, Request, []), []),
    {Answer, Step} = pick(Request, Headers, Path, Entries),
    N = length(Entries),
    {Output, Completion} = response_output(N, Answer, Step),
    Prompt = 10 * N + 5 * length(maps:get(<<"tools">>, Request, [])),
    Status = case finish(Model, <<"completed">>, <<"incomplete">>) of
        <<"incomplete">> -> #{<<"status">> => <<"incomplete">>, <<"incomplete_details">> => #{<<"reason">> => <<"max_output_tokens">>}};
        Completed -> #{<<"status">> => Completed, <<"incomplete_details">> => null}
    end,
    Response = maps:merge(Status, #{
        <<"id">> => <<"resp_fake_", (integer_to_binary(N))/binary>>,
        <<"object">> => <<"response">>,
        <<"created_at">> => ?EPOCH + N,
        <<"model">> => <<Model/binary, "-2026-01-01">>,
        <<"output">> => Output,
        <<"error">> => null,
        <<"instructions">> => maps:get(<<"instructions">>, Request, null),
        <<"metadata">> => #{},
        <<"parallel_tool_calls">> => true,
        <<"temperature">> => 1,
        <<"top_p">> => 1,
        <<"tool_choice">> => maps:get(<<"tool_choice">>, Request, <<"auto">>),
        <<"tools">> => maps:get(<<"tools">>, Request, []),
        <<"text">> => maps:get(<<"text">>, Request, #{<<"format">> => #{<<"type">> => <<"text">>}}),
        <<"usage">> => #{
            <<"input_tokens">> => Prompt,
            <<"input_tokens_details">> => #{<<"cached_tokens">> => 0},
            <<"output_tokens">> => Completion,
            <<"output_tokens_details">> => #{<<"reasoning_tokens">> => 0},
            <<"total_tokens">> => Prompt + Completion
        }
    }),
    Extra = [{<<"x-request-id">>, <<"req_fake_", (integer_to_binary(N))/binary>>}],
    case is_streamed(Request) of
        false -> {200, Extra, json:encode(Response)};
        true -> {200, Extra, {events, response_events(Response)}}
    end.

%% The entries of a Responses `input`: a string, or a list of items. The
%% function calls of one step are adjacent items, so they form one entry.
response_entries(Text, []) when is_binary(Text) -> [{user, Text}];
response_entries([], Entries) -> lists:reverse(Entries);
response_entries([#{<<"type">> := <<"function_call">>, <<"call_id">> := Id, <<"name">> := Name} | Items], [{assistant, Calls} | Entries]) when Calls =/= [] ->
    response_entries(Items, [{assistant, Calls ++ [{Id, Name}]} | Entries]);
response_entries([#{<<"type">> := <<"function_call">>, <<"call_id">> := Id, <<"name">> := Name} | Items], Entries) ->
    response_entries(Items, [{assistant, [{Id, Name}]} | Entries]);
response_entries([#{<<"type">> := <<"function_call_output">>, <<"call_id">> := Id, <<"output">> := Output} | Items], Entries) ->
    response_entries(Items, [{result, Id, text(Output)} | Entries]);
response_entries([#{<<"role">> := Role} = Item | Items], Entries) when Role =:= <<"system">>; Role =:= <<"developer">> ->
    response_entries(Items, [{system, text(maps:get(<<"content">>, Item, <<>>))} | Entries]);
response_entries([#{<<"role">> := <<"user">>} = Item | Items], Entries) ->
    response_entries(Items, [{user, text(maps:get(<<"content">>, Item, <<>>))} | Entries]);
response_entries([#{<<"role">> := <<"assistant">>} | Items], Entries) ->
    response_entries(Items, [{assistant, []} | Entries]);
response_entries([_Item | Items], Entries) ->
    response_entries(Items, Entries).

response_output(_N, {calls, Calls}, Step) ->
    {[#{<<"type">> => <<"function_call">>,
        <<"id">> => call_id("fc_fake_", Step, I),
        <<"call_id">> => call_id("call_", Step, I),
        <<"name">> => Name,
        <<"arguments">> => arguments(Call),
        <<"status">> => <<"completed">>}
      || {I, #{<<"name">> := Name} = Call} <- lists:enumerate(Calls)], 3 * length(Calls)};
response_output(N, {text, Text}, _Step) ->
    {[#{<<"type">> => <<"message">>,
        <<"id">> => <<"msg_fake_", (integer_to_binary(N))/binary>>,
        <<"status">> => <<"completed">>,
        <<"role">> => <<"assistant">>,
        <<"content">> => [#{<<"type">> => <<"output_text">>, <<"text">> => Text, <<"annotations">> => [], <<"logprobs">> => []}]}],
     words(Text)}.

%% The events of a streamed response, in the order that the API sends them.
response_events(#{<<"output">> := Output} = Response) ->
    Started = Response#{<<"status">> => <<"in_progress">>, <<"output">> => [], <<"incomplete_details">> => null},
    Events = [{<<"response.created">>, #{<<"response">> => Started}},
              {<<"response.in_progress">>, #{<<"response">> => Started}}]
             ++ lists:append([item_events(Index - 1, Item) || {Index, Item} <- lists:enumerate(Output)])
             ++ [{done_event(Response), #{<<"response">> => Response}}],
    [[<<"event: ">>, Type, <<"\ndata: ">>, json:encode(Data#{<<"type">> => Type, <<"sequence_number">> => Sequence - 1}), <<"\n\n">>]
     || {Sequence, {Type, Data}} <- lists:enumerate(Events)].

done_event(#{<<"status">> := <<"incomplete">>}) -> <<"response.incomplete">>;
done_event(_Response) -> <<"response.completed">>.

item_events(Index, #{<<"type">> := <<"message">>, <<"id">> := Id, <<"content">> := [#{<<"text">> := Text} = Part]} = Item) ->
    Place = #{<<"item_id">> => Id, <<"output_index">> => Index, <<"content_index">> => 0},
    [{<<"response.output_item.added">>, #{<<"output_index">> => Index, <<"item">> => Item#{<<"status">> => <<"in_progress">>, <<"content">> => []}}},
     {<<"response.content_part.added">>, Place#{<<"part">> => Part#{<<"text">> => <<>>}}}]
    ++ [{<<"response.output_text.delta">>, Place#{<<"delta">> => Piece, <<"logprobs">> => []}} || Piece <- pieces(Text)]
    ++ [{<<"response.output_text.done">>, Place#{<<"text">> => Text, <<"logprobs">> => []}},
        {<<"response.content_part.done">>, Place#{<<"part">> => Part}},
        {<<"response.output_item.done">>, #{<<"output_index">> => Index, <<"item">> => Item}}];
item_events(Index, #{<<"type">> := <<"function_call">>, <<"id">> := Id, <<"arguments">> := Arguments} = Item) ->
    Place = #{<<"item_id">> => Id, <<"output_index">> => Index},
    [{<<"response.output_item.added">>, #{<<"output_index">> => Index, <<"item">> => Item#{<<"status">> => <<"in_progress">>, <<"arguments">> => <<>>}}},
     {<<"response.function_call_arguments.delta">>, Place#{<<"delta">> => Arguments}},
     {<<"response.function_call_arguments.done">>, Place#{<<"arguments">> => Arguments}},
     {<<"response.output_item.done">>, #{<<"output_index">> => Index, <<"item">> => Item}}].

%%% Anthropic Messages

messages(#{<<"model">> := <<"fake-500">>}, _Headers, _Path) ->
    {Status, Extra, Message} = server_error(),
    anthropic_failure(Status, Extra, Message, <<"api_error">>);
messages(#{<<"model">> := Model, <<"messages">> := Messages} = Request, Headers, Path) ->
    System = case maps:get(<<"system">>, Request, null) of
        null -> [];
        Given -> [{system, text(Given)}]
    end,
    Entries = System ++ lists:flatmap(fun message_entries/1, Messages),
    {Answer, Step} = pick(Request, Headers, Path, Entries),
    N = length(Entries),
    {Content, Stop, Completion} = case Answer of
        {calls, Calls} ->
            {[#{<<"type">> => <<"tool_use">>, <<"id">> => call_id("toolu_fake_", Step, I), <<"name">> => Name, <<"input">> => input(Call)}
              || {I, #{<<"name">> := Name} = Call} <- lists:enumerate(Calls)], <<"tool_use">>, 3 * length(Calls)};
        {text, Text} ->
            {[#{<<"type">> => <<"text">>, <<"text">> => Text}], finish(Model, <<"end_turn">>, <<"max_tokens">>), words(Text)}
    end,
    Prompt = 10 * N + 5 * length(maps:get(<<"tools">>, Request, [])),
    Usage = #{<<"input_tokens">> => Prompt, <<"output_tokens">> => Completion,
              <<"cache_creation_input_tokens">> => 0, <<"cache_read_input_tokens">> => 0},
    Message = #{
        <<"id">> => <<"msg_fake_", (integer_to_binary(N))/binary>>,
        <<"type">> => <<"message">>,
        <<"role">> => <<"assistant">>,
        <<"model">> => <<Model/binary, "-20260101">>,
        <<"content">> => Content,
        <<"stop_reason">> => Stop,
        <<"stop_sequence">> => null,
        <<"usage">> => Usage
    },
    Extra = [{<<"request-id">>, <<"req_fake_", (integer_to_binary(N))/binary>>}],
    case is_streamed(Request) of
        false -> {200, Extra, json:encode(Message)};
        true -> {200, Extra, {events, message_events(Message)}}
    end.

message_entries(#{<<"role">> := <<"user">>, <<"content">> := Text}) when is_binary(Text) -> [{user, Text}];
message_entries(#{<<"role">> := <<"user">>, <<"content">> := Blocks}) ->
    Results = [{result, Id, text(Content)} || #{<<"type">> := <<"tool_result">>, <<"tool_use_id">> := Id} = Block <- Blocks,
                                             Content <- [maps:get(<<"content">>, Block, <<>>)]],
    case [Block || #{<<"type">> := <<"text">>} = Block <- Blocks] of
        [] -> Results;
        Texts -> Results ++ [{user, text(Texts)}]
    end;
message_entries(#{<<"role">> := <<"assistant">>, <<"content">> := Blocks}) when is_list(Blocks) ->
    [{assistant, [{Id, Name} || #{<<"type">> := <<"tool_use">>, <<"id">> := Id, <<"name">> := Name} <- Blocks]}];
message_entries(#{<<"role">> := <<"assistant">>}) -> [{assistant, []}];
message_entries(_Message) -> [].

%% The events of a streamed message, in the order that the API sends them.
message_events(#{<<"content">> := Content, <<"stop_reason">> := Stop, <<"usage">> := Usage} = Message) ->
    Started = Message#{<<"content">> => [], <<"stop_reason">> => null, <<"usage">> => Usage#{<<"output_tokens">> => 1}},
    Events = [{<<"message_start">>, #{<<"message">> => Started}}]
             ++ lists:append([block_events(Index - 1, Block) || {Index, Block} <- lists:enumerate(Content)])
             ++ [{<<"message_delta">>, #{<<"delta">> => #{<<"stop_reason">> => Stop, <<"stop_sequence">> => null},
                                         <<"usage">> => #{<<"output_tokens">> => maps:get(<<"output_tokens">>, Usage)}}},
                 {<<"message_stop">>, #{}}],
    [[<<"event: ">>, Type, <<"\ndata: ">>, json:encode(Data#{<<"type">> => Type}), <<"\n\n">>] || {Type, Data} <- Events].

block_events(Index, #{<<"type">> := <<"text">>, <<"text">> := Text}) ->
    [{<<"content_block_start">>, #{<<"index">> => Index, <<"content_block">> => #{<<"type">> => <<"text">>, <<"text">> => <<>>}}}]
    ++ [{<<"content_block_delta">>, #{<<"index">> => Index, <<"delta">> => #{<<"type">> => <<"text_delta">>, <<"text">> => Piece}}}
        || Piece <- pieces(Text)]
    ++ [{<<"content_block_stop">>, #{<<"index">> => Index}}];
block_events(Index, #{<<"type">> := <<"tool_use">>, <<"input">> := Input} = Block) ->
    [{<<"content_block_start">>, #{<<"index">> => Index, <<"content_block">> => Block#{<<"input">> => #{}}}},
     {<<"content_block_delta">>, #{<<"index">> => Index, <<"delta">> => #{<<"type">> => <<"input_json_delta">>,
                                                                         <<"partial_json">> => iolist_to_binary(json:encode(Input))}}},
     {<<"content_block_stop">>, #{<<"index">> => Index}}].

%% JSON with sorted object keys, so a key order difference between two clients
%% does not show.
canonical(Value) ->
    iolist_to_binary(json:encode(Value, fun encode/2)).

encode(Map, Encode) when is_map(Map) -> json:encode_key_value_list(lists:sort(maps:to_list(Map)), Encode);
encode(Value, Encode) -> json:encode_value(Value, Encode).
