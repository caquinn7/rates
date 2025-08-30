import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/process.{type Selector}
import gleam/float
import gleam/function
import gleam/int
import gleam/json
import gleam/option.{type Option, Some}
import gleam/string
import glight
import mist.{
  type WebsocketConnection, type WebsocketMessage, Binary, Closed, Custom,
  Shutdown, Text,
}
import server/kraken/kraken.{type Kraken}
import server/kraken/price_store.{type PriceStore}
import server/rates/actors/rate_error.{
  type RateError, CmcError, CurrencyNotFound,
}
import server/rates/actors/subscriber.{type RateSubscriber} as rate_subscriber
import server/rates/cmc_rate_handler.{type RequestCmcConversion}
import server/rates/rate_request
import server/rates/rate_response
import shared/currency.{type Currency}
import shared/rates/rate_request.{type RateRequest} as _shared_rate_request
import shared/rates/rate_response.{type RateResponse} as shared_rate_response

pub fn on_init(
  _conn: WebsocketConnection,
  cmc_currencies: List(Currency),
  request_cmc_conversion: RequestCmcConversion,
  kraken_subject: Kraken,
  get_price_store: fn() -> PriceStore,
) -> #(RateSubscriber, Option(Selector(Result(RateResponse, RateError)))) {
  let subject = process.new_subject()

  let selector =
    process.new_selector()
    |> process.select_map(subject, function.identity)

  let assert Ok(rate_subscriber) =
    rate_subscriber.new(
      subject,
      cmc_currencies,
      request_cmc_conversion,
      kraken_subject,
      10_000,
      get_price_store,
    )

  log_socket_init()

  #(rate_subscriber, Some(selector))
}

pub type WebsocketRequest {
  GetRate(RateRequest)
  AddCurrencies(List(Currency))
}

pub fn websocket_request_decoder() -> Decoder(WebsocketRequest) {
  let get_rate_decoder =
    rate_request.decoder()
    |> decode.map(GetRate)

  let add_currencies_decoder =
    currency.decoder()
    |> decode.list
    |> decode.map(AddCurrencies)

  decode.one_of(get_rate_decoder, [add_currencies_decoder])
}

pub fn handler(
  state: RateSubscriber,
  message: WebsocketMessage(Result(RateResponse, RateError)),
  conn: WebsocketConnection,
) -> mist.Next(RateSubscriber, Result(RateResponse, RateError)) {
  log_message_received(message)

  case message {
    Text(str) -> {
      case json.parse(str, websocket_request_decoder()) {
        Ok(GetRate(rate_req)) -> {
          rate_subscriber.subscribe(state, rate_req)
          mist.continue(state)
        }

        Ok(AddCurrencies([])) -> mist.continue(state)

        Ok(AddCurrencies(currencies)) -> {
          rate_subscriber.add_currencies(state, currencies)
          mist.continue(state)
        }

        Error(_) -> {
          let _ = mist.send_text_frame(conn, "Failed to decode rate request")
          mist.continue(state)
        }
      }
    }

    Custom(response) -> {
      let response_str = case response {
        Ok(rate_resp) -> {
          log_rate_response(rate_resp)

          rate_resp
          |> rate_response.encode
          |> json.to_string
        }

        Error(err) -> {
          log_rate_response_error(err)

          case err {
            CurrencyNotFound(_, id) ->
              "currency id " <> int.to_string(id) <> " not found"

            CmcError(..) -> "Unexpected error getting rate"
          }
        }
      }

      let _ = mist.send_text_frame(conn, response_str)
      mist.continue(state)
    }

    Binary(_) -> mist.continue(state)
    Closed | Shutdown -> {
      mist.stop()
    }
  }
}

pub fn on_close(state: RateSubscriber) -> Nil {
  rate_subscriber.stop(state)
  log_socket_closed()
}

// logging

fn websocket_logger() -> Dict(String, String) {
  glight.logger()
  |> glight.with("source", "websocket")
}

fn log_message_received(
  message: WebsocketMessage(Result(RateResponse, RateError)),
) -> Nil {
  glight.debug(
    websocket_logger()
      |> glight.with("received", string.inspect(message)),
    "received websocket message",
  )
  Nil
}

fn log_socket_init() -> Nil {
  glight.debug(websocket_logger(), "socket initialized")
  Nil
}

fn log_socket_closed() -> Nil {
  glight.debug(websocket_logger(), "socket closed")
  Nil
}

fn log_rate_response(rate_response: RateResponse) -> Nil {
  glight.debug(
    websocket_logger()
      |> glight.with("from", int.to_string(rate_response.from))
      |> glight.with("to", int.to_string(rate_response.to))
      |> glight.with("rate", float.to_string(rate_response.rate))
      |> glight.with(
        "rate_source",
        shared_rate_response.source_to_string(rate_response.source),
      ),
    "successfully fetched rate",
  )

  Nil
}

fn log_rate_response_error(error: RateError) -> Nil {
  let #(rate_req, reason) = case error {
    CurrencyNotFound(rate_req, id) -> #(
      rate_req,
      "currency id " <> int.to_string(id) <> " not found",
    )

    CmcError(rate_req, rate_req_err) -> #(
      rate_req,
      "error getting rate from cmc: " <> string.inspect(rate_req_err),
    )
  }

  glight.error(
    websocket_logger()
      |> glight.with("error", string.inspect(error))
      |> glight.with("reason", reason)
      |> glight.with("rate_request.from", int.to_string(rate_req.from))
      |> glight.with("rate_request.to", int.to_string(rate_req.to)),
    "error getting rate",
  )

  Nil
}
