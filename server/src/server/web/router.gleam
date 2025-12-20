import gleam/bool
import gleam/http
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/result
import gleam/string
import mist
import server/dependencies.{type Dependencies}
import server/domain/currencies/cmc_currency_handler
import server/domain/currencies/currencies_fetcher
import server/domain/currencies/currency_interface.{type CurrencyInterface}
import server/domain/rates/factories as rates_factories
import server/domain/rates/rate_error.{type RateError}
import server/env_config.{type EnvConfig}
import server/integrations/coin_market_cap/client.{
  type CmcListResponse, type CmcRequestError,
}
import server/integrations/coin_market_cap/cmc_crypto_currency.{
  type CmcCryptoCurrency,
}
import server/utils/logger.{type Logger}
import server/web/routes/home
import server/web/routes/websocket
import shared/client_state
import shared/currency
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{type RateResponse}
import wisp
import wisp/wisp_mist

pub fn route_request(req, env_config: EnvConfig, deps: Dependencies) {
  case request.path_segments(req) {
    ["ws"] -> handle_websocket_request(req, deps)
    _ -> handle_http_request(req, env_config, deps)
  }
}

fn handle_websocket_request(req, deps: Dependencies) {
  mist.websocket(
    req,
    on_init: websocket.on_init(
      _,
      logger.with(deps.logger, "source", "websocket"),
    ),
    handler: fn(state, message, conn) {
      websocket.handler(
        state,
        message,
        conn,
        rates_factories.create_rate_subscriber_factory(deps),
      )
    },
    on_close: websocket.on_close,
  )
}

fn handle_http_request(req, env_config: EnvConfig, deps: Dependencies) {
  let handler =
    wisp_mist.handler(
      route_http_request(
        _,
        deps.currency_interface,
        deps.request_cmc_cryptos,
        rates_factories.create_rate_resolver(deps),
        deps.logger,
      ),
      env_config.secret_key_base,
    )

  handler(req)
}

fn route_http_request(
  req: wisp.Request,
  currency_interface: CurrencyInterface,
  request_cryptos: fn(Option(String)) ->
    Result(CmcListResponse(CmcCryptoCurrency), CmcRequestError),
  get_rate: fn(RateRequest) -> Result(RateResponse, RateError),
  logger: Logger,
) -> wisp.Response {
  use req <- middleware(req)
  case wisp.path_segments(req) {
    [] -> {
      use <- wisp.require_method(req, http.Get)

      let state = {
        let state_param =
          req
          |> wisp.get_query
          |> list.key_find("state")
          |> result.unwrap("")

        case state_param {
          "" -> None
          _ ->
            state_param
            |> client_state.decode
            |> option.from_result
        }
      }

      let get_cryptos = fn(symbols) {
        let request_cryptos_by_symbols = fn() {
          symbols
          |> string.join(",")
          |> Some
          |> request_cryptos
        }

        request_cryptos_by_symbols
        |> currencies_fetcher.get_cryptos(5000)
        |> result.map_error(fn(err) {
          logger
          |> logger.with("source", "router")
          |> logger.with("error", string.inspect(err))
          |> logger.error("Error getting cryptos from CMC")
        })
        |> result.unwrap(or: [])
      }
      home.get(currency_interface, get_rate, get_cryptos, state)
    }

    ["api", "currencies"] -> {
      use <- wisp.require_method(req, http.Get)

      let symbol =
        req
        |> wisp.get_query
        |> list.key_find("symbol")
        |> result.unwrap("")

      use <- bool.lazy_guard(symbol == "", fn() {
        wisp.json_body(
          wisp.response(400),
          "{\"error\": \"Query parameter 'symbol' is required.\"}",
        )
      })

      let assert Ok(re) = regexp.from_string("^[a-zA-Z0-9]+$")
      let symbol_valid = regexp.check(re, symbol)
      use <- bool.lazy_guard(!symbol_valid, fn() {
        wisp.json_body(
          wisp.response(400),
          "{\"error\": \"'symbol' should only include one or more alphanumeric characters.\"}",
        )
      })

      let currencies_response = fn(currencies) {
        currencies
        |> json.array(currency.encode)
        |> json.to_string
        |> wisp.json_response(200)
      }

      case currency_interface.get_by_symbol(symbol) {
        [] -> {
          let request_cryptos = fn() { request_cryptos(Some(symbol)) }

          case cmc_currency_handler.get_cryptos(request_cryptos) {
            Error(_) -> wisp.internal_server_error()

            Ok(currencies) -> {
              currency_interface.insert(currencies)
              currencies_response(currencies)
            }
          }
        }

        currencies -> currencies_response(currencies)
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
