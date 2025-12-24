import client/currency/collection as currency_collection
import client/currency/filtering as currency_filtering
import client/currency/formatting as currency_formatting
import client/positive_float
import client/side.{Left, Right}
import client/ui/button_dropdown.{ArrowDown, ArrowUp, Enter, Other}
import client/ui/converter.{
  AmountInput, Converter, ConverterInput, CurrencySelector, Decreased,
  EmptyCurrencyList, FocusOnCurrencyFilter, Increased, NoChange, NoEffect,
  RequestCurrencies, RequestRate, ScrollToOption, SelectedCurrencyNotFound,
  UserClickedCurrencySelector, UserEnteredAmount, UserFilteredCurrencies,
  UserPressedKeyInCurrencySelector,
}
import gleam/list
import gleam/option.{None, Some}
import shared/currency.{Crypto}
import shared/rates/rate_request.{RateRequest}

// new

pub fn new_returns_error_when_currency_list_is_empty_test() {
  assert converter.new("test", [], #(1, 2), "100", None)
    == Error(EmptyCurrencyList)
}

pub fn new_returns_error_when_left_currency_id_not_found_test() {
  let currencies = [
    Crypto(1, "BTC", "Bitcoin", None),
    Crypto(2, "ETH", "Ethereum", None),
  ]

  assert converter.new("test", currencies, #(999, 2), "100", None)
    == Error(SelectedCurrencyNotFound(999))
}

pub fn new_returns_error_when_right_currency_id_not_found_test() {
  let currencies = [
    Crypto(1, "BTC", "Bitcoin", None),
    Crypto(2, "ETH", "Ethereum", None),
  ]

  assert converter.new("test", currencies, #(1, 999), "100", None)
    == Error(SelectedCurrencyNotFound(999))
}

pub fn new_returns_ok_with_valid_inputs_test() {
  let currencies = [
    Crypto(1, "BTC", "Bitcoin", None),
    Crypto(2, "ETH", "Ethereum", None),
  ]

  let rate = Some(positive_float.from_float_unsafe(2.5))
  let result =
    converter.new("my-converter", currencies, #(1, 2), "100.50", rate)

  let assert Ok(converter) = result

  let left_converter_input = converter.get_converter_input(converter, Left)
  let left_currency_selector = left_converter_input.currency_selector

  let right_converter_input = converter.get_converter_input(converter, Right)
  let right_currency_selector = right_converter_input.currency_selector

  assert converter.id == "my-converter"
  assert converter.last_edited == Left

  assert left_currency_selector.id == "currency-selector-my-converter-left"
  assert right_currency_selector.id == "currency-selector-my-converter-right"

  assert converter.master_currency_list == currencies

  assert left_currency_selector.selected_currency.id == 1
  assert right_currency_selector.selected_currency.id == 2

  assert converter.rate == rate

  assert left_converter_input.amount_input.parsed
    == Some(positive_float.from_float_unsafe(100.5))
}

// with_master_currency_list

pub fn with_master_currency_list_updates_master_list_test() {
  let target =
    Converter(
      "test-id",
      [],
      #(empty_converter_input(), empty_converter_input()),
      Some(positive_float.from_float_unsafe(100.0)),
      Right,
    )

  let new_currencies = [
    Crypto(1, "BTC", "Bitcoin", None),
    Crypto(2, "ETH", "Ethereum", None),
  ]

  let result = converter.with_master_currency_list(target, new_currencies)

  assert result.master_currency_list == new_currencies
}

pub fn with_master_currency_list_refilters_both_sides_test() {
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Crypto(2, "Ethereum", "ETH", Some(2)),
    Crypto(3, "Litecoin", "LTC", Some(3)),
  ]

  // Set up converter with filter text on left side and different selected currencies
  let converter_with_mixed_state =
    Converter(..empty_converter(), inputs: #(
      ConverterInput(
        ..empty_converter_input(),
        currency_selector: CurrencySelector(
          ..empty_converter_input().currency_selector,
          currency_filter: "bit",
          // Has filter text
          selected_currency: Crypto(4, "Ripple", "XRP", Some(4)),
          // Won't match "bit" filter
        ),
      ),
      ConverterInput(
        ..empty_converter_input(),
        currency_selector: CurrencySelector(
          ..empty_converter_input().currency_selector,
          selected_currency: Crypto(2, "Ethereum", "ETH", Some(2)),
        ),
      ),
    ))

  let result =
    converter.with_master_currency_list(converter_with_mixed_state, currencies)

  // Should update master list
  assert result.master_currency_list == currencies

  // Both sides should have been re-filtered (both should have currencies)
  let left_currencies =
    converter.get_converter_input(result, Left).currency_selector.currencies
  let right_currencies =
    converter.get_converter_input(result, Right).currency_selector.currencies

  assert currency_collection.length(left_currencies) > 0
  assert currency_collection.length(right_currencies) > 0

  // Filter text should be preserved
  assert converter.get_converter_input(result, Left).currency_selector.currency_filter
    == "bit"
  assert converter.get_converter_input(result, Right).currency_selector.currency_filter
    == ""

  // Selected currencies should be preserved
  assert converter.get_converter_input(result, Left).currency_selector.selected_currency.id
    == 4
  assert converter.get_converter_input(result, Right).currency_selector.selected_currency.id
    == 2
}

// with_rate

pub fn with_rate_calculates_right_side_when_left_edited_test() {
  // Set up converter with valid amount on left side
  let left_input =
    ConverterInput(
      AmountInput("100", Some(positive_float.from_float_unsafe(100.0)), None),
      empty_converter_input().currency_selector,
    )

  let target =
    Converter(
      ..empty_converter(),
      inputs: #(left_input, empty_converter_input()),
      last_edited: Left,
    )

  let rate = Some(positive_float.from_float_unsafe(2.5))
  let result = converter.with_rate(target, rate)

  // Left side should remain unchanged (user input preserved)
  assert converter.get_converter_input(result, Left).amount_input.raw == "100"
  assert converter.get_converter_input(result, Left).amount_input.parsed
    == Some(positive_float.from_float_unsafe(100.0))

  // Right side should be calculated: 100 * 2.5 = 250
  let right_input = converter.get_converter_input(result, Right)
  assert right_input.amount_input.raw == "250"
  assert right_input.amount_input.parsed
    == Some(positive_float.from_float_unsafe(250.0))

  // Rate should be updated
  assert result.rate == rate

  // Other state should be preserved
  assert result.last_edited == Left
}

pub fn with_rate_calculates_left_side_when_right_edited_test() {
  // Set up converter with valid amount on right side
  let right_input =
    ConverterInput(
      AmountInput("500", Some(positive_float.from_float_unsafe(500.0)), None),
      empty_converter_input().currency_selector,
    )

  let target =
    Converter(
      ..empty_converter(),
      inputs: #(empty_converter_input(), right_input),
      last_edited: Right,
    )

  let rate = Some(positive_float.from_float_unsafe(4.0))
  let result = converter.with_rate(target, rate)

  // Right side should remain unchanged (user input preserved)
  assert converter.get_converter_input(result, Right).amount_input.raw == "500"
  assert converter.get_converter_input(result, Right).amount_input.parsed
    == Some(positive_float.from_float_unsafe(500.0))

  // Left side should be calculated: 500 / 4.0 = 125
  let left_input = converter.get_converter_input(result, Left)
  assert left_input.amount_input.raw == "125"
  assert left_input.amount_input.parsed
    == Some(positive_float.from_float_unsafe(125.0))

  // Rate should be updated
  assert result.rate == rate

  // Other state should be preserved
  assert result.last_edited == Right
}

pub fn with_rate_no_conversion_when_no_parsed_amount_test() {
  // Set up converter with no valid parsed amount on the last edited side
  let left_input =
    ConverterInput(
      AmountInput("invalid", None, None),
      // Raw input but no parsed value
      empty_converter_input().currency_selector,
    )

  let target =
    Converter(
      ..empty_converter(),
      inputs: #(left_input, empty_converter_input()),
      last_edited: Left,
    )

  let rate = Some(positive_float.from_float_unsafe(2.5))
  let result = converter.with_rate(target, rate)

  // Neither side should be recalculated since there's no valid parsed amount
  assert converter.get_converter_input(result, Left).amount_input.raw
    == "invalid"
  assert converter.get_converter_input(result, Left).amount_input.parsed == None

  assert converter.get_converter_input(result, Right).amount_input.raw == ""
  assert converter.get_converter_input(result, Right).amount_input.parsed
    == None

  // Rate should still be updated
  assert result.rate == rate

  // Other state should be preserved
  assert result.last_edited == Left
}

pub fn with_rate_handles_none_rate_when_left_side_is_last_edited_test() {
  // Set up converter with valid amount on left side
  let left_input =
    ConverterInput(
      AmountInput("100", Some(positive_float.from_float_unsafe(100.0)), None),
      empty_converter_input().currency_selector,
    )

  let target =
    Converter(
      ..empty_converter(),
      inputs: #(left_input, empty_converter_input()),
      rate: Some(positive_float.from_float_unsafe(1.0)),
      last_edited: Left,
    )

  let result = converter.with_rate(target, None)

  // Left side should remain unchanged
  let left_amount_input =
    converter.get_converter_input(result, Left).amount_input

  assert left_amount_input.raw == "100"
  assert left_amount_input.parsed
    == Some(positive_float.from_float_unsafe(100.0))

  // Right side should show "price not tracked" when rate is None
  let right_amount_input =
    converter.get_converter_input(result, Right).amount_input

  assert right_amount_input.raw == "price not tracked"
  assert right_amount_input.parsed == None

  // Rate should be updated to None
  assert result.rate == None

  // Other state should be preserved
  assert result.last_edited == Left
}

pub fn with_rate_handles_none_rate_when_right_side_is_last_edited_test() {
  // Set up converter with valid amount on right side
  let right_input =
    ConverterInput(
      AmountInput("250", Some(positive_float.from_float_unsafe(250.0)), None),
      empty_converter_input().currency_selector,
    )

  let target =
    Converter(
      ..empty_converter(),
      inputs: #(empty_converter_input(), right_input),
      rate: Some(positive_float.from_float_unsafe(1.0)),
      last_edited: Right,
    )

  let result = converter.with_rate(target, None)

  // Right side should remain unchanged
  let right_amount_input =
    converter.get_converter_input(result, Right).amount_input

  assert right_amount_input.raw == "250"
  assert right_amount_input.parsed
    == Some(positive_float.from_float_unsafe(250.0))

  // Left side should show "price not tracked" when rate is None
  let left_amount_input =
    converter.get_converter_input(result, Left).amount_input

  assert left_amount_input.raw == "price not tracked"
  assert left_amount_input.parsed == None

  // Rate should be updated to None
  assert result.rate == None

  // Other state should be preserved
  assert result.last_edited == Right
}

pub fn with_rate_transitions_from_none_to_some_test() {
  // Set up converter with None rate and "price not tracked" showing
  let left_input =
    ConverterInput(
      AmountInput("100", Some(positive_float.from_float_unsafe(100.0)), None),
      empty_converter_input().currency_selector,
    )

  let right_input =
    ConverterInput(
      AmountInput("price not tracked", None, None),
      empty_converter_input().currency_selector,
    )

  let target =
    Converter(
      ..empty_converter(),
      inputs: #(left_input, right_input),
      last_edited: Left,
    )

  // Transition to valid rate
  let rate = Some(positive_float.from_float_unsafe(3.0))
  let result = converter.with_rate(target, rate)

  // Left side should remain unchanged
  let left_amount_input =
    converter.get_converter_input(result, Left).amount_input

  assert left_amount_input.raw == "100"
  assert left_amount_input.parsed
    == Some(positive_float.from_float_unsafe(100.0))

  // Right side should now have converted value: 100 * 3.0 = 300
  let right_amount_input =
    converter.get_converter_input(result, Right).amount_input

  assert right_amount_input.raw == "300"
  assert right_amount_input.parsed
    == Some(positive_float.from_float_unsafe(300.0))

  // Rate should be updated
  assert result.rate == rate
}

pub fn with_rate_sets_border_color_to_none_when_no_parsed_amount_test() {
  // Set up converter with no valid parsed amount
  let left_input =
    ConverterInput(
      AmountInput("invalid", None, None),
      empty_converter_input().currency_selector,
    )

  let target =
    Converter(
      ..empty_converter(),
      inputs: #(left_input, empty_converter_input()),
      last_edited: Left,
    )

  let rate = Some(positive_float.from_float_unsafe(2.5))
  let result = converter.with_rate(target, rate)

  // Right side should not glow when there's no conversion
  assert converter.get_converter_input(result, Right).amount_input.border_color
    == None
}

pub fn with_rate_sets_border_color_to_none_when_rate_is_none_test() {
  // Set up converter with valid amount
  let left_input =
    ConverterInput(
      AmountInput("100", Some(positive_float.from_float_unsafe(100.0)), None),
      empty_converter_input().currency_selector,
    )

  let target =
    Converter(
      ..empty_converter(),
      inputs: #(left_input, empty_converter_input()),
      last_edited: Left,
    )

  let result = converter.with_rate(target, None)

  // Right side should not glow when rate is None (shows "price not tracked")
  assert converter.get_converter_input(result, Right).amount_input.border_color
    == None
}

pub fn with_rate_sets_right_border_color_to_some_when_left_side_edited_test() {
  let left_input =
    ConverterInput(
      AmountInput("50", Some(positive_float.from_float_unsafe(50.0)), None),
      empty_converter_input().currency_selector,
    )

  let target =
    Converter(
      ..empty_converter(),
      inputs: #(left_input, empty_converter_input()),
      last_edited: Left,
    )

  let rate = Some(positive_float.from_float_unsafe(3.0))
  let result = converter.with_rate(target, rate)

  // Right side should glow
  assert converter.get_converter_input(result, Right).amount_input.border_color
    != None
  // Left side should not glow
  assert converter.get_converter_input(result, Left).amount_input.border_color
    == None
}

pub fn with_rate_sets_left_border_color_to_some_when_right_side_edited_test() {
  let right_input =
    ConverterInput(
      AmountInput("200", Some(positive_float.from_float_unsafe(200.0)), None),
      empty_converter_input().currency_selector,
    )

  let target =
    Converter(
      ..empty_converter(),
      inputs: #(empty_converter_input(), right_input),
      last_edited: Right,
    )

  let rate = Some(positive_float.from_float_unsafe(5.0))
  let result = converter.with_rate(target, rate)

  // // Left side should glow
  assert converter.get_converter_input(result, Left).amount_input.border_color
    != None
  // Right side should not glow
  assert converter.get_converter_input(result, Right).amount_input.border_color
    == None
}

// border_color_from_rate_change

pub fn border_color_from_rate_change_returns_no_change_when_rates_equal_test() {
  let prev = Some(positive_float.from_float_unsafe(2.0))
  let new = Some(positive_float.from_float_unsafe(2.0))

  assert converter.border_color_from_rate_change(prev, new) == Some(NoChange)
}

pub fn border_color_from_rate_change_returns_increased_when_rate_increases_test() {
  let prev = Some(positive_float.from_float_unsafe(2.0))
  let new = Some(positive_float.from_float_unsafe(3.0))

  assert converter.border_color_from_rate_change(prev, new) == Some(Increased)
}

pub fn border_color_from_rate_change_returns_decreased_when_rate_decreases_test() {
  let prev = Some(positive_float.from_float_unsafe(3.0))
  let new = Some(positive_float.from_float_unsafe(2.0))

  assert converter.border_color_from_rate_change(prev, new) == Some(Decreased)
}

pub fn border_color_from_rate_change_returns_no_change_when_no_previous_rate_test() {
  let prev = None
  let new = Some(positive_float.from_float_unsafe(2.0))

  assert converter.border_color_from_rate_change(prev, new) == Some(NoChange)
}

pub fn border_color_from_rate_change_returns_none_when_new_rate_is_none_test() {
  let prev = Some(positive_float.from_float_unsafe(2.0))
  let new = None

  assert converter.border_color_from_rate_change(prev, new) == None
}

// with_glow_cleared

pub fn with_glow_cleared_sets_border_color_to_none_test() {
  let left_input =
    ConverterInput(
      AmountInput("50", Some(positive_float.from_float_unsafe(50.0)), None),
      empty_converter_input().currency_selector,
    )

  let target =
    Converter(
      ..empty_converter(),
      inputs: #(left_input, empty_converter_input()),
      last_edited: Left,
    )
    |> converter.with_rate(Some(positive_float.from_float_unsafe(3.0)))

  assert converter.get_converter_input(target, Right).amount_input.border_color
    != None

  let result = converter.with_glow_cleared(target, Right)

  assert converter.get_converter_input(result, Right).amount_input.border_color
    == None
}

// with_amount

pub fn with_amount_successful_parse_with_rate_left_to_right_test() {
  // Set up converter with a valid rate
  let target =
    Converter(
      ..empty_converter(),
      rate: Some(positive_float.from_float_unsafe(2.5)),
      // Different from the side we'll edit
      last_edited: Right,
    )

  let result = converter.with_amount(target, Left, "100")

  // Left side (edited) should have the raw input and parsed value
  let left_input = converter.get_converter_input(result, Left)
  assert left_input.amount_input.raw == "100"
  assert left_input.amount_input.parsed
    == Some(positive_float.from_float_unsafe(100.0))

  // Right side should be converted: 100 * 2.5 = 250
  let right_input = converter.get_converter_input(result, Right)
  let expected_converted_amount = positive_float.from_float_unsafe(250.0)
  let expected_raw =
    currency_formatting.format_currency_amount(expected_converted_amount)

  assert right_input.amount_input.raw == expected_raw
  assert right_input.amount_input.parsed == Some(expected_converted_amount)

  // last_edited should be updated to the edited side
  assert result.last_edited == Left

  // Rate should remain unchanged
  assert result.rate == Some(positive_float.from_float_unsafe(2.5))
}

pub fn with_amount_successful_parse_with_rate_right_to_left_test() {
  // Set up converter with a valid rate
  let target =
    Converter(
      ..empty_converter(),
      rate: Some(positive_float.from_float_unsafe(4.0)),
      // Different from the side we'll edit
      last_edited: Left,
    )

  let result = converter.with_amount(target, Right, "200")

  // Right side (edited) should have the raw input and parsed value
  let right_input = converter.get_converter_input(result, Right)
  assert right_input.amount_input.raw == "200"
  assert right_input.amount_input.parsed
    == Some(positive_float.from_float_unsafe(200.0))

  // Left side should be converted: 200 / 4.0 = 50
  let left_input = converter.get_converter_input(result, Left)
  let expected_converted_amount = positive_float.from_float_unsafe(50.0)
  let expected_raw =
    currency_formatting.format_currency_amount(expected_converted_amount)

  assert left_input.amount_input.raw == expected_raw
  assert left_input.amount_input.parsed == Some(expected_converted_amount)

  // last_edited should be updated to the edited side
  assert result.last_edited == Right

  // Rate should remain unchanged
  assert result.rate == Some(positive_float.from_float_unsafe(4.0))
}

pub fn with_amount_successful_parse_without_rate_test() {
  // Set up converter with no rate
  let target = Converter(..empty_converter(), rate: None, last_edited: Right)

  let result = converter.with_amount(target, Left, "100")

  // Left side (edited) should have the raw input and parsed value
  let left_input = converter.get_converter_input(result, Left)
  assert left_input.amount_input.raw == "100"
  assert left_input.amount_input.parsed
    == Some(positive_float.from_float_unsafe(100.0))

  // Right side should be empty (no rate means no conversion)
  let right_input = converter.get_converter_input(result, Right)
  assert right_input.amount_input.raw == ""
  assert right_input.amount_input.parsed == None

  // last_edited should be updated to the edited side
  assert result.last_edited == Left

  // Rate should remain None
  assert result.rate == None
}

pub fn with_amount_failed_parse_clears_opposite_side_test() {
  // Set up converter with existing amounts on both sides
  let left_input =
    ConverterInput(
      AmountInput("50", Some(positive_float.from_float_unsafe(50.0)), None),
      empty_converter_input().currency_selector,
    )

  let right_input =
    ConverterInput(
      AmountInput("100", Some(positive_float.from_float_unsafe(100.0)), None),
      empty_converter_input().currency_selector,
    )

  let target =
    Converter(
      ..empty_converter(),
      inputs: #(left_input, right_input),
      rate: Some(positive_float.from_float_unsafe(2.0)),
      last_edited: Right,
    )

  // Enter invalid input that will fail to parse
  let result = converter.with_amount(target, Left, "invalid_input")

  // Left side (edited) should store the raw input but have no parsed value
  let left_result = converter.get_converter_input(result, Left)
  assert left_result.amount_input.raw == "invalid_input"
  assert left_result.amount_input.parsed == None

  // Right side should be cleared (both raw and parsed)
  let right_result = converter.get_converter_input(result, Right)
  assert right_result.amount_input.raw == ""
  assert right_result.amount_input.parsed == None

  // last_edited should be updated to the edited side
  assert result.last_edited == Left

  // Rate should remain unchanged
  assert result.rate == Some(positive_float.from_float_unsafe(2.0))
}

pub fn with_amount_failed_parse_preserves_raw_input_test() {
  // Test that the raw input is preserved even when parsing fails
  let target = Converter(..empty_converter(), last_edited: Right)

  let result = converter.with_amount(target, Left, "not_a_number")

  // Edited side should preserve the exact raw input
  let left_input = converter.get_converter_input(result, Left)
  assert left_input.amount_input.raw == "not_a_number"
  assert left_input.amount_input.parsed == None

  // Opposite side should be cleared
  let right_input = converter.get_converter_input(result, Right)
  assert right_input.amount_input.raw == ""
  assert right_input.amount_input.parsed == None

  // State management should work correctly
  assert result.last_edited == Left
}

pub fn with_amount_empty_string_clears_both_sides_test() {
  // Set up converter with existing amounts on both sides
  let left_input =
    ConverterInput(
      AmountInput("100", Some(positive_float.from_float_unsafe(100.0)), None),
      empty_converter_input().currency_selector,
    )

  let right_input =
    ConverterInput(
      AmountInput("250", Some(positive_float.from_float_unsafe(250.0)), None),
      empty_converter_input().currency_selector,
    )

  let target =
    Converter(
      ..empty_converter(),
      inputs: #(left_input, right_input),
      rate: Some(positive_float.from_float_unsafe(2.5)),
      last_edited: Right,
    )

  // Enter empty string (user clearing the field)
  let result = converter.with_amount(target, Left, "")

  // Left side (edited) should have empty raw input and no parsed value
  let left_result = converter.get_converter_input(result, Left)
  assert left_result.amount_input.raw == ""
  assert left_result.amount_input.parsed == None

  // Right side should also be cleared (follows failed parse behavior)
  let right_result = converter.get_converter_input(result, Right)
  assert right_result.amount_input.raw == ""
  assert right_result.amount_input.parsed == None

  // last_edited should be updated to the edited side
  assert result.last_edited == Left

  // Rate should remain unchanged
  assert result.rate == Some(positive_float.from_float_unsafe(2.5))
}

pub fn with_amount_zero_input_converts_correctly_test() {
  // Set up converter with a valid rate
  let target =
    Converter(
      ..empty_converter(),
      rate: Some(positive_float.from_float_unsafe(2.5)),
      last_edited: Right,
    )

  let result = converter.with_amount(target, Left, "0")

  // Left side (edited) should have "0" as raw input and zero as parsed value
  let left_input = converter.get_converter_input(result, Left)
  assert left_input.amount_input.raw == "0"
  assert left_input.amount_input.parsed
    == Some(positive_float.from_float_unsafe(0.0))

  // Right side should be converted: 0 * 2.5 = 0
  let right_input = converter.get_converter_input(result, Right)
  let expected_converted_amount = positive_float.from_float_unsafe(0.0)
  let expected_raw =
    currency_formatting.format_currency_amount(expected_converted_amount)

  assert right_input.amount_input.raw == expected_raw
  assert right_input.amount_input.parsed == Some(expected_converted_amount)

  // last_edited should be updated to the edited side
  assert result.last_edited == Left

  // Rate should remain unchanged
  assert result.rate == Some(positive_float.from_float_unsafe(2.5))
}

// with_toggled_dropdown

pub fn with_toggled_dropdown_toggles_dropdown_visibility_from_false_to_true_test() {
  let result = converter.with_toggled_dropdown(empty_converter(), Left)

  assert converter.get_converter_input(result, Left).currency_selector.show_dropdown

  assert converter.get_converter_input(result, Left).currency_selector.show_dropdown
  assert !converter.get_converter_input(result, Right).currency_selector.show_dropdown
}

pub fn with_toggled_dropdown_toggles_dropdown_visibility_from_true_to_false_test() {
  let left_input =
    ConverterInput(
      ..empty_converter_input(),
      currency_selector: CurrencySelector(
        ..empty_converter_input().currency_selector,
        show_dropdown: True,
      ),
    )

  let right_input =
    ConverterInput(
      ..empty_converter_input(),
      currency_selector: CurrencySelector(
        ..empty_converter_input().currency_selector,
        show_dropdown: True,
      ),
    )

  let target =
    Converter(..empty_converter(), inputs: #(left_input, right_input))

  let result = converter.with_toggled_dropdown(target, Left)

  assert !converter.get_converter_input(result, Left).currency_selector.show_dropdown
  assert converter.get_converter_input(result, Right).currency_selector.show_dropdown
}

// with_selected_currency

pub fn with_selected_currency_sets_selected_currency_test() {
  let selected_currency = Crypto(999, "name", "symbol", None)

  let result =
    converter.with_selected_currency(empty_converter(), Left, selected_currency)

  assert converter.get_converter_input(result, Left).currency_selector.selected_currency
    == selected_currency

  assert converter.get_converter_input(result, Right)
    == converter.get_converter_input(empty_converter(), Right)
}

// with_focused_index

pub fn with_focused_index_sets_focused_index_to_next_focused_index_test() {
  let get_next_index = fn() { Some(1) }

  let result =
    converter.with_focused_index(empty_converter(), Left, get_next_index)

  assert converter.get_converter_input(result, Left).currency_selector.focused_index
    == Some(1)
}

// with_filtered_currencies

pub fn with_filtered_currencies_uses_defaults_when_filter_empty_test() {
  let master_currency_list = [
    Crypto(1, "Bitcoin", "BTC", Some(1)),
    Crypto(2, "Ethereum", "ETH", Some(2)),
    Crypto(3, "Tether", "USDT", Some(3)),
    Crypto(4, "BNB", "BNB", Some(4)),
    Crypto(5, "Solana", "SOL", Some(5)),
    Crypto(6, "USD Coin", "USDC", Some(6)),
  ]

  // Dummy default picker that returns a predictable set
  let dummy_default_picker = fn(_all_currencies) {
    [
      Crypto(1, "Bitcoin", "BTC", Some(1)),
      Crypto(3, "Tether", "USDT", Some(3)),
    ]
  }

  let dummy_matcher = fn(_, _) {
    panic as "should not be called with empty filter"
  }

  let target = Converter(..empty_converter(), master_currency_list:)

  let result =
    converter.with_filtered_currencies(
      target,
      Left,
      // Empty filter should trigger default picker
      "",
      dummy_matcher,
      dummy_default_picker,
    )

  // Should get exactly the currencies from our dummy default picker
  let left_currencies =
    converter.get_converter_input(result, Left).currency_selector.currencies

  let currency_list = currency_collection.flatten(left_currencies)

  assert list.length(currency_list) == 2
  // Bitcoin
  assert list.any(currency_list, fn(c) { c.id == 1 })
  // Tether
  assert list.any(currency_list, fn(c) { c.id == 3 })

  // Filter text should be updated
  assert converter.get_converter_input(result, Left).currency_selector.currency_filter
    == ""
}

pub fn with_filtered_currencies_filters_by_text_when_provided_test() {
  let master_currency_list = [
    Crypto(1, "Bitcoin", "BTC", None),
    Crypto(2, "Ethereum", "ETH", None),
    Crypto(3, "Litecoin", "LTC", None),
    Crypto(4, "Ripple", "XRP", None),
  ]

  // Dummy matcher that only matches Bitcoin and Litecoin for our test filter
  let dummy_matcher = fn(currency: currency.Currency, filter: String) {
    case filter {
      // Bitcoin or Litecoin
      "test_filter" -> currency.id == 1 || currency.id == 3
      _ -> False
    }
  }

  let dummy_default_picker = fn(_) {
    panic as "should not be called with non-empty filter"
  }

  // Set selected currency to Bitcoin (which would match our filter)
  let target =
    Converter(..empty_converter(), master_currency_list:, inputs: #(
      empty_converter_input(),
      ConverterInput(
        ..empty_converter_input(),
        currency_selector: CurrencySelector(
          ..empty_converter_input().currency_selector,
          // Should be excluded despite matching
          selected_currency: Crypto(1, "Bitcoin", "BTC", None),
        ),
      ),
    ))

  let result =
    converter.with_filtered_currencies(
      target,
      Right,
      "test_filter",
      dummy_matcher,
      dummy_default_picker,
    )

  let right_currencies =
    converter.get_converter_input(result, Right).currency_selector.currencies

  let currency_list = currency_collection.flatten(right_currencies)

  // Should only have Litecoin (matches filter, not selected)
  assert list.length(currency_list) == 1
  // Litecoin
  assert list.any(currency_list, fn(c) { c.id == 3 })

  // Should NOT have Bitcoin (excluded as selected currency despite matching filter)
  // Bitcoin (selected)
  assert !list.any(currency_list, fn(c) { c.id == 1 })
  // Should NOT have Ethereum or Ripple (don't match filter)
  // Ethereum
  assert !list.any(currency_list, fn(c) { c.id == 2 })
  // Ripple
  assert !list.any(currency_list, fn(c) { c.id == 4 })

  // Filter text should be updated
  assert converter.get_converter_input(result, Right).currency_selector.currency_filter
    == "test_filter"
}

pub fn with_filtered_currencies_excludes_selected_currency_test() {
  let master_currency_list = [
    Crypto(1, "Bitcoin", "BTC", None),
    Crypto(2, "Ethereum", "ETH", None),
    Crypto(3, "Litecoin", "LTC", None),
  ]

  // Set selected currency to BTC
  let target =
    Converter(..empty_converter(), master_currency_list:, inputs: #(
      ConverterInput(
        ..empty_converter_input(),
        currency_selector: CurrencySelector(
          ..empty_converter_input().currency_selector,
          selected_currency: Crypto(1, "Bitcoin", "BTC", None),
        ),
      ),
      empty_converter_input(),
    ))

  let result =
    converter.with_filtered_currencies(
      target,
      Left,
      // Should match Bitcoin and Litecoin, but exclude selected BTC
      "coin",
      currency_filtering.currency_matches_filter,
      currency_filtering.get_default_currencies,
    )

  let left_currencies =
    converter.get_converter_input(result, Left).currency_selector.currencies

  let currency_list = currency_collection.flatten(left_currencies)

  // Should only have Litecoin (Bitcoin excluded as selected currency)
  assert list.length(currency_list) == 1
  // Litecoin
  assert list.any(currency_list, fn(c) { c.id == 3 })
  // Bitcoin (excluded)
  assert !list.any(currency_list, fn(c) { c.id == 1 })
}

// get_converter_input

pub fn get_converter_input_returns_correct_side_test() {
  let left_input =
    ConverterInput(
      ..empty_converter_input(),
      currency_selector: CurrencySelector(
        ..empty_converter_input().currency_selector,
        id: "selector-1",
      ),
    )

  let right_input =
    ConverterInput(
      ..empty_converter_input(),
      currency_selector: CurrencySelector(
        ..empty_converter_input().currency_selector,
        id: "selector-2",
      ),
    )

  let target =
    Converter(..empty_converter(), inputs: #(left_input, right_input))

  assert converter.get_converter_input(target, Left) == left_input
  assert converter.get_converter_input(target, Right) == right_input
}

// to_rate_request

pub fn to_rate_request_extracts_currency_ids_test() {
  let left_input =
    ConverterInput(
      ..empty_converter_input(),
      currency_selector: CurrencySelector(
        ..empty_converter_input().currency_selector,
        selected_currency: Crypto(1, "", "", None),
      ),
    )

  let right_input =
    ConverterInput(
      ..empty_converter_input(),
      currency_selector: CurrencySelector(
        ..empty_converter_input().currency_selector,
        selected_currency: Crypto(2, "", "", None),
      ),
    )

  let target =
    Converter(..empty_converter(), inputs: #(left_input, right_input))

  assert converter.to_rate_request(target) == RateRequest(1, 2)
}

// map_converter_inputs

pub fn map_converter_inputs_only_updates_targeted_side_test() {
  let left_input =
    ConverterInput(
      AmountInput("100", Some(positive_float.from_float_unsafe(100.0)), None),
      CurrencySelector(
        "left-selector",
        True,
        "filter-text",
        currency_collection.from_list([]),
        Crypto(1, "Bitcoin", "BTC", None),
        Some(2),
      ),
    )

  let right_input =
    ConverterInput(
      AmountInput("200", Some(positive_float.from_float_unsafe(200.0)), None),
      CurrencySelector(
        "right-selector",
        False,
        "",
        currency_collection.from_list([]),
        Crypto(2, "Ethereum", "ETH", None),
        None,
      ),
    )

  let original_inputs = #(left_input, right_input)

  // Update only the left side - change the amount to "150"
  let updated_inputs =
    converter.map_converter_inputs(original_inputs, Left, fn(input) {
      ConverterInput(
        ..input,
        amount_input: AmountInput(
          "150",
          Some(positive_float.from_float_unsafe(150.0)),
          None,
        ),
      )
    })

  // Left side should be updated
  assert { updated_inputs.0 }.amount_input.raw == "150"
  assert { updated_inputs.0 }.amount_input.parsed
    == Some(positive_float.from_float_unsafe(150.0))

  // Right side should remain completely unchanged
  assert updated_inputs.1 == right_input
}

// update - UserEnteredAmount

pub fn update_user_entered_amount_calls_with_amount_test() {
  let #(result_converter, effect) =
    converter.update(empty_converter(), UserEnteredAmount(Left, "123"))

  // Should call with_amount and update the state accordingly
  // We don't need to test the detailed behavior (that's covered by with_amount tests)
  // Just verify that the message routes to the right function
  assert converter.get_converter_input(result_converter, Left).amount_input.raw
    == "123"

  assert effect == NoEffect
}

// update - UserClickedCurrencySelector

pub fn update_user_clicked_currency_selector_resets_filter_to_empty_test() {
  // Start with some filter text
  let left_input =
    ConverterInput(
      ..empty_converter_input(),
      currency_selector: CurrencySelector(
        ..empty_converter_input().currency_selector,
        currency_filter: "some_filter_text",
      ),
    )

  let target =
    Converter(..empty_converter(), inputs: #(
      left_input,
      empty_converter_input(),
    ))

  let #(result_converter, _) =
    converter.update(target, UserClickedCurrencySelector(Left))

  // Filter should be reset to empty string
  assert converter.get_converter_input(result_converter, Left).currency_selector.currency_filter
    == ""
}

pub fn update_user_clicked_currency_selector_resets_focused_index_test() {
  // Start with some focused index
  let left_input =
    ConverterInput(
      ..empty_converter_input(),
      currency_selector: CurrencySelector(
        ..empty_converter_input().currency_selector,
        focused_index: Some(5),
      ),
    )

  let target =
    Converter(..empty_converter(), inputs: #(
      left_input,
      empty_converter_input(),
    ))

  let #(result_converter, _) =
    converter.update(target, UserClickedCurrencySelector(Left))

  // Focused index should be reset to None
  assert converter.get_converter_input(result_converter, Left).currency_selector.focused_index
    == None
}

pub fn update_user_clicked_currency_selector_toggles_dropdown_test() {
  // Start with dropdown closed
  let target = empty_converter()

  let #(result_converter, _) =
    converter.update(target, UserClickedCurrencySelector(Left))

  // Dropdown should now be open
  assert converter.get_converter_input(result_converter, Left).currency_selector.show_dropdown
}

pub fn update_user_clicked_currency_selector_returns_focus_effect_when_opening_test() {
  // Start with dropdown closed
  let #(_, effect) =
    converter.update(empty_converter(), UserClickedCurrencySelector(Left))

  assert effect == FocusOnCurrencyFilter(Left)
}

pub fn update_user_clicked_currency_selector_returns_no_effect_when_closing_test() {
  // Start with dropdown open
  let left_input =
    ConverterInput(
      ..empty_converter_input(),
      currency_selector: CurrencySelector(
        ..empty_converter_input().currency_selector,
        show_dropdown: True,
      ),
    )

  let target =
    Converter(..empty_converter(), inputs: #(
      left_input,
      empty_converter_input(),
    ))

  let #(result_converter, effect) =
    converter.update(target, UserClickedCurrencySelector(Left))

  // Dropdown should now be closed
  assert !converter.get_converter_input(result_converter, Left).currency_selector.show_dropdown

  // Should return NoEffect when closing dropdown
  assert effect == NoEffect
}

