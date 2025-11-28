import client/currency/collection.{type CurrencyCollection} as currency_collection
import client/currency/filtering as currency_filtering
import client/currency/formatting as currency_formatting
import client/positive_float.{type PositiveFloat}
import client/side.{type Side, Left, Right}
import client/ui/auto_resize_input
import client/ui/button_dropdown.{
  type NavKey, ArrowDown, ArrowUp, Button, ButtonDropdown, Dropdown,
  DropdownOption, Enter, Flat, Grouped, Other,
}
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/pair
import gleam/result
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/currency.{type Currency, Crypto}
import shared/rates/rate_request.{RateRequest}

pub type Converter {
  Converter(
    id: String,
    master_currency_list: List(Currency),
    inputs: #(ConverterInput, ConverterInput),
    rate: Option(PositiveFloat),
    last_edited: Side,
  )
}

pub type ConverterInput {
  ConverterInput(amount_input: AmountInput, currency_selector: CurrencySelector)
}

pub type AmountInput {
  AmountInput(
    raw: String,
    parsed: Option(PositiveFloat),
    border_color: Option(RateChangeColor),
  )
}

pub type CurrencySelector {
  CurrencySelector(
    id: String,
    show_dropdown: Bool,
    currency_filter: String,
    currencies: CurrencyCollection,
    selected_currency: Currency,
    focused_index: Option(Int),
  )
}

pub type RateChangeColor {
  Increased
  Decreased
  NoChange
}

fn rate_change_color_to_css_var(color: RateChangeColor) -> String {
  case color {
    Increased -> "--color-success"
    Decreased -> "--color-error"
    NoChange -> "--color-info"
  }
}

pub type NewConverterError {
  EmptyCurrencyList
  SelectedCurrencyNotFound(Int)
}

pub fn new(
  id: String,
  currencies: List(Currency),
  selected_currency_ids: #(Int, Int),
  left_amount: String,
  rate: Option(PositiveFloat),
) -> Result(Converter, NewConverterError) {
  let empty_converter = {
    let empty_converter_input = fn(side) {
      ConverterInput(
        AmountInput("", None, None),
        CurrencySelector(
          "currency-selector-" <> id <> "-" <> side.to_string(side),
          False,
          "",
          currency_collection.from_list([]),
          Crypto(0, "", "", None),
          None,
        ),
      )
    }

    Converter(
      id,
      [],
      #(empty_converter_input(Left), empty_converter_input(Right)),
      None,
      Left,
    )
  }

  use <- bool.guard(list.is_empty(currencies), Error(EmptyCurrencyList))

  let find_currency = fn(id) {
    currencies
    |> list.find(fn(c) { c.id == id })
    |> result.replace_error(SelectedCurrencyNotFound(id))
  }
  use from_currency <- result.try(find_currency(selected_currency_ids.0))
  use to_currency <- result.try(find_currency(selected_currency_ids.1))

  empty_converter
  |> with_master_currency_list(currencies)
  |> with_selected_currency(Left, from_currency)
  |> with_selected_currency(Right, to_currency)
  |> with_rate(rate)
  |> with_amount(Left, left_amount)
  |> Ok
}

pub fn with_master_currency_list(
  converter: Converter,
  currencies: List(Currency),
) -> Converter {
  let filter_currencies = fn(converter, side) {
    let filter_text =
      get_converter_input(converter, side).currency_selector.currency_filter

    with_filtered_currencies(
      converter,
      side,
      filter_text,
      currency_filtering.currency_matches_filter,
      currency_filtering.get_default_currencies,
    )
  }

  Converter(..converter, master_currency_list: currencies)
  |> filter_currencies(Left)
  |> filter_currencies(Right)
}

pub fn with_rate(converter, rate) -> Converter {
  with_rate_with_custom_glow(converter, rate, border_color_from_rate_change)
}

