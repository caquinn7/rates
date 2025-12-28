import client/browser/element.{type Element}
import client/browser/event.{type Event}
import gleam/javascript/array.{type Array}

@external(javascript, "./document_ffi.mjs", "getElementById")
pub fn get_element_by_id(id: String) -> Result(Element, Nil)

@external(javascript, "./document_ffi.mjs", "querySelector")
pub fn query_selector(selector: String) -> Result(Element, Nil)

@external(javascript, "./document_ffi.mjs", "querySelectorAll")
pub fn query_selector_all(selector: String) -> Array(Element)

@external(javascript, "./document_ffi.mjs", "getDocumentUrl")
pub fn get_document_url() -> String

@external(javascript, "./document_ffi.mjs", "addEventListener")
pub fn add_event_listener(type_: String, listener: fn(Event) -> Nil) -> Nil
