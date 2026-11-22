import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import server/currencies/currency_catalog_loader
import server/currencies/currency_repository.{type CurrencyRepository}
import server/currencies/currency_symbol_cache.{type CurrencySymbolCache}
import server/currencies/currency_symbol_cache_factory
import server/currencies/internal/currency_store.{type CurrencyStore}
import server/integrations/coin_market_cap/client as cmc_client
import server/utils/logger.{type Logger}

const currency_fetch_timeout_ms = 10_000

// Leave one second for processing within the startup fetch deadline.
const cmc_catalog_timeout_ms = 9000

const cmc_symbol_lookup_timeout_ms = 3000

/// Failures encountered while starting the currency service.
pub type StartError {
  StoreCreationFailed(String)
  CatalogLoadFailed(currency_catalog_loader.LoadError)
  CacheStartFailed(actor.StartError)
}

/// Loads the startup catalog and starts a symbol cache backed by the returned
/// repository. The calling process owns the store and must stay alive while
/// the repository and cache are in use. Failed startup releases the store.
pub fn start(
  cmc_api_key: String,
  crypto_limit: Int,
  supported_fiat_symbols: List(String),
  logger: Logger,
) -> Result(#(CurrencyRepository, CurrencySymbolCache), StartError) {
  let logger = logger.with_source(logger, "currency_service")
  use store <- result.try(
    currency_store.new()
    |> result.map_error(StoreCreationFailed),
  )

  store
  |> initialize(cmc_api_key, crypto_limit, supported_fiat_symbols, logger)
  |> result.map_error(fn(error) {
    currency_store.delete(store)
    error
  })
}

fn initialize(
  store: CurrencyStore,
  cmc_api_key: String,
  crypto_limit: Int,
  supported_fiat_symbols: List(String),
  logger: Logger,
) -> Result(#(CurrencyRepository, CurrencySymbolCache), StartError) {
  let crypto_limit = Some(crypto_limit)

  let request_crypto_catalog = fn() {
    cmc_client.get_crypto_currencies(
      cmc_api_key,
      crypto_limit,
      None,
      cmc_catalog_timeout_ms,
    )
  }
  let request_fiat_catalog = fn() {
    cmc_client.get_fiat_currencies(
      cmc_api_key,
      Some(100),
      cmc_catalog_timeout_ms,
    )
  }

  use currencies <- result.try(
    currency_catalog_loader.get_currencies(
      supported_fiat_symbols,
      request_crypto_catalog,
      request_fiat_catalog,
      currency_fetch_timeout_ms,
    )
    |> result.map_error(CatalogLoadFailed),
  )

  let currency_repository = currency_repository.new(store)
  currency_repository.insert(currencies)

  log_currency_count(logger, list.length(currencies))

  let request_cryptos_by_symbol = cmc_client.get_crypto_currencies(
    cmc_api_key,
    crypto_limit,
    _,
    cmc_symbol_lookup_timeout_ms,
  )

  use currency_symbol_cache <- result.try(
    currency_symbol_cache_factory.create(
      currency_repository,
      request_cryptos_by_symbol,
      fn(err) {
        logger
        |> logger.with("error", string.inspect(err))
        |> logger.error("Error getting cryptos from CMC")
      },
    )
    |> result.map_error(CacheStartFailed),
  )

  Ok(#(currency_repository, currency_symbol_cache))
}

fn log_currency_count(logger: Logger, count: Int) -> Nil {
  logger
  |> logger.with("count", int.to_string(count))
  |> logger.info("fetched currencies from cmc")
}
