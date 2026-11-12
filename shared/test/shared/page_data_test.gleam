import gleam/json
import gleam/option.{Some}
import gleam/string
import shared/client_state.{ConverterState}
import shared/currency.{Crypto, Fiat}
import shared/page_data.{PageData}

pub fn encode_page_data_to_json_without_rates_test() {
  let data =
    PageData(
      [
        Crypto(1, "Bitcoin", "BTC", Some(1)),
        Fiat(2781, "United States Dollar", "USD", "$"),
      ],
      [
        ConverterState(1, 2781, 1.5),
        ConverterState(1, 2781, 1.0e-10),
        ConverterState(1, 2781, 1.0e-8),
        ConverterState(1, 2781, 1.0e-7),
        ConverterState(1, 2781, 1.0e-6),
      ],
    )

  let encoded =
    data
    |> page_data.encode
    |> json.to_string

  assert !string.contains(encoded, "\"rate\":")
  assert json.parse(encoded, page_data.decoder()) == Ok(data)
}

pub fn decode_page_data_json_without_rates_test() {
  let json =
    "{\"currencies\":[{\"type\":\"crypto\",\"id\":1,\"name\":\"Bitcoin\",\"symbol\":\"BTC\",\"rank\":1},{\"type\":\"fiat\",\"id\":2781,\"name\":\"United States Dollar\",\"symbol\":\"USD\",\"sign\":\"$\"}],\"converters\":\"1-2781-1.5\"}"

  let expected =
    PageData(
      [
        Crypto(1, "Bitcoin", "BTC", Some(1)),
        Fiat(2781, "United States Dollar", "USD", "$"),
      ],
      [ConverterState(1, 2781, 1.5)],
    )

  assert json.parse(json, page_data.decoder()) == Ok(expected)
}

pub fn decode_server_seed_with_small_amount_test() {
  let json =
    "{\"currencies\":[{\"type\":\"crypto\",\"id\":1,\"name\":\"Bitcoin\",\"symbol\":\"BTC\",\"rank\":1},{\"type\":\"fiat\",\"id\":2781,\"name\":\"United States Dollar\",\"symbol\":\"USD\",\"sign\":\"$\"}],\"converters\":\"1-2781-1.0e-8\"}"

  let assert Ok(decoded) = json.parse(json, page_data.decoder())
  assert decoded.converters == [ConverterState(1, 2781, 0.00000001)]
}