fn with_rate_with_custom_glow(
  converter: Converter,
  rate: Option(PositiveFloat),
  color_from_rate_change: fn(Option(PositiveFloat), Option(PositiveFloat)) ->
    Option(RateChangeColor),
) -> Converter {
  // When a new exchange rate comes in, we want to:
  // - Recalculate the opposite input field if the user previously entered a number
  // - Leave the inputs unchanged if there’s no valid parsed input
  // - Always update the stored rate

  let previous_rate = converter.rate
  let edited_side = converter.last_edited
  let opposite_side = side.opposite_side(edited_side)

  // Try to get the parsed amount from the side the user last edited
  let edited_side_parsed_amount =
    get_converter_input(converter, edited_side).amount_input.parsed

  // Decide how to update the inputs based on whether we have both a rate and parsed amount
  let inputs = case rate, edited_side_parsed_amount {
    None, Some(_) -> {
      // Rate is None but user has entered an amount, show "price not tracked" on opposite side
      converter.inputs
      |> map_converter_inputs(opposite_side, fn(input) {
        ConverterInput(
          ..input,
          amount_input: AmountInput("price not tracked", None, None),
        )
      })
    }

    None, None | Some(_), None -> converter.inputs

    Some(rate_value), Some(parsed_amount) -> {
      // Compute the value for the *opposite* field using the new rate
      let converted_amount = case edited_side {
        // converting from left to right
        Left -> Some(positive_float.multiply(parsed_amount, rate_value))

        // converting from right to left
        Right ->
          case positive_float.try_divide(parsed_amount, rate_value) {
            Error(_) -> panic as "rate should not be zero"
            Ok(x) -> Some(x)
          }
      }

      // Update only the opposite side’s amount_input field with the converted value
      converter.inputs
      |> map_converter_inputs(
        side.opposite_side(edited_side),
        fn(converter_input) {
          let amount_input = case converted_amount {
            None -> AmountInput("price not tracked", None, None)

            Some(amount) ->
              AmountInput(
                currency_formatting.format_currency_amount(
                  converter_input.currency_selector.selected_currency,
                  amount,
                ),
                Some(amount),
                color_from_rate_change(previous_rate, rate),
              )
          }

          ConverterInput(..converter_input, amount_input:)
        },
      )
    }
  }

  Converter(..converter, inputs:, rate:)
}

pub fn border_color_from_rate_change(
  previous_rate: Option(PositiveFloat),
  new_rate: Option(PositiveFloat),
) -> Option(RateChangeColor) {
  case previous_rate, new_rate {
    Some(x), Some(y) if x == y -> Some(NoChange)
    Some(x), Some(y) ->
      case positive_float.is_less_than(x, y) {
        False -> Some(Decreased)
        True -> Some(Increased)
      }
    None, _ -> Some(NoChange)
    Some(_), None -> None
  }
}

pub fn with_glow_cleared(converter: Converter, side: Side) -> Converter {
  converter_with_mapped_inputs(converter, side, fn(input) {
    ConverterInput(
      ..input,
      amount_input: AmountInput(..input.amount_input, border_color: None),
    )
  })
}

