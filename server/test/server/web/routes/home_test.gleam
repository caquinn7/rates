import gleam/option.{None, Some}
import server/domain/rates/rate_error.{CurrencyNotFound}
import server/web/routes/home
import shared/converter_input_state.{ConverterInputState}
import shared/currency.{Crypto, Fiat}
import shared/page_data.{PageData}
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{Kraken, RateResponse}

pub fn get_page_data_returns_error_when_state_is_empty_and_btc_not_found_test() {
  let currencies = [Fiat(2781, "", "", "")]
  let get_rate = fn(_) { panic }

  assert home.get_page_data(currencies, get_rate, []) == Error(Nil)
}

pub fn get_page_data_returns_error_when_state_is_empty_and_usd_not_found_test() {
  let currencies = [Crypto(1, "", "", None)]
  let get_rate = fn(_) { panic }

  assert home.get_page_data(currencies, get_rate, []) == Error(Nil)
}

pub fn get_page_data_returns_error_when_no_rate_successfully_fetched_test() {
  let currencies = [Crypto(1, "", "", None), Fiat(2781, "", "", "")]
  let get_rate = fn(rate_req) {
    Error(CurrencyNotFound(rate_req, rate_req.from))
  }
  let state = [ConverterInputState(1, 2781, "0.5")]

  assert home.get_page_data(currencies, get_rate, state) == Error(Nil)
}

pub fn get_page_data_returns_ok_when_rate_successfully_fetched_test() {
  let currencies = [
    Crypto(1, "", "", None),
    Fiat(2781, "", "", ""),
    Crypto(2, "", "", None),
  ]

  let get_rate = fn(rate_req: RateRequest) {
    case rate_req.from {
      1 -> Ok(RateResponse(rate_req.from, rate_req.to, Some(1.5), Kraken, 1))
      _ -> Error(CurrencyNotFound(rate_req, rate_req.from))
    }
  }

  let state = [
    ConverterInputState(1, 2781, "0.5"),
    ConverterInputState(2, 2781, "0.75"),
  ]

  let assert Ok(result) = home.get_page_data(currencies, get_rate, state)

  assert result
    == PageData(
      currencies,
      [RateResponse(1, 2781, Some(1.5), Kraken, 1)],
      state,
    )
}
