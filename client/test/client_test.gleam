import client.{AmountInput, Conversion, ConversionInput, CurrencySelector, Model}
import client/currency/collection as currency_collection
import client/side.{Left, Right}
import gleam/option.{None, Some}
import gleeunit
import shared/currency.{Crypto} as _shared_currency

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
    { model.conversion.conversion_inputs.1 }.currency_selector.currency

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
    { model.conversion.conversion_inputs.0 }.currency_selector.currency

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

  let left_currency =
    { model.conversion.conversion_inputs.0 }.currency_selector.currency
  let right_currency =
    { model.conversion.conversion_inputs.1 }.currency_selector.currency

  assert result
    == Model(
      ..model,
      conversion: Conversion(
        ..model.conversion,
        conversion_inputs: #(
          ConversionInput(
            ..model.conversion.conversion_inputs.0,
            amount_input: client.format_amount_input(left_currency, 3.0),
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
    { model.conversion.conversion_inputs.0 }.currency_selector.currency
  let right_currency =
    { model.conversion.conversion_inputs.1 }.currency_selector.currency

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
            amount_input: client.format_amount_input(right_currency, 6.0),
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

  let left_currency =
    { model.conversion.conversion_inputs.0 }.currency_selector.currency

  assert result
    == Model(
      ..model,
      conversion: Conversion(
        ..model.conversion,
        conversion_inputs: #(
          ConversionInput(
            ..model.conversion.conversion_inputs.0,
            amount_input: client.format_amount_input(left_currency, 3.0),
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

pub fn model_with_currency_filter_test() {
  let model =
    Model(..empty_model(), currencies: [
      Crypto(1, "abc", "abc", None),
      Crypto(2781, "xyz", "xyz", None),
    ])

  let currency_filter = "abc"

  let result =
    model
    |> client.model_with_currency_filter(Left, currency_filter)

  assert result
    == Model(
      ..model,
      conversion: Conversion(..model.conversion, conversion_inputs: #(
        ConversionInput(
          ..model.conversion.conversion_inputs.0,
          currency_selector: CurrencySelector(
            ..{ model.conversion.conversion_inputs.0 }.currency_selector,
            currency_filter:,
            currencies: model.currencies
              |> currency_collection.filter(currency_filter),
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
            currency:,
          ),
        ),
        model.conversion.conversion_inputs.1,
      )),
    )
}

fn empty_model() {
  let empty_selector =
    CurrencySelector("", False, "", [], Crypto(0, "", "", None))

  let empty_amount_input = AmountInput("", None)

  let empty_conversion_input =
    ConversionInput(empty_amount_input, empty_selector)

  Model(
    [],
    Conversion(#(empty_conversion_input, empty_conversion_input), None, Left),
    None,
  )
}
