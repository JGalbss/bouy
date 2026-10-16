%% Error values: maps tagged with the atom key `'$error'`, which holds the
%% classes of the error, with a name, a message, a stack, and any own fields
%% (contract sections 3 and 16). JSON and object literals make only binary
%% keys, so no plain data can pass for an error.
-module(bouy_error).

-export([new/2, new/3, throw/2, throw/3]).
-export(['Error#new'/1, 'TypeError#new'/1, 'RangeError#new'/1, 'SyntaxError#new'/1]).
-export([call/3, get/2]).
-export([from_erlang/2, fields/1, to_string/1, class/1, classes/1]).

-type class() :: {'$class', module(), binary()}.
-type error_value() :: #{'$error' := [class()], binary() => term()}.
-export_type([error_value/0, class/0]).

%% Own properties that JavaScript does not enumerate: `Object.keys`,
%% `JSON.stringify`, and spreads skip them.
-define(HIDDEN, ['$error', <<"name">>, <<"message">>, <<"stack">>, <<"cause">>]).
%% The JavaScript error classes whose instances the runtime builds by name.
-define(BUILT_IN, [<<"Error">>, <<"TypeError">>, <<"RangeError">>, <<"SyntaxError">>, <<"ReferenceError">>, <<"AggregateError">>]).

%% Name is the name of a built-in error, or the classes of a user error class,
%% the class itself first: `[{'$class', Module, <<"E">>}, Base]`.
-spec new(binary() | [class(), ...], binary()) -> error_value().
new(Name, Message) ->
    new(Name, Message, #{}).

-spec new(binary() | [class(), ...], binary(), map()) -> error_value().
new([{'$class', _, Name} | _] = Classes, Message, Fields) ->
    build(Name, Classes, Message, Fields);
new(Name, Message, Fields) ->
    build(Name, built_in(Name), Message, Fields).

build(Name, Classes, Message, Fields) ->
    {current_stacktrace, Frames} = erlang:process_info(self(), current_stacktrace),
    Base = #{
        '$error' => Classes,
        <<"name">> => Name,
        <<"message">> => Message,
        <<"stack">> => stack(Name, Message, Frames)
    },
    maps:merge(Base, Fields).

built_in(Name) ->
    case lists:member(Name, ?BUILT_IN) of
        true -> [{'$class', ?MODULE, Name}];
        false -> []
    end.

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

%% The classes of an error, the most derived first.
-spec classes(error_value()) -> [class()].
classes(#{'$error' := Classes}) -> Classes.

%% `error.constructor`: the class that built the error.
-spec class(error_value()) -> class().
class(#{'$error' := [Class | _]}) -> Class;
class(#{'$error' := []}) -> {'$class', ?MODULE, <<"Error">>}.

-spec call(binary(), error_value(), list()) -> term().
call(<<"toString">>, Error, _Args) ->
    to_string(Error);
call(Name, Error, Args) ->
    case maps:get(Name, Error, undefined) of
        F when is_function(F, 1) -> F(Args);
        _ -> bouy_rt:prototype_call(Error, Name, Args)
    end.

-spec get(error_value(), term()) -> term().
get(Error, Key) ->
    bouy_rt:get(Error, Key).

%% `Error.prototype.toString`.
-spec to_string(map()) -> binary().
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
    maps:filter(fun(Key, _) -> is_binary(Key) end, maps:without(?HIDDEN, Error)).

%% The error that a `catch` binds for an Erlang runtime error: a TypeError,
%% or the ReferenceError of a module-level const read before its declaration
%% runs. The `erlang` field keeps the original reason for debugging.
-spec from_erlang(term(), [tuple()]) -> error_value().
from_erlang(badarg, [{persistent_term, get, [{Module, Name}], _} | _]) when is_atom(Module), is_binary(Name) ->
    new(<<"ReferenceError">>, <<"Cannot access '", Name/binary, "' before initialization">>);
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
describe(undef, [{Module, Function, _, _} | _] = Stack) ->
    case bouy_rt:global_name(Module) of
        undefined -> <<"undefined function", (location(Stack))/binary>>;
        Global -> <<Global/binary, ".", (atom_to_binary(Function))/binary, " is not a function">>
    end;
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
