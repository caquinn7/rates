-module(price_store_ffi).
-export([table_exists/1]).

table_exists(TableName) ->
    ets:whereis(TableName) =/= undefined.
