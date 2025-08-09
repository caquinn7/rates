import dot_env
import dot_env/env
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/string_tree
import mist
import server/coin_market_cap/client as cmc
import server/context.{type Context, Context}
import server/currencies/cmc_currency_handler
import server/currencies/currencies_fetcher
import server/kraken/kraken
import server/kraken/price_store
import server/rates/actors/resolver as rate_resolver
import server/routes/currency
import server/routes/home/home
import server/ws/websocket
import shared/currency.{type Currency} as _shared_currency
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{type RateResponse}
import wisp.{type Request, type Response}
import wisp/wisp_mist

pub fn main() {
  wisp.configure_logger()

  // load env variables
  load_env()

  let assert Ok(secret_key_base) = env.get_string("SECRET_KEY_BASE")
  let assert Ok(cmc_api_key) = env.get_string("COIN_MARKET_CAP_API_KEY")
  let crypto_limit = env.get_int_or("CRYPTO_LIMIT", 100)
  let supported_fiat_symbols = case env.get_string("SUPPORTED_FIAT_SYMBOLS") {
    Error(_) -> ["USD"]
    Ok(s) -> string.split(s, ",")
  }

  // build Context
  let ctx = Context(cmc_api_key:, crypto_limit:, supported_fiat_symbols:)

  // get CMC currencies
  let cmc_currencies = {
    let request_cryptos = fn() {
      cmc.get_crypto_currencies(ctx.cmc_api_key, ctx.crypto_limit, None)
    }
    let request_fiats = cmc.get_fiat_currencies(ctx.cmc_api_key, _)

    let result =
      currencies_fetcher.get_currencies(
        ctx,
        request_cryptos,
        request_fiats,
        10_000,
      )

    case result {
      Error(err) ->
        panic as { "error getting currencies: " <> string.inspect(err) }

      Ok(cmc_currencies) -> {
        let count = list.length(cmc_currencies)
        echo "fetched " <> int.to_string(count) <> " currencies from cmc"
        cmc_currencies
      }
    }
  }

  // start kraken actor
  // todo? wait for instruments before proceeding
  let create_price_store = fn() {
    let assert Ok(store) = price_store.new()
    store
  }
  let assert Ok(kraken) = kraken.new(create_price_store)

  // request handlers
  let assert Ok(_) =
    mist.new(fn(req) {
      let request_cmc_conversion = cmc.get_conversion(cmc_api_key, _)

      let get_price_store = fn() {
        let store = case price_store.get_store() {
          Ok(store) -> store
          _ -> panic as "tried to get price store before it was created"
        }
        store
      }

      case request.path_segments(req) {
        // handle websocket connections
        ["ws"] -> {
          mist.websocket(
            req,
            on_init: websocket.on_init(
              _,
              cmc_currencies,
              request_cmc_conversion,
              kraken,
              get_price_store,
            ),
            handler: websocket.handler,
            on_close: websocket.on_close,
          )
        }

        // handle http requests
        _ -> {
          let get_rate = fn(rate_req) {
            let assert Ok(resolver) =
              rate_resolver.new(
                cmc_currencies,
                kraken,
                request_cmc_conversion,
                get_price_store,
              )

            resolver
            |> rate_resolver.get_rate(rate_req, 5000)
            |> result.map_error(fn(err) {
              echo "error getting rate for "
                <> string.inspect(rate_req)
                <> ": "
                <> string.inspect(err)

              Nil
            })
          }

          let handle_request =
            wisp_mist.handler(
              handle_request(ctx, _, cmc_currencies, get_rate),
              secret_key_base,
            )
          handle_request(req)
        }
      }
    })
    |> mist.port(8080)
    |> mist.start

  process.sleep_forever()
}

fn load_env() -> Nil {
  dot_env.new()
  |> dot_env.set_path(".env")
  |> dot_env.set_debug(True)
  |> dot_env.set_ignore_missing_file(True)
  |> dot_env.load
}

fn handle_request(
  ctx: Context,
  req: Request,
  currencies: List(Currency),
  get_rate: fn(RateRequest) -> Result(RateResponse, Nil),
) -> Response {
  use req <- middleware(req)
  case wisp.path_segments(req) {
    [] -> {
      use <- wisp.require_method(req, http.Get)
      home.get(currencies, get_rate)
    }

    ["api", "currencies"] -> {
      use <- wisp.require_method(req, http.Get)

      let get_symbol_param = fn() {
        req
        |> wisp.get_query
        |> list.key_find("symbol")
        |> result.map(string.trim_end)
      }

      case get_symbol_param() {
        Error(_) | Ok("") ->
          wisp.response(400)
          |> wisp.json_body(string_tree.from_string(
            "{\"error\": \"Query parameter 'symbol' is required.\"}",
          ))

        Ok(symbol) -> {
          let request_cryptos = fn() {
            cmc.get_crypto_currencies(
              ctx.cmc_api_key,
              ctx.crypto_limit,
              Some(symbol),
            )
          }

          case cmc_currency_handler.get_cryptos(request_cryptos) {
            Error(_) -> wisp.internal_server_error()

            Ok(currencies) ->
              currencies
              |> json.array(currency.encode)
              |> json.to_string_tree
              |> wisp.json_response(200)
          }
        }
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
