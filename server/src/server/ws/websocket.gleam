import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/process.{type Selector}
import gleam/float
import gleam/function
import gleam/int
import gleam/json
import gleam/option.{type Option, Some}
import gleam/string
import mist.{
  type WebsocketConnection, type WebsocketMessage, Binary, Closed, Custom,
  Shutdown, Text,
}
import server/kraken/kraken.{type Kraken}
import server/kraken/price_store.{type PriceStore}
import server/logger.{type Logger}
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
          log_rate_response_success(rate_resp)

          rate_resp
          |> rate_response.encode
          |> json.to_string
        }

        Error(err) -> {
          log_rate_response_error(err)

          case err {
            CurrencyNotFound(_, id) ->
              "Currency id " <> int.to_string(id) <> " not found"

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

fn websocket_logger() -> Logger {
  logger.new()
  |> logger.with_pid()
  |> logger.with_source("websocket")
}

fn log_message_received(
  message: WebsocketMessage(Result(RateResponse, RateError)),
) -> Nil {
  logger.debug(
    websocket_logger()
      |> logger.with("received", string.inspect(message)),
    "Received websocket message",
  )
}

fn log_socket_init() -> Nil {
  logger.debug(websocket_logger(), "Socket initialized")
}

fn log_socket_closed() -> Nil {
  logger.debug(websocket_logger(), "Socket closed")
}

fn log_rate_response_success(rate_response: RateResponse) -> Nil {
  logger.debug(
    websocket_logger()
      |> logger.with("rate_response.from", int.to_string(rate_response.from))
      |> logger.with("rate_response.to", int.to_string(rate_response.to))
      |> logger.with("rate_response.rate", float.to_string(rate_response.rate))
      |> logger.with(
        "rate_source",
        shared_rate_response.source_to_string(rate_response.source),
      ),
    "Successfully fetched rate",
  )
}

fn log_rate_response_error(error: RateError) -> Nil {
  let #(rate_req, reason) = case error {
    CurrencyNotFound(rate_req, id) -> #(
      rate_req,
      "Currency id " <> int.to_string(id) <> " not found",
    )

    CmcError(rate_req, rate_req_err) -> #(
      rate_req,
      "Error getting rate from cmc: " <> string.inspect(rate_req_err),
    )
  }

  logger.error(
    websocket_logger()
      |> logger.with("error", string.inspect(error))
      |> logger.with("reason", reason)
      |> logger.with("rate_request.from", int.to_string(rate_req.from))
      |> logger.with("rate_request.to", int.to_string(rate_req.to)),
    "Error getting rate",
  )
}
