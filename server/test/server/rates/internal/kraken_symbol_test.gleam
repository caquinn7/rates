import gleam/set
import server/integrations/kraken/pair_store
import server/rates/internal/kraken_symbol

pub fn new_returns_direct_when_only_direct_symbol_exists_test() {
  let mock_exists = fn(symbol) {
    case symbol {
      "BTC/USD" -> True
      _ -> False
    }
  }

  let result = kraken_symbol.new(#(1, 2781), mock_exists)

  let assert Ok(symbol) = result
  assert "BTC/USD" == kraken_symbol.to_string(symbol)
}

pub fn new_returns_direct_when_both_symbols_exist_test() {
  let mock_exists = fn(symbol) {
    case symbol {
      "BTC/USD" | "USD/BTC" -> True
      _ -> False
    }
  }

  let result = kraken_symbol.new(#(1, 2781), mock_exists)

  let assert Ok(symbol) = result
  assert "BTC/USD" == kraken_symbol.to_string(symbol)
}

pub fn new_returns_reversed_when_only_reversed_symbol_exists_test() {
  let mock_exists = fn(symbol) {
    case symbol {
      "BTC/USD" -> True
      _ -> False
    }
  }

  let result = kraken_symbol.new(#(2781, 1), mock_exists)

  let assert Ok(symbol) = result
  assert "BTC/USD" == kraken_symbol.to_string(symbol)
}

pub fn new_uses_verified_kraken_code_when_provider_tickers_differ_test() {
  let mock_exists = fn(symbol) {
    case symbol {
      "LIT/USD" | "LIGHTER/USD" -> True
      _ -> False
    }
  }

  let assert Ok(symbol) = kraken_symbol.new(#(39_125, 2781), mock_exists)

  assert "LIGHTER/USD" == kraken_symbol.to_string(symbol)
}

pub fn new_returns_error_when_neither_symbol_exists_test() {
  assert Error(Nil) == kraken_symbol.new(#(1, 2781), fn(_) { False })
}

pub fn new_integrates_with_pair_store_test() {
  let assert Ok(store) = pair_store.new()
  pair_store.apply_changes(
    store,
    added: set.from_list(["BTC/USD", "ETH/EUR"]),
    removed: set.new(),
  )

  let result = kraken_symbol.new(#(1, 2781), pair_store.exists(store, _))

  let assert Ok(kraken_symbol) = result
  assert "BTC/USD" == kraken_symbol.to_string(kraken_symbol)
}
