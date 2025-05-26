import client/browser/document
import client/browser/element as browser_element
import client/browser/shadow_root
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
      [attribute.class("input-mirror absolute invisible whitespace-pre")],
      [element.text(model.value)],
    )

  html.div([], [input, mirror_input])
}

fn resize_input(component_elem_id: String, min_width: Int) -> Effect(Msg) {
  use dispatch, _root_element <- effect.before_paint

  let assert Ok(component_elem) = document.get_element_by_id(component_elem_id)
  let shadow_root = shadow_root.shadow_root(component_elem)

  let assert Ok(shadow_input_elem) =
    shadow_root.query_selector(shadow_root, "input")

  let assert Ok(shadow_input_mirror_elem) =
    shadow_root.query_selector(shadow_root, ".input-mirror")

  browser_element.copy_input_styles(shadow_input_elem, shadow_input_mirror_elem)

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

  Nil
}

fn parse_pixel_count(
  from_elem: browser_element.Element,
  property_name: String,
) -> Float {
  let val =
    browser_element.get_computed_style_property(from_elem, property_name)

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