pub fn with_amount(
  converter: Converter,
  side: Side,
  raw_amount: String,
) -> Converter {
  let map_failed_parse = fn() {
    // Set the raw string on the edited side, clear the parsed value
    converter.inputs
    |> map_converter_inputs(side, fn(input) {
      ConverterInput(
        ..input,
        amount_input: AmountInput(
          ..input.amount_input,
          raw: raw_amount,
          parsed: None,
        ),
      )
    })
    // Clear the raw and parsed value on the opposite side
    |> map_converter_inputs(side.opposite_side(side), fn(input) {
      ConverterInput(
        ..input,
        amount_input: AmountInput(..input.amount_input, raw: "", parsed: None),
      )
    })
  }

  let map_successful_parse = fn(raw_amount, parsed_amount) {
    // Update the side the user edited
    converter.inputs
    |> map_converter_inputs(side, fn(input) {
      ConverterInput(
        ..input,
        amount_input: AmountInput(
          ..input.amount_input,
          raw: raw_amount,
          parsed: Some(parsed_amount),
        ),
      )
    })
    // Compute and set the converted amount on the opposite side if a rate is available
    |> map_converter_inputs(side.opposite_side(side), fn(_) {
      let opposite_input =
        get_converter_input(converter, side.opposite_side(side))

      let converted_amount = case side {
        Left ->
          option.map(converter.rate, positive_float.multiply(parsed_amount, _))

        Right ->
          option.map(converter.rate, fn(rate_value) {
            case positive_float.try_divide(parsed_amount, rate_value) {
              Ok(x) -> x
              _ -> panic as "rate should not be zero"
            }
          })
      }

      let amount_input = case converted_amount {
        None ->
          AmountInput(..opposite_input.amount_input, raw: "", parsed: None)

        Some(converted) -> {
          let raw_display =
            currency_formatting.format_currency_amount(
              opposite_input.currency_selector.selected_currency,
              converted,
            )

          AmountInput(
            ..opposite_input.amount_input,
            raw: raw_display,
            parsed: Some(converted),
          )
        }
      }

      ConverterInput(..opposite_input, amount_input:)
    })
  }

  let inputs = case positive_float.parse(raw_amount) {
    Error(_) -> map_failed_parse()
    Ok(parsed) -> map_successful_parse(raw_amount, parsed)
  }

  Converter(..converter, inputs:, last_edited: side)
}

pub fn with_toggled_dropdown(converter: Converter, side: Side) -> Converter {
  converter_with_mapped_inputs(converter, side, fn(input) {
    ConverterInput(
      ..input,
      currency_selector: CurrencySelector(
        ..input.currency_selector,
        show_dropdown: !input.currency_selector.show_dropdown,
      ),
    )
  })
}

pub fn with_selected_currency(
  converter: Converter,
  side: Side,
  currency: Currency,
) -> Converter {
  converter_with_mapped_inputs(converter, side, fn(input) {
    ConverterInput(
      ..input,
      currency_selector: CurrencySelector(
        ..input.currency_selector,
        selected_currency: currency,
      ),
    )
  })
}

pub fn with_focused_index(
  converter: Converter,
  side: Side,
  get_next_index: fn() -> Option(Int),
) -> Converter {
  converter_with_mapped_inputs(converter, side, fn(input) {
    ConverterInput(
      ..input,
      currency_selector: CurrencySelector(
        ..input.currency_selector,
        focused_index: get_next_index(),
      ),
    )
  })
}

pub fn with_filtered_currencies(
  converter: Converter,
  side: Side,
  filter_text: String,
  currency_matcher: fn(Currency, String) -> Bool,
  default_currency_picker: fn(List(Currency)) -> List(Currency),
) {
  let filter_or_get_defaults = fn(currencies) {
    case filter_text {
      "" -> default_currency_picker(currencies)
      _ -> list.filter(currencies, currency_matcher(_, filter_text))
    }
  }

  let remove_selected_currency = fn(currencies) {
    let selected_currency =
      get_converter_input(converter, side).currency_selector.selected_currency

    list.filter(currencies, fn(currency) { currency != selected_currency })
  }

  let currencies =
    converter.master_currency_list
    |> remove_selected_currency
    |> filter_or_get_defaults
    |> currency_collection.from_list

  converter_with_mapped_inputs(converter, side, fn(input) {
    ConverterInput(
      ..input,
      currency_selector: CurrencySelector(
        ..input.currency_selector,
        currency_filter: filter_text,
        currencies:,
      ),
    )
  })
}

pub fn converter_with_mapped_inputs(
  converter: Converter,
  side: Side,
  map_fn: fn(ConverterInput) -> ConverterInput,
) -> Converter {
  Converter(
    ..converter,
    inputs: map_converter_inputs(converter.inputs, side, map_fn),
  )
}

