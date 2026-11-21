import gleam/result
import server/rates/internal/kraken_asset
import shared/numbers/positive_float.{type PositiveFloat}

/// Represents a Kraken currency pair and whether it was found in the direct or reversed form.
/// For example, `Direct("BTC/USD")` vs `Reversed("USD/BTC")`.
pub opaque type KrakenSymbol {
  Direct(String)
  Reversed(String)
}

/// Resolves the CoinMarketCap IDs to a supported Kraken pair, preferring the
/// requested direction. Returns an error if an asset or pair is unavailable.
pub fn new(
  currency_ids: #(Int, Int),
  pair_exists: fn(String) -> Bool,
) -> Result(KrakenSymbol, Nil) {
  let #(from_id, to_id) = currency_ids
  use from_symbol <- result.try(kraken_asset.from_cmc_id(from_id))
  use to_symbol <- result.try(kraken_asset.from_cmc_id(to_id))
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

/// Returns the direct price or its reciprocal for a reversed pair.
/// Returns `Error(Nil)` if the reciprocal is outside the representable range.
pub fn apply_price_direction(
  symbol: KrakenSymbol,
  price: PositiveFloat,
) -> Result(PositiveFloat, Nil) {
  case symbol {
    Direct(..) -> Ok(price)
    Reversed(..) ->
      positive_float.from_float_unsafe(1.0)
      |> positive_float.divide(by: price)
  }
}
