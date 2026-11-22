-module(kraken_pairs_ffi).
-export([create_table/0, size/1]).

create_table() ->
    try ets:new(kraken_pairs, [set, protected, {read_concurrency, true}]) of
        Table -> {ok, Table}
    catch
        error:badarg -> {error, nil}
    end.

size(Table) ->
    case ets:info(Table, size) of
        undefined -> error(badarg);
        Size -> Size
    end.
