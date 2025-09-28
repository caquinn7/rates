//// A short-lived actor for resolving a single exchange rate.
////
//// The `RateResolver` actor attempts to fetch the exchange rate for a given
//// currency pair using Kraken, falling back to CoinMarketCap (CMC) if needed.
//// This actor is designed for one-shot use and terminates after handling a single
//// `GetRate` message.
////
//// Kraken is preferred as the source of truth if the currency pair is supported
//// and the price becomes available within a short polling window.
//// Otherwise, the actor gracefully falls back to CMC.
////
//// Usage:
////   - Start a new `RateResolver` with `new`.
////   - Send a `GetRate` message using `get_rate`.
////   - The actor automatically stops after sending its response.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor.{type Next, type StartError}
import gleam/result
import server/domain/rates/internal/cmc_rate_handler.{type RequestCmcConversion}
import server/domain/rates/internal/kraken_symbol
import server/domain/rates/internal/utils
import server/domain/rates/rate_error.{
  type RateError, CmcError, CurrencyNotFound,
}
import server/integrations/kraken/client.{type KrakenClient}
import server/integrations/kraken/pairs
import server/integrations/kraken/price_store.{type PriceStore}
import shared/currency.{type Currency}
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{type RateResponse, Kraken, RateResponse}

pub opaque type RateResolver {
  RateResolver(Subject(Msg))
}

type Msg {
  GetRate(Subject(Result(RateResponse, RateError)), RateRequest)
}

type State {
  State(
    cmc_currencies: Dict(Int, String),
    kraken_client: KrakenClient,
    kraken_price_store: PriceStore,
    request_cmc_conversion: RequestCmcConversion,
  )
}

pub fn new(
  cmc_currencies: List(Currency),
  kraken_client: KrakenClient,
  request_cmc_conversion: RequestCmcConversion,
  get_kraken_price_store: fn() -> PriceStore,
  get_current_time_ms: fn() -> Int,
) -> Result(RateResolver, StartError) {
  let currency_dict =
    cmc_currencies
    |> list.map(fn(c) { #(c.id, c.symbol) })
    |> dict.from_list

  let price_store = get_kraken_price_store()

  let initial_state =
    State(currency_dict, kraken_client, price_store, request_cmc_conversion)

  let msg_loop = fn(state, msg) {
    handle_msg(state, msg, request_cmc_conversion, get_current_time_ms)
  }

  initial_state
  |> actor.new
  |> actor.on_message(msg_loop)
  |> actor.start
  |> result.map(fn(started) { RateResolver(started.data) })
}

pub fn get_rate(
  resolver: RateResolver,
  rate_request: RateRequest,
  timeout: Int,
) -> Result(RateResponse, RateError) {
  let RateResolver(subject) = resolver
  actor.call(subject, timeout, GetRate(_, rate_request))
}

fn handle_msg(
  state: State,
  msg: Msg,
  request_cmc_conversion: RequestCmcConversion,
  get_current_time_ms: fn() -> Int,
) -> Next(State, Msg) {
  case msg {
    GetRate(reply_to, rate_req) -> {
      rate_req
      |> utils.resolve_currency_symbols(state.cmc_currencies)
      |> result.map_error(fn(err) {
        let utils.CurrencyNotFound(id) = err
        process.send(reply_to, Error(CurrencyNotFound(rate_req, id)))
        actor.stop()
      })
      |> result.map(fn(symbols) {
        case kraken_symbol.new(symbols, pairs.exists) {
          Error(_) ->
            handle_cmc_fallback(
              rate_req,
              request_cmc_conversion,
              reply_to,
              get_current_time_ms,
            )

          Ok(kraken_symbol) -> {
            utils.subscribe_to_kraken(state.kraken_client, kraken_symbol)

            let kraken_price_result =
              utils.wait_for_kraken_price(
                kraken_symbol,
                state.kraken_price_store,
                5,
                50,
              )

            case kraken_price_result {
              Error(_) ->
                handle_cmc_fallback(
                  rate_req,
                  request_cmc_conversion,
                  reply_to,
                  get_current_time_ms,
                )

              Ok(price_entry) -> {
                utils.unsubscribe_from_kraken(
                  state.kraken_client,
                  kraken_symbol,
                )

                let rate =
                  kraken_symbol.apply_price_direction(
                    kraken_symbol,
                    price_entry.price,
                  )

                process.send(
                  reply_to,
                  Ok(RateResponse(
                    rate_req.from,
                    rate_req.to,
                    rate,
                    Kraken,
                    price_entry.timestamp,
                  )),
                )

                actor.stop()
              }
            }
          }
        }
      })
      |> result.unwrap_both()
    }
  }
}

fn handle_cmc_fallback(
  rate_req: RateRequest,
  request_cmc_conversion: RequestCmcConversion,
  reply_to: Subject(Result(RateResponse, RateError)),
  get_current_time_ms: fn() -> Int,
) -> Next(State, Msg) {
  let result =
    cmc_rate_handler.get_rate(
      rate_req,
      request_cmc_conversion,
      get_current_time_ms,
    )

  case result {
    Error(err) -> {
      process.send(reply_to, Error(CmcError(rate_req, err)))
      actor.stop()
    }

    Ok(rate_resp) -> {
      process.send(reply_to, Ok(rate_resp))
      actor.stop()
    }
  }
}
