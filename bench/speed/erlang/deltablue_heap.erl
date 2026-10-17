-module(deltablue_heap).

%% DeltaBlue as a typed compilation with a heap. Variables and constraints form a cyclic
%% mutable graph, so they live in the process dictionary as tuples of their known shapes
%% under integer references. Whole-program analysis applies three rewrites:
%% - Strength has 7 immutable instances, compared by identity, so it is the integer of its
%%   strengthValue;
%% - a Plan and a todo list never alias, so they are a list and a `queue`;
%% - the first two writes of BinaryConstraint.chooseMethod are dead stores, because the
%%   last if/else always overwrites `direction`.
%% Method calls on a constraint dispatch on the class tag of its record.

-export([main/1]).

-define(REQUIRED, 0).
-define(PREFERRED, 2).
-define(STRONG_DEFAULT, 3).
-define(NORMAL, 4).
-define(WEAKEST, 6).

-define(NONE, 0).
-define(FORWARD, 1).
-define(BACKWARD, -1).

%% Variable: {variable, Value, Constraints, DeterminedBy, Mark, WalkStrength, Stay, Name}
-define(V_VALUE, 2).
-define(V_CONSTRAINTS, 3).
-define(V_DETERMINED_BY, 4).
-define(V_MARK, 5).
-define(V_WALK, 6).
-define(V_STAY, 7).
%% Unary: {stay | edit, Strength, Output, Satisfied}
-define(U_SATISFIED, 4).
%% Binary: {equality, Strength, V1, V2, Direction}
%%         {scale, Strength, V1, V2, Direction, Scale, Offset}
-define(B_DIRECTION, 5).

-compile({inline, [field/2, set/3, strength/1]}).

-spec main([string()]) -> no_return().
main(Args) ->
    speed_harness:bench(<<"deltablue">>, 100, fun iteration/1, Args).

iteration(Size) -> iteration(Size, 0).

iteration(0, Check) -> Check;
iteration(Size, Check) -> iteration(Size - 1, Check + chain_test(100) + projection_test(100)).

%%% Heap

field(Ref, Field) -> element(Field, get(Ref)).

set(Ref, Field, Value) -> put(Ref, setelement(Field, get(Ref), Value)).

new(Record) ->
    Ref = get(next),
    put(next, Ref + 1),
    put(Ref, Record),
    Ref.

reset() ->
    put(next, 1),
    put(mark, 0).

%%% Strength

stronger(S1, S2) -> S1 < S2.

weaker(S1, S2) -> S1 > S2.

weakest_of(S1, S2) ->
    case weaker(S1, S2) of
        true -> S1;
        false -> S2
    end.

next_weaker(0) -> ?WEAKEST;
next_weaker(1) -> 5;
next_weaker(2) -> 4;
next_weaker(3) -> 3;
next_weaker(4) -> 2;
next_weaker(_) -> ?REQUIRED.

%%% Variable

new_variable(Name, Value) -> new({variable, Value, [], null, 0, ?WEAKEST, true, Name}).

variable_add_constraint(V, C) -> set(V, ?V_CONSTRAINTS, field(V, ?V_CONSTRAINTS) ++ [C]).

variable_remove_constraint(V, C) ->
    set(V, ?V_CONSTRAINTS, [Each || Each <- field(V, ?V_CONSTRAINTS), Each =/= C]),
    case field(V, ?V_DETERMINED_BY) of
        C -> set(V, ?V_DETERMINED_BY, null);
        _ -> ok
    end.

%%% Constraint

new_stay(V, Strength) -> add_constraint(new({stay, Strength, V, false})).

new_edit(V, Strength) -> add_constraint(new({edit, Strength, V, false})).

new_equality(V1, V2, Strength) -> add_constraint(new({equality, Strength, V1, V2, ?NONE})).

new_scale(Src, Scale, Offset, Dest, Strength) ->
    add_constraint(new({scale, Strength, Src, Dest, ?NONE, Scale, Offset})).

strength(C) -> field(C, 2).

add_constraint(C) ->
    add_to_graph(C),
    incremental_add(C),
    C.

