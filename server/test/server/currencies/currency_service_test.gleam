import gleam/list
import gleam/otp/actor
import server/currencies/currency_catalog_loader
import server/currencies/currency_repository.{type CurrencyRepository}
import server/currencies/currency_service
import server/currencies/internal/currency_store
import server/utils/logger
import shared/currency.{Fiat}

pub fn catalog_load_failure_releases_the_allocated_store_test() {
  use previous_table_count <- with_existing_store

  let reason =
    currency_catalog_loader.EmptyCatalog(currency_catalog_loader.FiatRequest)
  let load_catalog = fn() {
    assert list.length(owned_ets_tables()) == previous_table_count + 1
    Error(reason)
  }

  assert currency_service.start_with_dependencies(
      load_catalog,
      fn(_) { panic as "Cache startup requires a loaded catalog" },
      logger.new(),
    )
    == Error(currency_service.CatalogLoadFailed(reason))
}

pub fn cache_start_failure_releases_the_allocated_store_test() {
  use previous_table_count <- with_existing_store

  let currency = Fiat(2781, "US Dollar", "USD", "$")
  let reason = actor.InitFailed("Cache initialization failed")
  let start_cache = fn(repository: CurrencyRepository) {
    assert list.length(owned_ets_tables()) == previous_table_count + 1
    assert repository.get_by_id(currency.id) == Ok(currency)
    Error(reason)
  }

  assert currency_service.start_with_dependencies(
      fn() { Ok([currency]) },
      start_cache,
      logger.new(),
    )
    == Error(currency_service.CacheStartFailed(reason))
}

fn with_existing_store(run: fn(Int) -> Nil) -> Nil {
  let assert Ok(store) = currency_store.new()
  let currency = Fiat(2790, "Euro", "EUR", "€")
  currency_store.insert(store, [currency])
  let tables = owned_ets_tables()

  run(list.length(tables))

  assert owned_ets_tables() == tables
  assert currency_store.get_by_id(store, currency.id) == Ok(currency)
  currency_store.delete(store)
}

type TableId

@external(erlang, "process_test_ffi", "owned_ets_tables")
fn owned_ets_tables() -> List(TableId)
