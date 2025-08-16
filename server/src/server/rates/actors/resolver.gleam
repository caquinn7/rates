/// A short-lived actor for resolving a single exchange rate.
///
/// The `RateResolver` actor attempts to fetch the exchange rate for a given
/// currency pair using Kraken, falling back to CoinMarketCap (CMC) if needed.
/// This actor is designed for one-shot use and terminates after handling a single
/// `GetRate` message.
///
/// Kraken is preferred as the source of truth if the currency pair is supported
/// and the price becomes available within a short polling window.
/// Otherwise, the actor gracefully falls back to CMC.
///
/// Usage:
///   - Start a new `RateResolver` with `new`.
///   - Send a `GetRate` message using `get_rate`.
///   - The actor automatically stops after sending its response.
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor.{type Next, type StartError}
import gleam/result
import server/kraken/kraken.{type Kraken}
import server/kraken/price_store.{type PriceStore}
import server/rates/actors/kraken_symbol
import server/rates/actors/utils
import server/rates/cmc_rate_handler.{
  type RateRequestError, type RequestCmcConversion,
}
import shared/currency.{type Currency}
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{type RateResponse, Kraken, RateResponse}

pub opaque type RateResolver {
  RateResolver(Subject(Msg))
}

pub type RateError {
  CurrencyNotFound(Int)
  CmcError(RateRequestError)
}

type Msg {
  GetRate(Subject(Result(RateResponse, RateError)), RateRequest)
}

type State {
  State(
    cmc_currencies: Dict(Int, String),
    kraken: Kraken,
    price_store: PriceStore,
    request_cmc_conversion: RequestCmcConversion,
  )
}

pub fn new(
  cmc_currencies: List(Currency),
  kraken: Kraken,
  request_cmc_conversion: RequestCmcConversion,
  get_price_store: fn() -> PriceStore,
) -> Result(RateResolver, StartError) {
  let currency_dict =
    cmc_currencies
    |> list.map(fn(c) { #(c.id, c.symbol) })
    |> dict.from_list

  let price_store = get_price_store()

  let initial_state =
    State(currency_dict, kraken, price_store, request_cmc_conversion)

  let msg_loop = fn(state, msg) {
    handle_msg(state, msg, request_cmc_conversion)
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
) -> Next(State, Msg) {
  case msg {
    GetRate(reply_to, rate_req) -> {
      rate_req
      |> utils.resolve_currency_symbols(state.cmc_currencies)
      |> result.map_error(fn(err) {
        let utils.CurrencyNotFound(id) = err
        process.send(reply_to, Error(CurrencyNotFound(id)))
        actor.stop()
      })
      |> result.map(fn(symbols) {
        case kraken_symbol.new(symbols) {
          Error(_) ->
            handle_cmc_fallback(rate_req, request_cmc_conversion, reply_to)

          Ok(kraken_symbol) -> {
            let symbol_str = kraken_symbol.to_string(kraken_symbol)
            kraken.subscribe(state.kraken, symbol_str)

            let kraken_price_result =
              utils.wait_for_kraken_price(
                kraken_symbol,
                state.price_store,
                5,
                50,
              )

            case kraken_price_result {
              Error(_) ->
                handle_cmc_fallback(rate_req, request_cmc_conversion, reply_to)

              Ok(rate) -> {
                kraken.unsubscribe(state.kraken, symbol_str)

                process.send(
                  reply_to,
                  Ok(RateResponse(rate_req.from, rate_req.to, rate, Kraken)),
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
) -> Next(State, Msg) {
  case cmc_rate_handler.get_rate(rate_req, request_cmc_conversion) {
    Error(err) -> {
      process.send(reply_to, Error(CmcError(err)))
      actor.stop()
    }

    Ok(rate_resp) -> {
      process.send(reply_to, Ok(rate_resp))
      actor.stop()
    }
  }
}
