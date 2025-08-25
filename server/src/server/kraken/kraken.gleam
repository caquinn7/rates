/// An actor responsible for managing a live WebSocket connection to the Kraken
/// exchange and distributing real-time price updates to interested processes.
///
/// This module handles:
/// - Connecting to Kraken’s WebSocket v2 API
/// - Subscribing to and unsubscribing from ticker channels
/// - Tracking which symbols are actively subscribed and by how many clients
/// - Writing the latest prices to a shared `PriceStore`
/// - Populating the global `pairs` registry with the set of supported symbols
///
/// Price updates are stored in a shared `PriceStore`, which other parts of the
/// application can query independently. Supported trading pairs are also exposed
/// globally via the `pairs` module, which is updated during the initial
/// instrument subscription.
///
/// Use `new` to create the actor and start the WebSocket session. Use
/// `subscribe` and `unsubscribe` to manage interest in specific symbols.
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/http/request as http_request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor.{type StartError, type Started}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import glight
import server/kraken/pairs
import server/kraken/price_store.{type PriceStore}
import server/kraken/request.{
  type KrakenRequest, Instruments, KrakenRequest, Tickers,
}
import server/kraken/response.{
  InstrumentsResponse, TickerResponse, TickerSubscribeConfirmation,
}
import stratus.{
  type Connection, type InternalMessage, type Message, Binary, Text, User,
}

pub opaque type Kraken {
  Kraken(subject: Subject(Msg))
}

type Msg {
  Init(Subject(stratus.InternalMessage(WebsocketMsg)))
  SetSupportedSymbols(Set(String))
  Subscribe(String)
  ConfirmSubscribe(String)
  Unsubscribe(String)
  UpdatePrice(String, Float)
}

type State {
  State(
    websocket_subject: Option(Subject(stratus.InternalMessage(WebsocketMsg))),
    supported_symbols: Set(String),
    pending_subscriptions: Dict(String, Int),
    active_subscriptions: Dict(String, Int),
    price_store: Option(PriceStore),
  )
}

pub fn new(create_price_store: fn() -> PriceStore) -> Result(Kraken, StartError) {
  let intitial_state = State(None, set.new(), dict.new(), dict.new(), None)
  let msg_loop = fn(state, msg) { kraken_loop(state, msg, create_price_store) }

  use kraken_subject <- result.try(
    intitial_state
    |> actor.new
    |> actor.on_message(msg_loop)
    |> actor.start
    |> result.map(fn(started) { started.data }),
  )

  use websocket_subject <- result.try(
    kraken_subject
    |> init_websocket
    |> result.map(fn(started) { started.data }),
  )

  actor.send(kraken_subject, Init(websocket_subject))
  Ok(Kraken(kraken_subject))
}

pub fn subscribe(kraken: Kraken, symbol: String) -> Nil {
  let Kraken(kraken_subject) = kraken
  actor.send(kraken_subject, Subscribe(symbol))
}

pub fn unsubscribe(kraken: Kraken, symbol: String) -> Nil {
  let Kraken(kraken_subject) = kraken
  actor.send(kraken_subject, Unsubscribe(symbol))
}

