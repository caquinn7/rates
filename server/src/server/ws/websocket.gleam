import gleam/erlang/process.{type Selector}
import gleam/function
import gleam/json
import gleam/option.{type Option, Some}
import mist.{
  type WebsocketConnection, type WebsocketMessage, Binary, Closed, Custom,
  Shutdown, Text,
}
import server/kraken/kraken.{type Kraken}
import server/kraken/price_store.{type PriceStore}
import server/rates/actors/subscriber.{type RateSubscriber} as rate_subscriber
import server/rates/cmc_rate_handler.{type RequestCmcConversion}
import server/rates/rate_request
import server/rates/rate_response
import shared/currency.{type Currency}
import shared/rates/rate_response.{type RateResponse} as _shared_rate_response

pub fn on_init(
  _conn: WebsocketConnection,
  cmc_currencies: List(Currency),
  request_cmc_conversion: RequestCmcConversion,
  kraken_subject: Kraken,
  get_price_store: fn() -> PriceStore,
) -> #(RateSubscriber, Option(Selector(Result(RateResponse, String)))) {
  echo "socket initialized"

  let self_subject = process.new_subject()

  let selector =
    process.new_selector()
    |> process.select_map(self_subject, function.identity)

  let assert Ok(rate_subscriber) =
    rate_subscriber.new(
      self_subject,
      cmc_currencies,
      request_cmc_conversion,
      kraken_subject,
      get_price_store,
      5000,
    )

  #(rate_subscriber, Some(selector))
}

pub fn handler(
  state: RateSubscriber,
  message: WebsocketMessage(Result(RateResponse, String)),
  conn: WebsocketConnection,
) -> mist.Next(RateSubscriber, Result(RateResponse, String)) {
  case message {
    Text(str) -> {
      echo "message received: " <> str

      case json.parse(str, rate_request.decoder()) {
        Ok(rate_req) -> {
          rate_subscriber.subscribe(state, rate_req)
          mist.continue(state)
        }

        _ -> {
          let _ = mist.send_text_frame(conn, "Failed to decode rate request")
          mist.continue(state)
        }
      }
    }

    Custom(response) -> {
      let response_str =
        case response {
          Ok(rate_resp) ->
            rate_resp
            |> rate_response.encode
            |> json.to_string

          Error(err) -> {
            echo "Error getting rate: " <> err
            "Unexpected error getting rate"
          }
        }
        |> echo

      let _ = mist.send_text_frame(conn, response_str)
      mist.continue(state)
    }

    Binary(_) -> mist.continue(state)
    Closed | Shutdown -> mist.stop()
  }
}

pub fn on_close(state: RateSubscriber) -> Nil {
  echo "socket closed"
  rate_subscriber.stop(state)
  Nil
}
