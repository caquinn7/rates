//// Currency symbol lookups with direct cache reads and serialized cache misses.
////
//// Cache hits are returned in the calling process, so they do not wait behind
//// slow CoinMarketCap requests. Misses go through an actor that checks the cache
//// again before fetching. Once a successful fetch populates the cache, queued
//// lookups reuse its results instead of making duplicate API calls.
////
//// Fetches for different symbols remain serialized. Empty results and failures
//// are not cached, so subsequent requests may fetch those symbols again.
//// Expired queued requests are skipped. Started fetches may finish and populate
//// the cache after their callers time out; their late replies are discarded.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor.{type Next, type StartError}
import gleam/result
import server/currencies/internal/cache_request.{type Reply}
import server/utils/time
import shared/currency.{type Currency}

const default_timeout_ms = 5000

pub opaque type CurrencySymbolCache {
  CurrencySymbolCache(
    subject: Subject(Msg),
    get_cached: fn(String) -> List(Currency),
  )
}

type Msg {
  GetBySymbol(
    reply_to: Reply(Result(List(Currency), Nil)),
    symbol: String,
    deadline_ms: Int,
  )
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

/// Returns cached currencies directly, or fetches them through the actor.
///
/// Misses wait up to five seconds, including queue time. Timeout, actor
/// termination, and fetch failures return `Error(Nil)`.
pub fn get_by_symbol(
  cache: CurrencySymbolCache,
  symbol: String,
) -> Result(List(Currency), Nil) {
  get_by_symbol_with_timeout(cache, symbol, default_timeout_ms)
}

/// Overrides the miss timeout for controlled tests. Cache hits do not wait.
/// Nonpositive budgets return `Error(Nil)` on misses without sending a request.
@internal
pub fn get_by_symbol_with_timeout(
  cache: CurrencySymbolCache,
  symbol: String,
  timeout_ms: Int,
) -> Result(List(Currency), Nil) {
  let CurrencySymbolCache(subject:, get_cached:) = cache

  case get_cached(symbol) {
    [] ->
      case timeout_ms <= 0 {
        True -> Error(Nil)
        False -> {
          let deadline_ms = time.monotonic_time_ms() + timeout_ms
          use pid <- result.try(process.subject_owner(subject))

          pid
          |> cache_request.call(deadline_ms, fn(reply_to) {
            process.send(subject, GetBySymbol(reply_to, symbol, deadline_ms))
          })
          |> result.flatten
        }
      }
    currencies -> Ok(currencies)
  }
}

fn handle_msg(state: State, msg: Msg) -> Next(State, Msg) {
  let State(get_cached:, fetch_and_cache:) = state
  let GetBySymbol(reply_to:, symbol:, deadline_ms:) = msg

  let result = case time.monotonic_time_ms() >= deadline_ms {
    True -> Error(Nil)
    False ->
      case get_cached(symbol) {
        [] ->
          case time.monotonic_time_ms() >= deadline_ms {
            True -> Error(Nil)
            False -> fetch_and_cache(symbol)
          }
        currencies -> Ok(currencies)
      }
  }

  cache_request.reply(reply_to, result)
  actor.continue(state)
}
