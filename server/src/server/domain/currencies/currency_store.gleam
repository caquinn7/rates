import carpenter/table.{
  type Set as EtsSet, NoWriteConcurrency, Protected, Set as EtsSet, Table,
}
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/pair
import gleam/result
import shared/currency.{type Currency}

pub opaque type CurrencyStore {
  CurrencyStore(EtsSet(Int, Currency))
}

const table_name = "currencies_store"

/// Creates a new `CurrenciesStore` by initializing a protected ETS table.
///
/// The table is:
/// - **Protected**: readable by all processes but writable only by the owner.
/// - **Read-concurrent**: allows multiple processes to read simultaneously.
/// - **Write-serialized**: disallows concurrent writes to ensure consistency.
///
/// This function is intended to be called once by the owner process during application startup.
/// Other processes should use `get_store` to access the table.
pub fn new() -> Result(CurrencyStore, Nil) {
  table_name
  |> table.build
  |> table.privacy(Protected)
  |> table.write_concurrency(NoWriteConcurrency)
  |> table.read_concurrency(True)
  |> table.set
  |> result.map(CurrencyStore)
}

pub fn insert(store: CurrencyStore, currencies: List(Currency)) -> Nil {
  let CurrencyStore(set) = store

  currencies
  |> list.map(fn(currency) { #(currency.id, currency) })
  |> table.insert(set, _)
}

pub fn get_all(store: CurrencyStore) -> List(Currency) {
  let CurrencyStore(set) = store

  set
  |> fn(set) {
    let EtsSet(table) = set
    let Table(name) = table
    name
  }
  |> table_to_list
  |> list.map(pair.second)
}

pub fn get_by_id(store: CurrencyStore, id: Int) -> Result(Currency, Nil) {
  let CurrencyStore(set) = store

  case table.lookup(set, id) {
    [] -> Error(Nil)
    [elem, ..] -> Ok(elem.1)
  }
}

pub fn get_by_symbol(store: CurrencyStore, symbol: String) -> List(Currency) {
  store
  |> get_all
  |> list.filter(fn(currency) { currency.symbol == symbol })
}

/// Deletes the underlying ETS table associated with the given `CurrenciesStore`.
pub fn drop(store: CurrencyStore) -> Nil {
  let CurrencyStore(set) = store
  table.drop(set)
}

@external(erlang, "ets", "tab2list")
fn table_to_list(table_name: Atom) -> List(#(k, v))
