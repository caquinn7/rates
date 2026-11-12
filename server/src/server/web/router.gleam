import gleam/bool
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/regexp
import gleam/result
import gleam/string
import mist
import server/currencies/currency_repository.{type CurrencyRepository}
import server/currencies/currency_symbol_cache.{type CurrencySymbolCache}
import server/dependencies.{type Dependencies}
import server/env_config.{type EnvConfig}
import server/rates/factories as rates_factories
import server/rates/resolver.{type ResolveError}
import server/utils/logger.{type Logger}
import server/web/routes/home
import server/web/routes/websocket
import shared/client_state
import shared/currency
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{type RateResponse}
import wisp
import wisp/wisp_mist

pub fn route_request(
  req: request.Request(mist.Connection),
  env_config: EnvConfig,
  deps: Dependencies,
) -> response.Response(mist.ResponseData) {
  case request.path_segments(req) {
    ["ws"] -> handle_websocket_request(req, deps)
    _ -> handle_http_request(req, env_config, deps)
  }
}

fn handle_websocket_request(
  req: request.Request(mist.Connection),
  deps: Dependencies,
) -> response.Response(mist.ResponseData) {
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

fn handle_http_request(
  req: request.Request(mist.Connection),
  env_config: EnvConfig,
  deps: Dependencies,
) -> response.Response(mist.ResponseData) {
  let handler =
    wisp_mist.handler(
      route_http_request(
        _,
        deps.currency_repository,
        deps.currency_symbol_cache,
        rates_factories.create_rate_resolver(deps),
        deps.logger,
      ),
      env_config.secret_key_base,
    )

  handler(req)
}

fn route_http_request(
  req: wisp.Request,
  currency_repository: CurrencyRepository,
  currency_symbol_cache: CurrencySymbolCache,
  get_rate: fn(RateRequest) -> Result(RateResponse, ResolveError),
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

      let get_rate = fn(rate_req) {
        rate_req
        |> get_rate
        |> result.map_error(log_rate_request_error(logger, rate_req, _))
      }

      home.get(currency_repository, get_rate, state)
    }

    ["api", "currencies"] -> {
      use <- wisp.require_method(req, http.Get)

      let symbol =
        req
        |> wisp.get_query
        |> list.key_find("symbol")
        |> result.unwrap("")

      use <- bool.lazy_guard(symbol == "", fn() {
        wisp.response(400)
        |> wisp.json_body(
          "{\"error\": \"Query parameter 'symbol' is required.\"}",
        )
      })

      let assert Ok(re) = regexp.from_string("^[a-zA-Z0-9]+$")
      let symbol_valid = regexp.check(re, symbol)
      use <- bool.lazy_guard(!symbol_valid, fn() {
        wisp.response(400)
        |> wisp.json_body(
          "{\"error\": \"'symbol' should only include one or more alphanumeric characters.\"}",
        )
      })

      case currency_symbol_cache.get_by_symbol(currency_symbol_cache, symbol) {
        Ok(currencies) ->
          currencies
          |> json.array(currency.encode)
          |> json.to_string
          |> wisp.json_response(200)
        Error(_) -> wisp.internal_server_error()
      }
    }

    _ -> wisp.not_found()
  }
}

fn log_rate_request_error(
  logger: Logger,
  rate_req: RateRequest,
  error: ResolveError,
) -> Nil {
  logger
  |> logger.with("source", "router")
  |> logger.with("rate_request.from", int.to_string(rate_req.from))
  |> logger.with("rate_request.to", int.to_string(rate_req.to))
  |> logger.with("error", string.inspect(error))
  |> logger.error("Error getting rate")
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
