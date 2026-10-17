%% Macros that the modules of the reference-semantics engine share. The value
%% representation they test is in the contract, section "Reference semantics".

-define(IS_OBJECT(V), (is_tuple(V) andalso (element(1, V) =:= '$o' orelse element(1, V) =:= '$f'))).
%% The pdict key of the current realm: absent for the realm of the process, N
%% for the realm that bouy_ref_realm:create/0 made N-th.
-define(REALM_KEY, '$bouy_realm').
%% These intrinsics are the ones of the current realm (bouy_heap:intrinsic/1).
-define(OBJECT_PROTO, bouy_heap:intrinsic('Object.prototype')).
%% Function.prototype is itself a function that returns undefined.
-define(FUNCTION_PROTO, bouy_heap:function_prototype()).
-define(ITERATOR_PROTO, bouy_heap:intrinsic('Iterator.prototype')).
%% The attributes of a builtin data property: writable and configurable.
-define(HIDDEN, 5).
-define(SYM(Name), {'$sym', Name, <<"Symbol.", (atom_to_binary(Name))/binary>>}).
%% The builtin methods Names of the object Owner, implemented by method/4 of
%% this module.
-define(METHODS(Owner, Names), bouy_ref_realm:methods(?MODULE, Owner, Names)).
%% A number: an integer, a float, or one of the atoms of the non-finite
%% values (bouy_ref_number).
-define(IS_NUMBER(V), (is_number(V) orelse V =:= 'NaN' orelse V =:= 'Infinity' orelse V =:= '-Infinity')).
%% A string: a one-byte binary or a two-byte {'$u16', Binary} (bouy_ref_string).
-define(IS_STRING(V), (is_binary(V) orelse (is_tuple(V) andalso tuple_size(V) =:= 2 andalso element(1, V) =:= '$u16'))).