// update - UserFilteredCurrencies

pub fn update_user_filtered_currencies_calls_with_filtered_currencies_test() {
  let target =
    Converter(..empty_converter(), master_currency_list: [
      Crypto(1, "Bitcoin", "BTC", None),
      Crypto(2, "Ethereum", "ETH", None),
    ])

  let #(result_converter, _) =
    converter.update(target, UserFilteredCurrencies(Left, "bit"))

  // Should call with_filtered_currencies and update the filter text
  assert converter.get_converter_input(result_converter, Left).currency_selector.currency_filter
    == "bit"
}

pub fn update_user_filtered_currencies_returns_no_effect_when_currencies_match_test() {
  let target =
    Converter(..empty_converter(), master_currency_list: [
      Crypto(1, "Bitcoin", "BTC", None),
      Crypto(2, "Ethereum", "ETH", None),
    ])

  let #(result_converter, effect) =
    converter.update(target, UserFilteredCurrencies(Left, "bit"))

  // Should have matching currencies (Bitcoin matches "bit")
  let currencies =
    converter.get_converter_input(result_converter, Left).currency_selector.currencies

  let currency_list = currency_collection.flatten(currencies)
  assert !list.is_empty(currency_list)

  // Should return NoEffect when currencies match
  assert effect == NoEffect
}