pub fn map_converter_inputs(
  inputs: #(ConverterInput, ConverterInput),
  side: Side,
  fun: fn(ConverterInput) -> ConverterInput,
) -> #(ConverterInput, ConverterInput) {
  let map_pair = case side {
    Left -> pair.map_first
    Right -> pair.map_second
  }
  map_pair(inputs, fun)
}

pub fn get_converter_input(converter: Converter, side: Side) {
  case side {
    Left -> converter.inputs.0
    Right -> converter.inputs.1
  }
}

pub fn to_rate_request(converter: Converter) {
  let from =
    get_converter_input(converter, Left).currency_selector.selected_currency

  let to =
    get_converter_input(converter, Right).currency_selector.selected_currency

  RateRequest(from.id, to.id)
}

pub type Msg {
  UserEnteredAmount(Side, String)
  UserClickedCurrencySelector(Side)
  UserFilteredCurrencies(Side, String)
  UserPressedKeyInCurrencySelector(Side, NavKey)
  UserSelectedCurrency(Side, Currency)
}

pub type Effect {
  NoEffect
  FocusOnCurrencyFilter(Side)
  ScrollToOption(side: Side, index: Int)
  RequestRate
  RequestCurrencies(String)
}

pub fn update(converter: Converter, msg: Msg) -> #(Converter, Effect) {
  case msg {
    UserEnteredAmount(side, amount_text) -> #(
      with_amount(converter, side, amount_text),
      NoEffect,
    )

    UserClickedCurrencySelector(side) -> {
      let converter =
        with_filtered_currencies(
          converter,
          side,
          "",
          currency_filtering.currency_matches_filter,
          currency_filtering.get_default_currencies,
        )
        |> with_focused_index(side, fn() { None })
        |> with_toggled_dropdown(side)

      let effect = {
        let dropdown_visible =
          get_converter_input(converter, side).currency_selector.show_dropdown

        case dropdown_visible {
          False -> NoEffect
          True -> FocusOnCurrencyFilter(side)
        }
      }

      #(converter, effect)
    }

    UserFilteredCurrencies(side, filter_text) -> {
      let converter =
        with_filtered_currencies(
          converter,
          side,
          filter_text,
          currency_filtering.currency_matches_filter,
          currency_filtering.get_default_currencies,
        )

      let effect = {
        let currency_selector =
          get_converter_input(converter, side).currency_selector

        let match_not_found =
          currency_selector.currencies
          |> currency_collection.flatten
          |> list.is_empty

        case match_not_found {
          False -> NoEffect
          True -> RequestCurrencies(filter_text)
        }
      }

      #(converter, effect)
    }

    UserPressedKeyInCurrencySelector(side, key) -> {
      let navigate_currency_selector = fn(converter, side, key) {
        let converter =
          with_focused_index(converter, side, fn() {
            let currency_selector =
              get_converter_input(converter, side).currency_selector

            button_dropdown.calculate_next_focused_index(
              currency_selector.focused_index,
              key,
              currency_collection.length(currency_selector.currencies),
            )
          })

        let focused_index =
          get_converter_input(converter, side).currency_selector.focused_index

        let effect = case focused_index {
          None -> NoEffect
          Some(index) -> ScrollToOption(side, index)
        }

        #(converter, effect)
      }

      let select_focused_currency = fn(converter, side) {
        let currency_selector =
          get_converter_input(converter, side).currency_selector

        let focused_index = currency_selector.focused_index
        let currencies = currency_selector.currencies

        case focused_index {
          None -> #(converter, NoEffect)

          Some(index) -> {
            let converter = {
              let assert Ok(selected_currency) =
                currency_collection.at_index(currencies, index)

              converter
              |> with_selected_currency(side, selected_currency)
              |> with_toggled_dropdown(side)
            }

            #(converter, RequestRate)
          }
        }
      }

      case key {
        ArrowDown | ArrowUp -> navigate_currency_selector(converter, side, key)
        Enter -> select_focused_currency(converter, side)
        Other(_) -> #(converter, NoEffect)
      }
    }

    UserSelectedCurrency(side, currency) -> {
      let converter =
        converter
        |> with_selected_currency(side, currency)
        |> with_toggled_dropdown(side)

      #(converter, RequestRate)
    }
  }
}

