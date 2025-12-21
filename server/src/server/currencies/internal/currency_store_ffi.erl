-module(currency_store_ffi).
-export([match_by_symbol/2]).

match_by_symbol(TableName, Symbol) ->
    %% Gleam custom types are represented as tuples: {Constructor, Field1, Field2, ...}
    %% Crypto: {crypto, Id, Name, Symbol, Rank}
    %% Fiat: {fiat, Id, Name, Symbol, Sign}
    %% Both have Symbol as the 4th element (index 3 in 0-based)
    ets:match_object(TableName, {'_', {'_', '_', '_', Symbol, '_'}}).