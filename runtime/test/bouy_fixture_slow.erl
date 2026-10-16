-module(bouy_fixture_slow).

%% The compiled shape of:
%%
%%   export class Slow {
%%     #done = 0;
%%     work(ms) { sleep(ms); this.#done += 1; return this.#done; }
%%     spin(ms) {
%%       const end = Date.now() + ms;
%%       let rounds = 0;
%%       while (Date.now() < end) rounds++;
%%       return rounds;
%%     }
%%     ping() { return "pong"; }
%%     done() { return this.#done; }
%%   }

-export([
    'Slow#new'/1,
    'Slow#dispatch'/3,
    'Slow#streams'/0,
    'Slow#work'/2,
    'Slow#spin'/2,
    'Slow#ping'/2,
    'Slow#done'/2
]).

-spec 'Slow#new'(list()) -> map().
'Slow#new'(_Args) ->
    #{<<"#done">> => 0}.

-spec 'Slow#dispatch'(binary(), map(), list()) -> {term(), map()}.
'Slow#dispatch'(<<"work">>, This, Args) -> 'Slow#work'(This, Args);
'Slow#dispatch'(<<"spin">>, This, Args) -> 'Slow#spin'(This, Args);
'Slow#dispatch'(<<"ping">>, This, Args) -> 'Slow#ping'(This, Args);
'Slow#dispatch'(<<"done">>, This, Args) -> 'Slow#done'(This, Args);
'Slow#dispatch'(Method, _This, _Args) ->
    bouy_error:throw(<<"TypeError">>, <<"Slow.", Method/binary, " is not a function">>).

-spec 'Slow#streams'() -> [binary()].
'Slow#streams'() -> [].

-spec 'Slow#work'(map(), list()) -> {integer(), map()}.
'Slow#work'(#{<<"#done">> := Done} = This, Args) ->
    undefined = bouy:sleep([bouy_rt:arg(1, Args)]),
    {Done + 1, This#{<<"#done">> := Done + 1}}.

-spec 'Slow#spin'(map(), list()) -> {integer(), map()}.
'Slow#spin'(This, Args) ->
    End = erlang:monotonic_time(millisecond) + bouy_rt:arg(1, Args),
    Loop = fun Loop(Rounds) ->
        case erlang:monotonic_time(millisecond) < End of
            true -> Loop(Rounds + 1);
            false -> Rounds
        end
    end,
    {Loop(0), This}.

-spec 'Slow#ping'(map(), list()) -> {binary(), map()}.
'Slow#ping'(This, _Args) ->
    {<<"pong">>, This}.

-spec 'Slow#done'(map(), list()) -> {integer(), map()}.
'Slow#done'(#{<<"#done">> := Done} = This, _Args) ->
    {Done, This}.