satisfy(C, Mark) ->
    choose_method(C, Mark),
    case is_satisfied(C) of
        false ->
            case strength(C) of
                ?REQUIRED -> error(required_constraint_unsatisfied);
                _ -> null
            end;
        true ->
            mark_inputs(C, Mark),
            Out = output(C),
            Overridden = field(Out, ?V_DETERMINED_BY),
            case Overridden of
                null -> ok;
                _ -> mark_unsatisfied(Overridden)
            end,
            set(Out, ?V_DETERMINED_BY, C),
            add_propagate(C, Mark) orelse error(cycle_encountered),
            set(Out, ?V_MARK, Mark),
            Overridden
    end.

destroy_constraint(C) ->
    case is_satisfied(C) of
        true -> incremental_remove(C);
        false -> remove_from_graph(C)
    end.

is_input(C) -> element(1, get(C)) =:= edit.

add_to_graph(C) ->
    case get(C) of
        {_, _, Out, _} ->
            variable_add_constraint(Out, C),
            set(C, ?U_SATISFIED, false);
        {equality, _, V1, V2, _} ->
            variable_add_constraint(V1, C),
            variable_add_constraint(V2, C),
            set(C, ?B_DIRECTION, ?NONE);
        {scale, _, V1, V2, _, Scale, Offset} ->
            variable_add_constraint(V1, C),
            variable_add_constraint(V2, C),
            set(C, ?B_DIRECTION, ?NONE),
            variable_add_constraint(Scale, C),
            variable_add_constraint(Offset, C)
    end.

choose_method(C, Mark) ->
    case get(C) of
        {_, Strength, Out, _} ->
            set(
                C,
                ?U_SATISFIED,
                field(Out, ?V_MARK) =/= Mark andalso stronger(Strength, field(Out, ?V_WALK))
            );
        Binary ->
            Strength = element(2, Binary),
            W1 = field(element(3, Binary), ?V_WALK),
            W2 = field(element(4, Binary), ?V_WALK),
            Direction =
                case weaker(W1, W2) of
                    true ->
                        case stronger(Strength, W1) of
                            true -> ?BACKWARD;
                            false -> ?NONE
                        end;
                    false ->
                        case stronger(Strength, W2) of
                            true -> ?FORWARD;
                            false -> ?BACKWARD
                        end
                end,
            set(C, ?B_DIRECTION, Direction)
    end.

is_satisfied(C) ->
    case get(C) of
        {_, _, _, Satisfied} -> Satisfied;
        Binary -> element(?B_DIRECTION, Binary) =/= ?NONE
    end.

mark_inputs(C, Mark) ->
    case get(C) of
        {_, _, _, _} ->
            ok;
        {equality, _, V1, V2, Direction} ->
            set(input(Direction, V1, V2), ?V_MARK, Mark);
        {scale, _, V1, V2, Direction, Scale, Offset} ->
            set(input(Direction, V1, V2), ?V_MARK, Mark),
            set(Scale, ?V_MARK, Mark),
            set(Offset, ?V_MARK, Mark)
    end.

input(?FORWARD, V1, _V2) -> V1;
input(_, _V1, V2) -> V2.

output(?FORWARD, _V1, V2) -> V2;
output(_, V1, _V2) -> V1.

output(C) ->
    case get(C) of
        {_, _, Out, _} -> Out;
        Binary -> output(element(?B_DIRECTION, Binary), element(3, Binary), element(4, Binary))
    end.

recalculate(C) ->
    case get(C) of
        {Kind, Strength, Out, _} ->
            set(Out, ?V_WALK, Strength),
            Stay = Kind =/= edit,
            set(Out, ?V_STAY, Stay),
            %% The execute of StayConstraint and of EditConstraint does nothing.
            ok;
        {equality, Strength, V1, V2, Direction} ->
            In = input(Direction, V1, V2),
            Out = output(Direction, V1, V2),
            set(Out, ?V_WALK, weakest_of(Strength, field(In, ?V_WALK))),
            Stay = field(In, ?V_STAY),
            set(Out, ?V_STAY, Stay),
            Stay andalso execute(C),
            ok;
        {scale, Strength, V1, V2, Direction, Scale, Offset} ->
            In = input(Direction, V1, V2),
            Out = output(Direction, V1, V2),
            set(Out, ?V_WALK, weakest_of(Strength, field(In, ?V_WALK))),
            Stay = field(In, ?V_STAY) andalso field(Scale, ?V_STAY) andalso field(Offset, ?V_STAY),
            set(Out, ?V_STAY, Stay),
            Stay andalso execute(C),
            ok
    end.

