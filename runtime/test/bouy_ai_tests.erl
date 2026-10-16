-module(bouy_ai_tests).

%% generateText over a scripted model, and the OpenAI provider against the
%% fake server. tests/equivalence/ai compares both with the real packages.

-include_lib("eunit/include/eunit.hrl").

%%% A scripted model: each call answers with the next response of the list.

model(Responses) ->
    Counter = counters:new(1, []),
    Generate = fun(Call) ->
        ok = counters:add(Counter, 1, 1),
        Answer = lists:nth(counters:get(Counter, 1), Responses),
        Answer(Call)
    end,
    #{<<"provider">> => <<"test.chat">>, <<"modelId">> => <<"scripted">>, '$generate' => Generate}.

text(Text) ->
    fun(_Call) -> response([#{<<"type">> => <<"text">>, <<"text">> => Text}], <<"stop">>) end.

calls(Calls) ->
    fun(_Call) ->
        response([#{<<"type">> => <<"tool-call">>, <<"toolCallId">> => Id, <<"toolName">> => Name, <<"input">> => Input}
                  || {Id, Name, Input} <- Calls], <<"tool-calls">>)
    end.

response(Content, Finish) ->
    #{content => Content, finish_reason => Finish, raw_finish_reason => Finish, warnings => [],
      usage => usage(10, 2), provider_metadata => #{},
      response => #{<<"id">> => <<"r">>, <<"modelId">> => <<"scripted-1">>, <<"timestamp">> => undefined, <<"headers">> => #{}}}.

usage(Input, Output) ->
    #{<<"inputTokens">> => Input,
      <<"inputTokenDetails">> => #{<<"noCacheTokens">> => Input, <<"cacheReadTokens">> => 0, <<"cacheWriteTokens">> => undefined},
      <<"outputTokens">> => Output,
      <<"outputTokenDetails">> => #{<<"textTokens">> => Output, <<"reasoningTokens">> => 0},
      <<"totalTokens">> => Input + Output,
      <<"raw">> => #{}}.

generate(Options) ->
    bouy_ai:generateText([Options]).

thrown(Fun) ->
    try Fun() of
        Value -> {returned, Value}
    catch
        error:{'$throw', Error} -> Error
    end.

add_tool() ->
    #{<<"inputSchema">> => bouy_ai:jsonSchema([#{<<"type">> => <<"object">>}]),
      <<"execute">> => fun([#{<<"a">> := A, <<"b">> := B} | _]) -> A + B end}.

text_test() ->
    Result = generate(#{<<"model">> => model([text(<<"hi">>)]), <<"prompt">> => <<"hello">>}),
    ?assertEqual(<<"hi">>, maps:get(<<"text">>, Result)),
    ?assertEqual(<<"stop">>, maps:get(<<"finishReason">>, Result)),
    ?assertEqual(<<"hi">>, maps:get(<<"output">>, Result)),
    ?assertMatch(#{<<"id">> := <<"r">>, <<"modelId">> := <<"scripted-1">>, <<"timestamp">> := {'$date', _}},
                 maps:get(<<"response">>, Result)),
    ?assertEqual(12, maps:get(<<"totalTokens">>, maps:get(<<"usage">>, Result))).

steps_run_tools_until_text_test() ->
    Model = model([calls([{<<"c1">>, <<"add">>, <<"{\"a\":2,\"b\":3}">>}]), text(<<"done">>)]),
    Result = generate(#{<<"model">> => Model, <<"prompt">> => <<"go">>, <<"tools">> => #{<<"add">> => add_tool()},
                        <<"stopWhen">> => bouy_ai:stepCountIs([5])}),
    [First, Second] = maps:get(<<"steps">>, Result),
    ?assertMatch([#{<<"output">> := 5, <<"toolCallId">> := <<"c1">>}], maps:get(<<"toolResults">>, First)),
    ?assertEqual(<<"done">>, maps:get(<<"text">>, Second)),
    ?assertEqual(<<"done">>, maps:get(<<"text">>, Result)),
    %% The sum of two steps keeps no raw usage.
    ?assertEqual(24, maps:get(<<"totalTokens">>, maps:get(<<"totalUsage">>, Result))),
    ?assertNot(maps:is_key(<<"raw">>, maps:get(<<"totalUsage">>, Result))),
    ?assertMatch([#{<<"role">> := <<"assistant">>}, #{<<"role">> := <<"tool">>}, #{<<"role">> := <<"assistant">>}],
                 maps:get(<<"responseMessages">>, Result)).

default_stop_is_one_step_test() ->
    Model = model([calls([{<<"c1">>, <<"add">>, <<"{\"a\":1,\"b\":1}">>}]), text(<<"never">>)]),
    Result = generate(#{<<"model">> => Model, <<"prompt">> => <<"go">>, <<"tools">> => #{<<"add">> => add_tool()}}),
    ?assertEqual(1, length(maps:get(<<"steps">>, Result))),
    ?assertEqual(<<"tool-calls">>, maps:get(<<"finishReason">>, Result)),
    ?assertEqual(undefined, maps:get(<<"output">>, Result)).

invalid_calls_go_back_to_the_model_test() ->
    Model = model([calls([{<<"c1">>, <<"nope">>, <<"{}">>}, {<<"c2">>, <<"add">>, <<"#">>}]), text(<<"ok">>)]),
    Result = generate(#{<<"model">> => Model, <<"prompt">> => <<"go">>, <<"tools">> => #{<<"add">> => add_tool()},
                        <<"stopWhen">> => bouy_ai:stepCountIs([5])}),
    [First | _] = maps:get(<<"steps">>, Result),
    Errors = [Error || #{<<"type">> := <<"tool-error">>, <<"error">> := Error} <- maps:get(<<"content">>, First)],
    ?assertMatch([<<"AI_NoSuchToolError: Model tried to call unavailable tool 'nope'. Available tools: add.">>,
                  <<"AI_InvalidToolInputError: Invalid input for tool add: AI_JSONParseError: ", _/binary>>], Errors),
    ?assertEqual(2, length(maps:get(<<"dynamicToolCalls">>, Result))).

a_throwing_tool_is_a_tool_error_test() ->
    Tool = #{<<"execute">> => fun(_) -> bouy_error:throw(<<"Error">>, <<"boom">>) end},
    Model = model([calls([{<<"c1">>, <<"fail">>, <<"">>}]), text(<<"ok">>)]),
    Result = generate(#{<<"model">> => Model, <<"prompt">> => <<"go">>, <<"tools">> => #{<<"fail">> => Tool},
                        <<"stopWhen">> => bouy_ai:stepCountIs([2])}),
    [First, _] = maps:get(<<"steps">>, Result),
    [#{<<"role">> := <<"tool">>, <<"content">> := [#{<<"output">> := Output}]}] =
        [Message || #{<<"role">> := <<"tool">>} = Message <- maps:get(<<"messages">>, maps:get(<<"response">>, First))],
    ?assertEqual(#{<<"type">> => <<"error-text">>, <<"value">> => <<"Error: boom">>}, Output).

retries_end_in_retry_error_test() ->
    Failure = fun(_Call) ->
        erlang:error({'$throw', bouy_ai:ai_error(<<"APICallError">>, <<"down">>,
                                                 #{<<"isRetryable">> => true, <<"responseHeaders">> => #{<<"retry-after-ms">> => <<"0">>}})})
    end,
    Error = thrown(fun() -> generate(#{<<"model">> => model([Failure, Failure, Failure]), <<"prompt">> => <<"go">>}) end),
    ?assertMatch(#{<<"name">> := <<"AI_RetryError">>, <<"reason">> := <<"maxRetriesExceeded">>,
                   <<"message">> := <<"Failed after 3 attempts. Last error: AI_APICallError: down">>}, Error),
    ?assertEqual(3, length(maps:get(<<"errors">>, Error))).

a_non_retryable_error_passes_through_test() ->
    Failure = fun(_Call) -> erlang:error({'$throw', bouy_ai:ai_error(<<"APICallError">>, <<"no">>, #{<<"isRetryable">> => false})}) end,
    ?assertMatch(#{<<"name">> := <<"AI_APICallError">>, <<"message">> := <<"no">>},
                 thrown(fun() -> generate(#{<<"model">> => model([Failure]), <<"prompt">> => <<"go">>}) end)).

prompt_errors_test() ->
    Model = model([text(<<"x">>)]),
    ?assertMatch(#{<<"name">> := <<"AI_InvalidPromptError">>, <<"message">> := <<"Invalid prompt: prompt or messages must be defined">>},
                 thrown(fun() -> generate(#{<<"model">> => Model}) end)),
    ?assertMatch(#{<<"name">> := <<"TypeError">>},
                 thrown(fun() -> generate(#{<<"model">> => Model, <<"prompt">> => <<"x">>, <<"onFinish">> => fun(_) -> ok end}) end)),
    ?assertMatch(#{<<"name">> := <<"TypeError">>},
                 thrown(fun() -> generate(#{<<"model">> => <<"openai/gpt-4o">>, <<"prompt">> => <<"x">>}) end)).

tool_choice_violation_test() ->
    Error = thrown(fun() -> generate(#{<<"model">> => model([text(<<"x">>)]), <<"prompt">> => <<"x">>,
                                       <<"tools">> => #{<<"add">> => add_tool()}, <<"toolChoice">> => <<"required">>}) end),
    ?assertMatch(#{<<"name">> := <<"AI_ToolChoiceViolationError">>, <<"finishReason">> := <<"stop">>}, Error).

stream_text_is_not_supported_test() ->
    ?assertMatch(#{<<"name">> := <<"TypeError">>, <<"message">> := <<"streamText is not supported yet: use generateText">>},
                 thrown(fun() -> bouy_ai:streamText([#{}]) end)).

%%% The OpenAI provider against the fake server

openai_test_() ->
    {setup,
     fun() -> bouy_fake_openai:start() end,
     fun({Server, _Port}) -> bouy_fake_openai:stop(Server) end,
     fun({_Server, Port}) ->
         Base = iolist_to_binary(io_lib:format("http://127.0.0.1:~b/v1/", [Port])),
         Provider = fun(Key) -> bouy_ai_openai:createOpenAI([#{<<"baseURL">> => Base, <<"apiKey">> => Key}]) end,
         Chat = fun(Key, Model) -> maps:get('$call', Provider(Key)) ([Model]) end,
         [?_test(openai_text(Chat(<<"sk-fake-key">>, <<"gpt-4o-mini">>))),
          ?_test(openai_tools(Chat(<<"sk-fake-key">>, <<"gpt-4o-mini">>))),
          ?_test(openai_unauthorized(Chat(<<"sk-wrong">>, <<"gpt-4o-mini">>))),
          ?_test(openai_server_error(Chat(<<"sk-fake-key">>, <<"fake-500">>))),
          ?_test(openai_developer_role(Chat(<<"sk-fake-key">>, <<"o3-echo">>))),
          ?_test(openai_refused())]
     end}.

openai_text(Model) ->
    Result = generate(#{<<"model">> => Model, <<"system">> => <<"Be terse">>, <<"prompt">> => <<"hi">>}),
    ?assertEqual(<<"Hello! System: Be terse. You said: hi">>, maps:get(<<"text">>, Result)),
    ?assertMatch(#{<<"id">> := <<"chatcmpl-fake-2">>, <<"modelId">> := <<"gpt-4o-mini-2026-01-01">>,
                   <<"timestamp">> := {'$date', 1767225602000}, <<"headers">> := #{<<"x-request-id">> := <<"req_fake_2">>}},
                 maps:get(<<"response">>, Result)),
    ?assertMatch(#{<<"inputTokens">> := 20, <<"outputTokens">> := 7, <<"totalTokens">> := 27},
                 maps:get(<<"usage">>, Result)).

openai_tools(Model) ->
    Prompt = <<"CALLS [[{\"name\":\"add\",\"input\":{\"a\":2,\"b\":3}}]]">>,
    Result = generate(#{<<"model">> => Model, <<"prompt">> => Prompt, <<"tools">> => #{<<"add">> => add_tool()},
                        <<"stopWhen">> => bouy_ai:stepCountIs([3])}),
    ?assertEqual(<<"Results: add -> 5">>, maps:get(<<"text">>, Result)),
    ?assertMatch([#{<<"toolCallId">> := <<"call_1_1">>, <<"input">> := #{<<"a">> := 2}}], maps:get(<<"toolCalls">>, Result)).

openai_unauthorized(Model) ->
    Error = thrown(fun() -> generate(#{<<"model">> => Model, <<"prompt">> => <<"hi">>}) end),
    ?assertMatch(#{<<"name">> := <<"AI_APICallError">>, <<"statusCode">> := 401, <<"isRetryable">> := false,
                   <<"message">> := <<"Incorrect API key provided: sk-wrong.">>}, Error).

openai_server_error(Model) ->
    Error = thrown(fun() -> generate(#{<<"model">> => Model, <<"prompt">> => <<"hi">>, <<"maxRetries">> => 0}) end),
    ?assertMatch(#{<<"name">> := <<"AI_APICallError">>, <<"statusCode">> := 500, <<"isRetryable">> := true,
                   <<"responseHeaders">> := #{<<"retry-after-ms">> := <<"0">>}}, Error).

%% A reasoning model gets the system prompt as a developer message.
openai_developer_role(Model) ->
    Result = generate(#{<<"model">> => Model, <<"system">> => <<"S">>, <<"prompt">> => <<"p">>, <<"temperature">> => 1}),
    #{<<"body">> := #{<<"messages">> := [System | _]} = Body} = json:decode(maps:get(<<"text">>, Result)),
    ?assertEqual(#{<<"role">> => <<"developer">>, <<"content">> => <<"S">>}, System),
    ?assertNot(maps:is_key(<<"temperature">>, Body)),
    ?assertMatch([#{<<"feature">> := <<"temperature">>}], maps:get(<<"warnings">>, Result)).

openai_refused() ->
    {ok, Socket} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Socket),
    ok = gen_tcp:close(Socket),
    Base = iolist_to_binary(io_lib:format("http://127.0.0.1:~b/v1", [Port])),
    Model = maps:get('$call', bouy_ai_openai:createOpenAI([#{<<"baseURL">> => Base, <<"apiKey">> => <<"k">>}])) ([<<"m">>]),
    Error = thrown(fun() -> generate(#{<<"model">> => Model, <<"prompt">> => <<"hi">>, <<"maxRetries">> => 0}) end),
    Expected = iolist_to_binary(io_lib:format("Cannot connect to API: connect ECONNREFUSED 127.0.0.1:~b", [Port])),
    ?assertMatch(#{<<"name">> := <<"AI_APICallError">>, <<"isRetryable">> := true, <<"statusCode">> := undefined}, Error),
    ?assertEqual(Expected, maps:get(<<"message">>, Error)).

provider_test() ->
    Provider = bouy_ai_openai:createOpenAI([#{<<"baseURL">> => <<"http://example.test/v1/">>, <<"name">> => <<"proxy">>}]),
    ?assertEqual(<<"function">>, bouy_rt:type_of(Provider)),
    ?assertMatch(#{<<"provider">> := <<"proxy.chat">>, <<"modelId">> := <<"m">>}, bouy_rt:call(Provider, [<<"m">>])),
    ?assertMatch(#{<<"provider">> := <<"openai.chat">>}, bouy_ai_openai:'$call'([<<"m">>])),
    ?assertMatch(#{<<"name">> := <<"AI_InvalidArgumentError">>},
                 thrown(fun() -> bouy_ai_openai:createOpenAI([#{<<"baseURL">> => <<" ">>}]) end)).
