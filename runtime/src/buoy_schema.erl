%% `Schema` from "effect" (contract section 13): Struct, String, Number,
%% Boolean, Literal, Array, optional, and Union, with decodeUnknownSync,
%% decodeUnknownEffect, and is. A schema is `{'$schema', Ast}`.
%%
%% Decoding stops at the first issue, as Effect does by default, and a
%% SchemaError has the message of Effect, such as
%% `Expected string\n  at ["name"]`. A struct checks its fields in key order,
%% because object keys are sorted (contract section 3).
-module(buoy_schema).

-export(['$member'/1, 'Struct'/1, 'Literal'/1, 'Array'/1, 'Union'/1, optional/1]).
-export([decodeUnknownSync/1, decodeUnknownEffect/1, is/1]).

-define(FUNCTIONS, [
    <<"Struct">>, <<"Literal">>, <<"Array">>, <<"Union">>, <<"optional">>,
    <<"decodeUnknownSync">>, <<"decodeUnknownEffect">>, <<"is">>
]).
-define(ALL_TYPES, [<<"null">>, <<"undefined">>, <<"string">>, <<"number">>, <<"boolean">>, <<"object">>, <<"array">>, <<"function">>]).

-type ast() ::
    string
    | number
    | boolean
    | undefined
    | {literal, term()}
    | {struct, [{binary(), required | optional, ast()}]}
    | {array, ast()}
    | {union, [ast()]}.
-type issue() ::
    {type, ast()}
    | missing
    | {pointer, binary() | non_neg_integer(), issue()}
    | {any_of, ast(), [issue()]}.

-spec '$member'(binary()) -> term().
'$member'(<<"String">>) -> {'$schema', string};
'$member'(<<"Number">>) -> {'$schema', number};
'$member'(<<"Boolean">>) -> {'$schema', boolean};
'$member'(Name) -> buoy_rt:member_function(?MODULE, Name, ?FUNCTIONS).

-spec 'Struct'(list()) -> {'$schema', ast()}.
'Struct'(Args) ->
    Fields = buoy_object:own_entries(buoy_rt:arg(1, Args)),
    {'$schema', {struct, [field(Key, Schema) || {Key, Schema} <- Fields]}}.

field(Key, {'$schema', {optional, Ast}}) -> {Key, optional, Ast};
field(Key, Schema) -> {Key, required, ast(Schema)}.

-spec 'Literal'(list()) -> {'$schema', ast()}.
'Literal'(Args) -> {'$schema', {literal, buoy_rt:arg(1, Args)}}.

-spec 'Array'(list()) -> {'$schema', ast()}.
'Array'(Args) -> {'$schema', {array, ast(buoy_rt:arg(1, Args))}}.

-spec 'Union'(list()) -> {'$schema', ast()}.
'Union'(Args) -> {'$schema', {union, [ast(Member) || Member <- buoy_rt:to_list(buoy_rt:arg(1, Args))]}}.

%% An optional field of a struct: the key may be missing, and the value may
%% be undefined. Elsewhere it is the union with undefined.
-spec optional(list()) -> {'$schema', {optional, ast()}}.
optional(Args) -> {'$schema', {optional, ast(buoy_rt:arg(1, Args))}}.

ast({'$schema', {optional, Ast}}) -> {union, [Ast, undefined]};
ast({'$schema', Ast}) -> Ast;
ast(Other) -> buoy_error:throw(<<"TypeError">>, <<(buoy_rt:describe(Other))/binary, " is not a schema">>).

%% `decodeUnknownSync(schema)(input)`: the decoded value, or a thrown
%% SchemaError.
-spec decodeUnknownSync(list()) -> fun((list()) -> term()).
decodeUnknownSync(Args) ->
    Ast = ast(buoy_rt:arg(1, Args)),
    fun(Input) ->
        case decode(Ast, buoy_rt:arg(1, Input)) of
            {ok, Value} -> Value;
            {issue, Issue} -> erlang:error({'$throw', schema_error(Issue)})
        end
    end.

