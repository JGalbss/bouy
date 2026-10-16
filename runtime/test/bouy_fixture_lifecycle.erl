-module(bouy_fixture_lifecycle).

%% The compiled shape of classes whose constructors throw or stop the actor:
%%
%%   export class Broken {
%%     constructor() { throw new Error("cannot start"); }
%%   }
%%   export class Moody {
%%     constructor() {
%%       if (process.env.BOUY_MOODY === "fail") throw new Error("bad mood");
%%     }
%%     ping() { return "pong"; }
%%     fail() { throw new Error("going down"); }
%%   }
%%   export class Quitter {
%%     constructor(now = false) { if (now) stop(self(this)); }
%%     ping() { return "pong"; }
%%     quit() { stop(self(this)); return "bye"; }
%%   }

-export([
    'Broken#new'/1,
    'Broken#dispatch'/3,
    'Broken#streams'/0,
    'Moody#new'/1,
    'Moody#dispatch'/3,
    'Moody#streams'/0,
    'Moody#ping'/2,
    'Moody#fail'/2,
    'Quitter#new'/1,
    'Quitter#dispatch'/3,
    'Quitter#streams'/0,
    'Quitter#ping'/2,
    'Quitter#quit'/2
]).

-spec 'Broken#new'(list()) -> no_return().
'Broken#new'(_Args) ->
    erlang:error({'$throw', bouy_error:new(<<"Error">>, <<"cannot start">>)}).

-spec 'Broken#dispatch'(binary(), map(), list()) -> no_return().
'Broken#dispatch'(Method, _This, _Args) ->
    bouy_error:throw(<<"TypeError">>, <<"Broken.", Method/binary, " is not a function">>).

-spec 'Broken#streams'() -> [binary()].
'Broken#streams'() -> [].

-spec 'Moody#new'(list()) -> map().
'Moody#new'(_Args) ->
    case os:getenv("BOUY_MOODY") of
        "fail" -> erlang:error({'$throw', bouy_error:new(<<"Error">>, <<"bad mood">>)});
        _ -> #{}
    end.

-spec 'Moody#dispatch'(binary(), map(), list()) -> {term(), map()}.
'Moody#dispatch'(<<"ping">>, This, Args) -> 'Moody#ping'(This, Args);
'Moody#dispatch'(<<"fail">>, This, Args) -> 'Moody#fail'(This, Args);
'Moody#dispatch'(Method, _This, _Args) ->
    bouy_error:throw(<<"TypeError">>, <<"Moody.", Method/binary, " is not a function">>).

-spec 'Moody#streams'() -> [binary()].
'Moody#streams'() -> [].

-spec 'Moody#ping'(map(), list()) -> {binary(), map()}.
'Moody#ping'(This, _Args) ->
    {<<"pong">>, This}.

-spec 'Moody#fail'(map(), list()) -> no_return().
'Moody#fail'(_This, _Args) ->
    erlang:error({'$throw', bouy_error:new(<<"Error">>, <<"going down">>)}).

-spec 'Quitter#new'(list()) -> map().
'Quitter#new'(Args) ->
    This = #{},
    case bouy_rt:arg(1, Args) of
        true -> undefined = bouy:stop([bouy:self([This])]);
        _ -> undefined
    end,
    This.

-spec 'Quitter#dispatch'(binary(), map(), list()) -> {term(), map()}.
'Quitter#dispatch'(<<"ping">>, This, Args) -> 'Quitter#ping'(This, Args);
'Quitter#dispatch'(<<"quit">>, This, Args) -> 'Quitter#quit'(This, Args);
'Quitter#dispatch'(Method, _This, _Args) ->
    bouy_error:throw(<<"TypeError">>, <<"Quitter.", Method/binary, " is not a function">>).

-spec 'Quitter#streams'() -> [binary()].
'Quitter#streams'() -> [].

-spec 'Quitter#ping'(map(), list()) -> {binary(), map()}.
'Quitter#ping'(This, _Args) ->
    {<<"pong">>, This}.

-spec 'Quitter#quit'(map(), list()) -> {binary(), map()}.
'Quitter#quit'(This, _Args) ->
    undefined = bouy:stop([bouy:self([This])]),
    {<<"bye">>, This}.
