import client.{
  AmountInput, ArrowDown, ArrowUp, Conversion, ConversionInput, CurrencySelector,
  Model, Other,
}
import client/currency/collection as currency_collection
import client/side.{Left, Right}
import gleam/option.{None, Some}
import gleeunit
import shared/currency.{type Currency, Crypto, Fiat} as _shared_currency

pub fn main() {
  gleeunit.main()
}

pub fn model_with_rate_edited_side_amount_not_parsed_test() {
  let model = empty_model()
  let new_rate = 2.5

  // Set up a model where last_edited is Left and Left has no parsed amount
  let model =
    Model(
      ..model,
      conversion: Conversion(
        last_edited: Left,
        rate: None,
        conversion_inputs: #(
          ConversionInput(
            ..model.conversion.conversion_inputs.0,
            amount_input: AmountInput("invalid", None),
          ),
          ConversionInput(
            ..model.conversion.conversion_inputs.1,
            amount_input: AmountInput("5.0", Some(5.0)),
          ),
        ),
      ),
    )

  let result = client.model_with_rate(model, new_rate)

  assert result
    == Model(
      ..model,
      conversion: Conversion(
        ..model.conversion,
        // rate is updated
        rate: Some(new_rate),
        // input values stay the same
        conversion_inputs: model.conversion.conversion_inputs,
      ),
    )
}

pub fn model_with_rate_left_side_amount_parsed_test() {
  let model = empty_model()
  let new_rate = 1.5

  let parsed_left_amount = 4.0
  let expected_right_amount = parsed_left_amount *. new_rate

  let model =
    Model(
      ..model,
      conversion: Conversion(
        last_edited: Left,
        rate: None,
        conversion_inputs: #(
          ConversionInput(
            ..model.conversion.conversion_inputs.0,
            amount_input: AmountInput("4.0", Some(parsed_left_amount)),
          ),
          ConversionInput(
            ..model.conversion.conversion_inputs.1,
            // should be overwritten
            amount_input: AmountInput("5.0", Some(5.0)),
          ),
        ),
      ),
    )

  let result = client.model_with_rate(model, new_rate)

  let right_currency =
    { model.conversion.conversion_inputs.1 }.currency_selector.selected_currency

  assert result
    == Model(
      ..model,
      conversion: Conversion(
        ..model.conversion,
        rate: Some(new_rate),
        conversion_inputs: #(
          // Left side unchanged
          model.conversion.conversion_inputs.0,
          // Right side updated based on new rate
          ConversionInput(
            ..model.conversion.conversion_inputs.1,
            amount_input: client.format_amount_input(
              right_currency,
              expected_right_amount,
            ),
          ),
        ),
      ),
    )
}

pub fn model_with_rate_right_side_amount_parsed_test() {
  let model = empty_model()
  let new_rate = 2.0

  let parsed_right_amount = 10.0
  let expected_left_amount = parsed_right_amount /. new_rate

  let model =
    Model(
      ..model,
      conversion: Conversion(
        last_edited: Right,
        rate: None,
        conversion_inputs: #(
          ConversionInput(
            ..model.conversion.conversion_inputs.0,
            // should be overwritten
            amount_input: AmountInput("3.0", Some(3.0)),
          ),
          ConversionInput(
            ..model.conversion.conversion_inputs.1,
            amount_input: AmountInput("10.0", Some(parsed_right_amount)),
          ),
        ),
      ),
    )

  let result = client.model_with_rate(model, new_rate)

  let left_currency =
    { model.conversion.conversion_inputs.0 }.currency_selector.selected_currency

  assert result
    == Model(
      ..model,
      conversion: Conversion(
        ..model.conversion,
        rate: Some(new_rate),
        conversion_inputs: #(
          // Left side updated based on new rate
          ConversionInput(
            ..model.conversion.conversion_inputs.0,
            amount_input: client.format_amount_input(
              left_currency,
              expected_left_amount,
            ),
          ),
          // Right side unchanged
          model.conversion.conversion_inputs.1,
        ),
      ),
    )
}

pub fn model_with_amount_parse_failure_test() {
  let model = empty_model()
  let model =
    Model(
      ..empty_model(),
      conversion: Conversion(..model.conversion, conversion_inputs: #(
        ConversionInput(
          ..model.conversion.conversion_inputs.0,
          amount_input: AmountInput("1.0", Some(1.0)),
        ),
        ConversionInput(
          ..model.conversion.conversion_inputs.1,
          amount_input: AmountInput("2.0", Some(2.0)),
        ),
      )),
    )

  let user_input = "invalid"
  let result =
    model
    |> client.model_with_amount(Left, user_input)

  assert result
    == Model(
      ..model,
      conversion: Conversion(..model.conversion, conversion_inputs: #(
        ConversionInput(
          ..model.conversion.conversion_inputs.0,
          amount_input: AmountInput(user_input, None),
        ),
        ConversionInput(
          ..model.conversion.conversion_inputs.1,
          amount_input: AmountInput("", None),
        ),
      )),
    )
}

