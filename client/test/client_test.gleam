import client.{Model}
import client/non_negative_float
import client/side.{Left, Right}
import client/ui/converter
import gleam/option.{None, Some}
import gleeunit
import shared/client_state.{ConverterState}
import shared/currency.{Crypto, Fiat}
import shared/page_data.{PageData}
import shared/rates/rate_response.{Kraken, RateResponse}

pub fn main() {
  gleeunit.main()
}

// model_from_page_data

pub fn model_from_page_data_constructs_model_test() {
  let currencies = [
    Fiat(1, "United States Dollar", "USD", "$"),
    Crypto(2, "Bitcoin", "BTC", Some(1)),
    Crypto(3, "Ethereum", "ETH", Some(2)),
  ]

  let converter_states = [
    ConverterState(from: 1, to: 2, amount: 100.0),
    ConverterState(from: 2, to: 3, amount: 2.5),
  ]

  let rates = [
    RateResponse(
      from: 1,
      to: 2,
      rate: Some(0.000015),
      source: Kraken,
      timestamp: 1_700_000_000,
    ),
    RateResponse(
      from: 2,
      to: 3,
      rate: Some(15.5),
      source: Kraken,
      timestamp: 1_700_000_000,
    ),
  ]

  let page_data = PageData(currencies:, rates:, converters: converter_states)

  let assert Ok(model) = client.model_from_page_data(page_data)

  // Verify the Model structure
  assert model.currencies == currencies
  assert model.socket == None
  assert model.reconnect_attempts == 0

  // Verify converters were created correctly
  let assert [converter1, converter2] = model.converters

  // Check converter IDs
  assert converter1.id == "converter-1"
  assert converter2.id == "converter-2"

  // Check converter currency selections
  assert converter.get_selected_currency_id(converter1, Left) == 1
  assert converter.get_selected_currency_id(converter1, Right) == 2
  assert converter.get_selected_currency_id(converter2, Left) == 2
  assert converter.get_selected_currency_id(converter2, Right) == 3

  // Check converter amounts
  assert converter.get_parsed_amount(converter1, Left)
    == Some(non_negative_float.from_float_unsafe(100.0))
  assert converter.get_parsed_amount(converter2, Left)
    == Some(non_negative_float.from_float_unsafe(2.5))

  // Check converter rates
  assert converter1.rate == Some(non_negative_float.from_float_unsafe(0.000015))
  assert converter2.rate == Some(non_negative_float.from_float_unsafe(15.5))
}

pub fn model_from_page_data_filters_out_converters_without_a_matching_rate_response_test() {
  let currencies = [
    Fiat(1, "United States Dollar", "USD", "$"),
    Crypto(2, "Bitcoin", "BTC", Some(1)),
    Crypto(3, "Ethereum", "ETH", Some(2)),
    Crypto(4, "Cardano", "ADA", Some(3)),
  ]

  let converter_states = [
    ConverterState(from: 1, to: 2, amount: 100.0),
    ConverterState(from: 2, to: 3, amount: 2.5),
    ConverterState(from: 3, to: 4, amount: 50.0),
  ]

  let rates = [
    // Only RateResponse for first converter (1 -> 2)
    RateResponse(
      from: 1,
      to: 2,
      rate: Some(0.000015),
      source: Kraken,
      timestamp: 1_700_000_000,
    ),
    // RateResponse with partial match - from matches but to doesn't
    RateResponse(
      from: 2,
      to: 4,
      rate: Some(10.0),
      source: Kraken,
      timestamp: 1_700_000_000,
    ),
    // RateResponse with no match at all
    RateResponse(
      from: 4,
      to: 1,
      rate: Some(25.0),
      source: Kraken,
      timestamp: 1_700_000_000,
    ),
  ]

  let page_data = PageData(currencies:, rates:, converters: converter_states)

  let assert Ok(model) = client.model_from_page_data(page_data)

  // Only the first converter should be created since it's the only one with a matching rate
  let assert [converter1] = model.converters

  assert converter1.id == "converter-1"
  assert converter.get_selected_currency_id(converter1, Left) == 1
  assert converter.get_selected_currency_id(converter1, Right) == 2
  assert converter.get_parsed_amount(converter1, Left)
    == Some(non_negative_float.from_float_unsafe(100.0))
}

// model_to_client_state

pub fn model_to_client_state_with_multiple_converters_test() {
  let currencies = [
    Fiat(1, "United States Dollar", "USD", "$"),
    Crypto(2, "Bitcoin", "BTC", Some(1)),
    Crypto(3, "Ethereum", "ETH", Some(2)),
  ]

  let assert Ok(converter1) =
    converter.new("converter-1", currencies, #(1, 2), "100", None)
  let assert Ok(converter2) =
    converter.new("converter-2", currencies, #(2, 3), "2.5", None)
  let assert Ok(converter3) =
    converter.new("converter-3", currencies, #(3, 1), "500", None)

  let model =
    Model(
      currencies: currencies,
      converters: [converter1, converter2, converter3],
      socket: None,
      reconnect_attempts: 0,
    )

  let result = client.model_to_client_state(model)

  assert result.converters
    == [
      ConverterState(from: 1, to: 2, amount: 100.0),
      ConverterState(from: 2, to: 3, amount: 2.5),
      ConverterState(from: 3, to: 1, amount: 500.0),
    ]
}

pub fn model_to_client_state_uses_default_amount_when_unparseable_test() {
  let currencies = [
    Fiat(1, "United States Dollar", "USD", "$"),
    Crypto(2, "Bitcoin", "BTC", Some(1)),
  ]

  let assert Ok(converter1) =
    converter.new("converter-1", currencies, #(1, 2), "100", None)

  // Set an unparseable amount by using with_amount with an invalid string
  let converter_with_bad_amount =
    converter.with_amount(converter1, Left, "not a number")

  let model =
    Model(
      currencies: currencies,
      converters: [converter_with_bad_amount],
      socket: None,
      reconnect_attempts: 0,
    )

  let result = client.model_to_client_state(model)

  // When amount is unparseable, it should default to 1.0
  assert result.converters == [ConverterState(from: 1, to: 2, amount: 1.0)]
}