pub fn update_user_filtered_currencies_returns_request_currencies_when_no_match_test() {
  let target =
    Converter(..empty_converter(), master_currency_list: [
      Crypto(1, "Bitcoin", "BTC", None),
      Crypto(2, "Ethereum", "ETH", None),
    ])

  let #(result_converter, effect) =
    converter.update(target, UserFilteredCurrencies(Left, "nonexistent"))

  // Should have no matching currencies
  let currencies =
    converter.get_converter_input(result_converter, Left).currency_selector.currencies

  let currency_list = currency_collection.flatten(currencies)
  assert list.is_empty(currency_list)

  // Should return RequestCurrencies effect with the filter text
  assert effect == RequestCurrencies("nonexistent")
}

pub fn update_user_filtered_currencies_excludes_selected_currency_test() {
  // Set up converter where the selected currency would match the filter
  let left_input =
    ConverterInput(
      ..empty_converter_input(),
      currency_selector: CurrencySelector(
        ..empty_converter_input().currency_selector,
        selected_currency: Crypto(1, "Bitcoin", "BTC", None),
      ),
    )

  let target =
    Converter(
      ..empty_converter(),
      master_currency_list: [
        Crypto(1, "Bitcoin", "BTC", None),
        Crypto(2, "Ethereum", "ETH", None),
      ],
      inputs: #(left_input, empty_converter_input()),
    )

  let #(result_converter, effect) =
    converter.update(target, UserFilteredCurrencies(Left, "bit"))

  // Bitcoin should be excluded even though it matches "bit" because it's selected
  let currencies =
    converter.get_converter_input(result_converter, Left).currency_selector.currencies

  let currency_list = currency_collection.flatten(currencies)
  assert list.is_empty(currency_list)

  // Should return RequestCurrencies because no currencies are available after excluding selected
  assert effect == RequestCurrencies("bit")
}

