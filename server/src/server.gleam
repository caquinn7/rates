import gleam/bool
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/string_tree
import glight
import mist
import server/app_config.{type AppConfig, AppConfig}
import server/domain/currencies/cmc_currency_handler
import server/domain/currencies/currencies_fetcher
import server/domain/rates/factories as rates_factories
import server/domain/rates/internal/kraken_interface.{type KrakenInterface}
import server/domain/rates/rate_error.{type RateError}
import server/domain/rates/rate_service_config.{
  type RateServiceConfig, RateServiceConfig,
}
import server/env_config.{type EnvConfig}
import server/integrations/coin_market_cap/client.{
  type CmcConversion, type CmcConversionParameters, type CmcCryptoCurrency,
  type CmcFiatCurrency, type CmcListResponse, type CmcRequestError,
  type CmcResponse,
}
import server/integrations/coin_market_cap/factories as cmc_factories
import server/integrations/kraken/client as kraken_client
import server/integrations/kraken/pairs
import server/integrations/kraken/price_store
import server/utils/logger.{type Logger}
import server/utils/time
import server/web/routes/home
import server/web/routes/ws/websocket
import server/web/routes/ws/websocket_v2
import shared/currency.{type Currency}
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{type RateResponse}
import wisp.{type Request, type Response}
import wisp/wisp_mist

pub type Dependencies {
  Dependencies(
    app_config: AppConfig,
    currencies: List(Currency),
    kraken_interface: KrakenInterface,
    request_cmc_cryptos: fn(Option(String)) ->
      Result(CmcListResponse(CmcCryptoCurrency), CmcRequestError),
    request_cmc_conversion: fn(CmcConversionParameters) ->
      Result(CmcResponse(CmcConversion), CmcRequestError),
    get_current_time_ms: fn() -> Int,
    logger: Logger,
  )
}

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

  let assert Ok(currencies) =
    get_currencies(app_config, request_cmc_cryptos, request_cmc_fiats, logger)

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

  wait_for_kraken_symbols_loop(time.monotonic_time_ms(), 10_000)

  let assert Ok(price_store) = price_store.get_store()
    as "tried to get reference to price store before it was created"

  let dependencies =
    Dependencies(
      app_config:,
      currencies:,
      kraken_interface: kraken_interface.new(kraken_client, price_store),
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

fn get_currencies(
  app_config: AppConfig,
  request_cmc_cryptos: fn(Option(String)) ->
    Result(CmcListResponse(CmcCryptoCurrency), CmcRequestError),
  request_cmc_fiats: fn() ->
    Result(CmcListResponse(CmcFiatCurrency), CmcRequestError),
  logger: Logger,
) -> Result(List(Currency), String) {
  let currencies_result =
    currencies_fetcher.get_currencies(
      app_config,
      fn() { request_cmc_cryptos(None) },
      request_cmc_fiats,
      10_000,
    )

  use currencies <- result.try(
    currencies_result
    |> result.map_error(fn(err) {
      "error getting currencies: " <> string.inspect(err)
    }),
  )

  logger
  |> logger.with("source", "server")
  |> logger.with("count", int.to_string(list.length(currencies)))
  |> logger.info("fetched currencies from cmc")

  Ok(currencies)
}

fn wait_for_kraken_symbols_loop(start_time: Int, timeout_ms: Int) -> Nil {
  case pairs.count() > 0 {
    True -> Nil

    False -> {
      let elapsed = time.monotonic_time_ms() - start_time
      case elapsed >= timeout_ms {
        True -> panic as "Timeout waiting for Kraken symbols"
        False -> {
          process.sleep(100)
          wait_for_kraken_symbols_loop(start_time, timeout_ms)
        }
      }
    }
  }
}

fn start_server(env_config: EnvConfig, deps: Dependencies) -> Nil {
  let assert Ok(_) =
    mist.new(fn(req) {
      case request.path_segments(req) {
        ["ws"] -> handle_websocket_v1(req, deps)
        ["ws", "v2"] -> handle_websocket_v2(req, deps)
        _ -> handle_http_request(req, env_config, deps)
      }
    })
    |> mist.port(8080)
    |> mist.start

  process.sleep_forever()
}

fn handle_websocket_v1(req, deps: Dependencies) {
  mist.websocket(
    req,
    on_init: websocket.on_init(
      _,
      deps.currencies,
      deps.kraken_interface,
      deps.request_cmc_conversion,
      logger.with(deps.logger, "source", "websocket"),
    ),
    handler: websocket.handler,
    on_close: websocket.on_close,
  )
}

fn handle_websocket_v2(req, deps: Dependencies) {
  let create_rate_subscriber =
    rates_factories.create_rate_subscriber_factory(
      create_rate_service_config(deps),
      deps.logger,
    )

  mist.websocket(
    req,
    on_init: websocket_v2.on_init(
      _,
      logger.with(deps.logger, "source", "websocket_v2"),
    ),
    handler: fn(state, message, conn) {
      websocket_v2.handler(state, message, conn, create_rate_subscriber)
    },
    on_close: websocket_v2.on_close,
  )
}

fn handle_http_request(req, env_config: EnvConfig, deps: Dependencies) {
  let get_rate =
    rates_factories.create_rate_resolver(create_rate_service_config(deps))

  let handle_request =
    wisp_mist.handler(
      handle_request(_, deps.request_cmc_cryptos, deps.currencies, get_rate),
      env_config.secret_key_base,
    )

  handle_request(req)
}

fn handle_request(
  req: Request,
  request_cryptos: fn(Option(String)) ->
    Result(CmcListResponse(CmcCryptoCurrency), CmcRequestError),
  currencies: List(Currency),
  get_rate: fn(RateRequest) -> Result(RateResponse, RateError),
) -> Response {
  use req <- middleware(req)
  case wisp.path_segments(req) {
    [] -> {
      use <- wisp.require_method(req, http.Get)
      home.get(currencies, get_rate)
    }

    ["api", "currencies"] -> {
      use <- wisp.require_method(req, http.Get)

      let symbol = {
        req
        |> wisp.get_query
        |> list.key_find("symbol")
        |> result.map(string.trim)
        |> result.unwrap("")
      }

      let missing_symbol_response =
        wisp.response(400)
        |> wisp.json_body(string_tree.from_string(
          "{\"error\": \"Query parameter 'symbol' is required.\"}",
        ))

      use <- bool.guard(symbol == "", missing_symbol_response)

      let request_cryptos = fn() { request_cryptos(Some(symbol)) }

      case cmc_currency_handler.get_cryptos(request_cryptos) {
        Error(_) -> wisp.internal_server_error()

        Ok(currencies) ->
          currencies
          |> json.array(currency.encode)
          |> json.to_string_tree
          |> wisp.json_response(200)
      }
    }

    _ -> wisp.not_found()
  }
}

fn middleware(req: Request, handle_request: fn(Request) -> Response) -> Response {
  let req = wisp.method_override(req)
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)
  use <- wisp.serve_static(req, under: "/static", from: get_static_directory())
  handle_request(req)
}

fn get_static_directory() -> String {
  let assert Ok(priv_directory) = wisp.priv_directory("server")
  priv_directory <> "/static"
}

pub fn create_rate_service_config(deps: Dependencies) -> RateServiceConfig {
  RateServiceConfig(
    currencies: deps.currencies,
    kraken_interface: deps.kraken_interface,
    request_cmc_conversion: deps.request_cmc_conversion,
    get_current_time_ms: deps.get_current_time_ms,
  )
}
