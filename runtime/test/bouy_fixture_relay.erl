-module(bouy_fixture_relay).

%% The compiled shape of a class that calls another actor:
%%
%%   export class Relay {
%%     ping() { return "pong"; }
%%     ask(peer, method, ...args) {
%%       try { return peer[method](...args); } catch (e) { return e._tag; }
%%     }
%%     tell(peer, method, ...args) { return peer[method](...args); }
%%   }

-export([
    'Relay#new'/1,
    'Relay#dispatch'/3,
    'Relay#streams'/0,
    'Relay#ping'/2,
    'Relay#ask'/2,
    'Relay#tell'/2
]).

-spec 'Relay#new'(list()) -> map().
'Relay#new'(_Args) ->
    #{}.

-spec 'Relay#dispatch'(binary(), map(), list()) -> {term(), map()}.
'Relay#dispatch'(<<"ping">>, This, Args) -> 'Relay#ping'(This, Args);
'Relay#dispatch'(<<"ask">>, This, Args) -> 'Relay#ask'(This, Args);
'Relay#dispatch'(<<"tell">>, This, Args) -> 'Relay#tell'(This, Args);
'Relay#dispatch'(Method, _This, _Args) ->
    bouy_error:throw(<<"TypeError">>, <<"Relay.", Method/binary, " is not a function">>).

-spec 'Relay#streams'() -> [binary()].
'Relay#streams'() -> [].

-spec 'Relay#ping'(map(), list()) -> {binary(), map()}.
'Relay#ping'(This, _Args) ->
    {<<"pong">>, This}.

-spec 'Relay#ask'(map(), list()) -> {term(), map()}.
'Relay#ask'(This, [Peer, Method | Args]) ->
    try
        {bouy_actor:call(Peer, Method, Args), This}
    catch
        error:Reason:Stack -> {maps:get(<<"_tag">>, bouy_rt:caught(Reason, Stack)), This}
    end.

-spec 'Relay#tell'(map(), list()) -> {term(), map()}.
'Relay#tell'(This, [Peer, Method | Args]) ->
    {bouy_actor:call(Peer, Method, Args), This}.