// update - UserPressedKeyInCurrencySelector

pub fn update_user_pressed_key_arrow_down_updates_focused_index_test() {
  // Set up converter with some currencies and no current focus
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", None),
    Crypto(2, "Ethereum", "ETH", None),
  ]

  let left_input =
    ConverterInput(
      ..empty_converter_input(),
      currency_selector: CurrencySelector(
        ..empty_converter_input().currency_selector,
        currencies: currency_collection.from_list(currencies),
        focused_index: None,
      ),
    )

  let target =
    Converter(..empty_converter(), inputs: #(
      left_input,
      empty_converter_input(),
    ))

  let #(result_converter, effect) =
    converter.update(target, UserPressedKeyInCurrencySelector(Left, ArrowDown))

  // Should call with_focused_index and update the focused index
  let focused_index =
    converter.get_converter_input(result_converter, Left).currency_selector.focused_index

  // First item should be focused
  assert focused_index == Some(0)

  // Should return ScrollToOption effect
  assert effect == ScrollToOption(Left, 0)
}

pub fn update_user_pressed_key_arrow_up_updates_focused_index_test() {
  // Set up converter with some currencies and current focus on second item
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", None),
    Crypto(2, "Ethereum", "ETH", None),
  ]

  let left_input =
    ConverterInput(
      ..empty_converter_input(),
      currency_selector: CurrencySelector(
        ..empty_converter_input().currency_selector,
        currencies: currency_collection.from_list(currencies),
        // Currently on second item
        focused_index: Some(1),
      ),
    )

  let target =
    Converter(..empty_converter(), inputs: #(
      left_input,
      empty_converter_input(),
    ))

  let #(result_converter, effect) =
    converter.update(target, UserPressedKeyInCurrencySelector(Left, ArrowUp))

  // Should move focus to first item
  let focused_index =
    converter.get_converter_input(result_converter, Left).currency_selector.focused_index

  assert focused_index == Some(0)

  assert effect == ScrollToOption(Left, 0)
}