fn kraken_loop(
  state: State,
  msg: Msg,
  create_price_store: fn() -> PriceStore,
) -> actor.Next(State, Msg) {
  let State(
    maybe_websocket_subject,
    supported_symbols,
    pending_subscriptions,
    active_subscriptions,
    maybe_price_store,
  ) = state

  case msg {
    Init(websocket_subject) -> {
      KrakenRequest(request.Subscribe, Instruments, None)
      |> Request
      |> stratus.to_user_message
      |> actor.send(websocket_subject, _)

      State(
        ..state,
        websocket_subject: Some(websocket_subject),
        price_store: Some(create_price_store()),
      )
      |> actor.continue
    }

    SetSupportedSymbols(symbols) -> {
      // Updates the set of supported symbols based on Kraken's latest Instruments response.
      log_symbols_received(symbols)
      pairs.set(symbols)

      let assert Some(websocket_subject) = maybe_websocket_subject
      KrakenRequest(request.Unsubscribe, Instruments, None)
      |> Request
      |> stratus.to_user_message
      |> actor.send(websocket_subject, _)

      actor.continue(State(..state, supported_symbols: symbols))
    }

    Subscribe(symbol) -> {
      // Handles a subscribe request from a client.
      // - If already subscribed, increment the active subscription count.
      // - If not subscribed, and the symbol is supported, send a Kraken subscribe request and track it as pending.
      // - Ignore unsupported symbols.
      case dict.get(active_subscriptions, symbol) {
        // no one has subscribed to symbol yet
        Error(_) -> {
          case set.contains(supported_symbols, symbol) {
            // symbol is not supported. just continue
            False -> actor.continue(state)

            // symbol is supported. request subscription from kraken
            True -> {
              let assert Some(websocket_subject) = maybe_websocket_subject

              KrakenRequest(request.Subscribe, Tickers([symbol]), None)
              |> Request
              |> stratus.to_user_message
              |> actor.send(websocket_subject, _)

              let pending_subscriptions =
                dict.upsert(pending_subscriptions, symbol, fn(maybe_count) {
                  case maybe_count {
                    None -> 1
                    Some(i) -> i + 1
                  }
                })

              {
                let assert Ok(pending_count) =
                  dict.get(pending_subscriptions, symbol)

                log_subscription_debug(
                  symbol,
                  pending_count,
                  "Incremented pending subscription count",
                )
              }

              actor.continue(State(..state, pending_subscriptions:))
            }
          }
        }

        // someone is already subscribed. increment the count
        Ok(current_count) -> {
          let new_count = current_count + 1

          let active_subscriptions =
            dict.insert(active_subscriptions, symbol, new_count)

          log_subscription_debug(
            symbol,
            new_count,
            "Incremented active subscription count",
          )

          actor.continue(State(..state, active_subscriptions:))
        }
      }
    }

    ConfirmSubscribe(symbol) -> {
      // Handles Kraken's confirmation that a subscription was successful for a symbol.
      // This marks the subscription as fully active by:
      // - Moving the pending subscription count into the active subscriptions map.
      // - Deleting the symbol from the pending subscriptions map.
      // This is safe because ConfirmSubscribe should only arrive for symbols the actor explicitly requested to subscribe.
      let assert Ok(pending_count) = dict.get(pending_subscriptions, symbol)
      let active_subscriptions =
        dict.insert(active_subscriptions, symbol, pending_count)

      let pending_subscriptions = dict.delete(pending_subscriptions, symbol)

      log_subscription_confirmed(symbol)

      actor.continue(
        State(..state, active_subscriptions:, pending_subscriptions:),
      )
    }

    Unsubscribe(symbol) -> {
      // Handles a client's request to unsubscribe from a symbol.
      // Decrements the pending or active subscription count for the symbol, depending on which state it's in.
      // If there are still clients interested (pending or active), update the state and continue.
      // If there are no more clients interested (total_interest == 0):
      // - Send an Unsubscribe request to Kraken for the symbol.
      // - Remove the symbol from both pending and active subscription maps to clean up the state.
      let pending_subscriptions = case dict.get(pending_subscriptions, symbol) {
        Error(_) -> pending_subscriptions
        Ok(count) -> dict.insert(pending_subscriptions, symbol, count - 1)
      }

      let active_subscriptions = case dict.get(active_subscriptions, symbol) {
        Error(_) -> active_subscriptions
        Ok(count) -> dict.insert(active_subscriptions, symbol, count - 1)
      }

      let pending_count = case dict.get(pending_subscriptions, symbol) {
        Error(_) -> 0
        Ok(count) -> count
      }

      let subscribed_count = case dict.get(active_subscriptions, symbol) {
        Error(_) -> 0
        Ok(count) -> count
      }

      let total_interest = pending_count + subscribed_count
      case total_interest == 0 {
        False ->
          actor.continue(
            State(..state, pending_subscriptions:, active_subscriptions:),
          )

        True -> {
          let assert Some(websocket_subject) = maybe_websocket_subject

          KrakenRequest(request.Unsubscribe, Tickers([symbol]), None)
          |> Request
          |> stratus.to_user_message
          |> actor.send(websocket_subject, _)

          let pending_subscriptions = dict.delete(pending_subscriptions, symbol)
          let active_subscriptions = dict.delete(active_subscriptions, symbol)

          actor.continue(
            State(..state, pending_subscriptions:, active_subscriptions:),
          )
        }
      }
    }

    UpdatePrice(symbol, price) ->
      case dict.get(active_subscriptions, symbol) {
        Error(_) -> actor.continue(state)
        Ok(_) -> {
          log_price_update(symbol, price)

          let assert Some(price_store) = maybe_price_store
          price_store.insert(price_store, symbol, price)
          actor.continue(state)
        }
      }
  }
}

