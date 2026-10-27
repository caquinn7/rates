-module(currency_store_ffi).
-export([match_by_symbol/2]).

match_by_symbol(TableName, Symbol) ->
    %% Gleam custom types are represented as tuples: {Constructor, Field1, Field2, ...}
    %% Crypto: {crypto, Id, Name, Symbol, Rank}
    %% Fiat: {fiat, Id, Name, Symbol, Sign}
    %% Both Currency variants must remain five-element tuples with Symbol at position 4.
    %% Keep this pattern in sync with shared/currency.gleam.
    ets:match_object(TableName, {'_', {'_', '_', '_', Symbol, '_'}}).
