-module(currency_store_ffi).
-export([create_table/0, match_by_symbol/2]).

create_table() ->
    ets_table_ffi:create(currencies_store, [
        set, public, {read_concurrency, true}, {write_concurrency, auto}
    ]).

match_by_symbol(Table, Symbol) ->
    ets:match_object(Table, {'_', Symbol, '_'}).