%% `decodeUnknownEffect(schema)(input)`: an Effect that fails with the
%% SchemaError.
-spec decodeUnknownEffect(list()) -> fun((list()) -> buoy_effect:effect()).
decodeUnknownEffect(Args) ->
    Ast = ast(buoy_rt:arg(1, Args)),
    fun(Input) ->
        Value = buoy_rt:arg(1, Input),
        {'$effect', fun() ->
            case decode(Ast, Value) of
                {ok, _} = Decoded -> Decoded;
                {issue, Issue} -> {error, schema_error(Issue)}
            end
        end}
    end.

%% `is(schema)(input)`.
-spec is(list()) -> fun((list()) -> boolean()).
is(Args) ->
    Ast = ast(buoy_rt:arg(1, Args)),
    fun(Input) -> element(1, decode(Ast, buoy_rt:arg(1, Input))) =:= ok end.

schema_error(Issue) ->
    buoy_error:new(<<"SchemaError">>, format(Issue, <<>>), #{<<"_tag">> => <<"SchemaError">>}).

%%% Decoding

-spec decode(ast(), term()) -> {ok, term()} | {issue, issue()}.
decode(string, Value) when is_binary(Value) -> {ok, Value};
decode(number, Value) when is_number(Value); Value =:= 'NaN'; Value =:= 'Infinity'; Value =:= '-Infinity' -> {ok, Value};
decode(boolean, Value) when is_boolean(Value) -> {ok, Value};
decode(undefined, undefined) -> {ok, undefined};
decode({literal, Literal} = Ast, Value) ->
    case buoy_rt:strict_eq(Literal, Value) of
        true -> {ok, Value};
        false -> {issue, {type, Ast}}
    end;
decode({struct, []} = Ast, Value) when Value =:= null; Value =:= undefined -> {issue, {type, Ast}};
decode({struct, []}, Value) -> {ok, Value};
decode({struct, Fields} = Ast, Value) ->
    case runtime_type(Value) of
        <<"object">> -> fields(Fields, Value, #{});
        _ -> {issue, {type, Ast}}
    end;
decode({array, Item}, Value) when is_list(Value) -> items(Item, Value, 0, []);
decode({union, Members} = Ast, Value) -> union(Ast, Members, Value);
decode(Ast, _Value) -> {issue, {type, Ast}}.

fields([], _Input, Decoded) ->
    {ok, Decoded};
fields([{Key, Kind, Ast} | Rest], Input, Decoded) ->
    case {lookup(Input, Key), Kind} of
        {missing, optional} ->
            fields(Rest, Input, Decoded);
        {missing, required} ->
            {issue, {pointer, Key, missing}};
        {{value, Value}, _} ->
            case decode(field_ast(Kind, Ast), Value) of
                {ok, Field} -> fields(Rest, Input, Decoded#{Key => Field});
                {issue, Issue} -> {issue, {pointer, Key, Issue}}
            end
    end.

field_ast(optional, Ast) -> {union, [Ast, undefined]};
field_ast(required, Ast) -> Ast.

lookup(#{} = Object, Key) ->
    case Object of
        #{Key := Value} -> {value, Value};
        _ -> missing
    end;
lookup(_Object, _Key) ->
    missing.

items(_Item, [], _Index, Decoded) ->
    {ok, lists:reverse(Decoded)};
items(Item, [Value | Rest], Index, Decoded) ->
    case decode(Item, Value) of
        {ok, Field} -> items(Item, Rest, Index + 1, [Field | Decoded]);
        {issue, Issue} -> {issue, {pointer, Index, Issue}}
    end.

%% The first candidate that decodes the input wins. When none does, the
%% issue holds the issue of each candidate.
union(Ast, Members, Value) ->
    first_decoded([lists:nth(Index, Members) || Index <- candidates(Members, Value)], Value, Ast, []).

first_decoded([], _Value, Ast, Issues) ->
    {issue, {any_of, Ast, lists:reverse(Issues)}};
first_decoded([Member | Rest], Value, Ast, Issues) ->
    case decode(Member, Value) of
        {ok, _} = Decoded -> Decoded;
        {issue, Issue} -> first_decoded(Rest, Value, Ast, [Issue | Issues])
    end.

%% The indexes of the members of a union that can decode Input, as Effect
%% selects them (`getCandidateIndex` in SchemaAST): a union of literals by
%% the value, structs by their literal fields, and other members by the
%% runtime type of the input.
candidates(Members, Input) ->
    Indexed = lists:enumerate(Members),
    Discriminated = [{Index, Sentinels} || {Index, Member} <- Indexed, Sentinels <- [sentinels(Member)], Sentinels =/= []],
    Plain = [{Index, Member} || {Index, Member} <- Indexed, sentinels(Member) =:= []],
    Type = runtime_type(Input),
    Fallback = [Index || {Index, Member} <- Plain, lists:member(Type, candidate_types(Member))],
    Keys = lists:usort([Key || {_, Sentinels} <- Discriminated, {Key, _} <- Sentinels]),
    OnlyLiterals = Members =/= [] andalso lists:all(fun is_literal/1, Members),
    Object = is_object(Input),
    if
        OnlyLiterals ->
            [Index || {Index, {literal, Literal}} <- Indexed, buoy_rt:same_value_zero(Literal, Input)];
        Discriminated =:= [] ->
            [Index || Index <- Fallback, literal_allows(lists:nth(Index, Members), Input)];
        Plain =:= [], length(Keys) =:= 1, Object ->
            [Key] = Keys,
            case lookup(Input, Key) of
                {value, Value} when Value =/= undefined -> matching(Discriminated, Key, Value);
                _ -> []
            end;
        Plain =:= [], length(Keys) =:= 1 ->
            [];
        Object ->
            discriminated(Discriminated, Keys, Fallback, Input);
        true ->
            Fallback
    end.

%% The general case: a key that every discriminated member has selects the
%% members by its value, else each key that the input has adds its members.
%% Then each key that the input has removes the members that disagree.
discriminated(Discriminated, Keys, Fallback, Input) ->
    Common = common_key(Discriminated, Keys),
    Seeded =
        case Common of
            {Key, _} ->
                case lookup(Input, Key) of
                    {value, Value} ->
                        case matching(Discriminated, Key, Value) of
                            [] -> fallback;
                            Matching -> {Key, Fallback ++ Matching}
                        end;
                    missing ->
                        none
                end;
            none ->
                none
        end,
    case Seeded of
        fallback ->
            Fallback;
        {Direct, Selected} ->
            prune(Discriminated, Keys -- [Direct], lists:usort(Selected), Input);
        none ->
            Added = [Index || Key <- Keys, {value, Value} <- [lookup(Input, Key)], Index <- matching(Discriminated, Key, Value)],
            prune(Discriminated, Keys, lists:usort(Fallback ++ Added), Input)
    end.

prune(Discriminated, Keys, Selected, Input) ->
    lists:foldl(
        fun(Key, Kept) ->
            case lookup(Input, Key) of
                {value, Value} ->
                    Owners = [Index || {Index, Sentinels} <- Discriminated, lists:keymember(Key, 1, Sentinels)],
                    Matching = matching(Discriminated, Key, Value),
                    [Index || Index <- Kept, not lists:member(Index, Owners) orelse lists:member(Index, Matching)];
                missing ->
                    Kept
            end
        end,
        Selected,
        Keys
    ).

%% The key that every discriminated member has, with the most distinct
%% values.
common_key(Discriminated, Keys) ->
    Shared = [
        {Key, length(lists:usort([Literal || {_, Sentinels} <- Discriminated, {K, Literal} <- Sentinels, K =:= Key]))}
     || Key <- Keys,
        lists:all(fun({_, Sentinels}) -> lists:keymember(Key, 1, Sentinels) end, Discriminated)
    ],
    case Shared of
        [] -> none;
        _ -> lists:foldl(fun({_, Count} = Next, {_, Best}) when Count > Best -> Next; (_, Best) -> Best end, hd(Shared), tl(Shared))
    end.

matching(Discriminated, Key, Value) ->
    [Index || {Index, Sentinels} <- Discriminated, {K, Literal} <- Sentinels, K =:= Key, buoy_rt:same_value_zero(Literal, Value)].

is_literal({literal, _}) -> true;
is_literal(_Ast) -> false.

literal_allows({literal, Literal}, Input) -> buoy_rt:strict_eq(Literal, Input);
literal_allows(_Member, _Input) -> true.

%% The literal fields that discriminate a struct, and those that every
%% member of a union shares.
sentinels({struct, Fields}) ->
    [{Key, Literal} || {Key, required, {literal, Literal}} <- Fields];
sentinels({union, []}) ->
    [];
sentinels({union, [First | Rest]}) ->
    Others = [sentinels(Member) || Member <- Rest],
    [Sentinel || Sentinel <- sentinels(First), lists:all(fun(Sentinels) -> lists:member(Sentinel, Sentinels) end, Others)];
sentinels(_Ast) ->
    [].

candidate_types(string) -> [<<"string">>];
candidate_types(number) -> [<<"number">>];
candidate_types(boolean) -> [<<"boolean">>];
candidate_types(undefined) -> [<<"undefined">>];
candidate_types({literal, Literal}) -> [buoy_rt:type_of(Literal)];
candidate_types({struct, []}) -> ?ALL_TYPES;
candidate_types({struct, _}) -> [<<"object">>];
candidate_types({array, _}) -> [<<"array">>];
candidate_types({union, Members}) -> lists:usort(lists:append([candidate_types(Member) || Member <- Members])).

runtime_type(null) -> <<"null">>;
runtime_type(Value) when is_list(Value) -> <<"array">>;
runtime_type(Value) -> buoy_rt:type_of(Value).

is_object(Value) -> lists:member(runtime_type(Value), [<<"object">>, <<"array">>, <<"function">>]).

%%% Messages

format({pointer, Segment, Issue}, Path) ->
    format(Issue, <<Path/binary, (segment(Segment))/binary>>);
format({any_of, _Ast, [_ | _] = Issues}, Path) ->
    iolist_to_binary(lists:join(<<"\n">>, [format(Issue, Path) || Issue <- Issues]));
format(Issue, <<>>) ->
    leaf(Issue);
format(Issue, Path) ->
    <<(leaf(Issue))/binary, "\n  at ", Path/binary>>.

leaf({type, Ast}) -> <<"Expected ", (expected(Ast))/binary>>;
leaf({any_of, Ast, []}) -> <<"Expected ", (expected(Ast))/binary>>;
leaf(missing) -> <<"Missing key">>.

segment(Index) when is_integer(Index) -> <<"[", (integer_to_binary(Index))/binary, "]">>;
segment(Key) -> <<"[", (json(Key))/binary, "]">>.

expected(string) -> <<"string">>;
expected(number) -> <<"number">>;
expected(boolean) -> <<"boolean">>;
expected(undefined) -> <<"undefined">>;
expected({literal, Literal}) when is_binary(Literal) -> json(Literal);
expected({literal, Literal}) -> buoy_rt:to_string(Literal);
expected({struct, []}) -> <<"object | array">>;
expected({struct, _}) -> <<"object">>;
expected({array, _}) -> <<"array">>;
expected({union, []}) -> <<"never">>;
expected({union, Members}) ->
    Texts = lists:foldl(
        fun(Member, Seen) ->
            Text = member_expected(Member),
            case lists:member(Text, Seen) of
                true -> Seen;
                false -> Seen ++ [Text]
            end
        end,
        [],
        Members
    ),
    iolist_to_binary(lists:join(<<" | ">>, Texts)).

%% A struct with literal fields shows them in a union.
member_expected({struct, Fields} = Ast) ->
    case [{Key, Literal} || {Key, required, {literal, Literal}} <- Fields] of
        [] ->
            expected(Ast);
        Literals ->
            Shown = [[<<"readonly ">>, json(Key), <<": ">>, expected({literal, Literal})] || {Key, Literal} <- Literals],
            iolist_to_binary([<<"{ ">>, lists:join(<<", ">>, Shown), <<", ... }">>])
    end;
member_expected(Ast) ->
    expected(Ast).

json(Text) -> buoy_json:stringify([Text]).
