import server/currencies/internal/currency_store.{type CurrencyStore}
import shared/currency.{type Currency}

/// Currency storage operations exposed as functions.
///
/// Callers depend on this interface rather than the underlying storage, allowing
/// alternative implementations and test stubs to supply the same operations.
pub type CurrencyRepository {
  CurrencyRepository(
    /// Inserts currencies, replacing existing entries with the same ID.
    insert: fn(List(Currency)) -> Nil,
    /// Returns the currency with this ID, or `Error(Nil)` when it is absent.
    get_by_id: fn(Int) -> Result(Currency, Nil),
    /// Returns all exact, case-sensitive symbol matches, or `[]` when none match.
    get_by_symbol: fn(String) -> List(Currency),
    /// Returns all stored currencies, with no guaranteed order.
    get_all: fn() -> List(Currency),
  )
}

/// Binds the repository operations to an existing `CurrencyStore`.
///
/// All callbacks access the same store, so inserts are visible to subsequent
/// lookups. The store's owning process must remain alive while the repository is used.
pub fn new(store: CurrencyStore) -> CurrencyRepository {
  let insert = currency_store.insert(store, _)
  let get_by_id = currency_store.get_by_id(store, _)
  let get_by_symbol = currency_store.get_by_symbol(store, _)
  let get_all = fn() { currency_store.get_all(store) }

  CurrencyRepository(insert:, get_by_id:, get_by_symbol:, get_all:)
}
