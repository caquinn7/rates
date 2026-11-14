import exception
import gleam/erlang/process.{type Pid, type Subject}
import gleam/option.{None}
import server/currencies/currency_symbol_cache.{type CurrencySymbolCache}
import server/currencies/internal/currency_store.{type CurrencyStore}
import shared/currency.{type Currency, Crypto}

pub fn get_by_symbol_returns_cached_currencies_test() {
  let cached_currencies = [Crypto(1, "Bitcoin", "BTC", None)]

  let get_cached = fn(symbol) {
    case symbol {
      "BTC" -> cached_currencies
      _ -> []
    }
  }
  let fetch_and_cache = fn(_) { panic }

  let assert Ok(cache) = currency_symbol_cache.new(get_cached, fetch_and_cache)

  assert currency_symbol_cache.get_by_symbol(cache, "BTC")
    == Ok(cached_currencies)
}

pub fn get_by_symbol_fetches_when_not_cached_test() {
  let get_cached = fn(_) { [] }

  let fetched_currencies = [Crypto(1, "Bitcoin", "BTC", None)]
  let fetch_and_cache = fn(_) { Ok(fetched_currencies) }

  let assert Ok(cache) = currency_symbol_cache.new(get_cached, fetch_and_cache)

  assert currency_symbol_cache.get_by_symbol(cache, "BTC")
    == Ok(fetched_currencies)
}

pub fn get_by_symbol_returns_error_when_fetch_fails_test() {
  let get_cached = fn(_) { [] }
  let fetch_and_cache = fn(_) { Error(Nil) }

  let assert Ok(cache) = currency_symbol_cache.new(get_cached, fetch_and_cache)

  assert currency_symbol_cache.get_by_symbol(cache, "BTC") == Error(Nil)
}

pub fn cached_lookup_returns_while_another_symbol_is_fetching_test() {
  use store <- with_currency_store
  let btc = Crypto(1, "Bitcoin", "BTC", None)
  let eth = Crypto(1027, "Ethereum", "ETH", None)
  currency_store.insert(store, [btc])

  let fetches = process.new_subject()
  let assert Ok(cache) =
    currency_symbol_cache.new(
      currency_store.get_by_symbol(store, _),
      gated_fetch(store, eth, fetches, _),
    )

  let #(_, slow_replies) = start_lookup(cache, "ETH")
  let assert Ok(#("ETH", release)) = process.receive(fetches, 1000)
  use <- exception.defer(fn() { process.send(release, Nil) })

  let #(_, cached_replies) = start_lookup(cache, "BTC")
  assert process.receive(cached_replies, 1000) == Ok(Ok([btc]))
  assert process.receive(slow_replies, 0) == Error(Nil)

  process.send(release, Nil)
  assert process.receive(slow_replies, 1000) == Ok(Ok([eth]))
  assert process.receive(fetches, 0) == Error(Nil)
}

pub fn concurrent_misses_for_one_symbol_fetch_only_once_test() {
  use store <- with_currency_store
  let btc = Crypto(1, "Bitcoin", "BTC", None)
  let misses = process.new_subject()
  let fetches = process.new_subject()
  let assert Ok(cache) =
    currency_symbol_cache.new(tracked_lookup(store, misses, _), gated_fetch(
      store,
      btc,
      fetches,
      _,
    ))

  let #(_, first_replies) = start_lookup(cache, "BTC")
  let assert Ok(#("BTC", release)) = process.receive(fetches, 1000)
  use <- exception.defer(fn() { process.send(release, Nil) })

  let #(second_pid, second_replies) = start_lookup(cache, "BTC")
  await_miss(misses, second_pid)

  process.send(release, Nil)
  assert process.receive(first_replies, 1000) == Ok(Ok([btc]))
  assert process.receive(second_replies, 1000) == Ok(Ok([btc]))
  assert process.receive(fetches, 0) == Error(Nil)
  assert currency_store.get_by_symbol(store, "BTC") == [btc]
}

pub fn miss_rechecks_cache_after_waiting_for_another_fetch_test() {
  use store <- with_currency_store
  let btc = Crypto(1, "Bitcoin", "BTC", None)
  let eth = Crypto(1027, "Ethereum", "ETH", None)
  let misses = process.new_subject()
  let fetches = process.new_subject()
  let assert Ok(cache) =
    currency_symbol_cache.new(tracked_lookup(store, misses, _), gated_fetch(
      store,
      eth,
      fetches,
      _,
    ))

  let #(_, slow_replies) = start_lookup(cache, "ETH")
  let assert Ok(#("ETH", release)) = process.receive(fetches, 1000)
  use <- exception.defer(fn() { process.send(release, Nil) })

  let #(queued_pid, queued_replies) = start_lookup(cache, "BTC")
  await_miss(misses, queued_pid)
  currency_store.insert(store, [btc])

  process.send(release, Nil)
  assert process.receive(slow_replies, 1000) == Ok(Ok([eth]))
  assert process.receive(queued_replies, 1000) == Ok(Ok([btc]))
  assert process.receive(fetches, 0) == Error(Nil)
}

fn with_currency_store(run: fn(CurrencyStore) -> a) -> a {
  let assert Ok(store) = currency_store.new()
  use <- exception.defer(fn() { currency_store.drop(store) })
  run(store)
}

fn start_lookup(
  cache: CurrencySymbolCache,
  symbol: String,
) -> #(Pid, Subject(Result(List(Currency), Nil))) {
  let replies = process.new_subject()
  let pid =
    process.spawn(fn() {
      process.send(replies, currency_symbol_cache.get_by_symbol(cache, symbol))
    })
  #(pid, replies)
}

fn tracked_lookup(
  store: CurrencyStore,
  misses: Subject(Pid),
  symbol: String,
) -> List(Currency) {
  let currencies = currency_store.get_by_symbol(store, symbol)
  case currencies {
    [] -> process.send(misses, process.self())
    _ -> Nil
  }
  currencies
}

fn await_miss(misses: Subject(a), caller: a) -> Nil {
  let assert Ok(pid) = process.receive(misses, 1000)
  case pid == caller {
    True -> Nil
    False -> await_miss(misses, caller)
  }
}

fn gated_fetch(
  store: CurrencyStore,
  currency: Currency,
  fetches: Subject(#(String, Subject(Nil))),
  symbol: String,
) -> Result(List(Currency), a) {
  assert symbol == currency.symbol
  let release = process.new_subject()
  process.send(fetches, #(symbol, release))
  let assert Ok(Nil) = process.receive(release, 1000)
  currency_store.insert(store, [currency])
  Ok([currency])
}
