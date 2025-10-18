import client/browser/document
import client/browser/element as browser_element
import client/currency/collection.{type CurrencyCollection} as currency_collection
import client/currency/formatting as currency_formatting
import client/positive_float.{type PositiveFloat}
import client/side.{type Side, Left, Right}
import client/ui/button_dropdown.{DropdownOption, Flat, Grouped}
import client/ui/components/auto_resize_input
import gleam/bool
import gleam/dynamic/decode
import gleam/int
import gleam/javascript/array
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/pair
import gleam/result
import gleam/string
import lustre
import lustre/attribute.{type Attribute}
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/currency.{type Currency, Crypto, Fiat}
import shared/rates/rate_request.{type RateRequest, RateRequest}

const element_name = "converter"

const request_rate_event = "requestrate"

const request_currencies_event = "requestcurrencies"

pub fn register() -> Result(Nil, lustre.Error) {
  let component_options = [
    component.on_attribute_change("id", fn(id) { Ok(ParentSetId(id)) }),
    component.on_property_change("currencies", {
      currency.decoder()
      |> decode.list
      |> decode.map(ParentSetCurrencies)
    }),
    component.on_attribute_change("from", fn(from) {
      from
      |> int.parse
      |> result.map(ParentSelectedCurrency(Left, _))
    }),
    component.on_attribute_change("to", fn(to) {
      to
      |> int.parse
      |> result.map(ParentSelectedCurrency(Right, _))
    }),
    component.on_attribute_change("from_amount", fn(amount) {
      amount
      |> positive_float.parse
      |> result.map(ParentSetAmount(Left, _))
    }),
    component.on_attribute_change("to_amount", fn(amount) {
      amount
      |> positive_float.parse
      |> result.map(ParentSetAmount(Right, _))
    }),
    component.on_attribute_change("rate", fn(rate) {
      case positive_float.parse(rate) {
        Error(_) -> Ok(ParentSetRate(None))
        Ok(r) -> Ok(ParentSetRate(Some(r)))
      }
    }),
  ]

  lustre.component(init, update, view, component_options)
  |> lustre.register(element_name)
}

pub fn element(attrs: List(Attribute(msg))) {
  element.element(element_name, attrs, [])
}

pub fn id(id: String) -> Attribute(msg) {
  attribute.id(id)
}

pub fn currencies(currencies: List(Currency)) -> Attribute(msg) {
  currencies
  |> json.array(currency.encode)
  |> attribute.property("currencies", _)
}

pub fn from(from: Int) -> Attribute(msg) {
  from
  |> int.to_string
  |> attribute.attribute("from", _)
}

pub fn to(to: Int) -> Attribute(msg) {
  to
  |> int.to_string
  |> attribute.attribute("to", _)
}

pub fn from_amount(amount: PositiveFloat) -> Attribute(msg) {
  amount
  |> positive_float.to_string
  |> attribute.attribute("from_amount", _)
}

pub fn to_amount(amount: PositiveFloat) -> Attribute(msg) {
  amount
  |> positive_float.to_string
  |> attribute.attribute("to_amount", _)
}

pub fn rate(rate: Option(PositiveFloat)) -> Attribute(msg) {
  rate
  |> option.map(positive_float.to_string)
  |> option.unwrap("")
  |> attribute.attribute("rate", _)
}

pub fn on_rate_request(handler: fn(RateRequest) -> msg) -> Attribute(msg) {
  let decoder =
    decode.at(["detail"], rate_request.decoder())
    |> decode.map(handler)

  event.on(request_rate_event, decoder)
}

pub fn on_request_currencies(handler: fn(String) -> msg) -> Attribute(msg) {
  let decoder =
    decode.at(["detail"], decode.string)
    |> decode.map(handler)

  event.on(request_currencies_event, decoder)
}

pub type Model {
  Model(
    id: String,
    currencies: List(Currency),
    conversion_inputs: #(ConversionInput, ConversionInput),
    rate: Option(PositiveFloat),
    last_edited: Side,
  )
}