mark_unsatisfied(C) ->
    case get(C) of
        {_, _, _, _} -> set(C, ?U_SATISFIED, false);
        _ -> set(C, ?B_DIRECTION, ?NONE)
    end.

inputs_known(C, Mark) ->
    case get(C) of
        {_, _, _, _} ->
            true;
        Binary ->
            In = input(element(?B_DIRECTION, Binary), element(3, Binary), element(4, Binary)),
            {variable, _, _, DeterminedBy, InMark, _, Stay, _} = get(In),
            InMark =:= Mark orelse Stay orelse DeterminedBy =:= null
    end.

remove_from_graph(C) ->
    case get(C) of
        {_, _, Out, _} ->
            variable_remove_constraint(Out, C),
            set(C, ?U_SATISFIED, false);
        {equality, _, V1, V2, _} ->
            variable_remove_constraint(V1, C),
            variable_remove_constraint(V2, C),
            set(C, ?B_DIRECTION, ?NONE);
        {scale, _, V1, V2, _, Scale, Offset} ->
            variable_remove_constraint(V1, C),
            variable_remove_constraint(V2, C),
            set(C, ?B_DIRECTION, ?NONE),
            variable_remove_constraint(Scale, C),
            variable_remove_constraint(Offset, C)
    end.

execute(C) ->
    case get(C) of
        {_, _, _, _} ->
            ok;
        {equality, _, V1, V2, Direction} ->
            set(output(Direction, V1, V2), ?V_VALUE, field(input(Direction, V1, V2), ?V_VALUE));
        {scale, _, V1, V2, ?FORWARD, Scale, Offset} ->
            set(V2, ?V_VALUE, field(V1, ?V_VALUE) * field(Scale, ?V_VALUE) + field(Offset, ?V_VALUE));
        {scale, _, V1, V2, _, Scale, Offset} ->
            set(V1, ?V_VALUE, (field(V2, ?V_VALUE) - field(Offset, ?V_VALUE)) / field(Scale, ?V_VALUE))
    end.

%%% Planner

new_mark() ->
    Mark = get(mark) + 1,
    put(mark, Mark),
    Mark.

incremental_add(C) ->
    Mark = new_mark(),
    satisfy_all(satisfy(C, Mark), Mark).

satisfy_all(null, _Mark) -> ok;
satisfy_all(Overridden, Mark) -> satisfy_all(satisfy(Overridden, Mark), Mark).

incremental_remove(C) ->
    Out = output(C),
    mark_unsatisfied(C),
    remove_from_graph(C),
    Unsatisfied = remove_propagate_from(Out),
    add_by_strength(Unsatisfied, ?REQUIRED).

add_by_strength(Unsatisfied, Strength) ->
    _ = [incremental_add(U) || U <- Unsatisfied, strength(U) =:= Strength],
    case next_weaker(Strength) of
        ?WEAKEST -> ok;
        Next -> add_by_strength(Unsatisfied, Next)
    end.

make_plan(Sources) ->
    make_plan(queue:from_list(Sources), new_mark(), []).

make_plan(Todo, Mark, Plan) ->
    case queue:out(Todo) of
        {empty, _} ->
            lists:reverse(Plan);
        {{value, C}, Rest} ->
            Out = output(C),
            case field(Out, ?V_MARK) =/= Mark andalso inputs_known(C, Mark) of
                true ->
                    set(Out, ?V_MARK, Mark),
                    make_plan(add_constraints_consuming_to(Out, Rest), Mark, [C | Plan]);
                false ->
                    make_plan(Rest, Mark, Plan)
            end
    end.

extract_plan_from_constraints(Constraints) ->
    make_plan([C || C <- Constraints, is_input(C), is_satisfied(C)]).

add_propagate(C, Mark) -> add_propagate(C, Mark, queue:from_list([C])).

add_propagate(C, Mark, Todo) ->
    case queue:out(Todo) of
        {empty, _} ->
            true;
        {{value, D}, Rest} ->
            case field(output(D), ?V_MARK) of
                Mark ->
                    incremental_remove(C),
                    false;
                _ ->
                    recalculate(D),
                    add_propagate(C, Mark, add_constraints_consuming_to(output(D), Rest))
            end
    end.

