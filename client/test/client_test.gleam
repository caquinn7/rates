import client.{Model}
import client/side.{Left}
import client/ui/converter
import gleam/option.{None, Some}
import gleeunit
import shared/client_state.{ConverterState}
import shared/currency.{Crypto, Fiat}

pub fn main() {
  gleeunit.main()
}

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
      added_currencies: [],
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

pub fn model_to_client_state_filters_unused_added_currencies_test() {
  let currencies = [
    Fiat(1, "United States Dollar", "USD", "$"),
    Crypto(2, "Bitcoin", "BTC", Some(1)),
    Crypto(3, "Ethereum", "ETH", Some(2)),
    Crypto(4, "Cardano", "ADA", Some(3)),
    Crypto(5, "Solana", "SOL", Some(4)),
  ]

  let assert Ok(converter1) =
    converter.new("converter-1", currencies, #(1, 2), "100", None)

  // added_currencies includes IDs for ADA (4), SOL (5), and ETH (3)
  // but only ETH would be filtered out since it's not used by any converter
  let model =
    Model(
      currencies: currencies,
      added_currencies: [3, 4, 5],
      converters: [converter1],
      socket: None,
      reconnect_attempts: 0,
    )

  let result = client.model_to_client_state(model)

  // Only converters using currencies 1 (USD) and 2 (BTC) exist,
  // so none of the added currencies should be included
  assert result.added_currencies == []
}

pub fn model_to_client_state_filters_added_currencies_not_in_master_list_test() {
  let currencies = [
    Fiat(1, "United States Dollar", "USD", "$"),
    Crypto(2, "Bitcoin", "BTC", Some(1)),
    Crypto(3, "Ethereum", "ETH", Some(2)),
  ]

  let assert Ok(converter1) =
    converter.new("converter-1", currencies, #(1, 3), "100", None)

  // added_currencies includes ID 3 (ETH, which is used) and ID 999 (doesn't exist)
  let model =
    Model(
      currencies: currencies,
      added_currencies: [3, 999],
      converters: [converter1],
      socket: None,
      reconnect_attempts: 0,
    )

  let result = client.model_to_client_state(model)

  // Only ETH (3) should be included since 999 doesn't exist in currencies list
  assert result.added_currencies == ["ETH"]
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
      added_currencies: [],
      converters: [converter_with_bad_amount],
      socket: None,
      reconnect_attempts: 0,
    )

  let result = client.model_to_client_state(model)

  // When amount is unparseable, it should default to 1.0
  assert result.converters == [ConverterState(from: 1, to: 2, amount: 1.0)]
}
