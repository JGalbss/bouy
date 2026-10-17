%% Macros that the modules of the reference-semantics engine share. The value
%% representation they test is in the contract, section "Reference semantics".

-define(IS_OBJECT(V), (is_tuple(V) andalso (element(1, V) =:= '$o' orelse element(1, V) =:= '$f'))).
-define(OBJECT_PROTO, {'$o', 'Object.prototype'}).
-define(FUNCTION_PROTO, {'$o', 'Function.prototype'}).
-define(ITERATOR_PROTO, {'$o', 'Iterator.prototype'}).
%% The attributes of a builtin data property: writable and configurable.
-define(HIDDEN, 5).
-define(SYM(Name), {'$sym', Name, <<"Symbol.", (atom_to_binary(Name))/binary>>}).
%% The builtin methods Names of the object Owner, implemented by method/4 of
%% this module.
-define(METHODS(Owner, Names), bouy_ref_realm:methods(?MODULE, Owner, Names)).