pub fn update_user_pressed_key_enter_selects_focused_currency_test() {
  // Set up converter with currencies and focus on second item
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", None),
    Crypto(2, "Ethereum", "ETH", None),
  ]

  let left_input =
    ConverterInput(
      ..empty_converter_input(),
      currency_selector: CurrencySelector(
        ..empty_converter_input().currency_selector,
        currencies: currency_collection.from_list(currencies),
        // Focus on Ethereum
        focused_index: Some(1),
        // Dropdown is open
        show_dropdown: True,
      ),
    )

  let target =
    Converter(..empty_converter(), inputs: #(
      left_input,
      empty_converter_input(),
    ))

  let #(result_converter, effect) =
    converter.update(target, UserPressedKeyInCurrencySelector(Left, Enter))

  // Should select the focused currency (Ethereum)
  assert converter.get_converter_input(result_converter, Left).currency_selector.selected_currency.id
    == 2

  // Should close the dropdown
  assert !converter.get_converter_input(result_converter, Left).currency_selector.show_dropdown

  assert effect == RequestRate
}

pub fn update_user_pressed_key_enter_with_no_focus_returns_no_effect_test() {
  // Set up converter with currencies but no focused index
  let currencies = [
    Crypto(1, "Bitcoin", "BTC", None),
    Crypto(2, "Ethereum", "ETH", None),
  ]

  let original_currency = Crypto(99, "Original", "ORIG", None)

  let left_input =
    ConverterInput(
      ..empty_converter_input(),
      currency_selector: CurrencySelector(
        ..empty_converter_input().currency_selector,
        currencies: currency_collection.from_list(currencies),
        // No focus
        focused_index: None,
        selected_currency: original_currency,
        show_dropdown: True,
      ),
    )

  let target =
    Converter(..empty_converter(), inputs: #(
      left_input,
      empty_converter_input(),
    ))

  let #(result_converter, effect) =
    converter.update(target, UserPressedKeyInCurrencySelector(Left, Enter))

  // Should not change selected currency
  assert converter.get_converter_input(result_converter, Left).currency_selector.selected_currency
    == original_currency

  // Should not change dropdown state
  assert converter.get_converter_input(result_converter, Left).currency_selector.show_dropdown

  // Should return NoEffect when no currency is focused (nothing changed)
  assert effect == NoEffect
}

