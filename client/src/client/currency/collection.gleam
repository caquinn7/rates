import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/order.{type Order}
import gleam/pair
import gleam/result
import gleam/string
import shared/currency.{type Currency, Crypto, Fiat}

pub type CurrencyType {
  CryptoCurrency
  FiatCurrency
}

pub fn currency_type_to_string(currency_type: CurrencyType) -> String {
  case currency_type {
    CryptoCurrency -> "Crypto"
    FiatCurrency -> "Fiat"
  }
}

/// Groups a list of `Currency` values by their type (`CryptoCurrency` or `FiatCurrency`),
/// sorts each group using the appropriate sorting function (`sort_cryptos` for crypto, `sort_fiats` for fiat),
/// and returns a sorted list of tuples containing the currency type and the sorted list of currencies.
/// The resulting list is ordered with `CryptoCurrency` first, followed by `FiatCurrency`.
pub fn group(
  currencies: List(Currency),
) -> List(#(CurrencyType, List(Currency))) {
  currencies
  |> list.group(fn(currency) {
    case currency {
      Crypto(..) -> CryptoCurrency
      Fiat(..) -> FiatCurrency
    }
  })
  |> dict.map_values(fn(currency_type, currencies) {
    currencies
    |> list.sort(fn(c1, c2) {
      let assert Ok(order) = case currency_type {
        CryptoCurrency -> sort_cryptos(c1, c2)
        FiatCurrency -> sort_fiats(c1, c2)
      }
      order
    })
  })
  |> dict.to_list
  |> list.sort(fn(a, b) {
    case a.0, b.0 {
      CryptoCurrency, _ -> order.Lt
      FiatCurrency, CryptoCurrency -> order.Gt
      _, _ -> order.Eq
    }
  })
}

/// Finds the flat index of a currency by its ID within a grouped currency list.
///
/// Given a list of currency groups (as returned by `group`), this function flattens all groups into a single list,
/// then searches for the currency with the specified `currency_id`.
/// Returns `Ok(index)` if found, where `index` is the position in the flattened list,
/// or `Error(Nil)` if the currency is not present.
///
/// This is useful for mapping a currency id to its position in a UI or for navigation purposes.
pub fn find_flat_index(
  in currencies: List(#(CurrencyType, List(Currency))),
  of currency_id: Int,
) -> Result(Int, Nil) {
  currencies
  |> flatten_groups
  |> list.index_map(fn(currency, idx) { #(currency.id, idx) })
  |> dict.from_list
  |> dict.get(currency_id)
}

/// Finds a currency by its flat index within a grouped currency list.
///
/// Given a list of currency groups (as returned by `group`), this function flattens all groups into a single list,
/// then returns the currency at the specified `index` in the flattened list.
/// Returns `Ok(currency)` if found, or `Error(Nil)` if the index is out of bounds.
///
/// This is useful for retrieving a currency by its position in a UI or for keyboard navigation.
pub fn find_by_flat_index(
  in currencies: List(#(CurrencyType, List(Currency))),
  at index: Int,
) -> Result(Currency, Nil) {
  currencies
  |> flatten_groups
  |> list.drop(index)
  |> list.first
}

fn flatten_groups(
  currencies: List(#(CurrencyType, List(Currency))),
) -> List(Currency) {
  currencies
  |> list.flat_map(pair.second)
}

/// Compares two crypto currencies for sorting.
///
/// - If only one currency has a rank, the ranked currency comes first.
/// - If both or neither have a rank, sorts by rank (ascending) or by name (alphabetically) if no rank is present.
/// Returns `Ok(Order)` for valid comparisons, or `Error(Nil)` if either input is not a crypto currency.
pub fn sort_cryptos(c1: Currency, c2: Currency) -> Result(Order, Nil) {
  let get_rank = fn(c) {
    case c {
      Crypto(_, _, _, rank) -> Ok(rank)
      _ -> Error(Nil)
    }
  }

  use c1_rank <- result.try(get_rank(c1))
  use c2_rank <- result.try(get_rank(c2))

  case c1_rank, c2_rank {
    Some(_), None -> order.Lt
    None, Some(_) -> order.Gt
    None, None -> string.compare(c1.name, c2.name)
    Some(r1), Some(r2) -> int.compare(r1, r2)
  }
  |> Ok
}

/// Compares two fiat currencies for sorting.
///
/// - "USD" is always sorted first among fiats.
/// - If neither is "USD", sorts alphabetically by name.
/// Returns `Ok(Order)` for valid comparisons, or `Error(Nil)` if either input is not a fiat currency.
pub fn sort_fiats(c1: Currency, c2: Currency) -> Result(Order, Nil) {
  let is_fiat = fn(c) {
    case c {
      Fiat(..) -> Ok(c)
      _ -> Error(Nil)
    }
  }

  use c1 <- result.try(is_fiat(c1))
  use c2 <- result.try(is_fiat(c2))

  case c1.symbol, c2.symbol {
    "USD", "USD" -> order.Eq
    "USD", _ -> order.Lt
    _, "USD" -> order.Gt
    _, _ -> string.compare(c1.name, c2.name)
  }
  |> Ok
}

/// Filters a list of currencies by a search string.
///
/// Returns all currencies whose name or symbol contains the given `filter_str` (case-insensitive).
pub fn filter(
  currency_list: List(Currency),
  filter_str: String,
) -> List(Currency) {
  let is_match = fn(str) {
    str
    |> string.lowercase
    |> string.contains(string.lowercase(filter_str))
  }

  currency_list
  |> list.filter(fn(currency) {
    is_match(currency.name) || is_match(currency.symbol)
  })
}
