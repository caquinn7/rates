import birdie
import gleam/json
import gleam/option.{Some}
import shared/currency.{Crypto, Fiat}
import shared/page_data.{PageData}
import shared/rates/rate_response.{Kraken, RateResponse}

pub fn encode_page_data_to_json_test() {
  PageData(
    [
      Crypto(1, "Bitcoin", "BTC", Some(1)),
      Fiat(2781, "United States Dollar", "USD", "$"),
    ],
    RateResponse(1, 2781, 100_000.0, Kraken, 1_756_654_456),
  )
  |> page_data.encode
  |> json.to_string
  |> birdie.snap("encode_page_data_to_json_test")
}
