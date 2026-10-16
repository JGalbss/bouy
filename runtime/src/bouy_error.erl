%% Error values: maps with `<<"$error">> => true`, a name, a message, a
%% stack, and any own fields (contract sections 3 and 16).
-module(bouy_error).

-export([new/2, new/3, throw/2, throw/3]).
-export(['Error#new'/1, 'TypeError#new'/1, 'RangeError#new'/1, 'SyntaxError#new'/1]).
-export([call/3, get/2]).
-export([from_erlang/2, fields/1, to_string/1]).

-type error_value() :: #{binary() => term()}.
-export_type([error_value/0]).

%% Own properties that JavaScript does not enumerate: `Object.keys`,
%% `JSON.stringify`, and spreads skip them.
-define(HIDDEN, [<<"$error">>, <<"name">>, <<"message">>, <<"stack">>, <<"cause">>]).

-spec new(binary(), binary()) -> error_value().
new(Name, Message) ->
    new(Name, Message, #{}).

-spec new(binary(), binary(), map()) -> error_value().
new(Name, Message, Fields) ->
    {current_stacktrace, Frames} = erlang:process_info(self(), current_stacktrace),
    Base = #{
        <<"$error">> => true,
        <<"name">> => Name,
        <<"message">> => Message,
        <<"stack">> => stack(Name, Message, Frames)
    },
    maps:merge(Base, Fields).

-spec throw(binary(), binary()) -> no_return().
throw(Name, Message) ->
    erlang:error({'$throw', new(Name, Message)}).

-spec throw(binary(), binary(), map()) -> no_return().
throw(Name, Message, Fields) ->
    erlang:error({'$throw', new(Name, Message, Fields)}).

-spec 'Error#new'(list()) -> error_value().
'Error#new'(Args) -> construct(<<"Error">>, Args).

-spec 'TypeError#new'(list()) -> error_value().
'TypeError#new'(Args) -> construct(<<"TypeError">>, Args).

-spec 'RangeError#new'(list()) -> error_value().
'RangeError#new'(Args) -> construct(<<"RangeError">>, Args).

-spec 'SyntaxError#new'(list()) -> error_value().
'SyntaxError#new'(Args) -> construct(<<"SyntaxError">>, Args).

%% `new Error(message, { cause })`.
construct(Name, Args) ->
    Message =
        case bouy_rt:arg(1, Args) of
            undefined -> <<>>;
            Value -> bouy_rt:to_string(Value)
        end,
    new(Name, Message, cause(bouy_rt:arg(2, Args))).

cause(#{<<"cause">> := Cause}) -> #{<<"cause">> => Cause};
cause(_) -> #{}.

-spec call(binary(), error_value(), list()) -> term().
call(<<"toString">>, Error, _Args) ->
    to_string(Error);
call(Name, Error, Args) ->
    case maps:get(Name, Error, undefined) of
        F when is_function(F, 1) -> F(Args);
        _ -> throw(<<"TypeError">>, <<(to_string(Error))/binary, ".", Name/binary, " is not a function">>)
    end.

-spec get(error_value(), term()) -> term().
get(Error, Key) ->
    maps:get(bouy_rt:to_key(Key), Error, undefined).

%% `Error.prototype.toString`.
-spec to_string(error_value()) -> binary().
to_string(Error) ->
    header(text(maps:get(<<"name">>, Error, undefined), <<"Error">>), text(maps:get(<<"message">>, Error, undefined), <<>>)).

text(undefined, Default) -> Default;
text(Value, _) -> bouy_rt:to_string(Value).

header(Name, <<>>) -> Name;
header(<<>>, Message) -> Message;
header(Name, Message) -> <<Name/binary, ": ", Message/binary>>.

%% The own fields that JavaScript enumerates.
-spec fields(error_value()) -> map().
fields(Error) ->
    maps:without(?HIDDEN, Error).

%% The TypeError that a `catch` binds for an Erlang runtime error. The
%% `erlang` field keeps the original reason for debugging.
-spec from_erlang(term(), [tuple()]) -> error_value().
from_erlang(Reason, Stack) ->
    Message = describe(Reason, Stack),
    new(<<"TypeError">>, Message, #{
        <<"erlang">> => format(Reason),
        <<"stack">> => stack(<<"TypeError">>, Message, Stack)
    }).

describe(badarith, _) -> <<"bad argument in an arithmetic expression">>;
describe(badarg, Stack) -> <<"bad argument", (location(Stack))/binary>>;
describe(function_clause, Stack) -> <<"no function clause matching", (location(Stack))/binary>>;
describe({badmatch, Value}, _) -> <<"no match of right hand side value ", (format(Value))/binary>>;
describe({case_clause, Value}, _) -> <<"no case clause matching ", (format(Value))/binary>>;
describe({try_clause, Value}, _) -> <<"no try clause matching ", (format(Value))/binary>>;
describe(if_clause, _) -> <<"no true branch found in an if expression">>;
describe(undef, Stack) -> <<"undefined function", (location(Stack))/binary>>;
describe({badfun, Value}, _) -> <<(format(Value))/binary, " is not a function">>;
describe({badarity, _}, Stack) -> <<"function called with the wrong number of arguments", (location(Stack))/binary>>;
describe({badkey, Key}, _) -> <<"key ", (format(Key))/binary, " not found">>;
describe({badmap, Value}, _) -> <<(format(Value))/binary, " is not a map">>;
describe(system_limit, _) -> <<"a system limit was reached">>;
describe(Reason, _) -> format(Reason).

location([{Module, Function, Arity, _} | _]) ->
    <<" in ", (mfa(Module, Function, Arity))/binary>>;
location(_) ->
    <<>>.

format(Term) ->
    unicode:characters_to_binary(io_lib:format("~0tP", [Term, 12])).

stack(Name, Message, Frames) ->
    iolist_to_binary([header(Name, Message) | [frame(Frame) || Frame <- Frames, element(1, Frame) =/= ?MODULE]]).

frame({Module, Function, Arity, Location}) ->
    File = proplists:get_value(file, Location),
    Line = proplists:get_value(line, Location),
    [<<"\n    at ">>, mfa(Module, Function, Arity), position(File, Line)];
frame(_) ->
    [].

position(undefined, _) -> <<>>;
position(File, undefined) -> [<<" (">>, unicode:characters_to_binary(File), <<")">>];
position(File, Line) -> [<<" (">>, unicode:characters_to_binary(File), <<":">>, integer_to_binary(Line), <<")">>].

mfa(Module, Function, Arity) when is_list(Arity) ->
    mfa(Module, Function, length(Arity));
mfa(Module, Function, Arity) ->
    <<(atom_to_binary(Module))/binary, ":", (atom_to_binary(Function))/binary, "/", (integer_to_binary(Arity))/binary>>.
