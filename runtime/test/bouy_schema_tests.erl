-module(bouy_schema_tests).

-include_lib("eunit/include/eunit.hrl").

-import(bouy_test_runtime, [thrown/1]).

string() -> bouy_schema:'$member'(<<"String">>).
number() -> bouy_schema:'$member'(<<"Number">>).
literal(Value) -> bouy_schema:'Literal'([Value]).
struct(Fields) -> bouy_schema:'Struct'([Fields]).
union(Members) -> bouy_schema:'Union'([Members]).

decode(Schema, Input) -> (bouy_schema:decodeUnknownSync([Schema]))([Input]).

%% The message of the SchemaError that decoding Input throws.
message(Schema, Input) ->
    #{<<"_tag">> := <<"SchemaError">>, <<"message">> := Message} = thrown(fun() -> decode(Schema, Input) end),
    Message.

person() ->
    struct(#{
        <<"name">> => string(),
        <<"tags">> => bouy_schema:'Array'([string()]),
        <<"nick">> => bouy_schema:optional([string()])
    }).

decodes_and_strips_unknown_keys_test() ->
    Input = #{<<"name">> => <<"Ann">>, <<"tags">> => [<<"x">>], <<"extra">> => 1},
    ?assertEqual(#{<<"name">> => <<"Ann">>, <<"tags">> => [<<"x">>]}, decode(person(), Input)),
    ?assertEqual(#{<<"name">> => <<"A">>, <<"tags">> => [], <<"nick">> => undefined}, decode(person(), #{<<"name">> => <<"A">>, <<"tags">> => [], <<"nick">> => undefined})).

messages_name_the_path_test() ->
    ?assertEqual(<<"Expected number">>, message(number(), <<"x">>)),
    ?assertEqual(<<"Expected object">>, message(person(), [])),
    ?assertEqual(<<"Missing key\n  at [\"name\"]">>, message(person(), #{<<"tags">> => []})),
    ?assertEqual(<<"Expected string\n  at [\"tags\"][1]">>, message(person(), #{<<"name">> => <<"A">>, <<"tags">> => [<<"a">>, 1]})),
    ?assertEqual(<<"Expected string | undefined\n  at [\"nick\"]">>, message(person(), #{<<"name">> => <<"A">>, <<"tags">> => [], <<"nick">> => 1})),
    ?assertEqual(<<"Expected \"x\"">>, message(literal(<<"x">>), <<"y">>)).

unions_pick_candidates_as_effect_does_test() ->
    ?assertEqual(1, decode(union([string(), number()]), 1)),
    ?assertEqual(<<"Expected string | number">>, message(union([string(), number()]), true)),
    ?assertEqual(<<"Expected \"a\" | \"b\"">>, message(union([literal(<<"a">>), literal(<<"b">>)]), <<"c">>)),
    Shapes = union([
        struct(#{<<"k">> => literal(<<"x">>)}),
        struct(#{<<"k">> => literal(<<"y">>), <<"n">> => number()})
    ]),
    ?assertEqual(#{<<"k">> => <<"x">>}, decode(Shapes, #{<<"k">> => <<"x">>, <<"n">> => <<"ignored">>})),
    ?assertEqual(<<"Missing key\n  at [\"n\"]">>, message(Shapes, #{<<"k">> => <<"y">>})),
    ?assertEqual(<<"Expected { readonly \"k\": \"x\", ... } | { readonly \"k\": \"y\", ... }">>, message(Shapes, #{<<"k">> => <<"z">>})),
    Untagged = union([struct(#{<<"a">> => number()}), struct(#{<<"b">> => number()})]),
    ?assertEqual(<<"Missing key\n  at [\"a\"]\nMissing key\n  at [\"b\"]">>, message(Untagged, #{<<"c">> => 1})).

is_and_decode_effect_test() ->
    ?assert((bouy_schema:is([number()]))([1.5])),
    ?assertNot((bouy_schema:is([person()]))([#{}])),
    {'$effect', Thunk} = (bouy_schema:decodeUnknownEffect([number()]))([<<"x">>]),
    ?assertMatch({error, #{<<"_tag">> := <<"SchemaError">>, <<"message">> := <<"Expected number">>}}, Thunk()).
