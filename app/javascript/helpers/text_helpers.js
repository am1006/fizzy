export function isMultiLineString(string) {
  return /\r|\n/.test(string)
}