pub fn update_user_pressed_key_other_does_nothing_test() {
  let target = empty_converter()

  let #(result_converter, effect) =
    converter.update(
      target,
      UserPressedKeyInCurrencySelector(Left, Other("Space")),
    )

  // Should not change the converter
  assert result_converter == target

  assert effect == NoEffect
}

pub fn update_user_pressed_key_navigation_with_empty_list_returns_no_effect_test() {
  // Set up converter with no currencies (empty list)
  let left_input =
    ConverterInput(
      ..empty_converter_input(),
      currency_selector: CurrencySelector(
        ..empty_converter_input().currency_selector,
        currencies: currency_collection.from_list([]),
        focused_index: None,
      ),
    )

  let target =
    Converter(..empty_converter(), inputs: #(
      left_input,
      empty_converter_input(),
    ))

  let #(result_converter, effect) =
    converter.update(target, UserPressedKeyInCurrencySelector(Left, ArrowDown))

  // Should not set any focused index (still None)
  let focused_index =
    converter.get_converter_input(result_converter, Left).currency_selector.focused_index

  assert focused_index == None

  // Should return NoEffect when no focused index is set
  assert effect == NoEffect
}

// update - UserSelectedCurrency

pub fn update_user_selected_currency_calls_with_selected_currency_test() {
  let new_currency = Crypto(999, "Test Currency", "TEST", None)

  let #(result_converter, effect) =
    converter.update(
      empty_converter(),
      converter.UserSelectedCurrency(Left, new_currency),
    )

  // Should call with_selected_currency and update the selected currency
  assert converter.get_converter_input(result_converter, Left).currency_selector.selected_currency
    == new_currency

  assert effect == RequestRate
}

