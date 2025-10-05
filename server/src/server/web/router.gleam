import gleam/bool
import gleam/http
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/string
import gleam/string_tree
import mist
import server/dependencies.{type Dependencies}
import server/domain/currencies/cmc_currency_handler
import server/domain/rates/factories as rates_factories
import server/domain/rates/rate_error.{type RateError}
import server/env_config.{type EnvConfig}
import server/integrations/coin_market_cap/client.{
  type CmcCryptoCurrency, type CmcListResponse, type CmcRequestError,
}
import server/utils/logger
import server/web/routes/home
import server/web/routes/ws/websocket
import server/web/routes/ws/websocket_v2
import shared/currency.{type Currency}
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{type RateResponse}
import wisp
import wisp/wisp_mist

pub fn route_request(req, env_config: EnvConfig, deps: Dependencies) {
  case request.path_segments(req) {
    ["ws"] -> handle_websocket_v1(req, deps)
    ["ws", "v2"] -> handle_websocket_v2(req, deps)
    _ -> handle_http_request(req, env_config, deps)
  }
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
  mist.websocket(
    req,
    on_init: websocket_v2.on_init(
      _,
      logger.with(deps.logger, "source", "websocket_v2"),
    ),
    handler: fn(state, message, conn) {
      websocket_v2.handler(
        state,
        message,
        conn,
        rates_factories.create_rate_subscriber_factory(deps),
      )
    },
    on_close: websocket_v2.on_close,
  )
}

fn handle_http_request(req, env_config: EnvConfig, deps: Dependencies) {
  let handle_request =
    wisp_mist.handler(
      handle_request(
        _,
        deps.currencies,
        deps.request_cmc_cryptos,
        rates_factories.create_rate_resolver(deps),
      ),
      env_config.secret_key_base,
    )

  handle_request(req)
}

fn handle_request(
  req: wisp.Request,
  currencies: List(Currency),
  request_cryptos: fn(Option(String)) ->
    Result(CmcListResponse(CmcCryptoCurrency), CmcRequestError),
  get_rate: fn(RateRequest) -> Result(RateResponse, RateError),
) -> wisp.Response {
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

      let handle_missing_symbol = fn() {
        wisp.json_body(
          wisp.response(400),
          string_tree.from_string(
            "{\"error\": \"Query parameter 'symbol' is required.\"}",
          ),
        )
      }
      use <- bool.lazy_guard(symbol == "", handle_missing_symbol)

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

fn middleware(
  req: wisp.Request,
  handle_request: fn(wisp.Request) -> wisp.Response,
) -> wisp.Response {
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
