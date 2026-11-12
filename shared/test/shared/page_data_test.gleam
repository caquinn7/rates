import birdie
import gleam/json
import gleam/list
import gleam/option.{Some}
import shared/client_state.{ConverterState}
import shared/currency.{Crypto, Fiat}
import shared/page_data.{PageData}

pub fn encode_page_data_to_json_without_rates_test() {
  PageData(
    [
      Crypto(1, "Bitcoin", "BTC", Some(1)),
      Fiat(2781, "United States Dollar", "USD", "$"),
    ],
    [ConverterState(1, 2781, 1.5)],
  )
  |> page_data.encode
  |> json.to_string
  |> birdie.snap("encode_page_data_to_json_without_rates_test")
}

pub fn decode_page_data_json_without_rates_test() {
  let json =
    "{\"currencies\":[{\"type\":\"crypto\",\"id\":1,\"name\":\"Bitcoin\",\"symbol\":\"BTC\",\"rank\":1},{\"type\":\"fiat\",\"id\":2781,\"name\":\"United States Dollar\",\"symbol\":\"USD\",\"sign\":\"$\"}],\"converters\":[{\"from\":1,\"to\":2781,\"amount\":1.5}]}"

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
    "{\"currencies\":[{\"type\":\"crypto\",\"id\":1,\"name\":\"Bitcoin\",\"symbol\":\"BTC\",\"rank\":1},{\"type\":\"fiat\",\"id\":2781,\"name\":\"United States Dollar\",\"symbol\":\"USD\",\"sign\":\"$\"}],\"converters\":[{\"from\":1,\"to\":2781,\"amount\":1.0e-8}]}"

  let assert Ok(decoded) = json.parse(json, page_data.decoder())
  assert decoded.converters == [ConverterState(1, 2781, 0.00000001)]
}

pub fn empty_converter_array_round_trips_test() {
  let data = PageData(currencies: [], converters: [])
  let encoded = data |> page_data.encode |> json.to_string

  assert encoded == "{\"currencies\":[],\"converters\":[]}"
  assert json.parse(encoded, page_data.decoder()) == Ok(data)
}

pub fn converter_array_preserves_order_duplicates_and_amounts_test() {
  let data =
    PageData(currencies: [], converters: [
      ConverterState(1, 2781, 0.0),
      ConverterState(1027, 2781, 42.0),
      ConverterState(1, 2781, 1.0),
      ConverterState(1, 2781, 1.5),
      ConverterState(1, 2781, 1.0e-10),
      ConverterState(1, 2781, 1.0e-8),
      ConverterState(1, 2781, 1.0e-7),
      ConverterState(1, 2781, 1.0e-6),
    ])
  let encoded =
    data
    |> page_data.encode
    |> json.to_string

  assert json.parse(encoded, page_data.decoder()) == Ok(data)
}

pub fn decode_integer_float_and_scientific_amounts_test() {
  let cases = [
    #("0", 0.0),
    #("1", 1.0),
    #("42", 42.0),
    #("1.0", 1.0),
    #("1.5", 1.5),
    #("0.00000001", 0.00000001),
    #("1e-8", 0.00000001),
    #("1.0e-8", 0.00000001),
    #("1e+8", 100_000_000.0),
  ]

  list.each(cases, fn(test_case) {
    let #(encoded_amount, amount) = test_case
    let encoded =
      page_json_with_converters(
        "[{\"from\":1,\"to\":2781,\"amount\":" <> encoded_amount <> "}]",
      )

    assert json.parse(encoded, page_data.decoder())
      == Ok(PageData([], [ConverterState(1, 2781, amount)]))
  })
}

pub fn decode_rejects_non_array_converters_test() {
  list.each(["\"1-2781-1.5\"", "null", "{}", "1", "true"], fn(converters) {
    let encoded = page_json_with_converters(converters)
    let assert Error(_) = json.parse(encoded, page_data.decoder())
  })
}

pub fn decode_rejects_malformed_converter_entries_test() {
  list.each(["null", "[]", "\"1-2781\"", "true", "42", "{}"], fn(entry) {
    let encoded =
      page_json_with_converters(
        "[{\"from\":1,\"to\":2781,\"amount\":1}," <> entry <> "]",
      )

    let assert Error(_) = json.parse(encoded, page_data.decoder())
  })
}

pub fn decode_rejects_missing_converter_fields_test() {
  let assert Error(_) = json.parse("{\"currencies\":[]}", page_data.decoder())

  let incomplete_converters = [
    "{\"to\":2781,\"amount\":1}",
    "{\"from\":1,\"amount\":1}",
    "{\"from\":1,\"to\":2781}",
  ]

  list.each(incomplete_converters, fn(converter) {
    let encoded = page_json_with_converters("[" <> converter <> "]")
    let assert Error(_) = json.parse(encoded, page_data.decoder())
  })
}

pub fn decode_rejects_incorrect_converter_field_types_test() {
  let invalid_converters = [
    "{\"from\":\"1\",\"to\":2781,\"amount\":1}",
    "{\"from\":1.5,\"to\":2781,\"amount\":1}",
    "{\"from\":null,\"to\":2781,\"amount\":1}",
    "{\"from\":1,\"to\":\"2781\",\"amount\":1}",
    "{\"from\":1,\"to\":2781.5,\"amount\":1}",
    "{\"from\":1,\"to\":null,\"amount\":1}",
    "{\"from\":1,\"to\":2781,\"amount\":\"1\"}",
    "{\"from\":1,\"to\":2781,\"amount\":null}",
    "{\"from\":1,\"to\":2781,\"amount\":false}",
    "{\"from\":1,\"to\":2781,\"amount\":{}}",
    "{\"from\":1,\"to\":2781,\"amount\":[]}",
  ]

  list.each(invalid_converters, fn(converter) {
    let encoded = page_json_with_converters("[" <> converter <> "]")
    let assert Error(_) = json.parse(encoded, page_data.decoder())
  })
}

fn page_json_with_converters(converters: String) -> String {
  "{\"currencies\":[],\"converters\":" <> converters <> "}"
}
