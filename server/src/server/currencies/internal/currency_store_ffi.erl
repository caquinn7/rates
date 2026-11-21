-module(currency_store_ffi).
-export([create_table/0, match_by_symbol/2]).

create_table() ->
    try ets:new(currencies_store, [
        set, public, {read_concurrency, true}, {write_concurrency, auto}
    ]) of
        Table -> {ok, Table}
    catch
        error:badarg -> {error, nil}
    end.

match_by_symbol(Table, Symbol) ->
    ets:match_object(Table, {'_', Symbol, '_'}).