pub fn view(converter: Converter) -> Element(Msg) {
  let equal_sign =
    html.p([attribute.class("text-2xl font-semi-bold")], [element.text("=")])

  let conversion_input_elem = fn(side) {
    let target_input = get_converter_input(converter, side)

    let on_currency_selected = fn(currency_id_str) {
      let assert Ok(currency_id) = int.parse(currency_id_str)

      let assert Ok(currency) =
        target_input.currency_selector.currencies
        |> currency_collection.find_by_id(currency_id)

      UserSelectedCurrency(side, currency)
    }

    let on_keydown_in_dropdown = fn(key) {
      UserPressedKeyInCurrencySelector(side, case key {
        "ArrowUp" -> ArrowUp
        "ArrowDown" -> ArrowDown
        "Enter" -> Enter
        _ -> Other(key)
      })
    }

    conversion_input(
      amount_input(
        "amount-input-" <> converter.id <> "-" <> side.to_string(side),
        target_input.amount_input,
        option.is_none(converter.rate),
        UserEnteredAmount(side, _),
      ),
      currency_selector(
        target_input.currency_selector,
        UserClickedCurrencySelector(side),
        UserFilteredCurrencies(side, _),
        on_keydown_in_dropdown,
        on_currency_selected,
      ),
    )
  }

  html.div(
    [
      attribute.class(
        "flex flex-col md:flex-row "
        <> "items-center justify-left py-4 "
        <> "space-y-4 md:space-y-0 md:space-x-4",
      ),
    ],
    [conversion_input_elem(Left), equal_sign, conversion_input_elem(Right)],
  )
}

fn conversion_input(
  amount_input: Element(Msg),
  currency_selector: Element(Msg),
) -> Element(Msg) {
  html.span([attribute.class("flex flex-row items-center space-x-2")], [
    amount_input,
    currency_selector,
  ])
}

fn amount_input(
  id: String,
  amount_input: AmountInput,
  disabled: Bool,
  on_change: fn(String) -> Msg,
) -> Element(Msg) {
  let border_color =
    amount_input.border_color
    |> option.map(rate_change_color_to_css_var)

  auto_resize_input.element([
    auto_resize_input.id(id),
    auto_resize_input.value(amount_input.raw),
    auto_resize_input.min_width(184),
    auto_resize_input.disabled(disabled),
    auto_resize_input.border_color(border_color),
    on_change
      |> auto_resize_input.on_change
      |> event.debounce(300),
  ])
}

fn currency_selector(
  currency_selector: CurrencySelector,
  on_btn_click: Msg,
  on_filter: fn(String) -> Msg,
  on_keydown_in_dropdown: fn(String) -> Msg,
  on_select: fn(String) -> Msg,
) -> Element(Msg) {
  let currencies = currency_selector.currencies

  let dropdown_options =
    currencies
    |> currency_collection.index_map(
      currency_collection.currency_type_to_string,
      fn(currency, index) {
        DropdownOption(
          value: int.to_string(currency.id),
          display: html.text(currency.symbol <> " - " <> currency.name),
          is_focused: Some(index) == currency_selector.focused_index,
        )
      },
    )

  let dropdown_mode = case currency_selector.currency_filter {
    "" -> Flat
    _ -> Grouped
  }

  ButtonDropdown(
    currency_selector.id,
    Button(currency_selector.selected_currency.symbol, on_btn_click),
    Dropdown(
      currency_selector.currency_filter,
      dropdown_options,
      dropdown_mode,
      on_filter,
      on_keydown_in_dropdown,
      on_select,
    ),
    currency_selector.show_dropdown,
  )
  |> button_dropdown.view
}
