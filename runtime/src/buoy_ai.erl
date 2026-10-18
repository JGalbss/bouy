-module(buoy_ai).

%% The subset of `ai` 7.0.142 in contract section 14: generateText with
%% tools and stop conditions, over a language model of buoy_ai_openai. The
%% result and its steps hold, as fields, the values that the classes of `ai`
%% compute in getters.

-export([generateText/1, streamText/1, tool/1, stepCountIs/1, jsonSchema/1]).
%% For buoy_ai_openai.
-export([ai_error/3, error_message/1, random_id/1]).

-type value() :: buoy_rt:value().

%% The options of generateText that Buoy honors. Another option throws a
%% TypeError, so an option that would change the result never passes
%% silently.
-define(OPTIONS, [<<"model">>, <<"system">>, <<"instructions">>, <<"prompt">>, <<"messages">>,
                  <<"tools">>, <<"toolChoice">>, <<"stopWhen">>, <<"maxRetries">>, <<"headers">>,
                  <<"maxOutputTokens">>, <<"temperature">>, <<"topP">>, <<"topK">>,
                  <<"presencePenalty">>, <<"frequencyPenalty">>, <<"stopSequences">>, <<"seed">>]).
%% The schema of a tool without an inputSchema.
-define(EMPTY_SCHEMA, #{<<"type">> => <<"object">>, <<"properties">> => #{}, <<"additionalProperties">> => false}).
-define(ID_ALPHABET, <<"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz">>).
-define(NULLISH(Value), (Value =:= undefined orelse Value =:= null)).

%%% generateText

-spec generateText([value()]) -> map().
generateText(Args) ->
    Options = buoy_rt:arg(1, Args),
    ok = check_options(Options),
    Model = buoy_rt:get(Options, <<"model">>),
    Generate = generator(Model),
    Retries = retries(buoy_rt:get(Options, <<"maxRetries">>)),
    {Instructions, Messages} = prompt(Options),
    Tools = buoy_rt:get(Options, <<"tools">>),
    Call = #{instructions => Instructions,
             tools => definitions(Tools),
             tool_choice => tool_choice(buoy_rt:get(Options, <<"toolChoice">>)),
             options => Options},
    Turn = #{generate => fun(Input) -> retry(fun() -> Generate(Call#{messages => Input}) end, Retries) end,
             call_id => <<"call-", (random_id(24))/binary>>,
             tool_choice => maps:get(tool_choice, Call),
             model => #{<<"provider">> => maps:get(<<"provider">>, Model), <<"modelId">> => maps:get(<<"modelId">>, Model)},
             tools => Tools,
             stop => conditions(buoy_rt:get(Options, <<"stopWhen">>))},
    result(steps(Turn, Messages, [])).

-spec streamText([value()]) -> no_return().
streamText(_Args) ->
    buoy_error:throw(<<"TypeError">>, <<"streamText is not supported yet: use generateText">>).

%% `tool(definition)` returns the definition, as in `ai`.
-spec tool([value()]) -> value().
tool(Args) ->
    buoy_rt:arg(1, Args).

-spec stepCountIs([value()]) -> fun((list()) -> boolean()).
stepCountIs(Args) ->
    Count = buoy_rt:arg(1, Args),
    fun(Event) ->
        Steps = buoy_rt:get(buoy_rt:arg(1, Event), <<"steps">>),
        buoy_rt:strict_eq(buoy_rt:get(Steps, <<"length">>), Count)
    end.

%% `jsonSchema(schema)`. The atom key marks the value as a schema, as the
%% symbol of `ai` does.
-spec jsonSchema([value()]) -> map().
jsonSchema(Args) ->
    case buoy_rt:arg(2, Args) of
        #{<<"validate">> := Validate} when Validate =/= undefined ->
            buoy_error:throw(<<"TypeError">>, <<"jsonSchema does not support validate yet">>);
        _ ->
            ok
    end,
    Schema = case buoy_rt:arg(1, Args) of
        Lazy when is_function(Lazy, 1) -> Lazy([]);
        Value -> Value
    end,
    #{'$schema' => true, <<"jsonSchema">> => Schema, <<"validate">> => undefined, <<"_type">> => undefined}.