remove_propagate_from(Out) ->
    set(Out, ?V_DETERMINED_BY, null),
    set(Out, ?V_WALK, ?WEAKEST),
    set(Out, ?V_STAY, true),
    remove_propagate(queue:from_list([Out]), []).

remove_propagate(Todo, Unsatisfied) ->
    case queue:out(Todo) of
        {empty, _} ->
            lists:reverse(Unsatisfied);
        {{value, V}, Rest} ->
            Constraints = field(V, ?V_CONSTRAINTS),
            Unsatisfied1 = lists:foldl(
                fun(C, Acc) ->
                    case is_satisfied(C) of
                        true -> Acc;
                        false -> [C | Acc]
                    end
                end,
                Unsatisfied,
                Constraints
            ),
            Determining = field(V, ?V_DETERMINED_BY),
            Rest1 = lists:foldl(
                fun(Next, Acc) ->
                    case Next =/= Determining andalso is_satisfied(Next) of
                        true ->
                            recalculate(Next),
                            queue:in(output(Next), Acc);
                        false ->
                            Acc
                    end
                end,
                Rest,
                Constraints
            ),
            remove_propagate(Rest1, Unsatisfied1)
    end.

add_constraints_consuming_to(V, Todo) ->
    Determining = field(V, ?V_DETERMINED_BY),
    lists:foldl(
        fun(C, Acc) ->
            case C =/= Determining andalso is_satisfied(C) of
                true -> queue:in(C, Acc);
                false -> Acc
            end
        end,
        Todo,
        field(V, ?V_CONSTRAINTS)
    ).

execute_plan(Plan) -> lists:foreach(fun execute/1, Plan).

%%% The tests

chain_test(N) ->
    reset(),
    Variables = [new_variable(<<"v", (integer_to_binary(I))/binary>>, 0) || I <- lists:seq(0, N)],
    chain(Variables),
    First = hd(Variables),
    Last = lists:last(Variables),
    _ = new_stay(Last, ?STRONG_DEFAULT),
    Edit = new_edit(First, ?PREFERRED),
    Plan = extract_plan_from_constraints([Edit]),
    lists:foreach(
        fun(I) ->
            set(First, ?V_VALUE, I),
            execute_plan(Plan),
            field(Last, ?V_VALUE) == I orelse error(chain_test_failed)
        end,
        lists:seq(0, 99)
    ),
    field(Last, ?V_VALUE).

chain([Prev, Next | Rest]) ->
    _ = new_equality(Prev, Next, ?REQUIRED),
    chain([Next | Rest]);
chain(_) ->
    ok.

change(V, NewValue) ->
    Edit = new_edit(V, ?PREFERRED),
    Plan = extract_plan_from_constraints([Edit]),
    lists:foreach(
        fun(_) ->
            set(V, ?V_VALUE, NewValue),
            execute_plan(Plan)
        end,
        lists:seq(1, 10)
    ),
    destroy_constraint(Edit).

projection_test(N) ->
    reset(),
    Scale = new_variable(<<"scale">>, 10),
    Offset = new_variable(<<"offset">>, 1000),
    Pairs = [
        begin
            Src = new_variable(<<"src", (integer_to_binary(I))/binary>>, I),
            Dst = new_variable(<<"dst", (integer_to_binary(I))/binary>>, I),
            _ = new_stay(Src, ?NORMAL),
            _ = new_scale(Src, Scale, Offset, Dst, ?REQUIRED),
            {Src, Dst}
        end
     || I <- lists:seq(0, N - 1)
    ],
    {Src, Dst} = lists:last(Pairs),
    Dests = [D || {_, D} <- Pairs],
    change(Src, 17),
    field(Dst, ?V_VALUE) == 1170 orelse error(projection_1_failed),
    change(Dst, 1050),
    field(Src, ?V_VALUE) == 5 orelse error(projection_2_failed),
    change(Scale, 5),
    check_dests(Dests, 0, N - 1, 5, 1000) orelse error(projection_3_failed),
    change(Offset, 2000),
    check_dests(Dests, 0, N - 1, 5, 2000) orelse error(projection_4_failed),
    field(Dst, ?V_VALUE).

check_dests(_Dests, I, Limit, _Scale, _Offset) when I >= Limit -> true;
check_dests([D | Rest], I, Limit, Scale, Offset) ->
    field(D, ?V_VALUE) == I * Scale + Offset andalso check_dests(Rest, I + 1, Limit, Scale, Offset).
