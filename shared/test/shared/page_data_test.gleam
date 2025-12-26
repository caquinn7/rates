import gleam/json
import gleam/option.{Some}
import shared/client_state.{ConverterState}
import shared/currency.{Crypto, Fiat}
import shared/page_data.{PageData}
import shared/positive_float
import shared/rates/rate_response.{Kraken, RateResponse}

pub fn encode_page_data_to_json_test() {
  let page_data =
    PageData(
      [
        Crypto(1, "Bitcoin", "BTC", Some(1)),
        Fiat(2781, "United States Dollar", "USD", "$"),
      ],
      [
        RateResponse(
          1,
          2781,
          Some(positive_float.from_float_unsafe(100_000.0)),
          Kraken,
          1_756_654_456,
        ),
      ],
      [ConverterState(1, 2781, 1.5)],
    )

  let result =
    page_data
    |> page_data.encode
    |> json.to_string
    |> json.parse(page_data.decoder())

  assert result == Ok(page_data)
}

pub fn decode_page_data_json_test() {
  let json =
    "{\"currencies\":[{\"type\":\"crypto\",\"id\":1,\"name\":\"Bitcoin\",\"symbol\":\"BTC\",\"rank\":1},{\"type\":\"fiat\",\"id\":2781,\"name\":\"United States Dollar\",\"symbol\":\"USD\",\"sign\":\"$\"}],\"rate\":[{\"from\":1,\"to\":2781,\"rate\":1.0e5,\"source\":\"Kraken\",\"timestamp\":1756654456}],\"converters\":\"1-2781-1.5\"}"

  let expected =
    PageData(
      [
        Crypto(1, "Bitcoin", "BTC", Some(1)),
        Fiat(2781, "United States Dollar", "USD", "$"),
      ],
      [
        RateResponse(
          1,
          2781,
          Some(positive_float.from_float_unsafe(100_000.0)),
          Kraken,
          1_756_654_456,
        ),
      ],
      [ConverterState(1, 2781, 1.5)],
    )

  assert json.parse(json, page_data.decoder()) == Ok(expected)
}
