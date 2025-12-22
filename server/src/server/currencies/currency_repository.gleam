import server/currencies/internal/currency_store.{type CurrencyStore}
import shared/currency.{type Currency}

pub type CurrencyRepository {
  CurrencyRepository(
    insert: fn(List(Currency)) -> Nil,
    get_by_id: fn(Int) -> Result(Currency, Nil),
    get_by_symbol: fn(String) -> List(Currency),
    get_all: fn() -> List(Currency),
  )
}

/// Creates a CurrencyRepository from a currency store
/// 
/// This factory function encapsulates access to the currency store,
/// providing a clean interface for currency lookups without exposing
/// the underlying ETS table implementation.
/// 
/// ## Parameters
/// - `store`: The CurrencyStore to wrap
/// 
/// ## Returns
/// A fully configured CurrencyInterface
pub fn new(store: CurrencyStore) -> CurrencyRepository {
  let insert = currency_store.insert(store, _)
  let get_by_id = currency_store.get_by_id(store, _)
  let get_by_symbol = currency_store.get_by_symbol(store, _)
  let get_all = fn() { currency_store.get_all(store) }

  CurrencyRepository(insert:, get_by_id:, get_by_symbol:, get_all:)
}