type WebsocketMsg {
  Request(KrakenRequest)
}

fn init_websocket(
  reply_to: Subject(Msg),
) -> Result(Started(Subject(InternalMessage(WebsocketMsg))), StartError) {
  let assert Ok(req) = http_request.to("https://ws.kraken.com/v2")
  stratus.websocket(
    request: req,
    init: fn() { #(reply_to, None) },
    loop: websocket_loop,
  )
  |> stratus.on_close(fn(_state) {
    glight.info(kraken_logger(), "kraken socket closed")
    Nil
  })
  |> stratus.initialize
}

fn websocket_loop(
  state: Subject(Msg),
  msg: Message(WebsocketMsg),
  conn: Connection,
) -> stratus.Next(Subject(Msg), WebsocketMsg) {
  case msg {
    Text(str) -> {
      log_message_from_kraken(str)

      case json.parse(str, response.decoder()) {
        Error(_) -> stratus.continue(state)

        Ok(InstrumentsResponse(pairs)) -> {
          let symbols =
            pairs
            |> list.map(fn(p) { p.symbol })
            |> set.from_list

          actor.send(state, SetSupportedSymbols(symbols))
          stratus.continue(state)
        }

        Ok(TickerSubscribeConfirmation(symbol)) -> {
          actor.send(state, ConfirmSubscribe(symbol))
          stratus.continue(state)
        }

        Ok(TickerResponse(symbol, price)) -> {
          actor.send(state, UpdatePrice(symbol, price))
          stratus.continue(state)
        }
      }
    }

    User(Request(kraken_req)) -> {
      let json_str =
        kraken_req
        |> request.encode
        |> json.to_string

      case stratus.send_text_message(conn, json_str) {
        Error(err) -> {
          log_message_send_error(err)
          stratus.continue(state)
        }

        Ok(_) -> stratus.continue(state)
      }
    }

    Binary(_) -> stratus.continue(state)
  }
}

// logging

fn kraken_logger() -> Dict(String, String) {
  glight.logger()
  |> glight.with("source", "kraken")
}

fn log_symbols_received(symbols: Set(String)) -> Nil {
  glight.info(
    kraken_logger()
      |> glight.with("count", int.to_string(set.size(symbols))),
    "Received pair symbols from Kraken",
  )
  Nil
}

fn log_subscription_debug(symbol: String, count: Int, message: String) -> Nil {
  glight.debug(
    kraken_logger()
      |> glight.with("symbol", symbol)
      |> glight.with("count", int.to_string(count)),
    message,
  )
  Nil
}

fn log_subscription_confirmed(symbol: String) -> Nil {
  glight.debug(
    kraken_logger() |> glight.with("symbol", symbol),
    "Subscription confirmed",
  )
  Nil
}

fn log_price_update(symbol: String, price: Float) -> Nil {
  glight.debug(
    kraken_logger()
      |> glight.with("symbol", symbol)
      |> glight.with("price", float.to_string(price)),
    "Received price update",
  )
  Nil
}

fn log_message_send_error(err) -> Nil {
  glight.error(
    kraken_logger()
      |> glight.with("error", string.inspect(err)),
    "failed to send message to kraken",
  )
  Nil
}

fn log_message_from_kraken(message) {
  glight.debug(
    kraken_logger()
      |> glight.with("received", message),
    "received message from kraken",
  )
}
