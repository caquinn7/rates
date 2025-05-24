import birdie
import client/start_data.{StartData} as _client_start_data
import gleam/json
import gleam/option.{Some}
import server/routes/home/start_data
import shared/currency.{Crypto, Fiat}
import shared/rates/rate_response.{RateResponse}

pub fn encode_start_data_to_json_test() {
  StartData(
    [
      Crypto(1, "Bitcoin", "BTC", Some(1)),
      Fiat(2781, "United States Dollar", "USD", "$"),
    ],
    RateResponse(1, 2781, 100_000.0),
  )
  |> start_data.encode
  |> json.to_string
  |> birdie.snap("encode_start_data_to_json_test")
}