check_options(Options) when is_map(Options) ->
    case [Key || {Key, _} <- buoy_object:own_entries(Options), not lists:member(Key, ?OPTIONS)] of
        [] -> ok;
        [Key | _] -> buoy_error:throw(<<"TypeError">>, <<"generateText does not support the option ", Key/binary, " yet">>)
    end;
check_options(_Options) ->
    ok.

generator(#{'$generate' := Generate}) ->
    Generate;
generator(_Model) ->
    buoy_error:throw(<<"TypeError">>, <<"generateText needs a model of @ai-sdk/openai, such as openai.chat(\"gpt-4o-mini\")">>).

retries(undefined) ->
    2;
retries(Count) ->
    case buoy_number:'isInteger'([Count]) of
        false -> invalid_argument(<<"maxRetries">>, Count, <<"maxRetries must be an integer">>);
        true when Count < 0 -> invalid_argument(<<"maxRetries">>, Count, <<"maxRetries must be >= 0">>);
        true -> round(Count)
    end.

-spec invalid_argument(binary(), value(), binary()) -> no_return().
invalid_argument(Parameter, Value, Message) ->
    erlang:error({'$throw', ai_error(<<"InvalidArgumentError">>,
                                     <<"Invalid argument for parameter ", Parameter/binary, ": ", Message/binary>>,
                                     #{<<"parameter">> => Parameter, <<"value">> => Value})}).

%% standardizePrompt: the instructions and the messages of the first step.
prompt(Options) ->
    Instructions = case buoy_rt:get(Options, <<"instructions">>) of
        undefined -> buoy_rt:get(Options, <<"system">>);
        Given -> Given
    end,
    Prompt = buoy_rt:get(Options, <<"prompt">>),
    case prompt_messages(Instructions, Prompt, buoy_rt:get(Options, <<"messages">>)) of
        {ok, Messages} -> {Instructions, Messages};
        {invalid, Reason} -> invalid_prompt(Prompt, Reason)
    end.

%% The checks of standardizePrompt, in its order.
prompt_messages(_Instructions, Prompt, Messages) when ?NULLISH(Prompt), ?NULLISH(Messages) ->
    {invalid, <<"prompt or messages must be defined">>};
prompt_messages(_Instructions, Prompt, Messages) when not ?NULLISH(Prompt), not ?NULLISH(Messages) ->
    {invalid, <<"prompt and messages cannot be defined at the same time">>};
prompt_messages(Instructions, Prompt, Messages) ->
    case is_binary(Instructions) orelse lists:all(fun is_system/1, as_list(Instructions)) of
        true -> checked_messages(input_messages(Prompt, Messages));
        false -> {invalid, <<"instructions must be a string, SystemModelMessage, or array of SystemModelMessage">>}
    end.

input_messages(Text, _Messages) when is_binary(Text) -> [#{<<"role">> => <<"user">>, <<"content">> => Text}];
input_messages(List, _Messages) when is_list(List) -> List;
input_messages(_Prompt, Messages) -> Messages.

checked_messages(Messages) when not is_list(Messages) ->
    {invalid, <<"prompt or messages must be defined">>};
checked_messages([]) ->
    {invalid, <<"messages must not be empty">>};
checked_messages(Messages) ->
    case {lists:any(fun is_system/1, Messages), lists:all(fun is_message/1, Messages)} of
        {true, _} -> {invalid, <<"System messages are not allowed in the prompt or messages fields. Use the instructions option instead.">>};
        {false, false} -> {invalid, <<"The messages do not match the ModelMessage[] schema.">>};
        {false, true} -> {ok, Messages}
    end.

as_list(undefined) -> [];
as_list(List) when is_list(List) -> List;
as_list(Value) -> [Value].

is_system(#{<<"role">> := <<"system">>}) -> true;
is_system(_) -> false.

is_message(#{<<"role">> := Role, <<"content">> := Content}) ->
    lists:member(Role, [<<"user">>, <<"assistant">>, <<"tool">>]) andalso (is_binary(Content) orelse is_list(Content));
is_message(_) ->
    false.

-spec invalid_prompt(value(), binary()) -> no_return().
invalid_prompt(Prompt, Message) ->
    erlang:error({'$throw', ai_error(<<"InvalidPromptError">>, <<"Invalid prompt: ", Message/binary>>,
                                     #{<<"prompt">> => Prompt, <<"cause">> => undefined})}).

%% The tools as the model sees them, in key order.
definitions(Tools) when is_map(Tools), map_size(Tools) > 0 ->
    [definition(Name, Tool) || {Name, Tool} <- buoy_object:own_entries(Tools)];
definitions(_Tools) ->
    undefined.

definition(Name, Tool) ->
    lists:member(buoy_rt:get(Tool, <<"type">>), [undefined, <<"function">>, <<"dynamic">>]) orelse
        buoy_error:throw(<<"TypeError">>, <<"the tool ", Name/binary, " has a type that Buoy does not support">>),
    #{<<"type">> => <<"function">>,
      <<"name">> => Name,
      <<"inputSchema">> => input_schema(buoy_rt:get(Tool, <<"inputSchema">>)),
      <<"description">> => buoy_rt:get(Tool, <<"description">>),
      <<"strict">> => buoy_rt:get(Tool, <<"strict">>)}.

input_schema(undefined) -> ?EMPTY_SCHEMA;
input_schema(#{'$schema' := true, <<"jsonSchema">> := Schema}) -> Schema;
input_schema(_) -> buoy_error:throw(<<"TypeError">>, <<"a tool inputSchema must be jsonSchema(...) from \"ai\"">>).

tool_choice(undefined) -> #{<<"type">> => <<"auto">>};
tool_choice(Type) when is_binary(Type) -> #{<<"type">> => Type};
tool_choice(Choice) -> #{<<"type">> => <<"tool">>, <<"toolName">> => buoy_rt:get(Choice, <<"toolName">>)}.

conditions(undefined) -> [stepCountIs([1])];
conditions(List) when is_list(List) -> List;
conditions(Condition) -> [Condition].

%%% Steps

%% One model call per step. The next step starts while every tool call of the
%% step has an output and no stop condition holds.
steps(#{generate := Generate, tools := Tools} = Turn, Messages, Done) ->
    Response = Generate(Messages),
    Calls = [tool_call(Part, Tools) || #{<<"type">> := <<"tool-call">>} = Part <- maps:get(content, Response)],
    ok = check_tool_choice(Turn, Response, Calls),
    Outputs = tool_outputs(Calls, maps:get(finish_reason, Response), Tools, Messages),
    Step = step(length(Done), Turn, Response, Calls, Outputs),
    Steps = Done ++ [Step],
    case Calls =/= [] andalso length(Outputs) =:= length(Calls) andalso not stops(Turn, Steps) of
        true -> steps(Turn, Messages ++ maps:get(<<"messages">>, maps:get(<<"response">>, Step)), Steps);
        false -> Steps
    end.

%% A tool choice of "required" or of one tool needs a matching call.
check_tool_choice(#{tool_choice := #{<<"type">> := Type} = Choice, model := Model}, Response, Calls)
  when Type =:= <<"required">>; Type =:= <<"tool">> ->
    Wanted = maps:get(<<"toolName">>, Choice, undefined),
    case lists:any(fun(#{<<"toolName">> := Name}) -> Type =:= <<"required">> orelse Name =:= Wanted end, Calls) of
        true ->
            ok;
        false ->
            Message = case Type of
                <<"required">> -> <<"Model response did not contain a tool call even though tool choice was required.">>;
                _ -> <<"Model response did not contain a call to the required tool '", (buoy_rt:to_string(Wanted))/binary, "'.">>
            end,
            Fields = Model#{<<"toolChoice">> => Choice, <<"finishReason">> => maps:get(finish_reason, Response),
                            <<"content">> => maps:get(content, Response)},
            erlang:error({'$throw', ai_error(<<"ToolChoiceViolationError">>, Message, Fields)})
    end;
check_tool_choice(_Turn, _Response, _Calls) ->
    ok.

%% Every condition runs, as Promise.all runs them, before any one decides.
stops(#{stop := Conditions}, Steps) ->
    Event = #{<<"steps">> => Steps},
    lists:any(fun buoy_rt:truthy/1, [buoy_rt:call(Condition, [Event]) || Condition <- Conditions]).

%% A tool call with its input parsed, or an invalid call with the error that
%% goes back to the model.
tool_call(#{<<"toolCallId">> := Id, <<"toolName">> := Name, <<"input">> := Text}, Tools) ->
    Tool = own(Tools, Name),
    Call = #{<<"type">> => <<"tool-call">>, <<"toolCallId">> => Id, <<"toolName">> => Name,
             <<"providerExecuted">> => undefined, <<"providerMetadata">> => undefined, <<"title">> => field(Tool, <<"title">>)},
    try Call#{<<"input">> => tool_input(Tool, Tools, Name, Text)}
    catch
        error:{'$throw', Error} ->
            Call#{<<"input">> => parsed_or_text(Text), <<"dynamic">> => true, <<"invalid">> => true, <<"error">> => Error}
    end.

own(Tools, Name) when is_map(Tools) -> maps:get(Name, Tools, undefined);
own(_Tools, _Name) -> undefined.

%% `object?.[key]`.
field(Object, _Key) when ?NULLISH(Object) -> undefined;
field(Object, Key) -> buoy_rt:get(Object, Key).

tool_input(undefined, Tools, Name, _Text) ->
    Available = case is_map(Tools) of
        true -> <<"Available tools: ", (iolist_to_binary(lists:join(<<", ">>, [Key || {Key, _} <- buoy_object:own_entries(Tools)])))/binary, ".">>;
        false -> <<"No tools are available.">>
    end,
    erlang:error({'$throw', ai_error(<<"NoSuchToolError">>, <<"Model tried to call unavailable tool '", Name/binary, "'. ", Available/binary>>,
                                     #{<<"toolName">> => Name})});
tool_input(_Tool, _Tools, Name, Text) ->
    case buoy_string:trim(Text) of
        <<>> -> #{};
        _ -> parse_input(Name, Text)
    end.

parse_input(Name, Text) ->
    try buoy_json:parse([Text])
    catch
        error:{'$throw', Cause} ->
            Parse = ai_error(<<"JSONParseError">>, <<"JSON parsing failed: Text: ", Text/binary, ".\nError message: ", (error_message(Cause))/binary>>,
                             #{<<"text">> => Text, <<"cause">> => Cause}),
            erlang:error({'$throw', ai_error(<<"InvalidToolInputError">>, <<"Invalid input for tool ", Name/binary, ": ", (error_message(Parse))/binary>>,
                                             #{<<"toolInput">> => Text, <<"toolName">> => Name, <<"cause">> => Parse})})
    end.

parsed_or_text(Text) ->
    try buoy_json:parse([Text])
    catch
        error:{'$throw', _} -> Text
    end.

%% The outputs of a step: an error for each invalid call, then the result or
%% the error of each tool that has `execute`, when the finish reason allows
%% tools to run. The tools of one step run in parallel, as `Promise.all` runs
%% them.
tool_outputs(Calls, Finish, Tools, Messages) ->
    Invalid = [#{<<"type">> => <<"tool-error">>, <<"toolCallId">> => Id, <<"toolName">> => Name, <<"input">> => Input,
                 <<"error">> => error_message(Error), <<"dynamic">> => true}
               || #{<<"invalid">> := true, <<"toolCallId">> := Id, <<"toolName">> := Name, <<"input">> := Input, <<"error">> := Error} <- Calls],
    Valid = case lists:member(Finish, [<<"stop">>, <<"tool-calls">>]) of
        true -> [Call || Call <- Calls, not maps:is_key(<<"invalid">>, Call)];
        false -> []
    end,
    Results = buoy_task:all([fun() -> call_tool(Call, Tools, Messages) end || Call <- Valid]),
    Invalid ++ [Output || {output, Output} <- Results].

call_tool(#{<<"toolCallId">> := Id, <<"toolName">> := Name, <<"input">> := Input}, Tools, Messages) ->
    case field(own(Tools, Name), <<"execute">>) of
        undefined ->
            none;
        Implementation ->
            Options = #{<<"toolCallId">> => Id, <<"messages">> => Messages, <<"abortSignal">> => undefined, <<"context">> => undefined},
            Part = #{<<"toolCallId">> => Id, <<"toolName">> => Name, <<"input">> => Input, <<"dynamic">> => false},
            try buoy_rt:call(Implementation, [Input, Options]) of
                Output -> {output, Part#{<<"type">> => <<"tool-result">>, <<"output">> => Output}}
            catch
                error:Reason:Stack -> {output, Part#{<<"type">> => <<"tool-error">>, <<"error">> => buoy_rt:caught(Reason, Stack)}}
            end
    end.

step(Number, #{call_id := CallId, model := Model, tools := Tools}, Response, Calls, Outputs) ->
    #{content := Parts, finish_reason := Finish, raw_finish_reason := Raw, usage := Usage,
      response := Metadata, provider_metadata := ProviderMetadata, warnings := Warnings} = Response,
    Content = with_calls(Parts, Calls) ++ Outputs,
    ToolCalls = [Part || #{<<"type">> := <<"tool-call">>} = Part <- Content],
    ToolResults = [Part || #{<<"type">> := <<"tool-result">>} = Part <- Content],
    #{<<"callId">> => CallId,
      <<"stepNumber">> => Number,
      <<"model">> => Model,
      <<"runtimeContext">> => #{},
      <<"toolsContext">> => #{},
      <<"content">> => Content,
      <<"finishReason">> => Finish,
      <<"rawFinishReason">> => Raw,
      <<"usage">> => Usage,
      <<"warnings">> => Warnings,
      <<"request">> => #{<<"body">> => undefined, <<"messages">> => undefined},
      <<"response">> => (response_metadata(Metadata, Model))#{<<"body">> => undefined, <<"messages">> => response_messages(Content, Tools)},
      <<"providerMetadata">> => ProviderMetadata,
      <<"text">> => iolist_to_binary([Text || #{<<"type">> := <<"text">>, <<"text">> := Text} <- Content]),
      <<"reasoning">> => [],
      <<"reasoningText">> => undefined,
      <<"files">> => [],
      <<"sources">> => [],
      <<"toolCalls">> => ToolCalls,
      <<"staticToolCalls">> => [Call || Call <- ToolCalls, not is_dynamic(Call)],
      <<"dynamicToolCalls">> => [Call || Call <- ToolCalls, is_dynamic(Call)],
      <<"toolResults">> => ToolResults,
      <<"staticToolResults">> => [Result || Result <- ToolResults, not is_dynamic(Result)],
      <<"dynamicToolResults">> => [Result || Result <- ToolResults, is_dynamic(Result)]}.

is_dynamic(Part) -> maps:get(<<"dynamic">>, Part, false) =:= true.

%% The parts of the model, with each tool call replaced by its parsed form.
with_calls([#{<<"type">> := <<"tool-call">>} | Parts], [Call | Calls]) -> [Call | with_calls(Parts, Calls)];
with_calls([Part | Parts], Calls) -> [Part | with_calls(Parts, Calls)];
with_calls([], []) -> [].

%% The response metadata, with the defaults that generateText fills in.
response_metadata(Metadata, #{<<"modelId">> := ModelId}) ->
    #{<<"id">> => given(maps:get(<<"id">>, Metadata, undefined), fun() -> <<"aitxt-", (random_id(24))/binary>> end),
      <<"timestamp">> => given(maps:get(<<"timestamp">>, Metadata, undefined), fun() -> buoy_date:new([]) end),
      <<"modelId">> => given(maps:get(<<"modelId">>, Metadata, undefined), fun() -> ModelId end),
      <<"headers">> => maps:get(<<"headers">>, Metadata, undefined)}.

given(Value, Default) when ?NULLISH(Value) -> Default();
given(Value, _Default) -> Value.

%% toResponseMessages: the assistant message of a step and the tool message
%% that holds its tool outputs in the order of the calls.
response_messages(Content, Tools) ->
    Assistant = [assistant_part(Part) || Part <- Content, in_assistant(Part)],
    Order = maps:from_list([{Id, I} || {I, #{<<"type">> := <<"tool-call">>, <<"toolCallId">> := Id}} <- lists:enumerate(Content)]),
    Outputs = [{maps:get(Id, Order, length(Content) + 1), I, tool_result(Part, Tools)}
               || {I, #{<<"type">> := Type, <<"toolCallId">> := Id} = Part} <- lists:enumerate(Content),
                  Type =:= <<"tool-result">> orelse Type =:= <<"tool-error">>],
    [#{<<"role">> => <<"assistant">>, <<"content">> => Assistant} || Assistant =/= []] ++
        [#{<<"role">> => <<"tool">>, <<"content">> => [Part || {_, _, Part} <- lists:sort(Outputs)]} || Outputs =/= []].

in_assistant(#{<<"type">> := <<"text">>, <<"text">> := Text}) -> Text =/= <<>>;
in_assistant(#{<<"type">> := <<"tool-call">>}) -> true;
in_assistant(_) -> false.

assistant_part(#{<<"type">> := <<"text">>, <<"text">> := Text}) ->
    #{<<"type">> => <<"text">>, <<"text">> => Text, <<"providerOptions">> => undefined};
assistant_part(#{<<"type">> := <<"tool-call">>, <<"toolCallId">> := Id, <<"toolName">> := Name, <<"input">> := Input} = Call) ->
    Sent = case maps:get(<<"invalid">>, Call, false) =:= true andalso buoy_rt:type_of(Input) =/= <<"object">> of
        true -> #{};
        false -> Input
    end,
    #{<<"type">> => <<"tool-call">>, <<"toolCallId">> => Id, <<"toolName">> => Name, <<"input">> => Sent,
      <<"providerExecuted">> => undefined, <<"providerOptions">> => undefined}.

tool_result(#{<<"toolCallId">> := Id, <<"toolName">> := Name} = Part, _Tools) ->
    Output = case Part of
        #{<<"type">> := <<"tool-result">>, <<"output">> := Value} -> model_output(Value);
        #{<<"error">> := Error} -> #{<<"type">> => <<"error-text">>, <<"value">> => error_message(Error)}
    end,
    #{<<"type">> => <<"tool-result">>, <<"toolCallId">> => Id, <<"toolName">> => Name, <<"output">> => Output}.

%% createToolModelOutput: a string as text, any other value as its JSON value.
model_output(Text) when is_binary(Text) ->
    #{<<"type">> => <<"text">>, <<"value">> => Text};
model_output(Value) ->
    Json = case buoy_json:stringify([Value]) of
        undefined -> null;
        Text -> buoy_json:parse([Text])
    end,
    #{<<"type">> => <<"json">>, <<"value">> => Json}.

%%% The result

result(Steps) ->
    Last = lists:last(Steps),
    Total = lists:foldl(fun(Step, Sum) -> add_usage(Sum, maps:get(<<"usage">>, Step)) end, empty_usage(), Steps),
    All = fun(Key) -> lists:append([maps:get(Key, Step) || Step <- Steps]) end,
    Text = maps:get(<<"text">>, Last),
    Finish = maps:get(<<"finishReason">>, Last),
    #{<<"steps">> => Steps,
      <<"finalStep">> => Last,
      <<"totalUsage">> => Total,
      <<"usage">> => Total,
      <<"content">> => All(<<"content">>),
      <<"text">> => Text,
      <<"output">> => output(Finish, Text),
      <<"reasoning">> => [],
      <<"reasoningText">> => undefined,
      <<"files">> => [],
      <<"sources">> => [],
      <<"toolCalls">> => All(<<"toolCalls">>),
      <<"staticToolCalls">> => All(<<"staticToolCalls">>),
      <<"dynamicToolCalls">> => All(<<"dynamicToolCalls">>),
      <<"toolResults">> => All(<<"toolResults">>),
      <<"staticToolResults">> => All(<<"staticToolResults">>),
      <<"dynamicToolResults">> => All(<<"dynamicToolResults">>),
      <<"finishReason">> => Finish,
      <<"rawFinishReason">> => maps:get(<<"rawFinishReason">>, Last),
      <<"warnings">> => All(<<"warnings">>),
      <<"providerMetadata">> => maps:get(<<"providerMetadata">>, Last),
      <<"request">> => maps:get(<<"request">>, Last),
      <<"response">> => maps:get(<<"response">>, Last),
      <<"responseMessages">> => lists:append([maps:get(<<"messages">>, maps:get(<<"response">>, Step)) || Step <- Steps])}.

%% The text output: `ai` parses it only when the last step can hold text.
output(<<"tool-calls">>, _Text) -> undefined;
output(<<"stop">>, Text) -> Text;
output(_Finish, <<>>) -> undefined;
output(_Finish, Text) -> Text.

empty_usage() ->
    #{<<"inputTokens">> => undefined,
      <<"inputTokenDetails">> => #{<<"noCacheTokens">> => undefined, <<"cacheReadTokens">> => undefined, <<"cacheWriteTokens">> => undefined},
      <<"outputTokens">> => undefined,
      <<"outputTokenDetails">> => #{<<"textTokens">> => undefined, <<"reasoningTokens">> => undefined},
      <<"totalTokens">> => undefined}.

%% addLanguageModelUsage. The sum keeps `raw` only while one side is empty.
add_usage(A, B) ->
    Usage = #{<<"inputTokens">> => add_count(<<"inputTokens">>, A, B),
              <<"inputTokenDetails">> => add_counts(maps:get(<<"inputTokenDetails">>, A), maps:get(<<"inputTokenDetails">>, B)),
              <<"outputTokens">> => add_count(<<"outputTokens">>, A, B),
              <<"outputTokenDetails">> => add_counts(maps:get(<<"outputTokenDetails">>, A), maps:get(<<"outputTokenDetails">>, B)),
              <<"totalTokens">> => add_count(<<"totalTokens">>, A, B)},
    Raw = case {is_empty(A), is_empty(B)} of
        {true, _} -> maps:get(<<"raw">>, B, undefined);
        {_, true} -> maps:get(<<"raw">>, A, undefined);
        _ -> undefined
    end,
    case Raw of
        undefined -> Usage;
        _ -> Usage#{<<"raw">> => Raw}
    end.

add_counts(A, B) ->
    maps:map(fun(Key, _) -> add_count(Key, A, B) end, A).

add_count(Key, A, B) ->
    case {maps:get(Key, A, undefined), maps:get(Key, B, undefined)} of
        {X, Y} when ?NULLISH(X), ?NULLISH(Y) -> undefined;
        {X, Y} -> buoy_rt:add(zero_if_nullish(X), zero_if_nullish(Y))
    end.

zero_if_nullish(Value) when ?NULLISH(Value) -> 0;
zero_if_nullish(Value) -> Value.

is_empty(Usage) ->
    Counts = [maps:get(Key, Usage, undefined) || Key <- [<<"inputTokens">>, <<"outputTokens">>, <<"totalTokens">>, <<"raw">>]]
        ++ maps:values(maps:get(<<"inputTokenDetails">>, Usage)) ++ maps:values(maps:get(<<"outputTokenDetails">>, Usage)),
    lists:all(fun(Count) -> ?NULLISH(Count) end, Counts).

%%% Retries

%% retryWithExponentialBackoffRespectingRetryHeaders: a retryable APICallError
%% runs the call again after 2 s, then 4 s, or after the delay that the
%% retry headers of the response ask for.
retry(Attempt, 0) -> Attempt();
retry(Attempt, Retries) -> retry(Attempt, Retries, 2000, []).

retry(Attempt, Retries, Delay, Errors) ->
    try Attempt()
    catch
        error:{'$throw', Error}:Stack ->
            Tries = Errors ++ [Error],
            Count = length(Tries),
            Message = error_message(Error),
            case {Count > Retries, is_retryable(Error), Count} of
                {true, _, _} ->
                    retry_error(<<"Failed after ", (integer_to_binary(Count))/binary, " attempts. Last error: ", Message/binary>>,
                                <<"maxRetriesExceeded">>, Tries);
                {false, true, _} ->
                    ok = buoy_task:wait(retry_delay(Error, Delay)),
                    retry(Attempt, Retries, 2 * Delay, Tries);
                {false, false, 1} ->
                    erlang:raise(error, {'$throw', Error}, Stack);
                {false, false, _} ->
                    retry_error(<<"Failed after ", (integer_to_binary(Count))/binary, " attempts with non-retryable error: '", Message/binary, "'">>,
                                <<"errorNotRetryable">>, Tries)
            end
    end.

-spec retry_error(binary(), binary(), [value()]) -> no_return().
retry_error(Message, Reason, Errors) ->
    erlang:error({'$throw', ai_error(<<"RetryError">>, Message,
                                     #{<<"reason">> => Reason, <<"errors">> => Errors, <<"lastError">> => lists:last(Errors)})}).

is_retryable(#{'$error' := Classes, <<"isRetryable">> := true}) -> lists:member({'$class', ?MODULE, <<"APICallError">>}, Classes);
is_retryable(_) -> false.

retry_delay(Error, Backoff) ->
    Headers = case Error of
        #{<<"responseHeaders">> := #{} = Own} -> Own;
        #{<<"cause">> := #{<<"responseHeaders">> := #{} = Cause}} -> Cause;
        _ -> #{}
    end,
    Asked = case {seconds(maps:get(<<"retry-after-ms">>, Headers, <<>>)), seconds(maps:get(<<"retry-after">>, Headers, <<>>))} of
        {Ms, _} when is_number(Ms) -> Ms;
        {_, Seconds} when is_number(Seconds) -> Seconds * 1000;
        _ -> none
    end,
    case Asked of
        Ms1 when is_number(Ms1), Ms1 >= 0, (Ms1 < 60000 orelse Ms1 < Backoff) -> trunc(Ms1);
        _ -> Backoff
    end.

%% shortcut: a retry-after header that holds an HTTP date counts as absent, so
%% the backoff applies; parse the date when a provider sends one.
seconds(<<>>) -> none;
seconds(Text) ->
    case buoy_number:'parseFloat'([Text]) of
        Number when is_number(Number) -> Number;
        _ -> none
    end.

%%% Errors

%% An AI SDK error, such as APICallError: an Error named `AI_<Class>`.
-spec ai_error(binary(), binary(), map()) -> buoy_error:error_value().
ai_error(Class, Message, Fields) ->
    Error = buoy_error:new([{'$class', ?MODULE, Class}, {'$class', buoy_error, <<"Error">>}], Message, Fields),
    Error#{<<"name">> := <<"AI_", Class/binary>>}.

%% getErrorMessage of `@ai-sdk/provider`.
-spec error_message(value()) -> binary().
error_message(Value) when Value =:= undefined; Value =:= null -> <<"unknown error">>;
error_message(Text) when is_binary(Text) -> Text;
error_message(#{'$error' := _} = Error) -> buoy_rt:to_string(Error);
error_message(Value) ->
    case buoy_json:stringify([Value]) of
        undefined -> <<"undefined">>;
        Text -> Text
    end.

%% The random part of an id of `ai`, such as the 24 characters after `aitxt-`.
-spec random_id(pos_integer()) -> binary().
random_id(Size) ->
    << <<(binary:at(?ID_ALPHABET, rand:uniform(byte_size(?ID_ALPHABET)) - 1))>> || _ <- lists:seq(1, Size) >>.
