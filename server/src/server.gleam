import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None}
import gleam/string
import glight
import mist
import server/app_config.{type AppConfig, AppConfig}
import server/dependencies.{type Dependencies, Dependencies}
import server/domain/currencies/currencies_fetcher
import server/domain/currencies/currency_interface
import server/domain/currencies/currency_store.{type CurrencyStore}
import server/domain/rates/internal/kraken_interface
import server/env_config.{type EnvConfig}
import server/integrations/coin_market_cap/client.{
  type CmcListResponse, type CmcRequestError,
}
import server/integrations/coin_market_cap/cmc_crypto_currency.{
  type CmcCryptoCurrency,
}
import server/integrations/coin_market_cap/cmc_fiat_currency.{
  type CmcFiatCurrency,
}
import server/integrations/coin_market_cap/factories as cmc_factories
import server/integrations/kraken/client as kraken_client
import server/integrations/kraken/pairs
import server/integrations/kraken/price_store
import server/utils/logger.{type Logger}
import server/utils/time
import server/web/router

pub fn main() {
  let env_config = case env_config.load() {
    Error(msg) -> panic as msg
    Ok(c) -> c
  }

  let logger = configure_logging(env_config.log_level)

  let app_config =
    AppConfig(
      cmc_api_key: env_config.cmc_api_key,
      crypto_limit: env_config.crypto_limit,
      supported_fiat_symbols: env_config.supported_fiat_symbols,
    )

  let request_cmc_cryptos =
    cmc_factories.create_crypto_requester(
      app_config.cmc_api_key,
      app_config.crypto_limit,
    )

  let request_cmc_fiats =
    cmc_factories.create_fiat_requester(app_config.cmc_api_key)

  let request_cmc_conversion =
    cmc_factories.create_conversion_requester(app_config.cmc_api_key)

  let assert Ok(currency_store) = currency_store.new()

  fetch_and_store_currencies(
    app_config,
    request_cmc_cryptos,
    request_cmc_fiats,
    currency_store,
    logger,
  )

  let assert Ok(kraken_client) = {
    let create_price_store = fn() {
      let assert Ok(store) = price_store.new()
      store
    }

    kraken_client.new(
      logger.with(logger, "source", "kraken"),
      create_price_store,
    )
  }

  wait_for_kraken_symbols(time.monotonic_time_ms(), 10_000)

  let assert Ok(price_store) = price_store.get_store()
    as "tried to get reference to price store before it was created"

  let dependencies =
    Dependencies(
      currency_interface: currency_interface.new(currency_store),
      subscription_refresh_interval_ms: 10_000,
      kraken_interface: kraken_interface.new(
        kraken_client,
        price_store,
        pairs.exists,
      ),
      request_cmc_cryptos:,
      request_cmc_conversion:,
      get_current_time_ms: time.system_time_ms,
      logger:,
    )

  start_server(env_config, dependencies)
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
  app_config: AppConfig,
  request_cmc_cryptos: fn(Option(String)) ->
    Result(CmcListResponse(CmcCryptoCurrency), CmcRequestError),
  request_cmc_fiats: fn() ->
    Result(CmcListResponse(CmcFiatCurrency), CmcRequestError),
  currency_store: CurrencyStore,
  logger: Logger,
) {
  let currencies_result =
    currencies_fetcher.get_currencies(
      app_config,
      fn() { request_cmc_cryptos(None) },
      request_cmc_fiats,
      10_000,
    )

  case currencies_result {
    Error(err) -> {
      let msg = "error getting currencies: " <> string.inspect(err)
      panic as msg
    }

    Ok(currencies) -> {
      currency_store.insert(currency_store, currencies)

      logger
      |> logger.with("source", "server")
      |> logger.with("count", int.to_string(list.length(currencies)))
      |> logger.info("fetched currencies from cmc")
    }
  }
}

fn wait_for_kraken_symbols(start_time: Int, timeout_ms: Int) -> Nil {
  case pairs.count() > 0 {
    True -> Nil

    False -> {
      let elapsed = time.monotonic_time_ms() - start_time
      case elapsed >= timeout_ms {
        False -> {
          process.sleep(100)
          wait_for_kraken_symbols(start_time, timeout_ms)
        }
        True -> panic as "Timeout waiting for Kraken symbols"
      }
    }
  }
}

fn start_server(env_config: EnvConfig, deps: Dependencies) -> Nil {
  let assert Ok(_) =
    router.route_request(_, env_config, deps)
    |> mist.new
    |> mist.bind("0.0.0.0")
    |> mist.port(8080)
    |> mist.start

  process.sleep_forever()
}