pub type ConversionInput {
  ConversionInput(
    amount_input: AmountInput,
    currency_selector: CurrencySelector,
  )
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
    selected_currency: Option(Currency),
    focused_index: Option(Int),
  )
}

pub fn model_with_currencies(model: Model, currencies: List(Currency)) -> Model {
  let currency_collection = currency_collection.from_list(currencies)

  let conversion_input_with_currencies = fn(input) {
    ConversionInput(
      ..input,
      currency_selector: CurrencySelector(
        ..input.currency_selector,
        currencies: currency_collection,
      ),
    )
  }

  let conversion_inputs =
    model.conversion_inputs
    |> map_conversion_inputs(Left, conversion_input_with_currencies)
    |> map_conversion_inputs(Right, conversion_input_with_currencies)

  Model(..model, conversion_inputs:)
}

pub fn model_with_rate(model: Model, rate: PositiveFloat) -> Model {
  // When a new exchange rate comes in, we want to:
  // - Recalculate the opposite input field if the user previously entered a number
  // - Leave the inputs unchanged if there’s no valid parsed input
  // - Always update the stored rate

  let currency_missing = {
    let left_currency =
      get_conversion_input(model, Left).currency_selector.selected_currency

    let right_currency =
      get_conversion_input(model, Right).currency_selector.selected_currency

    option.is_none(left_currency) || option.is_none(right_currency)
  }
  use <- bool.guard(currency_missing, Model(..model, rate: Some(rate)))

  let edited_side = model.last_edited

  // Try to get the parsed amount from the side the user last edited
  let edited_side_parsed_amount =
    get_conversion_input(model, edited_side).amount_input.parsed

  // Decide how to update the inputs based on whether we have a parsed amount
  let updated_inputs = case edited_side_parsed_amount {
    None -> model.conversion_inputs

    Some(parsed_amount) -> {
      // Compute the value for the *opposite* field using the new rate
      let converted_amount = case edited_side {
        // converting from left to right
        Left -> positive_float.multiply(parsed_amount, rate)
        // converting from right to left
        Right ->
          case positive_float.try_divide(parsed_amount, rate) {
            Error(_) -> panic as "rate should not be zero"
            Ok(x) -> x
          }
      }

      // Update only the opposite side’s amount_input field with the converted value
      model.conversion_inputs
      |> map_conversion_inputs(side.opposite_side(edited_side), fn(input) {
        let assert Some(selected_currency) =
          input.currency_selector.selected_currency

        ConversionInput(
          ..input,
          amount_input: AmountInput(
            raw: currency_formatting.format_currency_amount(
              selected_currency,
              converted_amount,
            ),
            parsed: Some(converted_amount),
          ),
        )
      })
    }
  }

  Model(..model, conversion_inputs: updated_inputs, rate: Some(rate))
}

