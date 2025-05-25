import client/browser/document
import client/browser/element as browser_element
import client/browser/shadow_root
import client/browser/window
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import lustre
import lustre/attribute.{type Attribute}
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

pub fn register(name: String) -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [
    component.on_attribute_change("id", fn(new_value) {
      Ok(ParentSetId(new_value))
    }),
    component.on_attribute_change("value", fn(new_value) {
      Ok(ParentSetValue(new_value))
    }),
    component.on_attribute_change("min-width", fn(new_value) {
      new_value
      |> int.parse
      |> result.map(ParentSetMinWidth)
    }),
    component.open_shadow_root(True),
  ])
  |> lustre.register(name)
}

pub fn auto_resize_input(attrs: List(Attribute(msg))) -> Element(msg) {
  element.element("auto-resize-input", attrs, [])
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

pub type Model {
  Model(id: String, value: String, width: Int, min_width: Int)
}

pub type Msg {
  ParentSetId(String)
  ParentSetValue(String)
  ParentSetMinWidth(Int)
  UserTypedValue(String)
  UserResizedInput(Int)
}

fn init(_) -> #(Model, Effect(Msg)) {
  #(Model("", "", 0, 0), effect.none())
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    ParentSetId(id) -> #(Model(..model, id:), effect.none())

    ParentSetValue(value) -> #(
      Model(..model, value:),
      resize_input(model.id, model.min_width),
    )

    ParentSetMinWidth(min_width) -> #(Model(..model, min_width:), effect.none())

    UserTypedValue(value) -> {
      #(
        Model(..model, value:),
        effect.batch([
          resize_input(model.id, model.min_width),
          event.emit("value-changed", json.string(value)),
        ]),
      )
    }

    UserResizedInput(width) -> #(Model(..model, width:), effect.none())
  }
}

fn view(model: Model) -> Element(Msg) {
  let input =
    html.input([
      attribute.class("px-6 py-4 border rounded-l-lg focus:outline-none"),
      attribute.class("font-light text-4xl text-center"),
      attribute.id(model.id),
      attribute.style("width", int.to_string(model.width) <> "px"),
      attribute.value(model.value),
      event.on_input(UserTypedValue),
    ])

  let mirror_input =
    html.span(
      [attribute.class("amount-input-mirror absolute invisible whitespace-pre")],
      [element.text(model.value)],
    )

  html.div([], [input, mirror_input])
}

fn resize_input(elem_id: String, min_width: Int) -> Effect(Msg) {
  use dispatch <- effect.from

  window.request_animation_frame(fn(_) {
    let assert Ok(input_elem) = document.get_element_by_id(elem_id)
    let shadow_root = shadow_root.shadow_root(input_elem)

    let assert Ok(shadow_input_elem) =
      shadow_root.query_selector(shadow_root, "input")

    let assert Ok(mirror_elem) =
      shadow_root.query_selector(shadow_root, ".amount-input-mirror")

    browser_element.copy_input_styles(shadow_input_elem, mirror_elem)

    let parse_pixel_count = fn(property_name) {
      let val =
        browser_element.get_computed_style_property(
          shadow_input_elem,
          property_name,
        )

      let assert True = string.ends_with(val, "px")

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

    let new_width =
      mirror_elem
      |> browser_element.offset_width
      |> int.to_float
      |> fn(mirror_offset_width) {
        ["paddingLeft", "paddingRight", "borderLeftWidth", "borderRightWidth"]
        |> list.map(parse_pixel_count)
        |> float.sum
        |> fn(x) { x +. mirror_offset_width +. 2.0 }
      }
      |> float.truncate
      |> int.max(min_width)

    new_width
    |> UserResizedInput
    |> dispatch

    Nil
  })

  Nil
}
