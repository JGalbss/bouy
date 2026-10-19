%% The JavaScript call stack of the reference engine (contract section 17.4).
%%
%% The Erlang stack of a realm process is its JavaScript stack: compiled code
%% keeps the caller of each JavaScript call on the stack, and each compiled
%% module maps the lines of its Erlang code to the places of its source with
%% '$frames'/0. A stack trace is the list of the frames of the Erlang stack
%% whose modules have that table, innermost first. The entry of each function
%% checks the size of the stack every 64 calls, so a runaway recursion throws
%% V8's RangeError instead of growing the process to its memory limit.
-module(buoy_stack).

-export([check/1, limit/0, set_limit/1, words/1, capture/2, function_start/1]).
-export([call_site/1, script/1]).
-export_type([frame/0]).

-include("buoy_ref.hrl").

%% A frame: the module, the line and the column of its place, both from 1,
%% and the index of its function in the table of the module.
-type frame() :: {module(), pos_integer(), pos_integer(), non_neg_integer()}.

-define(CALLS, '$buoy_calls').
-define(LIMIT, '$buoy_stack_limit').
%% V8's default --stack-size, in KiB.
-define(DEFAULT_KB, 984).
%% The words of the Erlang stack for each byte of V8's stack.
-define(WORDS_PER_BYTE, 0.125).

%%% The stack limit

%% The check of a function entry once every 64 calls: past the limit of the
%% stack, the call throws V8's RangeError.
-spec check(term()) -> ok.
check(Calls) ->
    erlang:put(?CALLS, case Calls of undefined -> 1; _ -> Calls + 1 end),
    {stack_size, Size} = erlang:process_info(self(), stack_size),
    case Size > limit() of
        true -> buoy_heap:throw_error('RangeError', <<"Maximum call stack size exceeded">>);
        false -> ok
    end.

