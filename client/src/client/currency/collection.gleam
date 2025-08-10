import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/order.{type Order}
import gleam/pair
import gleam/string
import shared/currency.{type Currency, Crypto, Fiat}

pub opaque type CurrencyCollection {
  CurrencyCollection(List(#(CurrencyType, List(Currency))))
}

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

/// Builds a `CurrencyCollection` from a flat list of currencies.
///
/// The currencies are:
/// - Sorted by type (`Crypto(..)` before `Fiat(..)`)
/// - Sorted within each type using `compare_currencies`
///
/// Returns a grouped and sorted `CurrencyCollection`.
pub fn from_list(currencies: List(Currency)) -> CurrencyCollection {
  let #(cryptos, fiats) =
    currencies
    |> list.sort(compare_currencies)
    |> list.split_while(fn(currency) {
      case currency {
        Crypto(..) -> True
        Fiat(..) -> False
      }
    })

  CurrencyCollection([#(CryptoCurrency, cryptos), #(FiatCurrency, fiats)])
}

pub fn to_list(
  collection: CurrencyCollection,
) -> List(#(CurrencyType, List(Currency))) {
  let CurrencyCollection(currencies) = collection
  currencies
}

/// Finds the flat index of a currency by id within a `CurrencyCollection`.
///
/// Returns:
/// - `Ok(index)` if the currency is found
/// - `Error(Nil)` if it is not present
///
/// The index is relative to the flattened view of the collection.
pub fn index_of(
  collection: CurrencyCollection,
  currency_id: Int,
) -> Result(Int, Nil) {
  collection
  |> flatten
  |> list.index_map(fn(currency, idx) { #(currency.id, idx) })
  |> dict.from_list
  |> dict.get(currency_id)
}

/// Returns the currency at the given flat index within a `CurrencyCollection`.
///
/// Returns:
/// - `Ok(currency)` if the index is within bounds
/// - `Error(Nil)` if the index is out of range
pub fn at_index(
  collection: CurrencyCollection,
  index: Int,
) -> Result(Currency, Nil) {
  collection
  |> flatten
  |> list.drop(index)
  |> list.first
}

/// Flattens a `CurrencyCollection` into a single list of currencies, preserving order.
pub fn flatten(collection: CurrencyCollection) -> List(Currency) {
  let CurrencyCollection(currencies) = collection
  list.flat_map(currencies, pair.second)
}

/// Returns the total number of currencies in a `CurrencyCollection`.
pub fn length(collection: CurrencyCollection) -> Int {
  let CurrencyCollection(currencies) = collection

  currencies
  |> list.map(fn(group) { list.length(group.1) })
  |> int.sum
}

/// Maps over each currency in the `CurrencyCollection`, passing its flat index to
/// `map_currency`, and applies `map_type` to each group tag. Returns a grouped result
/// with the original structure preserved.
///
/// - `map_type` transforms the group tag (e.g., `CryptoCurrency` → `"Crypto"`)
/// - `map_currency` transforms each currency, given its flat index across the entire collection
pub fn index_map(
  collection: CurrencyCollection,
  map_type: fn(CurrencyType) -> a,
  map_currency: fn(Currency, Int) -> b,
) -> List(#(a, List(b))) {
  let CurrencyCollection(groups) = collection

  groups
  |> list.fold(#([], 0), fn(acc, item) {
    let #(grouped_results, flat_index) = acc
    let #(currency_type, currencies) = item

    let mapped_type = map_type(currency_type)

    let mapped_currencies =
      list.index_map(currencies, fn(currency, local_index) {
        map_currency(currency, flat_index + local_index)
      })

    let next_results =
      list.append(grouped_results, [#(mapped_type, mapped_currencies)])

    let next_flat_index = flat_index + list.length(currencies)

    #(next_results, next_flat_index)
  })
  |> pair.first
}

/// Compares two currencies for sorting purposes.
///
/// Sorting rules:
/// - All cryptos come before all fiats
/// - Cryptos are sorted by rank (ascending), then by name
/// - Fiats are sorted with `"USD"` first, then by name
pub fn compare_currencies(c1: Currency, c2: Currency) -> Order {
  case c1, c2 {
    Crypto(..), Fiat(..) -> order.Lt
    Fiat(..), Crypto(..) -> order.Gt
    Crypto(..), Crypto(..) ->
      case c1.rank, c2.rank {
        Some(_), None -> order.Lt
        None, Some(_) -> order.Gt
        Some(r1), Some(r2) if r1 != r2 -> int.compare(r1, r2)
        _, _ -> string.compare(c1.name, c2.name)
      }
    Fiat(..), Fiat(..) ->
      case c1.symbol, c2.symbol {
        "USD", "USD" -> order.Eq
        "USD", _ -> order.Lt
        _, "USD" -> order.Gt
        _, _ -> string.compare(c1.name, c2.name)
      }
  }
}
