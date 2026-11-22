-module(kraken_pairs_ffi).
-export([create_table/0, size/1]).

create_table() ->
    ets_table_ffi:create(kraken_pairs, [set, protected, {read_concurrency, true}]).

size(Table) ->
    case ets:info(Table, size) of
        undefined -> error(badarg);
        Size -> Size
    end.