pub fn model_with_amount(model: Model, side: Side, raw_amount: String) -> Model {
  let conversion_inputs = model.conversion_inputs

  let map_failed_parse = fn() {
    // Set the raw string on the edited side, clear the parsed value
    conversion_inputs
    |> map_conversion_inputs(side, fn(input) {
      ConversionInput(..input, amount_input: AmountInput(raw_amount, None))
    })
    // Clear the raw and parsed value on the opposite side
    |> map_conversion_inputs(side.opposite_side(side), fn(input) {
      ConversionInput(..input, amount_input: AmountInput("", None))
    })
  }

  let map_successful_parse = fn(raw_amount, parsed_amount) {
    // Update the side the user edited
    conversion_inputs
    |> map_conversion_inputs(side, fn(input) {
      ConversionInput(
        ..input,
        amount_input: AmountInput(raw_amount, Some(parsed_amount)),
      )
    })
    // Compute and set the converted amount on the opposite side if a rate is available
    |> map_conversion_inputs(side.opposite_side(side), fn(_) {
      let opposite_side = side.opposite_side(side)
      let opposite_input = case opposite_side {
        Left -> model.conversion_inputs.0
        Right -> model.conversion_inputs.1
      }

      let converted_amount = case side {
        Left ->
          option.map(model.rate, positive_float.multiply(parsed_amount, _))

        Right ->
          option.map(model.rate, fn(rate_value) {
            case positive_float.try_divide(parsed_amount, rate_value) {
              Ok(x) -> x
              _ -> panic as "rate should not be zero"
            }
          })
      }

      let amount_input = case converted_amount {
        None -> AmountInput("", None)

        Some(converted) -> {
          let raw_display = case
            opposite_input.currency_selector.selected_currency
          {
            None -> positive_float.to_string(converted)
            Some(currency) ->
              currency_formatting.format_currency_amount(currency, converted)
          }

          AmountInput(raw_display, Some(converted))
        }
      }

      ConversionInput(..opposite_input, amount_input:)
    })
  }

  let conversion_inputs = case positive_float.parse(raw_amount) {
    Error(_) -> map_failed_parse()
    Ok(parsed) -> map_successful_parse(raw_amount, parsed)
  }

  Model(..model, conversion_inputs:, last_edited: side)
}

pub fn model_with_toggled_dropdown(model: Model, side: Side) -> Model {
  let conversion_inputs =
    model.conversion_inputs
    |> map_conversion_inputs(side, fn(input) {
      ConversionInput(
        ..input,
        currency_selector: CurrencySelector(
          ..input.currency_selector,
          show_dropdown: !input.currency_selector.show_dropdown,
        ),
      )
    })

  Model(..model, conversion_inputs:)
}

pub fn model_with_currency_filter(
  model: Model,
  side: Side,
  filter_str: String,
  currency_matcher: fn(Currency, String) -> Bool,
  default_currency_picker: fn(List(Currency)) -> List(Currency),
) -> Model {
  let filter_or_get_defaults = fn(currencies, filter_str) {
    case filter_str {
      "" -> default_currency_picker(currencies)
      _ -> list.filter(currencies, currency_matcher(_, filter_str))
    }
  }

  let remove_selected_currency = fn(currencies) {
    let selected_currency =
      get_conversion_input(model, side).currency_selector.selected_currency

    list.filter(currencies, fn(currency) { Some(currency) != selected_currency })
  }

  let currencies =
    model.currencies
    |> remove_selected_currency
    |> filter_or_get_defaults(filter_str)
    |> currency_collection.from_list

  let conversion_inputs =
    model.conversion_inputs
    |> map_conversion_inputs(side, fn(conversion_input) {
      ConversionInput(
        ..conversion_input,
        currency_selector: CurrencySelector(
          ..conversion_input.currency_selector,
          currency_filter: filter_str,
          currencies:,
        ),
      )
    })

  Model(..model, conversion_inputs:)
}

pub fn get_default_currencies(all_currencies: List(Currency)) -> List(Currency) {
  // want top 5 ranked cryptos
  let cryptos =
    all_currencies
    |> list.filter(fn(currency) {
      case currency {
        Crypto(..) -> True
        Fiat(..) -> False
      }
    })
    |> list.sort(currency_collection.compare_currencies)
    |> list.take(5)

  // just want USD
  let fiats =
    all_currencies
    |> list.filter(fn(currency) { currency.id == 2781 })

  cryptos
  |> list.append(fiats)
}

pub fn name_or_symbol_contains_filter(
  currency: Currency,
  filter_str: String,
) -> Bool {
  let is_match = fn(str) {
    str
    |> string.lowercase
    |> string.contains(string.lowercase(filter_str))
  }

  is_match(currency.name) || is_match(currency.symbol)
}

