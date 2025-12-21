//// This module wraps currency symbol lookups in an actor to prevent duplicate
//// API calls to CoinMarketCap under concurrent requests.
////
//// ## The Problem
//// Without the actor, multiple concurrent requests for the same uncached symbol
//// could all observe a cache miss simultaneously and each trigger a separate API
//// call to CoinMarketCap, wasting resources and potentially hitting rate limits.
////
//// ## The Solution
//// By serializing check-and-fetch operations through an actor, only ONE API call
//// is made per symbol, even when many requests arrive concurrently. The actor
//// coordinates which symbols need fetching vs. which are already cached.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor.{type Next, type StartError}
import gleam/result
import gleam/string
import shared/currency.{type Currency}

pub opaque type CurrencySymbolCache {
  CurrencySymbolCache(subject: Subject(Msg))
}

type Msg {
  GetBySymbol(reply_to: Subject(Result(List(Currency), Nil)), symbol: String)
  GetBySymbols(
    reply_to: Subject(Result(List(Currency), Nil)),
    symbols: List(String),
  )
}

type State {
  State(
    get_cached: fn(String) -> List(Currency),
    fetch_and_cache: fn(String) -> Result(List(Currency), Nil),
  )
}

pub fn new(
  get_cached: fn(String) -> List(Currency),
  fetch_and_cache: fn(String) -> Result(List(Currency), Nil),
) -> Result(CurrencySymbolCache, StartError) {
  State(get_cached:, fetch_and_cache:)
  |> actor.new
  |> actor.on_message(handle_msg)
  |> actor.start
  |> result.map(fn(started) { CurrencySymbolCache(started.data) })
}

pub fn get_by_symbol(
  resolver: CurrencySymbolCache,
  symbol: String,
) -> Result(List(Currency), Nil) {
  let CurrencySymbolCache(subject) = resolver
  actor.call(subject, 5000, GetBySymbol(_, string.trim(symbol)))
}

pub fn get_by_symbols(
  resolver: CurrencySymbolCache,
  symbols: List(String),
) -> Result(List(Currency), Nil) {
  let CurrencySymbolCache(subject) = resolver
  actor.call(subject, 5000, GetBySymbols(_, symbols))
}

fn handle_msg(state: State, msg: Msg) -> Next(State, Msg) {
  let State(get_cached:, fetch_and_cache:) = state

  case msg {
    GetBySymbol(reply_to, "") | GetBySymbols(reply_to, []) -> {
      process.send(reply_to, Ok([]))
      actor.continue(state)
    }

    GetBySymbol(reply_to, symbol) -> {
      let result = case get_cached(symbol) {
        [] -> fetch_and_cache(symbol)
        currencies -> Ok(currencies)
      }

      process.send(reply_to, result)
      actor.continue(state)
    }

    GetBySymbols(reply_to, symbols) -> {
      let cached_currencies = list.flat_map(symbols, get_cached)
      let cached_symbols = list.map(cached_currencies, fn(c) { c.symbol })
      let uncached_symbols =
        list.filter(symbols, fn(symbol) {
          !list.contains(cached_symbols, symbol)
        })

      let result = case uncached_symbols {
        [] -> Ok(cached_currencies)

        symbols -> {
          let symbols_str = string.join(symbols, ",")
          use fetched <- result.map(fetch_and_cache(symbols_str))
          list.append(cached_currencies, fetched)
        }
      }

      process.send(reply_to, result)
      actor.continue(state)
    }
  }
}