pub fn model_with_amount_parse_success_on_left_side_with_rate_test() {
  let model = empty_model()
  let rate = 2.0

  let model =
    Model(
      ..model,
      conversion: Conversion(
        last_edited: Right,
        conversion_inputs: #(
          ConversionInput(
            ..model.conversion.conversion_inputs.0,
            amount_input: AmountInput("1.0", Some(1.0)),
          ),
          ConversionInput(
            ..model.conversion.conversion_inputs.1,
            amount_input: AmountInput("2.0", Some(2.0)),
          ),
        ),
        rate: Some(rate),
      ),
    )

  let result =
    model
    |> client.model_with_amount(Left, "3.0")

  let right_currency =
    { model.conversion.conversion_inputs.1 }.currency_selector.selected_currency

  assert result
    == Model(
      ..model,
      conversion: Conversion(
        ..model.conversion,
        conversion_inputs: #(
          ConversionInput(
            ..model.conversion.conversion_inputs.0,
            amount_input: AmountInput("3.0", Some(3.0)),
          ),
          ConversionInput(
            ..model.conversion.conversion_inputs.1,
            amount_input: client.format_amount_input(right_currency, 6.0),
          ),
        ),
        last_edited: Left,
      ),
    )
}

pub fn model_with_amount_parse_success_on_right_side_with_rate_test() {
  let model = empty_model()
  let rate = 2.0

  let model =
    Model(
      ..model,
      conversion: Conversion(
        last_edited: Left,
        conversion_inputs: #(
          ConversionInput(
            ..model.conversion.conversion_inputs.0,
            amount_input: AmountInput("1.0", Some(1.0)),
          ),
          ConversionInput(
            ..model.conversion.conversion_inputs.1,
            amount_input: AmountInput("2.0", Some(2.0)),
          ),
        ),
        rate: Some(rate),
      ),
    )

  let result =
    model
    |> client.model_with_amount(Right, "6.0")

  let left_currency =
    { model.conversion.conversion_inputs.0 }.currency_selector.selected_currency

  assert result
    == Model(
      ..model,
      conversion: Conversion(
        ..model.conversion,
        conversion_inputs: #(
          ConversionInput(
            ..model.conversion.conversion_inputs.0,
            amount_input: client.format_amount_input(left_currency, 3.0),
            // 6.0 / 2.0 = 3.0
          ),
          ConversionInput(
            ..model.conversion.conversion_inputs.1,
            amount_input: AmountInput("6.0", Some(6.0)),
          ),
        ),
        last_edited: Right,
      ),
    )
}

pub fn model_with_amount_parse_success_with_no_rate_test() {
  let model = empty_model()

  let model =
    Model(
      ..model,
      conversion: Conversion(
        ..model.conversion,
        conversion_inputs: #(
          ConversionInput(
            ..model.conversion.conversion_inputs.0,
            amount_input: AmountInput("1.0", Some(1.0)),
          ),
          ConversionInput(
            ..model.conversion.conversion_inputs.1,
            amount_input: AmountInput("2.0", Some(2.0)),
          ),
        ),
        rate: None,
      ),
    )

  let result =
    model
    |> client.model_with_amount(Left, "3.0")

  assert result
    == Model(
      ..model,
      conversion: Conversion(
        ..model.conversion,
        conversion_inputs: #(
          ConversionInput(
            ..model.conversion.conversion_inputs.0,
            amount_input: AmountInput("3.0", Some(3.0)),
          ),
          ConversionInput(
            ..model.conversion.conversion_inputs.1,
            amount_input: AmountInput(raw: "", parsed: None),
          ),
        ),
        last_edited: Left,
      ),
    )
}

pub fn toggle_currency_selector_dropdown_test() {
  let model = empty_model()

  let initial_val =
    { model.conversion.conversion_inputs.0 }.currency_selector.show_dropdown

  assert initial_val == False

  let result =
    model
    |> client.toggle_currency_selector_dropdown(Left)

  assert result
    == Model(
      ..model,
      conversion: Conversion(..model.conversion, conversion_inputs: #(
        ConversionInput(
          ..model.conversion.conversion_inputs.0,
          currency_selector: CurrencySelector(
            ..{ model.conversion.conversion_inputs.0 }.currency_selector,
            show_dropdown: True,
          ),
        ),
        model.conversion.conversion_inputs.1,
      )),
    )
}

