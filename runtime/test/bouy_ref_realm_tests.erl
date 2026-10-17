-module(bouy_ref_realm_tests).

-include_lib("eunit/include/eunit.hrl").

%% While one realm installs the intrinsics, another realm that reads the global
%% object must see every global binding. An install that first wrote an empty
%% global object let a realm copy the empty one.
install_never_shows_a_partial_global_object_test() ->
    ok = bouy_ref_realm:install(),
    Self = self(),
    Watcher = spawn(fun() -> watch(Self, 0) end),
    [begin
         persistent_term:erase({bouy_ref_realm, installed}),
         ok = bouy_ref_realm:install()
     end || _ <- lists:seq(1, 20)],
    Watcher ! stop,
    receive
        {partial, Seen} -> ?assertEqual(0, Seen)
    end.

watch(Parent, Seen) ->
    receive
        stop -> Parent ! {partial, Seen}
    after 0 ->
        Partial = case persistent_term:get({bouy_heap, 'globalThis'}, undefined) of
            undefined -> 0;
            {_, _, Props, _, _, _} when is_map_key(<<"Array">>, Props) -> 0;
            _ -> 1
        end,
        watch(Parent, Seen + Partial)
    end.

global_object_holds_the_globals_test() ->
    Self = self(),
    spawn(fun() ->
                  ok = bouy_ref_realm:install(),
                  G = {'$o', 'globalThis'},
                  Self ! {result, bouy_heap:get(G, <<"Array">>) =:= bouy_ref_realm:global(<<"Array">>),
                          bouy_heap:get_own(G, <<"undefined">>)}
          end),
    receive
        {result, Same, Undefined} ->
            ?assert(Same),
            ?assertEqual({data, undefined, 0}, Undefined)
    end.
