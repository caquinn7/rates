import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option
import gleam/result
import mist
import server/currencies/currency_repository.{type CurrencyRepository}
import server/currencies/currency_symbol_cache.{type CurrencySymbolCache}
import server/services.{type Services}
import server/utils/logger
import server/web/routes/currencies
import server/web/routes/home
import server/web/routes/websocket
import shared/client_state
import wisp
import wisp/wisp_mist

pub fn route_request(
  req: request.Request(mist.Connection),
  secret_key_base: String,
  services: Services,
) -> response.Response(mist.ResponseData) {
  case request.path_segments(req) {
    ["ws"] -> handle_websocket_request(req, services)
    _ -> handle_http_request(req, secret_key_base, services)
  }
}

fn handle_websocket_request(
  req: request.Request(mist.Connection),
  services: Services,
) -> response.Response(mist.ResponseData) {
  mist.websocket(
    req,
    on_init: websocket.on_init(
      _,
      logger.with_source(services.logger, "websocket"),
    ),
    handler: fn(state, message, conn) {
      websocket.handler(state, message, conn, services.create_rate_subscriber)
    },
    on_close: websocket.on_close,
  )
}

fn handle_http_request(
  req: request.Request(mist.Connection),
  secret_key_base: String,
  services: Services,
) -> response.Response(mist.ResponseData) {
  let handler =
    wisp_mist.handler(
      route_http_request(
        _,
        services.currency_repository,
        services.currency_symbol_cache,
      ),
      secret_key_base,
    )

  handler(req)
}

fn route_http_request(
  req: wisp.Request,
  currency_repository: CurrencyRepository,
  currency_symbol_cache: CurrencySymbolCache,
) -> wisp.Response {
  use req <- middleware(req)
  case wisp.path_segments(req) {
    [] -> {
      use <- wisp.require_method(req, http.Get)

      let state =
        req
        |> wisp.get_query
        |> list.key_find("state")
        |> result.unwrap("")
        |> client_state.decode
        |> option.from_result

      home.get(currency_repository.get_all(), state)
    }

    ["api", "currencies"] -> {
      use <- wisp.require_method(req, http.Get)
      currencies.get(req, currency_symbol_cache)
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
