-module(currency_store_ffi).
-export([create_table/0, match_by_symbol/2]).

create_table() ->
    try ets:new(currencies_store, [
        named_table, set, public, {read_concurrency, true}, {write_concurrency, auto}
    ]) of
        Name ->
            case ets:whereis(Name) of
                undefined -> {error, nil};
                Table -> {ok, Table}
            end
    catch
        error:badarg -> {error, nil}
    end.

match_by_symbol(Table, Symbol) ->
    ets:match_object(Table, {'_', Symbol, '_'}).
