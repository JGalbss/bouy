-module(buoy_ai_openai).

%% The subset of `@ai-sdk/openai` 4.0.95 in contract section 14: language
%% models on the Chat Completions API, called through OTP httpc. The real
%% package sends `openai(model)` to the Responses API; Buoy sends it to Chat
%% Completions, as `openai.chat(model)`.

-export(['$member'/1, '$call'/1, chat/1, languageModel/1, createOpenAI/1]).

-type value() :: buoy_rt:value().

-define(FUNCTIONS, [<<"chat">>, <<"languageModel">>]).
-define(DEFAULT_BASE_URL, <<"https://api.openai.com/v1">>).
-define(USER_AGENT, <<"ai/7.0.142 ai-sdk-provider-utils/5.0.61 runtime/buoy">>).

-spec '$member'(binary()) -> term().
'$member'(Name) -> buoy_rt:member_function(?MODULE, Name, ?FUNCTIONS).

%% `openai(model)`.
-spec '$call'([value()]) -> map().
'$call'(Args) -> chat(Args).

-spec chat([value()]) -> map().
chat(Args) -> model(settings(#{}), buoy_rt:arg(1, Args)).

-spec languageModel([value()]) -> map().
languageModel(Args) -> chat(Args).

%% `createOpenAI(options)`: a provider that is a function with the methods
%% `chat` and `languageModel`, as the provider of the real package is.
-spec createOpenAI([value()]) -> map().
createOpenAI(Args) ->
    Settings = settings(case buoy_rt:arg(1, Args) of
        undefined -> #{};
        Options -> Options
    end),
    Chat = fun(ModelArgs) -> model(Settings, buoy_rt:arg(1, ModelArgs)) end,
    #{'$call' => Chat, <<"chat">> => Chat, <<"languageModel">> => Chat}.

%% The settings of a provider. The base URL is read when the provider is made,
%% and the API key when a request is sent, as in the real package.
settings(Options) ->
    #{base_url => base_url(buoy_rt:get(Options, <<"baseURL">>)),
      api_key => buoy_rt:get(Options, <<"apiKey">>),
      headers => buoy_rt:get(Options, <<"headers">>),
      organization => buoy_rt:get(Options, <<"organization">>),
      project => buoy_rt:get(Options, <<"project">>),
      name => case buoy_rt:get(Options, <<"name">>) of
          undefined -> <<"openai">>;
          Name -> Name
      end}.

base_url(Setting) ->
    Url = case Setting of
        Text when is_binary(Text) -> Text;
        Missing when Missing =:= undefined; Missing =:= null -> buoy_rt:env(<<"OPENAI_BASE_URL">>);
        _ -> undefined
    end,
    case Url of
        undefined ->
            ?DEFAULT_BASE_URL;
        _ ->
            buoy_string:trim(Url) =/= <<>> orelse
                erlang:error({'$throw', buoy_ai:ai_error(<<"InvalidArgumentError">>, <<"baseURL must be a non-empty string.">>,
                                                         #{<<"argument">> => <<"baseURL">>, <<"cause">> => undefined})}),
            without_trailing_slash(Url)
    end.

without_trailing_slash(Url) ->
    case binary:last(Url) of
        $/ -> binary:part(Url, 0, byte_size(Url) - 1);
        _ -> Url
    end.

model(#{name := Name} = Settings, ModelId) ->
    #{<<"specificationVersion">> => <<"v4">>,
      <<"provider">> => <<Name/binary, ".chat">>,
      <<"modelId">> => ModelId,
      '$generate' => fun(Call) -> generate(Settings, ModelId, Call) end}.

%%% doGenerate

generate(#{base_url := BaseUrl} = Settings, ModelId, Call) ->
    #{messages := Messages, instructions := Instructions, tools := Tools, tool_choice := Choice, options := Options} = Call,
    {Body, Warnings} = body(ModelId, Instructions, Messages, Tools, Choice, Options),
    Url = <<BaseUrl/binary, "/chat/completions">>,
    Headers = headers(Settings, buoy_rt:get(Options, <<"headers">>)),
    Response = post(Url, Headers, Body),
    (completion(Response, Url, Body))#{warnings => Warnings}.

%% The request body of getArgs, with the warnings of the settings it drops.
body(ModelId, Instructions, Messages, Tools, Choice, Options) ->
    Reasoning = is_reasoning_model(ModelId),
    Setting = fun(Key) -> buoy_rt:get(Options, Key) end,
    Settings = #{<<"max_tokens">> => Setting(<<"maxOutputTokens">>),
                 <<"temperature">> => Setting(<<"temperature">>),
                 <<"top_p">> => Setting(<<"topP">>),
                 <<"frequency_penalty">> => Setting(<<"frequencyPenalty">>),
                 <<"presence_penalty">> => Setting(<<"presencePenalty">>),
                 <<"stop">> => Setting(<<"stopSequences">>),
                 <<"seed">> => Setting(<<"seed">>)},
    {Kept, Dropped} = reasoning_settings(Reasoning, Settings),
    SystemRole = case Reasoning of
        true -> <<"developer">>;
        false -> <<"system">>
    end,
    Body = Kept#{<<"model">> => ModelId,
                 <<"messages">> => chat_messages(Instructions, Messages, SystemRole),
                 <<"tools">> => chat_tools(Tools),
                 <<"tool_choice">> => chat_tool_choice(Tools, Choice)},
    TopK = [#{<<"type">> => <<"unsupported">>, <<"feature">> => <<"topK">>} || Setting(<<"topK">>) =/= undefined],
    {Body, TopK ++ Dropped}.

%% Reasoning models take no sampling settings, and take max_completion_tokens
%% for max_tokens.
reasoning_settings(false, Settings) ->
    {Settings, []};
reasoning_settings(true, Settings) ->
    Unsupported = [{<<"temperature">>, <<"temperature">>}, {<<"top_p">>, <<"topP">>},
                   {<<"frequency_penalty">>, <<"frequencyPenalty">>}, {<<"presence_penalty">>, <<"presencePenalty">>}],
    Warnings = [#{<<"type">> => <<"unsupported">>, <<"feature">> => Feature,
                  <<"details">> => <<Feature/binary, " is not supported for reasoning models">>}
                || {Key, Feature} <- Unsupported, maps:get(Key, Settings) =/= undefined],
    Kept = maps:without([Key || {Key, _} <- Unsupported] ++ [<<"max_tokens">>], Settings),
    {Kept#{<<"max_completion_tokens">> => maps:get(<<"max_tokens">>, Settings)}, Warnings}.

%% getOpenAILanguageModelCapabilities: the o series, and GPT 5 and later
%% except the chat variants without a minor version.
is_reasoning_model(ModelId) ->
    case re:run(ModelId, <<"^o\\d+(?:-|$)">>, [{capture, none}]) of
        match ->
            true;
        nomatch ->
            case re:run(ModelId, <<"^gpt-(\\d+)(?:\\.(\\d+))?(?:-(.+))?$">>, [{capture, all_but_first, binary}]) of
                {match, [Major | Rest]} -> binary_to_integer(Major) >= 5 andalso not is_chat_variant(Rest);
                nomatch -> false
            end
    end.

is_chat_variant([<<>>, <<"chat", _/binary>>]) -> true;
is_chat_variant(_) -> false.

%%% Messages

chat_messages(Instructions, Messages, SystemRole) ->
    [#{<<"role">> => SystemRole, <<"content">> => Text} || Text <- instructions(Instructions)]
        ++ lists:append([chat_message(Message) || Message <- Messages]).

instructions(undefined) -> [];
instructions(Text) when is_binary(Text) -> [Text];
instructions(Messages) when is_list(Messages) -> [buoy_rt:get(Message, <<"content">>) || Message <- Messages];
instructions(Message) -> [buoy_rt:get(Message, <<"content">>)].

chat_message(#{<<"role">> := <<"user">>, <<"content">> := Text}) when is_binary(Text) ->
    [#{<<"role">> => <<"user">>, <<"content">> => Text}];
chat_message(#{<<"role">> := <<"user">>, <<"content">> := Parts}) ->
    case [user_part(Part) || Part <- Parts, not is_empty_text(Part)] of
        [#{<<"text">> := Text}] -> [#{<<"role">> => <<"user">>, <<"content">> => Text}];
        Content -> [#{<<"role">> => <<"user">>, <<"content">> => Content}]
    end;
chat_message(#{<<"role">> := <<"assistant">>, <<"content">> := Text}) when is_binary(Text) ->
    [#{<<"role">> => <<"assistant">>, <<"content">> => Text}];
chat_message(#{<<"role">> := <<"assistant">>, <<"content">> := Parts}) ->
    Text = iolist_to_binary([Text || #{<<"type">> := <<"text">>, <<"text">> := Text} <- Parts]),
    Calls = [#{<<"id">> => Id, <<"type">> => <<"function">>,
               <<"function">> => #{<<"name">> => Name, <<"arguments">> => arguments(buoy_rt:get(Part, <<"input">>))}}
             || #{<<"type">> := <<"tool-call">>, <<"toolCallId">> := Id, <<"toolName">> := Name} = Part <- Parts],
    case {Calls, Text} of
        {[], _} -> [#{<<"role">> => <<"assistant">>, <<"content">> => Text}];
        {_, <<>>} -> [#{<<"role">> => <<"assistant">>, <<"content">> => null, <<"tool_calls">> => Calls}];
        _ -> [#{<<"role">> => <<"assistant">>, <<"content">> => Text, <<"tool_calls">> => Calls}]
    end;
chat_message(#{<<"role">> := <<"tool">>, <<"content">> := Parts}) ->
    [#{<<"role">> => <<"tool">>, <<"tool_call_id">> => Id, <<"content">> => tool_content(Output)}
     || #{<<"type">> := <<"tool-result">>, <<"toolCallId">> := Id, <<"output">> := Output} <- Parts].

is_empty_text(#{<<"type">> := <<"text">>, <<"text">> := <<>>}) -> true;
is_empty_text(_) -> false.

user_part(#{<<"type">> := <<"text">>, <<"text">> := Text}) -> #{<<"type">> => <<"text">>, <<"text">> => Text};
user_part(_) -> buoy_error:throw(<<"TypeError">>, <<"Buoy supports only text parts in user messages">>).

%% The JSON of the input of a tool call: an object, or `{}` for another value.
arguments(Input) when is_map(Input) -> buoy_json:stringify([Input]);
arguments(_Input) -> <<"{}">>.

tool_content(#{<<"type">> := <<"text">>, <<"value">> := Text}) -> Text;
tool_content(#{<<"type">> := Type, <<"value">> := Value}) when Type =:= <<"error-text">>; Type =:= <<"error-json">> ->
    buoy_json:stringify([#{<<"error">> => Value}]);
tool_content(#{<<"type">> := <<"execution-denied">>} = Output) ->
    case buoy_rt:get(Output, <<"reason">>) of
        undefined -> <<"Tool call execution denied.">>;
        Reason -> Reason
    end;
tool_content(#{<<"value">> := Value}) ->
    buoy_json:stringify([Value]).

chat_tools(undefined) ->
    undefined;
chat_tools(Tools) ->
    [#{<<"type">> => <<"function">>,
       <<"function">> => #{<<"name">> => Name, <<"description">> => Description, <<"parameters">> => Schema,
                           <<"strict">> => Strict}}
     || #{<<"name">> := Name, <<"description">> := Description, <<"inputSchema">> := Schema, <<"strict">> := Strict} <- Tools].

chat_tool_choice(undefined, _Choice) -> undefined;
chat_tool_choice(_Tools, #{<<"type">> := <<"tool">>, <<"toolName">> := Name}) ->
    #{<<"type">> => <<"function">>, <<"function">> => #{<<"name">> => Name}};
chat_tool_choice(_Tools, #{<<"type">> := Type}) -> Type.

%%% HTTP

%% The headers of a request: the provider headers, then the headers of the
%% call. A missing API key throws here, when the first request is sent.
headers(#{api_key := Key, organization := Organization, project := Project, headers := Extra}, CallHeaders) ->
    Provider = [{<<"authorization">>, <<"Bearer ", (api_key(Key))/binary>>}]
        ++ [{<<"openai-organization">>, Organization} || is_binary(Organization)]
        ++ [{<<"openai-project">>, Project} || is_binary(Project)],
    Given = lists:ukeymerge(1, header_list(CallHeaders), lists:ukeymerge(1, header_list(Extra), lists:ukeysort(1, Provider))),
    Agent = iolist_to_binary(lists:join(<<" ">>, [Value || {<<"user-agent">>, Value} <- Given] ++ [?USER_AGENT])),
    [{Name, Value} || {Name, Value} <- Given, Name =/= <<"user-agent">>] ++ [{<<"user-agent">>, Agent}].

header_list(Headers) when is_map(Headers) ->
    lists:ukeysort(1, [{string:lowercase(Name), buoy_rt:to_string(Value)} || {Name, Value} <- buoy_object:own_entries(Headers), Value =/= undefined]);
header_list(_Headers) ->
    [].

%% loadApiKey.
api_key(Key) when is_binary(Key) ->
    Key;
api_key(Key) when Key =/= undefined, Key =/= null ->
    load_api_key_error(<<"OpenAI API key must be a string.">>);
api_key(_Key) ->
    case buoy_rt:env(<<"OPENAI_API_KEY">>) of
        undefined -> load_api_key_error(<<"OpenAI API key is missing. Pass it using the 'apiKey' parameter or the OPENAI_API_KEY environment variable.">>);
        Key -> Key
    end.

-spec load_api_key_error(binary()) -> no_return().
load_api_key_error(Message) ->
    erlang:error({'$throw', buoy_ai:ai_error(<<"LoadAPIKeyError">>, Message, #{<<"cause">> => undefined})}).

post(Url, Headers, Body) ->
    ok = start_http(Url),
    Request = {binary_to_list(Url), [{binary_to_list(Name), binary_to_list(Value)} || {Name, Value} <- Headers],
               "application/json", buoy_json:stringify([Body])},
    httpc:request(post, Request, http_options(Url), [{body_format, binary}]).

start_http(Url) ->
    ok = start_inet_db(),
    start_http_apps(Url).

start_http_apps(<<"https:", _/binary>>) ->
    {ok, _} = application:ensure_all_started([inets, ssl]),
    ok;
start_http_apps(_Url) ->
    {ok, _} = application:ensure_all_started(inets),
    ok.

%% The CLI boots the kernel with `-mode minimal` (section 1), which leaves out
%% inet_db, the resolver configuration that httpc needs. It joins the kernel
%% supervisor on the first request, as in a full boot.
start_inet_db() ->
    case whereis(inet_db) of
        undefined ->
            Spec = #{id => inet_db, start => {inet_db, start_link, []}, restart => permanent, shutdown => 2000},
            case supervisor:start_child(kernel_sup, Spec) of
                {ok, _} -> ok;
                {error, {already_started, _}} -> ok
            end;
        _Running ->
            ok
    end.

http_options(<<"https:", _/binary>>) -> [{ssl, httpc:ssl_verify_host_options(true)}];
http_options(_Url) -> [].

%% The result of doGenerate, or the APICallError of a failed request.
completion({ok, {{_Version, Status, _Reason}, Headers, Text}}, Url, Body) when Status >= 200, Status < 300 ->
    ResponseHeaders = header_map(Headers),
    Failure = #{url => Url, body => Body, status => Status, headers => ResponseHeaders, text => Text},
    Json = try buoy_json:parse([Text])
           catch
               error:{'$throw', Cause} -> api_call_error(Failure#{message => <<"Invalid JSON response">>, cause => Cause})
           end,
    case field(Json, <<"choices">>) of
        [Choice | _] ->
            choice(Json, Choice, ResponseHeaders);
        [] ->
            erlang:error({'$throw', buoy_ai:ai_error(<<"InvalidResponseDataError">>, <<"Response did not contain any choices.">>,
                                                     #{<<"data">> => Json, <<"cause">> => undefined})});
        _ ->
            api_call_error(Failure#{message => <<"Invalid JSON response">>})
    end;
completion({ok, {{_Version, Status, Reason}, Headers, Text}}, Url, Body) ->
    Failure = #{url => Url, body => Body, status => Status, headers => header_map(Headers), text => Text},
    api_call_error(error_message(Failure, unicode:characters_to_binary(Reason), Text));
completion({error, Reason}, Url, Body) ->
    api_call_error(#{url => Url, body => Body, retryable => true,
                     message => <<"Cannot connect to API: ", (connect_error(Reason))/binary>>}).

%% createJsonErrorResponseHandler: the message of an OpenAI error body, or else
%% the status text.
error_message(Failure, StatusText, Text) ->
    case buoy_string:trim(Text) of
        <<>> ->
            Failure#{message => StatusText};
        _ ->
            try buoy_json:parse([Text]) of
                #{<<"error">> := #{<<"message">> := Message}} = Data when is_binary(Message) -> Failure#{message => Message, data => Data};
                _ -> Failure#{message => StatusText}
            catch
                error:{'$throw', _} -> Failure#{message => StatusText}
            end
    end.

-spec api_call_error(map()) -> no_return().
api_call_error(#{url := Url, body := Body, message := Message} = Failure) ->
    Status = maps:get(status, Failure, undefined),
    Retryable = maps:get(retryable, Failure, is_integer(Status) andalso
                                             (lists:member(Status, [408, 409, 429]) orelse Status >= 500)),
    Fields = #{<<"url">> => Url,
               <<"requestBodyValues">> => Body,
               <<"statusCode">> => Status,
               <<"responseHeaders">> => maps:get(headers, Failure, undefined),
               <<"responseBody">> => maps:get(text, Failure, undefined),
               <<"isRetryable">> => Retryable,
               <<"data">> => maps:get(data, Failure, undefined),
               <<"cause">> => maps:get(cause, Failure, undefined)},
    erlang:error({'$throw', buoy_ai:ai_error(<<"APICallError">>, Message, Fields)}).

connect_error({failed_connect, Details}) ->
    case {proplists:get_value(to_address, Details), lists:keyfind(inet, 1, Details)} of
        {{Host, Port}, {inet, _, econnrefused}} ->
            iolist_to_binary(io_lib:format("connect ECONNREFUSED ~ts:~b", [Host, Port]));
        _ ->
            iolist_to_binary(io_lib:format("~0tp", [Details]))
    end;
connect_error(Reason) ->
    iolist_to_binary(io_lib:format("~0tp", [Reason])).

%% The response headers as fetch shows them: lower-case names, and the values
%% of a repeated name joined with ", ".
header_map(Headers) ->
    lists:foldl(fun({Name, Value}, Map) ->
                    Key = string:lowercase(unicode:characters_to_binary(Name)),
                    Text = unicode:characters_to_binary(Value),
                    maps:update_with(Key, fun(Old) -> <<Old/binary, ", ", Text/binary>> end, Text, Map)
                end, #{}, Headers).

%% The content, finish reason, usage, and metadata of the first choice.
choice(Json, Choice, Headers) ->
    Message = field(Choice, <<"message">>),
    Text = case field(Message, <<"content">>) of
        Content when is_binary(Content), Content =/= <<>> -> Content;
        _ -> field(field(Message, <<"audio">>), <<"transcript">>)
    end,
    Calls = case field(Message, <<"tool_calls">>) of
        List when is_list(List) -> List;
        _ -> []
    end,
    Parts = [#{<<"type">> => <<"text">>, <<"text">> => Text} || is_binary(Text), Text =/= <<>>]
        ++ [#{<<"type">> => <<"tool-call">>, <<"toolCallId">> => call_id(field(Call, <<"id">>)),
              <<"toolName">> => field(Function, <<"name">>), <<"input">> => field(Function, <<"arguments">>)}
            || Call <- Calls, Function <- [field(Call, <<"function">>)]],
    Finish = field(Choice, <<"finish_reason">>),
    #{content => Parts,
      finish_reason => finish_reason(Finish),
      raw_finish_reason => case Finish of
          null -> undefined;
          _ -> Finish
      end,
      usage => usage(field(Json, <<"usage">>)),
      response => #{<<"id">> => field(Json, <<"id">>),
                    <<"modelId">> => field(Json, <<"model">>),
                    <<"timestamp">> => timestamp(field(Json, <<"created">>)),
                    <<"headers">> => Headers},
      provider_metadata => #{<<"openai">> => prediction_tokens(field(field(Json, <<"usage">>), <<"completion_tokens_details">>))}}.

%% `object?.[key]`.
field(Object, _Key) when Object =:= undefined; Object =:= null -> undefined;
field(Object, Key) -> buoy_rt:get(Object, Key).

call_id(Id) when is_binary(Id), Id =/= <<>> -> Id;
call_id(_Id) -> buoy_ai:random_id(16).

finish_reason(<<"stop">>) -> <<"stop">>;
finish_reason(<<"length">>) -> <<"length">>;
finish_reason(<<"content_filter">>) -> <<"content-filter">>;
finish_reason(<<"function_call">>) -> <<"tool-calls">>;
finish_reason(<<"tool_calls">>) -> <<"tool-calls">>;
finish_reason(_) -> <<"other">>.

timestamp(Created) when is_number(Created), Created /= 0 -> buoy_date:new([buoy_rt:mul(Created, 1000)]);
timestamp(_) -> undefined.

prediction_tokens(Details) when is_map(Details) ->
    maps:from_list([{Key, Value} || {Name, Key} <- [{<<"accepted_prediction_tokens">>, <<"acceptedPredictionTokens">>},
                                                    {<<"rejected_prediction_tokens">>, <<"rejectedPredictionTokens">>}],
                                    Value <- [maps:get(Name, Details, null)], Value =/= null]);
prediction_tokens(_Details) ->
    #{}.

%% convertOpenAIChatUsage, then asLanguageModelUsage of `ai`.
usage(Usage) when not is_map(Usage) ->
    #{<<"inputTokens">> => undefined,
      <<"inputTokenDetails">> => #{<<"noCacheTokens">> => undefined, <<"cacheReadTokens">> => undefined, <<"cacheWriteTokens">> => undefined},
      <<"outputTokens">> => undefined,
      <<"outputTokenDetails">> => #{<<"textTokens">> => undefined, <<"reasoningTokens">> => undefined},
      <<"totalTokens">> => undefined,
      <<"raw">> => undefined};
usage(Usage) ->
    Count = fun(Object, Key) -> case field(Object, Key) of N when is_number(N) -> N; _ -> undefined end end,
    Prompt = zero(Count(Usage, <<"prompt_tokens">>)),
    Completion = zero(Count(Usage, <<"completion_tokens">>)),
    PromptDetails = field(Usage, <<"prompt_tokens_details">>),
    Cached = zero(Count(PromptDetails, <<"cached_tokens">>)),
    CacheWrite = Count(PromptDetails, <<"cache_write_tokens">>),
    Reasoning = zero(Count(field(Usage, <<"completion_tokens_details">>), <<"reasoning_tokens">>)),
    #{<<"inputTokens">> => Prompt,
      <<"inputTokenDetails">> => #{<<"noCacheTokens">> => buoy_rt:sub(buoy_rt:sub(Prompt, Cached), zero(CacheWrite)),
                                   <<"cacheReadTokens">> => Cached,
                                   <<"cacheWriteTokens">> => CacheWrite},
      <<"outputTokens">> => Completion,
      <<"outputTokenDetails">> => #{<<"textTokens">> => max(0, buoy_rt:sub(Completion, Reasoning)), <<"reasoningTokens">> => Reasoning},
      <<"totalTokens">> => buoy_rt:add(Prompt, Completion),
      <<"raw">> => Usage}.

zero(undefined) -> 0;
zero(Count) -> Count.