pub fn currency_matches_filter_when_name_matches_test() {
  let currency = Crypto(1, "Bitcoin", "BTC", None)
  assert client.currency_matches_filter(currency, "bit")
  assert client.currency_matches_filter(currency, "coin")
}

pub fn currency_matches_filter_when_symbol_matches_test() {
  let currency = Fiat(2, "US Dollar", "USD", "")
  assert client.currency_matches_filter(currency, "USD")
  assert client.currency_matches_filter(currency, "usd")
  assert client.currency_matches_filter(currency, "us")
}

pub fn currency_matches_filter_is_case_insensitive_test() {
  let currency = Crypto(3, "Ethereum", "ETH", None)
  assert client.currency_matches_filter(currency, "ether")
  assert client.currency_matches_filter(currency, "ETH")
  assert client.currency_matches_filter(currency, "Eth")
  assert client.currency_matches_filter(currency, "eTh")
}

pub fn currency_matches_filter_when_no_match_test() {
  let currency = Fiat(4, "Japanese Yen", "JPY", "")
  assert !client.currency_matches_filter(currency, "usd")
  assert !client.currency_matches_filter(currency, "bitcoin")
  assert !client.currency_matches_filter(currency, "euro")
}

pub fn model_with_currency_filter_test() {
  let model =
    Model(..empty_model(), currencies: [
      Crypto(1, "abc", "abc", None),
      Crypto(2781, "xyz", "xyz", None),
    ])

  let expected_currencies = [Crypto(1, "abc", "abc", None)]
  let filter_fun = fn(currency: Currency, _filter_str) {
    case currency.id {
      1 -> True
      _ -> False
    }
  }

  let result =
    model
    |> client.model_with_currency_filter(Left, "", filter_fun)

  assert result
    == Model(
      ..model,
      conversion: Conversion(..model.conversion, conversion_inputs: #(
        ConversionInput(
          ..model.conversion.conversion_inputs.0,
          currency_selector: CurrencySelector(
            ..{ model.conversion.conversion_inputs.0 }.currency_selector,
            currency_filter: "",
            currencies: expected_currencies
              |> currency_collection.from_list,
          ),
        ),
        model.conversion.conversion_inputs.1,
      )),
    )
}

pub fn model_with_selected_currency_test() {
  let model = empty_model()

  let currency = Crypto(1, "Bitcoin", "BTC", Some(1))

  let result =
    model
    |> client.model_with_selected_currency(Left, currency)

  assert result
    == Model(
      ..model,
      conversion: Conversion(..model.conversion, conversion_inputs: #(
        ConversionInput(
          ..model.conversion.conversion_inputs.0,
          currency_selector: CurrencySelector(
            ..{ model.conversion.conversion_inputs.0 }.currency_selector,
            selected_currency: currency,
          ),
        ),
        model.conversion.conversion_inputs.1,
      )),
    )
}

pub fn calculate_next_focused_index_arrow_down_from_none_test() {
  assert Some(0) == client.calculate_next_focused_index(None, ArrowDown, 1)
}

pub fn calculate_next_focused_index_arrow_down_wraps_test() {
  let option_count = 3

  assert Some(0)
    == client.calculate_next_focused_index(
      Some(option_count - 1),
      ArrowDown,
      option_count,
    )
}

pub fn calculate_next_focused_index_arrow_up_from_none_test() {
  let option_count = 3

  assert Some(option_count - 1)
    == client.calculate_next_focused_index(None, ArrowUp, option_count)
}

pub fn calculate_next_focused_index_arrow_up_wraps_test() {
  let option_count = 3

  assert Some(option_count - 1)
    == client.calculate_next_focused_index(Some(0), ArrowUp, option_count)
}

pub fn calculate_next_focused_index_non_arrow_key_ignored_test() {
  assert Some(0) == client.calculate_next_focused_index(Some(0), Other("a"), 3)
}

pub fn calculate_next_focused_index_with_no_options_test() {
  assert None == client.calculate_next_focused_index(Some(0), ArrowUp, 0)
}

fn empty_model() {
  let empty_selector =
    CurrencySelector(
      "",
      False,
      "",
      currency_collection.from_list([]),
      Crypto(0, "", "", None),
      None,
    )

  let empty_amount_input = AmountInput("", None)

  let empty_conversion_input =
    ConversionInput(empty_amount_input, empty_selector)

  Model(
    [],
    Conversion(#(empty_conversion_input, empty_conversion_input), None, Left),
    None,
  )
}
