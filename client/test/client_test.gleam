import client.{Model}
import client/side.{Left, Right}
import client/ui/converter.{Waiting}
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import shared/client_state.{ConverterState}
import shared/currency.{Crypto, Fiat}
import shared/numbers/non_negative_float
import shared/page_data.{PageData}

pub fn main() {
  gleeunit.main()
}

// model_from_page_data

pub fn model_from_page_data_constructs_waiting_converters_test() {
  let currencies = [
    Fiat(1, "United States Dollar", "USD", "$"),
    Crypto(2, "Bitcoin", "BTC", Some(1)),
    Crypto(3, "Ethereum", "ETH", Some(2)),
  ]
  let converter_states = [
    ConverterState(from: 1, to: 2, amount: 100.0),
    ConverterState(from: 2, to: 3, amount: 2.5),
  ]
  let data = PageData(currencies:, converters: converter_states)

  let model = client.model_from_page_data(data)

  assert model.currencies == currencies
  assert model.socket == None
  assert model.reconnect_attempts == 0
  assert client.model_to_client_state(model).converters == converter_states

  let assert [converter1, converter2] = model.converters
  assert converter1.id == "converter-1"
  assert converter2.id == "converter-2"
  assert converter.get_selected_currency_id(converter1, Left) == 1
  assert converter.get_selected_currency_id(converter1, Right) == 2
  assert converter.get_selected_currency_id(converter2, Left) == 2
  assert converter.get_selected_currency_id(converter2, Right) == 3
  assert converter.get_parsed_amount(converter1, Left)
    == Some(non_negative_float.from_float_unsafe(100.0))
  assert converter.get_parsed_amount(converter2, Left)
    == Some(non_negative_float.from_float_unsafe(2.5))

  list.each(model.converters, fn(target) {
    assert target.rate == None
    assert target.rate_status == Waiting(0, False)
    assert converter.get_parsed_amount(target, Right) == None
    assert converter.get_converter_input(target, Right).amount_input.raw == ""
  })
}

pub fn model_from_page_data_preserves_duplicate_pairs_and_small_amounts_test() {
  let converter_states = [
    ConverterState(1, 2781, 0.00000001),
    ConverterState(1, 2781, 20.0),
  ]
  let data =
    PageData(
      currencies: [
        Crypto(1, "Bitcoin", "BTC", Some(1)),
        Fiat(2781, "United States Dollar", "USD", "$"),
      ],
      converters: converter_states,
    )

  let model = client.model_from_page_data(data)
  let assert [first, second] = model.converters
  assert first.id == "converter-1"
  assert second.id == "converter-2"
  assert client.model_to_client_state(model).converters == converter_states
  assert first.rate_status == Waiting(0, False)
  assert second.rate_status == Waiting(0, False)
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
      protocol_error: False,
      next_loading_token: 1,
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
      protocol_error: False,
      next_loading_token: 1,
    )

  let result = client.model_to_client_state(model)

  // When amount is unparseable, it should default to 1.0
  assert result.converters == [ConverterState(from: 1, to: 2, amount: 1.0)]
}
