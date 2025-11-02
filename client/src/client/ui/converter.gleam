import client/currency/collection.{type CurrencyCollection} as currency_collection
import client/currency/filtering as currency_filtering
import client/currency/formatting as currency_formatting
import client/positive_float.{type PositiveFloat}
import client/side.{type Side, Left, Right}
import client/ui/button_dropdown.{
  type NavKey, ArrowDown, ArrowUp, DropdownOption, Enter, Flat, Grouped, Other,
}
import client/ui/components/auto_resize_input
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/pair
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/currency.{type Currency}
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
  AmountInput(raw: String, parsed: Option(PositiveFloat))
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

pub fn with_rate(converter: Converter, rate: Option(PositiveFloat)) -> Converter {
  // When a new exchange rate comes in, we want to:
  // - Recalculate the opposite input field if the user previously entered a number
  // - Leave the inputs unchanged if there’s no valid parsed input
  // - Always update the stored rate

  let edited_side = converter.last_edited

  // Try to get the parsed amount from the side the user last edited
  let edited_side_parsed_amount =
    get_converter_input(converter, edited_side).amount_input.parsed

  // Decide how to update the inputs based on whether we have a parsed amount
  let inputs = case edited_side_parsed_amount {
    None -> converter.inputs

    Some(parsed_amount) -> {
      // Compute the value for the *opposite* field using the new rate
      let converted_amount = case edited_side {
        // converting from left to right
        Left -> option.map(rate, positive_float.multiply(parsed_amount, _))

        // converting from right to left
        Right ->
          option.then(rate, fn(r) {
            case positive_float.try_divide(parsed_amount, r) {
              Error(_) -> panic as "rate should not be zero"
              Ok(x) -> Some(x)
            }
          })
      }

      // Update only the opposite side’s amount_input field with the converted value
      converter.inputs
      |> map_converter_inputs(
        side.opposite_side(edited_side),
        fn(converter_input) {
          let amount_input = case converted_amount {
            None -> AmountInput("price not tracked", None)

            Some(amount) ->
              AmountInput(
                currency_formatting.format_currency_amount(
                  converter_input.currency_selector.selected_currency,
                  amount,
                ),
                Some(amount),
              )
          }

          ConverterInput(..converter_input, amount_input:)
        },
      )
    }
  }

  Converter(..converter, inputs:, rate:)
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
      ConverterInput(..input, amount_input: AmountInput(raw_amount, None))
    })
    // Clear the raw and parsed value on the opposite side
    |> map_converter_inputs(side.opposite_side(side), fn(input) {
      ConverterInput(..input, amount_input: AmountInput("", None))
    })
  }

  let map_successful_parse = fn(raw_amount, parsed_amount) {
    // Update the side the user edited
    converter.inputs
    |> map_converter_inputs(side, fn(input) {
      ConverterInput(
        ..input,
        amount_input: AmountInput(raw_amount, Some(parsed_amount)),
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
        None -> AmountInput("", None)

        Some(converted) -> {
          let raw_display =
            currency_formatting.format_currency_amount(
              opposite_input.currency_selector.selected_currency,
              converted,
            )

          AmountInput(raw_display, Some(converted))
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
    html.p([attribute.class("text-3xl font-semi-bold")], [element.text("=")])

  let conversion_input_elem = fn(side) {
    let target_conversion_input = get_converter_input(converter, side)

    let on_currency_selected = fn(currency_id_str) {
      let assert Ok(currency_id) = int.parse(currency_id_str)

      let assert Ok(currency) =
        target_conversion_input.currency_selector.currencies
        |> currency_collection.find_by_id(currency_id)

      UserSelectedCurrency(side, currency)
    }

    let on_keydown_in_dropdown = fn(key_str) {
      let nav_key = case key_str {
        "ArrowUp" -> ArrowUp
        "ArrowDown" -> ArrowDown
        "Enter" -> Enter
        s -> Other(s)
      }

      UserPressedKeyInCurrencySelector(side, nav_key)
    }

    conversion_input(
      amount_input(
        "amount-input-" <> side.to_string(side),
        target_conversion_input.amount_input,
        UserEnteredAmount(side, _),
      ),
      currency_selector(
        target_conversion_input.currency_selector,
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
        <> "items-center justify-center p-4 "
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
  on_change: fn(String) -> Msg,
) -> Element(Msg) {
  auto_resize_input.element([
    auto_resize_input.id(id),
    auto_resize_input.value(amount_input.raw),
    auto_resize_input.min_width(48),
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

  button_dropdown.view(
    currency_selector.id,
    currency_selector.selected_currency.symbol,
    currency_selector.show_dropdown,
    currency_selector.currency_filter,
    dropdown_options,
    dropdown_mode,
    on_btn_click,
    on_filter,
    on_keydown_in_dropdown,
    on_select,
  )
}