pub fn model_with_selected_currency(model: Model, side: Side, currency_id: Int) {
  let assert Ok(currency) =
    model.currencies
    |> list.find(fn(c) { c.id == currency_id })

  let conversion_inputs =
    model.conversion_inputs
    |> map_conversion_inputs(side, fn(input) {
      ConversionInput(
        ..input,
        currency_selector: CurrencySelector(
          ..input.currency_selector,
          selected_currency: Some(currency),
        ),
      )
    })

  Model(..model, conversion_inputs:)
}

pub fn model_with_focused_index(
  model: Model,
  side: Side,
  get_next_index: fn() -> Option(Int),
) {
  let conversion_inputs =
    model.conversion_inputs
    |> map_conversion_inputs(side, fn(input) {
      ConversionInput(
        ..input,
        currency_selector: CurrencySelector(
          ..input.currency_selector,
          focused_index: get_next_index(),
        ),
      )
    })

  Model(..model, conversion_inputs:)
}

pub fn get_conversion_input(model: Model, side: Side) -> ConversionInput {
  case side {
    Left -> model.conversion_inputs.0
    Right -> model.conversion_inputs.1
  }
}

pub fn map_conversion_inputs(
  inputs: #(ConversionInput, ConversionInput),
  side: Side,
  fun: fn(ConversionInput) -> ConversionInput,
) -> #(ConversionInput, ConversionInput) {
  let map_pair = case side {
    Left -> pair.map_first
    Right -> pair.map_second
  }
  map_pair(inputs, fun)
}

fn init(_) -> #(Model, Effect(Msg)) {
  let empty_conversion_input =
    ConversionInput(
      AmountInput("", None),
      CurrencySelector(
        "",
        False,
        "",
        currency_collection.from_list([]),
        None,
        None,
      ),
    )

  #(
    Model("", [], #(empty_conversion_input, empty_conversion_input), None, Left),
    effect.none(),
  )
}

type Msg {
  ParentSetId(String)
  ParentSetCurrencies(List(Currency))
  ParentSelectedCurrency(Side, Int)
  ParentSetAmount(Side, PositiveFloat)
  ParentSetRate(Option(PositiveFloat))
  UserEnteredAmount(Side, String)
  UserClickedCurrencySelector(Side)
  UserFilteredCurrencies(Side, String)
  UserPressedKeyInCurrencySelector(Side, NavKey)
  UserSelectedCurrency(Side, Int)
}

pub type NavKey {
  ArrowUp
  ArrowDown
  Enter
  Other(String)
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    ParentSetId(id) -> #(Model(..model, id:), effect.none())

    ParentSetCurrencies(currencies) -> #(
      model_with_currencies(model, currencies),
      effect.none(),
    )

    ParentSelectedCurrency(side, id) -> #(
      model_with_selected_currency(model, side, id),
      try_emit_rate_request_event(model),
    )

    ParentSetAmount(side, amount) -> #(
      model_with_amount(model, side, positive_float.to_string(amount)),
      effect.none(),
    )

    ParentSetRate(rate) -> {
      // expectation is that parent would never set rate to None,
      // so rate should only ever be None when the component is first created
      let model = case rate {
        None -> model
        Some(r) -> model_with_rate(model, r)
      }

      #(model, effect.none())
    }

    UserEnteredAmount(side, amount_str) -> #(
      model_with_amount(model, side, amount_str),
      effect.none(),
    )

    UserClickedCurrencySelector(side) -> #(
      model_with_toggled_dropdown(model, side),
      effect.none(),
    )

    UserFilteredCurrencies(side, filter_str) -> {
      let model =
        model_with_currency_filter(
          model,
          side,
          filter_str,
          name_or_symbol_contains_filter,
          get_default_currencies,
        )

      let effect = {
        let currency_selector =
          get_conversion_input(model, side).currency_selector

        let currencies = currency_selector.currencies
        let filter_str = currency_selector.currency_filter

        let no_match =
          currencies
          |> currency_collection.flatten
          |> list.is_empty

        case no_match {
          False -> effect.none()
          True -> event.emit(request_currencies_event, json.string(filter_str))
        }
      }

      #(model, effect)
    }

    UserPressedKeyInCurrencySelector(side, key) ->
      case key {
        ArrowDown -> navigate_currency_selector(model, side, key)
        ArrowUp -> navigate_currency_selector(model, side, key)
        Enter -> select_currency_via_enter_key(model, side)
        Other(_) -> #(model, effect.none())
      }

    UserSelectedCurrency(side, currency_id) -> {
      let model =
        model
        |> model_with_selected_currency(side, currency_id)
        |> model_with_toggled_dropdown(side)

      #(model, try_emit_rate_request_event(model))
    }
  }
}