pub fn update_user_selected_currency_toggles_dropdown_test() {
  // Start with dropdown open
  let left_input =
    ConverterInput(
      ..empty_converter_input(),
      currency_selector: CurrencySelector(
        ..empty_converter_input().currency_selector,
        show_dropdown: True,
      ),
    )

  let initial_converter =
    Converter(..empty_converter(), inputs: #(
      left_input,
      empty_converter_input(),
    ))

  let new_currency = Crypto(888, "Another Currency", "ANOT", None)

  let #(result_converter, _) =
    converter.update(
      initial_converter,
      converter.UserSelectedCurrency(Left, new_currency),
    )

  // Dropdown should be closed after selection
  assert !converter.get_converter_input(result_converter, Left).currency_selector.show_dropdown

  // Right side dropdown should be unchanged
  assert !converter.get_converter_input(result_converter, Right).currency_selector.show_dropdown
}

pub fn update_user_selected_currency_returns_request_rate_effect_test() {
  let new_currency = Crypto(777, "Rate Currency", "RATE", None)

  let #(_, effect) =
    converter.update(
      empty_converter(),
      converter.UserSelectedCurrency(Right, new_currency),
    )

  assert effect == RequestRate
}

// helper functions

fn empty_converter() {
  Converter(
    id: "",
    master_currency_list: [],
    inputs: #(empty_converter_input(), empty_converter_input()),
    rate: None,
    last_edited: Left,
  )
}

fn empty_converter_input() {
  ConverterInput(
    AmountInput("", None, None),
    CurrencySelector(
      id: "",
      show_dropdown: False,
      currency_filter: "",
      currencies: currency_collection.from_list([]),
      selected_currency: Crypto(0, "", "", None),
      focused_index: None,
    ),
  )
}
