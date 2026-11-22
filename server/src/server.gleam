import gleam/erlang/process
import gleam/string
import glight
import mist
import server/currencies/currency_repository.{type CurrencyRepository}
import server/currencies/currency_service
import server/currencies/currency_symbol_cache.{type CurrencySymbolCache}
import server/env_config.{type EnvConfig}
import server/integrations/kraken/client.{type KrakenClient} as kraken_client
import server/integrations/kraken/price_store
import server/rates/subscriber_factory.{type SubscriberFactory}
import server/services.{type Services, Services}
import server/utils/logger.{type Logger}
import server/utils/time
import server/web/router

const kraken_readiness_timeout_ms = 10_000

pub fn main() {
  let env_config = load_env_config()
  let logger = create_logger(env_config.log_level)

  let #(currency_repository, currency_symbol_cache) =
    init_currencies(env_config, logger)

  let kraken_client = start_kraken(logger)

  let create_rate_subscriber =
    create_subscriber_factory(
      currency_repository,
      kraken_client,
      env_config,
      logger,
    )

  let services =
    Services(
      currency_repository:,
      currency_symbol_cache:,
      create_rate_subscriber:,
      logger:,
    )

  start_server(env_config.secret_key_base, services)
}

fn load_env_config() -> EnvConfig {
  case env_config.load() {
    Ok(c) -> c
    Error(msg) -> panic as { "failed to load env_config: " <> msg }
  }
}

fn create_logger(log_level: String) -> Logger {
  let log_level = case string.lowercase(log_level) {
    "error" -> glight.Error
    "warn" -> glight.Warning
    "info" -> glight.Info
    "debug" -> glight.Debug
    _ -> glight.Info
  }

  let assert Ok(Nil) =
    glight.configure([glight.Console, glight.File("server.log")])
  glight.set_log_level(log_level)
  glight.set_is_color(True)

  logger.new()
}

fn init_currencies(
  env_config: EnvConfig,
  logger: Logger,
) -> #(CurrencyRepository, CurrencySymbolCache) {
  case
    currency_service.start(
      env_config.cmc_api_key,
      env_config.crypto_limit,
      env_config.supported_fiat_symbols,
      logger,
    )
  {
    Ok(currencies) -> currencies
    Error(currency_service.StoreCreationFailed(reason)) ->
      panic as { "Failed to create currency store: " <> string.inspect(reason) }
    Error(currency_service.CatalogLoadFailed(reason)) ->
      panic as { "error getting currencies: " <> string.inspect(reason) }
    Error(currency_service.CacheStartFailed(reason)) ->
      panic as {
        "Failed to start currency symbol cache: " <> string.inspect(reason)
      }
  }
}

fn start_kraken(logger: Logger) -> KrakenClient {
  let logger = logger.with_source(logger, "kraken")
  let client = case kraken_client.new(logger, price_store.new) {
    Ok(client) -> client
    Error(error) ->
      panic as { "Failed to start Kraken client: " <> string.inspect(error) }
  }

  wait_for_kraken_symbols(
    client,
    time.monotonic_time_ms() + kraken_readiness_timeout_ms,
  )

  client
}

fn wait_for_kraken_symbols(client: KrakenClient, deadline_ms: Int) -> Nil {
  case
    kraken_client.has_supported_pairs(client),
    time.monotonic_time_ms() >= deadline_ms
  {
    True, _ -> Nil
    _, True -> panic as "Timeout waiting for Kraken symbols"
    _, False -> {
      process.sleep(100)
      wait_for_kraken_symbols(client, deadline_ms)
    }
  }
}

fn create_subscriber_factory(
  currency_repository: CurrencyRepository,
  kraken_client: KrakenClient,
  env_config: EnvConfig,
  logger: Logger,
) -> SubscriberFactory {
  case
    subscriber_factory.from_dependencies(
      currency_repository.get_by_id,
      kraken_client,
      env_config.cmc_api_key,
      logger,
    )
  {
    Ok(factory) -> factory
    Error(reason) ->
      panic as { "Failed to configure rate subscribers: " <> reason }
  }
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
