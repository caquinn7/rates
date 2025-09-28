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
import server/rates/internal/cmc_rate_handler.{type RequestCmcConversion}
import server/rates/internal/rate_source_strategy.{
  type CheckForKrakenPrice, type SubscribeToKraken, type UnsubscribeFromKraken,
}
import server/rates/internal/subscription_manager
import server/rates/rate_error.{type RateError, CmcError, CurrencyNotFound}
import server/rates/subscriber.{type RateSubscriber, type SubscriptionResult} as rate_subscriber
import server/utils/logger.{type Logger}
import server/utils/time
import shared/currency.{type Currency}
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{type RateResponse}
import shared/subscriptions/subscription_id

pub fn on_init(
  _conn: WebsocketConnection,
  cmc_currencies: List(Currency),
  subscribe_to_kraken: SubscribeToKraken,
  unsubscribe_from_kraken: UnsubscribeFromKraken,
  check_for_kraken_price: CheckForKrakenPrice,
  request_cmc_conversion: RequestCmcConversion,
  logger: Logger,
) -> #(#(RateSubscriber, Logger), Option(Selector(SubscriptionResult))) {
  let subject = process.new_subject()

  let selector =
    process.new_selector()
    |> process.select_map(subject, function.identity)

  // Use a fixed subscription ID since we don't need multiple subscriptions
  let assert Ok(fixed_subscription_id) = subscription_id.new("websocket-single")

  let assert Ok(rate_subscriber) = {
    let assert Ok(subscription_manager) = subscription_manager.new(10_000)
    let config =
      rate_subscriber.Config(
        cmc_currencies:,
        subscription_manager:,
        subscribe_to_kraken:,
        unsubscribe_from_kraken:,
        check_for_kraken_price:,
        request_cmc_conversion:,
        get_current_time_ms: time.system_time_ms,
        logger: logger.with(logger.new(), "source", "subscriber"),
      )
    rate_subscriber.new(fixed_subscription_id, subject, config)
  }

  log_socket_init(logger)

  #(#(rate_subscriber, logger), Some(selector))
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
  state: #(RateSubscriber, Logger),
  message: WebsocketMessage(SubscriptionResult),
  conn: WebsocketConnection,
) -> mist.Next(#(RateSubscriber, Logger), SubscriptionResult) {
  let #(rate_subscriber, logger) = state
  log_message_received(logger, message)

  case message {
    Text(str) -> {
      case json.parse(str, websocket_request_decoder()) {
        Ok(GetRate(rate_req)) -> {
          rate_subscriber.subscribe(rate_subscriber, rate_req)
          mist.continue(state)
        }

        Ok(AddCurrencies([])) -> mist.continue(state)

        Ok(AddCurrencies(currencies)) -> {
          rate_subscriber.add_currencies(rate_subscriber, currencies)
          mist.continue(state)
        }

        Error(_) -> {
          let _ = mist.send_text_frame(conn, "Failed to decode rate request")
          mist.continue(state)
        }
      }
    }

    Custom(#(_subscription_id, response)) -> {
      let response_str = case response {
        Ok(rate_resp) -> {
          log_rate_response_success(logger, rate_resp)

          rate_resp
          |> rate_response.encode
          |> json.to_string
        }

        Error(err) -> {
          log_rate_response_error(logger, err)

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
    Closed | Shutdown -> mist.stop()
  }
}

pub fn on_close(state: #(RateSubscriber, Logger)) -> Nil {
  let #(rate_subscriber, logger) = state
  rate_subscriber.stop(rate_subscriber)
  log_socket_closed(logger)
}

// logging

fn log_message_received(
  logger: Logger,
  message: WebsocketMessage(SubscriptionResult),
) -> Nil {
  logger
  |> logger.with("received", string.inspect(message))
  |> logger.debug("Received websocket message")
}

fn log_socket_init(logger: Logger) -> Nil {
  logger
  |> logger.debug("Socket initialized")
}

fn log_socket_closed(logger: Logger) -> Nil {
  logger
  |> logger.debug("Socket closed")
}

fn log_rate_response_success(logger: Logger, rate_response: RateResponse) -> Nil {
  logger
  |> logger.with("rate_response.from", int.to_string(rate_response.from))
  |> logger.with("rate_response.to", int.to_string(rate_response.to))
  |> logger.with("rate_response.rate", float.to_string(rate_response.rate))
  |> logger.with(
    "rate_response.source",
    rate_response.source_to_string(rate_response.source),
  )
  |> logger.with(
    "rate_response.timestamp",
    int.to_string(rate_response.timestamp),
  )
  |> logger.debug("Successfully fetched rate")
}

fn log_rate_response_error(logger: Logger, error: RateError) -> Nil {
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

  logger
  |> logger.with("error", string.inspect(error))
  |> logger.with("reason", reason)
  |> logger.with("rate_request.from", int.to_string(rate_req.from))
  |> logger.with("rate_request.to", int.to_string(rate_req.to))
  |> logger.error("Error getting rate")
}
