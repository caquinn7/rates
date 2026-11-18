import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Selector, type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, Some}
import gleam/string
import mist.{
  type WebsocketConnection, type WebsocketMessage, Binary, Closed, Custom,
  Shutdown, Text,
}
import server/rates/rate_error.{type RateError, CmcError, CurrencyNotFound}
import server/rates/subscriber.{type RateSubscriber, type SubscriptionResult} as rate_subscriber
import server/rates/subscriber_factory.{type SubscriberFactory}
import server/utils/logger.{type Logger}
import shared/numbers/positive_float
import shared/rates/rate_response.{type RateResponse, RateResponse}
import shared/subscriptions/subscription_id.{type SubscriptionId}
import shared/websocket_request.{Subscribe, Unsubscribe}
import shared/websocket_response.{
  type WebsocketResponse, ProtocolError, SubscriptionFailed, SubscriptionUpdate,
}

pub type State {
  State(
    /// Receives rate results from this connection's `RateSubscriber` actors.
    subject: Subject(SubscriptionResult),
    /// Subscriber actors registered on this connection, keyed by subscription ID.
    rate_subscribers: Dict(SubscriptionId, RateSubscriber),
    /// Logging context for WebSocket events and failures on this connection.
    logger: Logger,
  )
}

/// Initializes subscription state for a new connection and returns a selector
/// for rate subscriber results.
pub fn on_init(
  _conn: WebsocketConnection,
  logger: Logger,
) -> #(State, Option(Selector(SubscriptionResult))) {
  let subject = process.new_subject()

  let selector =
    process.new_selector()
    |> process.select(subject)

  log_socket_init(logger)

  #(State(subject, dict.new(), logger), Some(selector))
}

/// Handles client subscription requests and forwards rate results for active
/// subscription IDs. Sends a protocol error when a text request cannot be decoded.
pub fn handler(
  state: State,
  message: WebsocketMessage(SubscriptionResult),
  conn: WebsocketConnection,
  create_rate_subscriber: SubscriberFactory,
) -> mist.Next(State, SubscriptionResult) {
  log_message_received(state.logger, message)

  case message {
    Text(text) -> handle_text(state, text, conn, create_rate_subscriber)
    Custom(result) -> handle_rate_result(state, result, conn)
    Binary(_) -> mist.continue(state)
    Closed | Shutdown -> mist.stop()
  }
}

/// Queues a stop for each remaining rate subscriber when the connection closes.
pub fn on_close(state: State) -> Nil {
  state.rate_subscribers
  |> dict.each(fn(_, subscriber) { rate_subscriber.stop(subscriber) })

  log_socket_closed(state.logger)
}

fn handle_text(
  state: State,
  text: String,
  conn: WebsocketConnection,
  create_rate_subscriber: SubscriberFactory,
) -> mist.Next(State, SubscriptionResult) {
  let State(subject:, rate_subscribers:, logger:) = state

  case json.parse(text, websocket_request.decoder()) {
    Ok(Subscribe(subscription_reqs)) -> {
      let rate_subscribers =
        subscription_reqs
        |> list.fold(rate_subscribers, fn(subscribers, request) {
          let id = request.id

          let #(subscriber, subscribers) = case dict.get(subscribers, id) {
            Ok(subscriber) -> #(subscriber, subscribers)
            Error(_) -> {
              let subscriber = create_rate_subscriber(id, subject)
              #(subscriber, dict.insert(subscribers, id, subscriber))
            }
          }

          rate_subscriber.subscribe(subscriber, request.rate_request)
          subscribers
        })

      mist.continue(State(..state, rate_subscribers:))
    }

    Ok(Unsubscribe(subscription_id)) -> {
      case dict.get(rate_subscribers, subscription_id) {
        Ok(subscriber) -> {
          rate_subscriber.stop(subscriber)
          let rate_subscribers = dict.delete(rate_subscribers, subscription_id)
          mist.continue(State(..state, rate_subscribers:))
        }

        Error(_) -> mist.continue(state)
      }
    }

    Error(_) -> {
      send_response(conn, ProtocolError, logger)
      mist.continue(state)
    }
  }
}

fn handle_rate_result(
  state: State,
  result: SubscriptionResult,
  conn: WebsocketConnection,
) -> mist.Next(State, SubscriptionResult) {
  let #(subscription_id, rate_result) = result

  // An in-flight lookup can reply before the subscriber processes Stop.
  use <- bool.guard(
    !dict.has_key(state.rate_subscribers, subscription_id),
    mist.continue(state),
  )

  let logger = state.logger
  let response = case rate_result {
    Ok(rate_resp) -> {
      log_rate_response_success(logger, subscription_id, rate_resp)
      SubscriptionUpdate(subscription_id, rate_resp)
    }

    Error(err) -> {
      log_rate_response_error(logger, subscription_id, err)

      case err {
        CurrencyNotFound(request, id) ->
          SubscriptionFailed(
            subscription_id,
            request,
            websocket_response.CurrencyNotFound(id),
          )
        CmcError(request, _) ->
          SubscriptionFailed(
            subscription_id,
            request,
            websocket_response.RateUnavailable,
          )
      }
    }
  }

  send_response(conn, response, logger)
  mist.continue(state)
}

fn send_response(
  conn: WebsocketConnection,
  response: WebsocketResponse,
  logger: Logger,
) -> Nil {
  let frame_result =
    response
    |> websocket_response.encode
    |> json.to_string
    |> mist.send_text_frame(conn, _)

  case frame_result {
    Ok(Nil) -> Nil
    Error(reason) ->
      logger
      |> logger.with("reason", string.inspect(reason))
      |> logger.warning("Failed to send WebSocket response")
  }
}

// logging

fn log_message_received(
  logger: Logger,
  message: WebsocketMessage(SubscriptionResult),
) -> Nil {
  logger.debug_lazy(fn() {
    #(
      logger.with(logger, "received", string.inspect(message)),
      "Received websocket message",
    )
  })
}

fn log_socket_init(logger: Logger) -> Nil {
  logger
  |> logger.debug("Socket initialized")
}

fn log_socket_closed(logger: Logger) -> Nil {
  logger
  |> logger.debug("Socket closed")
}

fn log_rate_response_success(
  logger: Logger,
  subscription_id: SubscriptionId,
  rate_response: RateResponse,
) -> Nil {
  logger.debug_lazy(fn() {
    let RateResponse(from:, to:, rate:, source:, timestamp:) = rate_response

    let context =
      logger
      |> logger.with(
        "subscription_id",
        subscription_id.to_string(subscription_id),
      )
      |> logger.with("rate_response.from", int.to_string(from))
      |> logger.with("rate_response.to", int.to_string(to))
      |> logger.with(
        "rate_response.rate",
        rate
          |> option.map(positive_float.to_string)
          |> option.unwrap(""),
      )
      |> logger.with(
        "rate_response.source",
        rate_response.source_to_string(source),
      )
      |> logger.with("rate_response.timestamp", int.to_string(timestamp))

    #(context, "Successfully fetched subscription rate")
  })
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
