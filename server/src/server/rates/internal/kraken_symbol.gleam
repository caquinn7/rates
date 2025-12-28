import shared/positive_float.{type PositiveFloat}

/// Represents a Kraken currency pair and whether it was found in the direct or reversed form.
/// For example, `Direct("BTC/USD")` vs `Reversed("USD/BTC")`.
pub opaque type KrakenSymbol {
  Direct(String)
  Reversed(String)
}

/// Attempts to resolve a Kraken-compatible pair symbol from the given currency symbols.
/// Returns a `KrakenSymbol` indicating whether the direct or reversed form was matched.
/// Returns an error if neither form exists in the Kraken pair list.
pub fn new(
  currency_symbols: #(String, String),
  pair_exists: fn(String) -> Bool,
) -> Result(KrakenSymbol, Nil) {
  let #(from_symbol, to_symbol) = currency_symbols
  let direct_pair_symbol = from_symbol <> "/" <> to_symbol

  case pair_exists(direct_pair_symbol) {
    True -> Ok(Direct(direct_pair_symbol))

    False -> {
      let reverse_pair_symbol = to_symbol <> "/" <> from_symbol
      case pair_exists(reverse_pair_symbol) {
        True -> Ok(Reversed(reverse_pair_symbol))
        False -> Error(Nil)
      }
    }
  }
}

/// Retrieves the raw Kraken symbol string (e.g. "BTC/USD") from a `KrakenSymbol`.
pub fn to_string(symbol: KrakenSymbol) -> String {
  case symbol {
    Direct(s) -> s
    Reversed(s) -> s
  }
}

/// Applies the symbol direction to a price. Returns the price as-is for DirectSymbol,
/// or the inverse for ReversedSymbol
pub fn apply_price_direction(
  symbol: KrakenSymbol,
  price: PositiveFloat,
) -> PositiveFloat {
  case symbol {
    Direct(..) -> price
    Reversed(..) ->
      price
      |> positive_float.with_value(fn(p) { 1.0 /. p })
      |> positive_float.from_float_unsafe
  }
}
