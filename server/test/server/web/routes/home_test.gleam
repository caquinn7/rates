import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import server/web/routes/home
import shared/client_state.{ClientState, ConverterState}
import shared/currency.{Crypto, Fiat}
import shared/page_data
import wisp

pub fn resolve_page_data_with_no_client_state_uses_defaults_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]

  let data = home.resolve_page_data(currencies, None)

  assert data.currencies == currencies
  assert data.converters == [ConverterState(1, 2781, 1.0)]
}

pub fn resolve_page_data_preserves_converter_order_duplicates_and_amounts_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Crypto(1027, "Ethereum", "ETH", Some(2)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]
  let state =
    ClientState([
      ConverterState(1027, 2781, 10.0),
      ConverterState(1, 2781, 0.00000001),
      ConverterState(1027, 2781, 0.0),
    ])

  let data = home.resolve_page_data(currencies, Some(state))

  assert data.currencies == currencies
  assert data.converters == state.converters
}

pub fn resolve_page_data_filters_invalid_currency_ids_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]
  let state =
    ClientState([
      ConverterState(1, 2781, 5.0),
      ConverterState(999, 2781, 10.0),
      ConverterState(1, 888, 15.0),
      ConverterState(777, 666, 20.0),
      ConverterState(2781, 1, 0.00000001),
    ])

  let data = home.resolve_page_data(currencies, Some(state))

  assert data.converters
    == [
      ConverterState(1, 2781, 5.0),
      ConverterState(2781, 1, 0.00000001),
    ]
}

pub fn get_embeds_currency_catalog_and_saved_or_default_state_without_rates_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Crypto(1027, "Ethereum", "ETH", Some(2)),
    Fiat(2781, "United States Dollar", "USD", "$"),
  ]
  let saved =
    ClientState([
      ConverterState(1027, 2781, 10.0),
      ConverterState(1, 2781, 0.00000001),
    ])
  let cases = [
    #(Some(saved), saved.converters),
    #(None, [ConverterState(1, 2781, 1.0)]),
    #(Some(ClientState([])), [ConverterState(1, 2781, 1.0)]),
    #(Some(ClientState([ConverterState(999, 888, 10.0)])), [
      ConverterState(1, 2781, 1.0),
    ]),
  ]

  list.each(cases, fn(test_case) {
    let #(state, expected_converters) = test_case
    let data = home.resolve_page_data(currencies, state)
    assert data.currencies == currencies
    assert data.converters == expected_converters

    let response = home.get(currencies, state)
    assert response.status == 200
    let assert wisp.Text(html) = response.body
    let assert Ok(#(_, seed_and_rest)) =
      string.split_once(html, "<script id=\"model\" type=\"application/json\">")
    let assert Ok(#(seed, _)) = string.split_once(seed_and_rest, "</script>")
    assert json.parse(seed, page_data.decoder()) == Ok(data)
    assert !string.contains(seed, "\"rate\":")
  })
}

pub fn get_escapes_script_delimiters_without_changing_page_data_test() {
  let currencies = [
    Crypto(
      1,
      "Example </script><script>alert(\"seed\")</script> Coin",
      "BTC</ScRiPt>",
      Some(1),
    ),
    Fiat(2781, "<!--<script>US Dollar", "USD & \"", "<$ & € \\u003c >"),
  ]
  let state = ClientState([ConverterState(1, 2781, 0.00000001)])
  let response = home.get(currencies, Some(state))

  assert response.status == 200
  let assert wisp.Text(html) = response.body
  let assert Ok(#(_, seed_and_rest)) =
    string.split_once(html, "<script id=\"model\" type=\"application/json\">")
  let assert Ok(#(seed, rest)) = string.split_once(seed_and_rest, "</script>")
  let assert Ok(data) = json.parse(seed, page_data.decoder())
  assert data.currencies == currencies
  assert data.converters == state.converters
  assert !string.contains(seed, "<")
  assert string.starts_with(rest, "</head>")
}
