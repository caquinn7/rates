import gleam/dict.{type Dict}
import gleam/erlang/process.{type Selector}
import gleam/float
import gleam/function
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, Some}
import gleam/string
import mist.{
  type WebsocketConnection, type WebsocketMessage, Binary, Closed, Custom,
  Shutdown, Text,
}
import server/integrations/kraken/client.{type KrakenClient}
import server/integrations/kraken/price_store.{type PriceStore}
import server/rates/actors/rate_error.{
  type RateError, CmcError, CurrencyNotFound,
}
import server/rates/actors/subscriber.{
  type RateSubscriber, type SubscriptionResult,
} as rate_subscriber
import server/rates/cmc_rate_handler.{type RequestCmcConversion}
import server/utils/logger.{type Logger}
import server/utils/time
import shared/currency.{type Currency}
import shared/rates/rate_response.{RateResponse} as shared_rate_response
import shared/subscriptions/subscription_id.{type SubscriptionId}
import shared/subscriptions/subscription_response.{
  type SubscriptionResponse, SubscriptionResponse,
}
import shared/websocket_request.{AddCurrencies, Subscribe, Unsubscribe}

pub type State {
  State(
    create_rate_subscriber: fn(SubscriptionId) -> RateSubscriber,
    rate_subscribers: Dict(SubscriptionId, RateSubscriber),
    logger: Logger,
  )
}

pub fn on_init(
  _conn: WebsocketConnection,
  cmc_currencies: List(Currency),
  request_cmc_conversion: RequestCmcConversion,
  kraken_client: KrakenClient,
  get_price_store: fn() -> PriceStore,
  logger: Logger,
) -> #(State, Option(Selector(SubscriptionResult))) {
  let subject = process.new_subject()

  let selector =
    process.new_selector()
    |> process.select_map(subject, function.identity)

  let create_rate_subscriber = fn(subscription_id) {
    let assert Ok(rate_subscriber) =
      rate_subscriber.new(
        subscription_id,
        subject,
        cmc_currencies,
        request_cmc_conversion,
        kraken_client,
        10_000,
        get_price_store,
        time.system_time_ms,
        logger.with(logger.new(), "source", "subscriber"),
      )

    rate_subscriber
  }

  log_socket_init(logger)

  #(State(create_rate_subscriber, dict.new(), logger), Some(selector))
}

pub fn handler(
  state: State,
  message: WebsocketMessage(SubscriptionResult),
  conn: WebsocketConnection,
) -> mist.Next(State, SubscriptionResult) {
  let State(create_rate_subscriber, rate_subscribers, logger) = state

  log_message_received(logger, message)

  case message {
    Text(str) -> {
      case json.parse(str, websocket_request.decoder()) {
        Ok(Subscribe(subscription_reqs)) -> {
          // Updates the rate subscribers dictionary by processing a list of subscription requests.
          // For existing subscriber IDs, reuses the subscriber and updates their subscription.
          // For new subscriber IDs, creates a new rate subscriber, subscribes them to the rate request,
          // and adds them to the dictionary. Returns the updated state with the new subscribers map.
          let updated_subscribers =
            subscription_reqs
            |> list.fold(rate_subscribers, fn(acc, subscription_req) {
              case dict.get(acc, subscription_req.id) {
                Ok(existing_subscriber) -> {
                  rate_subscriber.subscribe(
                    existing_subscriber,
                    subscription_req.rate_request,
                  )
                  acc
                }

                Error(_) -> {
                  let new_subscriber =
                    create_rate_subscriber(subscription_req.id)

                  rate_subscriber.subscribe(
                    new_subscriber,
                    subscription_req.rate_request,
                  )

                  dict.insert(acc, subscription_req.id, new_subscriber)
                }
              }
            })

          mist.continue(State(..state, rate_subscribers: updated_subscribers))
        }

        Ok(Unsubscribe(subscription_id)) -> {
          case dict.get(rate_subscribers, subscription_id) {
            Ok(subscriber) -> {
              rate_subscriber.stop(subscriber)

              let rate_subscribers =
                dict.delete(rate_subscribers, subscription_id)

              mist.continue(State(..state, rate_subscribers:))
            }

            Error(_) -> mist.continue(state)
          }
        }

        Ok(AddCurrencies([])) -> mist.continue(state)

        Ok(AddCurrencies(currencies)) -> {
          rate_subscribers
          |> dict.values
          |> list.each(rate_subscriber.add_currencies(_, currencies))

          mist.continue(state)
        }

        Error(_) -> {
          let _ = mist.send_text_frame(conn, "Failed to decode request")
          mist.continue(state)
        }
      }
    }

    Custom(#(subscription_id, rate_result)) -> {
      let response_str = case rate_result {
        Ok(rate_resp) -> {
          let subscription_resp =
            SubscriptionResponse(subscription_id, rate_resp)

          log_subscription_response_success(logger, subscription_resp)

          subscription_resp
          |> subscription_response.encode
          |> json.to_string
        }

        Error(err) -> {
          log_rate_response_error(logger, subscription_id, err)

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

pub fn on_close(state: State) -> Nil {
  state.rate_subscribers
  |> dict.values
  |> list.each(rate_subscriber.stop)

  log_socket_closed(state.logger)
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

fn log_subscription_response_success(
  logger: Logger,
  subscription_resp: SubscriptionResponse,
) -> Nil {
  let SubscriptionResponse(
    subscription_id,
    RateResponse(from, to, rate, source, timestamp),
  ) = subscription_resp

  logger
  |> logger.with("subscription_id", subscription_id.to_string(subscription_id))
  |> logger.with("rate_response.from", int.to_string(from))
  |> logger.with("rate_response.to", int.to_string(to))
  |> logger.with("rate_response.rate", float.to_string(rate))
  |> logger.with(
    "rate_response.source",
    shared_rate_response.source_to_string(source),
  )
  |> logger.with("rate_response.timestamp", int.to_string(timestamp))
  |> logger.debug("Successfully fetched subscription rate")
}

fn log_rate_response_error(
  logger: Logger,
  subscription_id: SubscriptionId,
  error: RateError,
) -> Nil {
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
  |> logger.with("subscription_id", subscription_id.to_string(subscription_id))
  |> logger.with("error", string.inspect(error))
  |> logger.with("reason", reason)
  |> logger.with("rate_request.from", int.to_string(rate_req.from))
  |> logger.with("rate_request.to", int.to_string(rate_req.to))
  |> logger.error("Error getting rate")
}
