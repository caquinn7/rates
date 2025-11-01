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
    [RateResponse(1, 2781, Some(100_000.0), Kraken, 1_756_654_456)],
  )
  |> page_data.encode
  |> json.to_string
  |> birdie.snap("encode_page_data_to_json_test")
}

pub fn decode_page_data_json_test() {
  let json =
    "{\"currencies\":[{\"type\":\"crypto\",\"id\":1,\"name\":\"Bitcoin\",\"symbol\":\"BTC\",\"rank\":1},{\"type\":\"fiat\",\"id\":2781,\"name\":\"United States Dollar\",\"symbol\":\"USD\",\"sign\":\"$\"}],\"rate\":[{\"from\":1,\"to\":2781,\"rate\":1.0e5,\"source\":\"Kraken\",\"timestamp\":1756654456}]}"

  let expected =
    PageData(
      [
        Crypto(1, "Bitcoin", "BTC", Some(1)),
        Fiat(2781, "United States Dollar", "USD", "$"),
      ],
      [RateResponse(1, 2781, Some(100_000.0), Kraken, 1_756_654_456)],
    )

  assert Ok(expected) == json.parse(json, page_data.decoder())
}