pub fn calculate_next_focused_index(
  current_index: Option(Int),
  key: NavKey,
  option_count: Int,
) -> Option(Int) {
  use <- bool.guard(option_count == 0, None)

  current_index
  |> option.map(fn(index) {
    case key {
      ArrowDown -> { index + 1 } % option_count
      ArrowUp -> { index - 1 + option_count } % option_count
      _ -> index
    }
  })
  |> option.or(case key {
    ArrowDown -> Some(0)
    ArrowUp -> Some(option_count - 1)
    _ -> None
  })
}

fn navigate_currency_selector(
  model: Model,
  side: Side,
  key: NavKey,
) -> #(Model, Effect(Msg)) {
  let model = {
    let currency_selector = get_conversion_input(model, side).currency_selector

    model_with_focused_index(model, side, fn() {
      calculate_next_focused_index(
        currency_selector.focused_index,
        key,
        currency_collection.length(currency_selector.currencies),
      )
    })
  }

  let focused_index =
    get_conversion_input(model, side).currency_selector.focused_index

  let effect = case focused_index {
    None -> effect.none()

    Some(index) ->
      effect.before_paint(fn(_, _) {
        let currency_selector_id =
          get_conversion_input(model, side).currency_selector.id

        let option_elems =
          document.query_selector_all(
            "#"
            <> currency_selector_id
            <> " .options-container"
            <> " .dd-option",
          )

        let assert Ok(target_option_elem) = array.get(option_elems, index)
        let _ = browser_element.scroll_into_view(target_option_elem)

        Nil
      })
  }

  #(model, effect)
}

fn select_currency_via_enter_key(
  model: Model,
  side: Side,
) -> #(Model, Effect(Msg)) {
  let currency_selector = get_conversion_input(model, side).currency_selector
  let focused_index = currency_selector.focused_index
  let currencies = currency_selector.currencies

  let model = case focused_index {
    None -> model

    Some(index) -> {
      let assert Ok(selected_currency) =
        currencies
        |> currency_collection.at_index(index)

      model
      |> model_with_selected_currency(side, selected_currency.id)
      |> model_with_toggled_dropdown(side)
    }
  }

  #(model, try_emit_rate_request_event(model))
}

fn try_emit_rate_request_event(model: Model) -> Effect(Msg) {
  let from_currency =
    get_conversion_input(model, Left).currency_selector.selected_currency

  let to_currency =
    get_conversion_input(model, Right).currency_selector.selected_currency

  case from_currency, to_currency {
    Some(from), Some(to) ->
      RateRequest(from.id, to.id)
      |> rate_request.encode
      |> event.emit(request_rate_event, _)

    _, _ -> effect.none()
  }
}

fn view(model: Model) -> Element(Msg) {
  let equal_sign =
    html.p([attribute.class("text-3xl font-semi-bold")], [element.text("=")])

  let conversion_input_elem = fn(side) {
    let target_conversion_input = get_conversion_input(model, side)

    let on_currency_selected = fn(currency_id_str) {
      let assert Ok(currency_id) = int.parse(currency_id_str)
      UserSelectedCurrency(side, currency_id)
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
  let dropdown_options =
    currency_selector.currencies
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

  let btn_text = case currency_selector.selected_currency {
    None -> ""
    Some(currency) -> currency.symbol
  }

  button_dropdown.view(
    currency_selector.id,
    btn_text,
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
