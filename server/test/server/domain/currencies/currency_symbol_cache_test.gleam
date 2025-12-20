import gleam/option.{None}
import server/domain/currencies/currency_symbol_cache
import shared/currency.{Crypto}

// get_by_symbol

pub fn get_by_symbol_returns_cached_currencies_test() {
  let cached_currencies = [Crypto(1, "Bitcoin", "BTC", None)]

  let get_cached = fn(symbol) {
    case symbol {
      "BTC" -> cached_currencies
      _ -> []
    }
  }

  let fetch_and_cache = fn(_) { panic }

  let assert Ok(resolver) =
    currency_symbol_cache.new(get_cached, fetch_and_cache)

  let result = currency_symbol_cache.get_by_symbol(resolver, "BTC")

  assert result == Ok(cached_currencies)
}

pub fn get_by_symbol_fetches_when_not_cached_test() {
  let get_cached = fn(_) { [] }

  let fetched_currencies = [Crypto(1, "Bitcoin", "BTC", None)]
  let fetch_and_cache = fn(_) { Ok(fetched_currencies) }

  let assert Ok(resolver) =
    currency_symbol_cache.new(get_cached, fetch_and_cache)

  let result = currency_symbol_cache.get_by_symbol(resolver, "BTC")

  assert result == Ok(fetched_currencies)
}

pub fn get_by_symbol_returns_error_when_fetch_fails_test() {
  let get_cached = fn(_) { [] }
  let fetch_and_cache = fn(_) { Error(Nil) }

  let assert Ok(resolver) =
    currency_symbol_cache.new(get_cached, fetch_and_cache)

  let result = currency_symbol_cache.get_by_symbol(resolver, "BTC")

  assert result == Error(Nil)
}

// get_by_symbols

pub fn get_by_symbols_returns_all_cached_currencies_test() {
  let btc = Crypto(1, "Bitcoin", "BTC", None)
  let eth = Crypto(2, "Ethereum", "ETH", None)

  let get_cached = fn(symbol) {
    case symbol {
      "BTC" -> [btc]
      "ETH" -> [eth]
      _ -> []
    }
  }

  let fetch_and_cache = fn(_) { panic }

  let assert Ok(resolver) =
    currency_symbol_cache.new(get_cached, fetch_and_cache)

  let result = currency_symbol_cache.get_by_symbols(resolver, ["BTC", "ETH"])

  assert result == Ok([btc, eth])
}

pub fn get_by_symbols_fetches_uncached_and_merges_with_cached_test() {
  let btc = Crypto(1, "Bitcoin", "BTC", None)
  let eth = Crypto(2, "Ethereum", "ETH", None)

  let get_cached = fn(symbol) {
    case symbol {
      "BTC" -> [btc]
      _ -> []
    }
  }

  let fetch_and_cache = fn(symbols) {
    case symbols {
      "ETH" -> Ok([eth])
      _ -> panic
    }
  }

  let assert Ok(resolver) =
    currency_symbol_cache.new(get_cached, fetch_and_cache)

  let result = currency_symbol_cache.get_by_symbols(resolver, ["BTC", "ETH"])

  assert result == Ok([btc, eth])
}

pub fn get_by_symbols_fetches_all_when_none_cached_test() {
  let btc = Crypto(1, "Bitcoin", "BTC", None)
  let eth = Crypto(2, "Ethereum", "ETH", None)

  let get_cached = fn(_) { [] }

  let fetch_and_cache = fn(symbols) {
    case symbols {
      "BTC,ETH" -> Ok([btc, eth])
      _ -> panic
    }
  }

  let assert Ok(resolver) =
    currency_symbol_cache.new(get_cached, fetch_and_cache)

  let result = currency_symbol_cache.get_by_symbols(resolver, ["BTC", "ETH"])

  assert result == Ok([btc, eth])
}

pub fn get_by_symbols_returns_error_when_fetch_fails_test() {
  let get_cached = fn(_) { [] }
  let fetch_and_cache = fn(_) { Error(Nil) }

  let assert Ok(resolver) =
    currency_symbol_cache.new(get_cached, fetch_and_cache)

  let result = currency_symbol_cache.get_by_symbols(resolver, ["BTC", "ETH"])

  assert result == Error(Nil)
}
