import { Ok, Error } from "../../gleam.mjs";

export function getElementById(id) {
  let found = document.getElementById(id);
  if (!found) {
    return new Error();
  }
  return new Ok(found);
}

export function querySelector(query) {
  let found = document.querySelector(query);
  if (!found) {
    return new Error();
  }
  return new Ok(found);
}

export function querySelectorAll(query) {
  return Array.from(document.querySelectorAll(query));
}

export function getDocumentUrl() {
  return document.URL;
}

export function addEventListener(type, listener) {
  return document.addEventListener(type, listener);
}
