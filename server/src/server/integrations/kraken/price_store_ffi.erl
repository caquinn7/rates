-module(price_store_ffi).
-export([create_table/0, find_table/0]).

-define(TABLE_NAME, kraken_price_store).

create_table() ->
    try ets:new(?TABLE_NAME, [
        named_table, set, protected, {read_concurrency, true}, {write_concurrency, auto}
    ]) of
        ?TABLE_NAME -> find_table()
    catch
        error:badarg -> {error, nil}
    end.

find_table() ->
    case ets:whereis(?TABLE_NAME) of
        undefined -> {error, nil};
        Table -> {ok, Table}
    end.