%% The limit of the stack of this process, in words: the one that the process
%% set (a Worker's stackSizeMb), else the --stack-size of the program.
-spec limit() -> pos_integer().
limit() ->
    case erlang:get(?LIMIT) of
        undefined ->
            case persistent_term:get({?MODULE, limit}, undefined) of
                undefined -> program_limit();
                Limit -> Limit
            end;
        Limit ->
            Limit
    end.

%% The limit of --stack-size=<KiB> on the command line, as V8 reads it.
program_limit() ->
    Limit = words(lists:foldl(fun stack_size/2, ?DEFAULT_KB, buoy_node_process:vm_exec_argv())),
    persistent_term:put({?MODULE, limit}, Limit),
    Limit.

stack_size(<<"--stack-size=", KiB/binary>>, Default) -> kib(KiB, Default);
stack_size(<<"--stack_size=", KiB/binary>>, Default) -> kib(KiB, Default);
stack_size(_, Size) -> Size.

kib(Text, Default) ->
    case string:to_integer(Text) of
        {KiB, <<>>} when KiB > 0 -> KiB;
        _ -> Default
    end.

%% Sets the limit of this process, in words.
-spec set_limit(pos_integer()) -> ok.
set_limit(Words) ->
    erlang:put(?LIMIT, Words),
    ok.

%% The words of the Erlang stack for a stack of KiB as V8 counts it. A frame
%% of compiled code holds more words than V8's frame holds bytes, so the
%% depth of a recursion matches Node's at the same --stack-size.
-spec words(number()) -> pos_integer().
words(KiB) -> max(1024, round(KiB * 1024 * ?WORDS_PER_BYTE)).

%%% Stack traces

%% The frames of the JavaScript stack, innermost first: at most Limit, and
%% only those below the innermost frame of the function that Skip names,
%% {Module, Start}, when it is not none. A Skip that no frame runs leaves no
%% frame, as in V8.
-spec capture(non_neg_integer(), {module(), non_neg_integer()} | none) -> [frame()].
capture(0, _Skip) ->
    [];
capture(Limit, Skip) ->
    depth(Limit),
    {current_stacktrace, Trace} = erlang:process_info(self(), current_stacktrace),
    Frames = calls(lists:filtermap(fun frame/1, Trace)),
    lists:sublist(skip(Frames, Skip), Limit).

%% The frames of JavaScript calls. One call of a function can leave more than
%% one Erlang frame, when its code runs in a fun of its own inside an Erlang
%% try, such as the body of a for...of loop: a frame of the same function
%% whose line is no place of a call or a property read is such a frame.
calls([{Module, _, _, Index, _} = Inner, {Module, _, _, Index, inside} | Rest]) ->
    calls([Inner | Rest]);
calls([{Module, Line, Column, Index, _} | Rest]) ->
    [{Module, Line, Column, Index} | calls(Rest)];
calls([]) ->
    [].

skip(Frames, none) ->
    Frames;
skip(Frames, {Module, Start}) ->
    case lists:dropwhile(fun(Frame) -> not runs(Frame, Module, Start) end, Frames) of
        [_ | Below] -> Below;
        [] -> []
    end.

runs({Module, _, _, Index}, Module, Start) ->
    {_, _, Functions} = Module:'$frames'(),
    element(2, element(Index + 1, Functions)) =:= Start;
runs(_, _, _) ->
    false.

%% The Erlang stack that a trace reads holds at most backtrace_depth frames,
%% 8 by default, and runtime frames lie between the JavaScript ones.
depth(Limit) ->
    Wanted = min(4 * Limit + 32, 1024),
    case persistent_term:get({?MODULE, depth}, 8) of
        Depth when Depth >= Wanted -> ok;
        _ ->
            _ = erlang:system_flag(backtrace_depth, Wanted),
            persistent_term:put({?MODULE, depth}, Wanted)
    end.

%% The place of an Erlang frame in a compiled module: the last place that
%% starts at its line or before.
frame({Module, _Function, _Arity, Location}) ->
    case proplists:get_value(line, Location) of
        Line when is_integer(Line) ->
            case erlang:function_exported(Module, '$frames', 0) of
                true -> place(Module, Line);
                false -> false
            end;
        _ ->
            false
    end;
frame(_) ->
    false.

place(Module, Line) ->
    {_, Lines, _} = Module:'$frames'(),
    case search(Lines, Line, 0, byte_size(Lines) div 12 - 1, none) of
        {At, JsLine, Column, Index} when JsLine > 0 ->
            Where = case At of
                Line -> at;
                _ -> inside
            end,
            {true, {Module, JsLine, Column, Index, Where}};
        _ ->
            false
    end.

%% The last record of Lines whose Erlang line is at most Line.
search(_Lines, _Line, Low, High, Found) when Low > High ->
    Found;
search(Lines, Line, Low, High, Found) ->
    Middle = (Low + High) div 2,
    <<_:Middle/binary-unit:96, At:24, JsLine:24, Column:24, Index:24, _/binary>> = Lines,
    case At =< Line of
        true -> search(Lines, Line, Middle + 1, High, {At, JsLine, Column, Index});
        false -> search(Lines, Line, Low, Middle - 1, Found)
    end.

%% {Module, Start} of the source text of a function value, which frames
%% match, or none for a function that compiled code did not define.
-spec function_start(term()) -> {module(), non_neg_integer()} | none.
function_start({'$f', _, _} = F) ->
    case {buoy_heap:slots(F), F} of
        {#{source := {Module, Start, _End}}, _} -> {Module, Start};
        {_, {'$f', {_Form, Module, Name, _}, _}} -> span_start(Module, Name);
        {_, {'$f', {_Form, Module, Name, _, _}, _}} -> span_start(Module, Name);
        _ -> none
    end;
function_start(_) ->
    none.

span_start(Module, Name) ->
    case Module:'$span'(Name) of
        {Start, _End} -> {Module, Start};
        none -> none
    end.

%%% Call sites

%% What a CallSite answers for a frame, as V8's CallSiteInfo does: the
%% receiver is not kept, so the type of a method is the class or object
%% literal that defines it.
-spec call_site(frame()) -> map().
call_site({Module, Line, Column, Index} = Frame) ->
    {_, _, Functions} = Module:'$frames'(),
    {Name, _Start, Kind, Holder} = element(Index + 1, Functions),
    #{file => script(Module), line => Line, column => Column, name => Name, kind => Kind,
      holder => Holder, frame => Frame}.

%% The name of the script of Module in stack traces: the one that its code
%% names, the path of a CommonJS module, the file: URL of an ES module, or
%% undefined for eval code.
-spec script(module()) -> term().
script(Module) ->
    case Module:'$frames'() of
        {Script, _, _} when is_binary(Script) -> Script;
        _ ->
            case erlang:function_exported(Module, '$module', 0) andalso Module:'$module'() of
                #{kind := esm, path := Path} -> buoy_module:file_url(Path);
                #{path := Path} -> Path;
                _ -> undefined
            end
    end.
