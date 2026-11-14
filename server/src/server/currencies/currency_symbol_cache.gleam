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
import gleam/otp/actor.{type Next, type StartError}
import gleam/result
import shared/currency.{type Currency}

pub opaque type CurrencySymbolCache {
  CurrencySymbolCache(subject: Subject(Msg))
}

type Msg {
  GetBySymbol(reply_to: Subject(Result(List(Currency), Nil)), symbol: String)
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
  cache: CurrencySymbolCache,
  symbol: String,
) -> Result(List(Currency), Nil) {
  let CurrencySymbolCache(subject) = cache
  actor.call(subject, 5000, GetBySymbol(_, symbol))
}

fn handle_msg(state: State, msg: Msg) -> Next(State, Msg) {
  let State(get_cached:, fetch_and_cache:) = state
  let GetBySymbol(reply_to, symbol) = msg

  let result = case get_cached(symbol) {
    [] -> fetch_and_cache(symbol)
    currencies -> Ok(currencies)
  }

  process.send(reply_to, result)
  actor.continue(state)
}
