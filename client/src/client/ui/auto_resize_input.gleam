import client/browser/document
import client/browser/element as browser_element
import client/browser/shadow_root
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre
import lustre/attribute.{type Attribute}
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

const element_name = "auto-resize-input"

const change_event = "change"

const focus_event = "input-focus"

const blur_event = "input-blur"

pub type InputEvent {
  InputEvent(value: String, selection_start: Int, selection_end: Int)
}

pub type Selection {
  Selection(value: String, start: Int, end: Int, revision: Int)
}

fn input_event_decoder() -> decode.Decoder(InputEvent) {
  use value <- decode.field("value", decode.string)
  use selection_start <- decode.field("selectionStart", decode.int)
  use selection_end <- decode.field("selectionEnd", decode.int)
  decode.success(InputEvent(value:, selection_start:, selection_end:))
}

fn selection_decoder() -> decode.Decoder(Selection) {
  use value <- decode.field("value", decode.string)
  use start <- decode.field("start", decode.int)
  use end <- decode.field("end", decode.int)
  use revision <- decode.field("revision", decode.int)
  decode.success(Selection(value:, start:, end:, revision:))
}

fn input_event_json(input: InputEvent) -> json.Json {
  json.object([
    #("value", json.string(input.value)),
    #("selectionStart", json.int(input.selection_start)),
    #("selectionEnd", json.int(input.selection_end)),
  ])
}

/// Registers this component as a custom web component.
/// 
/// Uses a shadow DOM to encapsulate the input and mirror element, preventing
/// style conflicts with the rest of the page while still allowing accurate
/// width measurements through computed styles.
pub fn register() -> Result(Nil, lustre.Error) {
  let component_options = [
    component.on_attribute_change("id", fn(id) { Ok(ParentSetId(id)) }),
    component.on_attribute_change("value", fn(value) {
      Ok(ParentSetValue(value))
    }),
    component.on_attribute_change("min-width", fn(min_width) {
      min_width
      |> int.parse
      |> result.map(ParentSetMinWidth)
    }),
    component.on_property_change(
      "disabled",
      decode.map(decode.bool, ParentSetDisabled),
    ),
    component.on_property_change("border_color", {
      decode.string
      |> decode.optional
      |> decode.map(ParentSetBorderColor)
    }),
    component.on_property_change(
      "selection",
      decode.map(decode.optional(selection_decoder()), ParentSetSelection),
    ),
    component.open_shadow_root(True),
  ]

  lustre.component(init, update, view, component_options)
  |> lustre.register(element_name)
}

pub fn element(attrs: List(Attribute(msg))) -> Element(msg) {
  element.element(element_name, attrs, [])
}

pub fn id(id: String) -> Attribute(msg) {
  attribute.id(id)
}

pub fn value(value: String) -> Attribute(msg) {
  attribute.value(value)
}

pub fn min_width(value: Int) -> Attribute(msg) {
  attribute.attribute("min-width", int.to_string(value))
}

pub fn disabled(is_disabled: Bool) -> Attribute(msg) {
  attribute.property("disabled", json.bool(is_disabled))
}

pub fn on_change(handler: fn(InputEvent) -> msg) -> Attribute(msg) {
  event.on(
    change_event,
    decode.map(decode.at(["detail"], input_event_decoder()), handler),
  )
}

pub fn on_focus(handler: fn(InputEvent) -> msg) -> Attribute(msg) {
  event.on(
    focus_event,
    decode.map(decode.at(["detail"], input_event_decoder()), handler),
  )
}

pub fn on_blur(handler: fn(InputEvent) -> msg) -> Attribute(msg) {
  event.on(
    blur_event,
    decode.map(decode.at(["detail"], input_event_decoder()), handler),
  )
}

pub fn selection(value: Option(Selection)) -> Attribute(msg) {
  attribute.property(
    "selection",
    json.nullable(value, fn(selection) {
      json.object([
        #("value", json.string(selection.value)),
        #("start", json.int(selection.start)),
        #("end", json.int(selection.end)),
        #("revision", json.int(selection.revision)),
      ])
    }),
  )
}

pub fn border_color(color: Option(String)) -> Attribute(msg) {
  attribute.property("border_color", json.nullable(color, json.string))
}

type Model {
  Model(
    id: String,
    value: String,
    width: Int,
    min_width: Int,
    disabled: Bool,
    border_color: Option(String),
  )
}

fn init(_) -> #(Model, Effect(Msg)) {
  #(Model("", "", 0, 0, False, None), effect.none())
}

