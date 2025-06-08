import client/ui/button.{Button}
import gleam/json
import gleam/option.{type Option, None, Some}
import lustre
import lustre/attribute.{type Attribute}
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html

pub fn register(name: String) -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [
    component.on_attribute_change("id", fn(new_id) { Ok(ParentSetId(new_id)) }),
    component.on_attribute_change("value", fn(new_value) {
      Ok(ParentSetValue(new_value))
    }),
    component.on_attribute_change("btn_text", fn(new_btn_text) {
      Ok(ParentSetBtnText(new_btn_text))
    }),
  ])
  |> lustre.register(name)
}

pub fn element(attrs: List(Attribute(msg)), children) -> Element(msg) {
  element.element("button-dropdown", attrs, children)
}

pub fn id(id: String) -> Attribute(msg) {
  attribute.id(id)
}

pub fn value(value: String) -> Attribute(msg) {
  attribute.value(value)
}

pub fn btn_text(btn_text: String) -> Attribute(msg) {
  attribute.attribute("btn_text", btn_text)
}

pub fn dropdown_visible(value: Bool) -> Attribute(msg) {
  attribute.property("dropdown-hidden", json.bool(value))
}

pub type Model {
  Model(
    id: String,
    selected: Option(String),
    btn_text: String,
    dropdown_visible: Bool,
  )
}

fn init(_) -> #(Model, Effect(Msg)) {
  #(
    Model(id: "", selected: None, btn_text: "", dropdown_visible: False),
    effect.none(),
  )
}

pub type Msg {
  ParentSetId(String)
  ParentSetValue(String)
  ParentSetBtnText(String)
  UserClickedBtn
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    ParentSetId(id) -> #(Model(..model, id:), effect.none())

    ParentSetValue(value) -> #(
      Model(..model, selected: Some(value)),
      effect.none(),
    )

    ParentSetBtnText(btn_text) -> #(Model(..model, btn_text:), effect.none())

    UserClickedBtn -> #(
      Model(..model, dropdown_visible: !model.dropdown_visible),
      effect.none(),
    )
  }
}

fn view(model: Model) -> Element(Msg) {
  html.div([attribute.class("relative"), attribute.id(model.id)], [
    button.view(Button(model.btn_text, UserClickedBtn)),
    dropdown(model.dropdown_visible),
  ])
}

fn dropdown(visible: Bool) -> Element(Msg) {
  html.div(
    [
      attribute.class(
        "absolute z-10 border rounded-lg shadow-md max-h-64 overflow-y-auto",
      ),
      attribute.class(
        "min-w-max left-1/2 transform -translate-x-1/2 w-auto translate-y-3",
      ),
      case visible {
        True -> attribute.none()
        False -> attribute.class("hidden")
      },
    ],
    // [search_input(filter), html.div([], [todo])],
    [component.named_slot("options", [], [])],
  )
}
