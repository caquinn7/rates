import gleam/set
import server/integrations/kraken/pairs
import server/rates/actors/internal/kraken_symbol.{DirectSymbol, ReversedSymbol}

pub fn new_with_validator_returns_direct_when_only_direct_symbol_exists_test() {
  let mock_exists = fn(symbol) {
    case symbol {
      "BTC/USD" -> True
      _ -> False
    }
  }

  let result = kraken_symbol.new_with_validator(#("BTC", "USD"), mock_exists)

  let assert Ok(symbol) = result
  assert "BTC/USD" == kraken_symbol.to_string(symbol)
  assert DirectSymbol == kraken_symbol.direction(symbol)
}

pub fn new_with_validator_returns_direct_when_both_symbols_exist_test() {
  let mock_exists = fn(symbol) {
    case symbol {
      "BTC/USD" | "USD/BTC" -> True
      _ -> False
    }
  }

  let result = kraken_symbol.new_with_validator(#("BTC", "USD"), mock_exists)

  let assert Ok(symbol) = result
  assert "BTC/USD" == kraken_symbol.to_string(symbol)
  assert DirectSymbol == kraken_symbol.direction(symbol)
}

pub fn new_with_validator_returns_reversed_when_only_reversed_symbol_exists_test() {
  let mock_exists = fn(symbol) {
    case symbol {
      "USD/BTC" -> True
      _ -> False
    }
  }

  let result = kraken_symbol.new_with_validator(#("BTC", "USD"), mock_exists)

  let assert Ok(symbol) = result
  assert "USD/BTC" == kraken_symbol.to_string(symbol)
  assert ReversedSymbol == kraken_symbol.direction(symbol)
}

pub fn new_with_validator_returns_error_when_neither_symbol_exists_test() {
  assert Error(Nil)
    == kraken_symbol.new_with_validator(#("BTC", "USD"), fn(_) { False })
}

pub fn new_integrates_with_pairs_exists_test() {
  pairs.clear()
  pairs.set(set.from_list(["BTC/USD", "ETH/EUR"]))

  let result = kraken_symbol.new(#("BTC", "USD"))

  let assert Ok(kraken_symbol) = result
  assert "BTC/USD" == kraken_symbol.to_string(kraken_symbol)
  assert DirectSymbol == kraken_symbol.direction(kraken_symbol)
}
