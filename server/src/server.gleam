import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import glight
import mist
import server/currencies/cmc_currency_handler.{
  type RequestCmcCryptos, type RequestCmcFiats,
}
import server/currencies/currency_catalog_loader
import server/currencies/currency_repository.{type CurrencyRepository}
import server/currencies/currency_symbol_cache_factory.{
  type RequestCmcCryptosBySymbol,
}
import server/currencies/internal/currency_store.{type CurrencyStore}
import server/env_config
import server/integrations/coin_market_cap/client as cmc_client
import server/integrations/kraken/client.{type KrakenClient} as kraken_client
import server/integrations/kraken/pairs
import server/integrations/kraken/price_store
import server/rates/internal/cmc_rate_handler.{type RequestCmcConversion}
import server/rates/internal/kraken_interface
import server/rates/internal/subscription_manager
import server/rates/subscriber
import server/rates/subscriber_factory
import server/services.{type Services, Services}
import server/utils/logger.{type Logger}
import server/utils/time
import server/web/router

const currency_fetch_timeout_ms = 10_000

// Leave one second for processing within the startup fetch deadline.
const cmc_catalog_timeout_ms = 9000

const cmc_lookup_timeout_ms = 3000

const kraken_readiness_timeout_ms = 10_000

const subscription_refresh_interval_ms = 10_000

pub fn main() {
  let env_config = case env_config.load() {
    Ok(c) -> c
    Error(msg) -> panic as { "failed to load env_config: " <> msg }
  }

  let logger = configure_logging(env_config.log_level)

  let request_cmc_crypto_catalog = fn() {
    cmc_client.get_crypto_currencies(
      env_config.cmc_api_key,
      Some(env_config.crypto_limit),
      None,
      cmc_catalog_timeout_ms,
    )
  }

  let request_cmc_cryptos = cmc_client.get_crypto_currencies(
    env_config.cmc_api_key,
    Some(env_config.crypto_limit),
    _,
    cmc_lookup_timeout_ms,
  )

  let request_cmc_fiats = fn() {
    cmc_client.get_fiat_currencies(
      env_config.cmc_api_key,
      Some(100),
      cmc_catalog_timeout_ms,
    )
  }

  let request_cmc_conversion = cmc_client.get_conversion(
    env_config.cmc_api_key,
    _,
    cmc_lookup_timeout_ms,
  )

  let assert Ok(currency_store) = currency_store.new()

  fetch_and_store_currencies(
    env_config.supported_fiat_symbols,
    request_cmc_crypto_catalog,
    request_cmc_fiats,
    currency_store,
    logger,
  )

  let kraken_client = start_kraken(logger)

  let services =
    build_services(
      currency_store,
      logger,
      request_cmc_cryptos,
      kraken_client,
      request_cmc_conversion,
    )

  start_server(env_config.secret_key_base, services)
}

fn configure_logging(log_level: String) -> Logger {
  let log_level = case string.lowercase(log_level) {
    "error" -> glight.Error
    "warn" -> glight.Warning
    "info" -> glight.Info
    "debug" -> glight.Debug
    _ -> glight.Info
  }

  glight.set_log_level(log_level)
  glight.configure([glight.Console, glight.File("server.log")])
  glight.set_is_color(True)

  logger.new()
}

fn fetch_and_store_currencies(
  supported_fiat_symbols: List(String),
  request_cmc_cryptos: RequestCmcCryptos,
  request_cmc_fiats: RequestCmcFiats,
  currency_store: CurrencyStore,
  logger: Logger,
) {
  let currencies_result =
    currency_catalog_loader.get_currencies(
      supported_fiat_symbols,
      request_cmc_cryptos,
      request_cmc_fiats,
      currency_fetch_timeout_ms,
    )

  case currencies_result {
    Ok(currencies) -> {
      currency_store.insert(currency_store, currencies)

      logger
      |> logger.with_source("server")
      |> logger.with("count", int.to_string(list.length(currencies)))
      |> logger.info("fetched currencies from cmc")
    }
    Error(err) ->
      panic as { "error getting currencies: " <> string.inspect(err) }
  }
}

fn start_kraken(logger: Logger) -> KrakenClient {
  let logger = logger.with_source(logger, "kraken")
  let create_price_store = fn() {
    let assert Ok(store) = price_store.new()
    store
  }
  let assert Ok(client) = kraken_client.new(logger, create_price_store)

  wait_for_kraken_symbols(
    time.monotonic_time_ms() + kraken_readiness_timeout_ms,
  )

  client
}

fn wait_for_kraken_symbols(deadline_ms: Int) -> Nil {
  case pairs.count() > 0, time.monotonic_time_ms() >= deadline_ms {
    True, _ -> Nil
    False, True -> panic as "Timeout waiting for Kraken symbols"
    False, False -> {
      process.sleep(100)
      wait_for_kraken_symbols(deadline_ms)
    }
  }
}

fn build_services(
  currency_store: CurrencyStore,
  logger: Logger,
  request_cmc_cryptos: RequestCmcCryptosBySymbol,
  kraken_client: KrakenClient,
  request_cmc_conversion: RequestCmcConversion,
) -> Services {
  let currency_repository = currency_repository.new(currency_store)

  let currency_symbol_cache = {
    let on_fetch_failed = fn(err) {
      logger
      |> logger.with_source("server")
      |> logger.with("error", string.inspect(err))
      |> logger.error("Error getting cryptos from CMC")
    }

    currency_symbol_cache_factory.create(
      currency_repository,
      request_cmc_cryptos,
      on_fetch_failed,
    )
  }

  let create_rate_subscriber =
    build_subscriber_config(
      kraken_client,
      currency_repository,
      request_cmc_conversion,
      logger,
    )
    |> subscriber_factory.create

  Services(
    currency_repository:,
    currency_symbol_cache:,
    create_rate_subscriber:,
    logger:,
  )
}

fn build_subscriber_config(
  kraken_client: KrakenClient,
  currency_repository: CurrencyRepository,
  request_cmc_conversion: RequestCmcConversion,
  logger: Logger,
) -> subscriber.Config {
  let assert Ok(subscription_manager) =
    subscription_manager.new(subscription_refresh_interval_ms)

  let kraken_interface = {
    let assert Ok(price_store) = price_store.get_store()
      as "tried to get reference to price store before it was created"

    kraken_interface.new(kraken_client, price_store, pairs.exists)
  }

  subscriber.Config(
    get_currency: currency_repository.get_by_id,
    kraken_interface:,
    request_cmc_conversion:,
    subscription_manager:,
    logger: logger.with_source(logger, "subscriber"),
  )
}

fn start_server(secret_key_base: String, services: Services) -> Nil {
  let assert Ok(_) =
    router.route_request(_, secret_key_base, services)
    |> mist.new
    |> mist.bind("0.0.0.0")
    |> mist.port(8080)
    |> mist.start

  process.sleep_forever()
}
