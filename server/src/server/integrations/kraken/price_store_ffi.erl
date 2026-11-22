-module(price_store_ffi).
-export([create_table/0]).

create_table() ->
    try ets:new(kraken_price_store, [
        set, protected, {read_concurrency, true}, {write_concurrency, auto}
    ]) of
        Table -> {ok, Table}
    catch
        error:badarg -> {error, nil}
    end.