type Msg {
  ParentSetId(String)
  ParentSetValue(String)
  ParentSetMinWidth(Int)
  ParentSetDisabled(Bool)
  ParentSetBorderColor(Option(String))
  ParentSetSelection(Option(Selection))
  UserTypedValue(InputEvent)
  UserFocused(InputEvent)
  UserBlurred(InputEvent)
  UserResizedInput(Int)
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    ParentSetId(id) -> #(Model(..model, id:), effect.none())

    ParentSetValue(value) -> #(
      Model(..model, value:),
      resize_input(model.id, model.min_width),
    )

    ParentSetMinWidth(min_width) -> #(Model(..model, min_width:), effect.none())

    ParentSetDisabled(disabled) -> #(Model(..model, disabled:), effect.none())

    ParentSetBorderColor(border_color) -> #(
      Model(..model, border_color:),
      effect.none(),
    )

    ParentSetSelection(None) -> #(model, effect.none())

    ParentSetSelection(Some(selection)) -> #(
      model,
      effect.before_paint(fn(_, _) {
        case get_shadow_elements(model.id) {
          Ok(#(input, _)) ->
            browser_element.set_selection_range(
              input,
              selection.value,
              selection.start,
              selection.end,
            )
          Error(_) -> Nil
        }
      }),
    )

    UserFocused(input) -> #(
      model,
      event.emit(focus_event, input_event_json(input)),
    )

    UserBlurred(input) -> #(
      model,
      event.emit(blur_event, input_event_json(input)),
    )

    UserTypedValue(input) ->
      case model.disabled {
        False -> #(
          Model(..model, value: input.value),
          effect.batch([
            resize_input(model.id, model.min_width),
            event.emit(change_event, input_event_json(input)),
          ]),
        )

        True -> #(model, effect.none())
      }

    UserResizedInput(width) -> #(Model(..model, width:), effect.none())
  }
}

fn view(model: Model) -> Element(Msg) {
  let input =
    html.input([
      attribute.id(model.id),
      attribute.class("px-3 py-3 border-2 rounded-l-lg focus:outline-none"),
      attribute.class("font-light text-3xl text-center"),
      attribute.styles([
        #("font-family", "var(--font-mono)"),
        #("width", int.to_string(model.width) <> "px"),
      ]),
      attribute.value(model.value),
      attribute.disabled(model.disabled),
      case model.disabled {
        True -> attribute.class("opacity-75")
        False -> attribute.none()
      },
      case model.border_color {
        None -> attribute.none()
        Some(_) -> attribute.class("animate-glow")
      },
      case model.border_color {
        None -> attribute.none()
        Some(color) -> attribute.style("--glow-color", "var(" <> color <> ")")
      },
      event.on(
        "input",
        decode.map(decode.at(["target"], input_event_decoder()), UserTypedValue),
      ),
      event.on(
        "focus",
        decode.map(decode.at(["target"], input_event_decoder()), UserFocused),
      ),
      event.on(
        "blur",
        decode.map(decode.at(["target"], input_event_decoder()), UserBlurred),
      ),
    ])

  let mirror_input =
    html.span(
      [attribute.class("input-mirror absolute invisible whitespace-pre")],
      [element.text(model.value)],
    )

  html.div([], [input, mirror_input])
}

/// Dynamically resizes the input element to fit its content.
///
/// Standard HTML inputs have fixed widths, causing text overflow. This function
/// measures the actual text width using an invisible mirror element with identical
/// styling, then updates the input width to match (respecting the minimum width).
///
/// The measurement runs before paint to avoid visual flickering, and the shadow DOM
/// ensures the mirror element doesn't interfere with page layout.
fn resize_input(auto_resize_input_id: String, min_width: Int) -> Effect(Msg) {
  use dispatch, _root_element <- effect.before_paint

  case get_shadow_elements(auto_resize_input_id) {
    Error(_) -> Nil

    Ok(#(shadow_input_elem, shadow_input_mirror_elem)) -> {
      let _ =
        browser_element.copy_input_styles(
          shadow_input_elem,
          shadow_input_mirror_elem,
        )

      let new_width =
        shadow_input_mirror_elem
        |> browser_element.offset_width
        |> int.to_float
        |> fn(mirror_offset_width) {
          ["paddingLeft", "paddingRight", "borderLeftWidth", "borderRightWidth"]
          |> list.map(parse_pixel_count(shadow_input_elem, _))
          |> float.sum
          |> fn(x) { x +. mirror_offset_width +. 2.0 }
        }
        |> float.truncate
        |> int.max(min_width)

      new_width
      |> UserResizedInput
      |> dispatch
    }
  }
}

fn get_shadow_elements(
  auto_resize_input_id: String,
) -> Result(#(browser_element.Element, browser_element.Element), Nil) {
  use component_elem <- result.try(document.get_element_by_id(
    auto_resize_input_id,
  ))

  let shadow_root = shadow_root.shadow_root(component_elem)

  use shadow_input_elem <- result.try(shadow_root.query_selector(
    shadow_root,
    "input",
  ))
  use shadow_input_mirror_elem <- result.try(shadow_root.query_selector(
    shadow_root,
    ".input-mirror",
  ))

  Ok(#(shadow_input_elem, shadow_input_mirror_elem))
}

fn parse_pixel_count(
  from_elem: browser_element.Element,
  property_name: String,
) -> Float {
  let val =
    browser_element.get_computed_style_property(from_elem, property_name)

  assert True == string.ends_with(val, "px")
  let pixel_count_str = string.replace(val, "px", "")

  let assert Ok(parsed) =
    pixel_count_str
    |> float.parse
    |> result.lazy_or(fn() {
      int.parse(pixel_count_str)
      |> result.map(int.to_float)
    })

  parsed
}
