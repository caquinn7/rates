//// Currency symbol lookups with direct cache reads and serialized cache misses.
////
//// Cache hits are returned in the calling process, so they do not wait behind
//// slow CoinMarketCap requests. Misses go through an actor that checks the cache
//// again before fetching. Once a successful fetch populates the cache, queued
//// lookups reuse its results instead of making duplicate API calls.
////
//// Fetches for different symbols remain serialized. Empty results and failures
//// are not cached, so subsequent requests may fetch those symbols again.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor.{type Next, type StartError}
import gleam/result
import shared/currency.{type Currency}

pub opaque type CurrencySymbolCache {
  CurrencySymbolCache(
    subject: Subject(Msg),
    get_cached: fn(String) -> List(Currency),
  )
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

/// Creates a cache with a direct lookup callback and a serialized fetch callback.
///
/// `get_cached` must support concurrent calls from different processes.
/// `fetch_and_cache` must store successful results before returning them so that
/// queued requests can find them when the actor checks the cache again.
pub fn new(
  get_cached: fn(String) -> List(Currency),
  fetch_and_cache: fn(String) -> Result(List(Currency), Nil),
) -> Result(CurrencySymbolCache, StartError) {
  State(get_cached:, fetch_and_cache:)
  |> actor.new
  |> actor.on_message(handle_msg)
  |> actor.start
  |> result.map(fn(started) { CurrencySymbolCache(started.data, get_cached) })
}

pub fn get_by_symbol(
  cache: CurrencySymbolCache,
  symbol: String,
) -> Result(List(Currency), Nil) {
  let CurrencySymbolCache(subject, get_cached) = cache
  case get_cached(symbol) {
    [] -> actor.call(subject, 5000, GetBySymbol(_, symbol))
    currencies -> Ok(currencies)
  }
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
