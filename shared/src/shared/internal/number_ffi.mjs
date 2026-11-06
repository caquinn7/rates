export function isFinite(n) {
  return Number.isFinite(n);
}

export function toFixed(n, digits) {
  // At 1e21 and above, toFixed switches to exponential notation.
  // JavaScript numbers this large cannot represent fractional parts, so format
  // the stored integer with BigInt and add the requested decimal places as zeros.
  if (n >= 1e21) {
    const whole = BigInt(n).toString();
    if (digits === 0) {
      return whole;
    } else {
      return whole + "." + "0".repeat(digits);
    }
  }
  return n.toFixed(digits);
}
