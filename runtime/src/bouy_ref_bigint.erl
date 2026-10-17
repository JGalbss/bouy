%% The BigInt family. BigInt values are {'$bigint', Integer} (contract, "Reference semantics").
-module(bouy_ref_bigint).

-include("bouy_ref.hrl").

-export([intrinsics/0, globals/0]).


-spec intrinsics() -> [{term(), tuple()}].
intrinsics() -> [].

-spec globals() -> [{binary(), term()}].
globals() -> [].
