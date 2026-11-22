-module(price_store_ffi).
-export([create_table/0]).

create_table() ->
    ets_table_ffi:create(kraken_price_store, [
        set, protected, {read_concurrency, true}, {write_concurrency, auto}
    ]).
