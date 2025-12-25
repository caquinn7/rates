import { Ok, Error } from "./gleam.mjs";

export function safe_multiply(a, b) {
  const x = a * b;

  if (!Number.isFinite(x)) {
    return new Error(undefined);
  }

  return new Ok(x);
}
