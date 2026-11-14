import gleam/option.{None}
import server/currencies/currency_symbol_cache
import shared/currency.{Crypto}

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
