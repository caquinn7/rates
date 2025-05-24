import { Ok, Error } from "./gleam.mjs";

export function shadowRoot(elem) {
  return elem.shadowRoot;
}

export function querySelector(shadowRoot, query) {
  let found = shadowRoot.querySelector(query)
  if (!found) {
    return new Error();
  }
  return new Ok(found);
}