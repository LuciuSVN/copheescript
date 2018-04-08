util = require 'util'

# This file contains the common helper functions that we'd like to share among
# the **Lexer**, **Rewriter**, and the **Nodes**. Merge objects, flatten
# arrays, count characters, that sort of thing.

# Peek at the beginning of a given string to see if it matches a sequence.
exports.starts = (string, literal, start) ->
  literal is string.substr start, literal.length

# Peek at the end of a given string to see if it matches a sequence.
exports.ends = (string, literal, back) ->
  len = literal.length
  literal is string.substr string.length - len - (back or 0), len

# Repeat a string `n` times.
exports.repeat = repeat = (str, n) ->
  # Use clever algorithm to have O(log(n)) string concatenation operations.
  res = ''
  while n > 0
    res += str if n & 1
    n >>>= 1
    str += str
  res

# Trim out all falsy values from an array.
exports.compact = (array) ->
  item for item in array when item

# Count the number of occurrences of a string in a string.
exports.count = (string, substr) ->
  num = pos = 0
  return 1/0 unless substr.length
  num++ while pos = 1 + string.indexOf substr, pos
  num

# Merge objects, returning a fresh copy with attributes from both sides.
# Used every time `Base#compile` is called, to allow properties in the
# options hash to propagate down the tree without polluting other branches.
exports.merge = (options, overrides) ->
  extend (extend {}, options), overrides

# Extend a source object with the properties of another object (shallow copy).
extend = exports.extend = (object, properties) ->
  for key, val of properties
    object[key] = val
  object

# Return a flattened version of an array.
# Handy for getting a list of `children` from the nodes.
exports.flatten = flatten = (array) ->
  flattened = []
  for element in array
    if '[object Array]' is Object::toString.call element
      flattened = flattened.concat flatten element
    else
      flattened.push element
  flattened

# Delete a key from an object, returning the value. Useful when a node is
# looking for a particular method in an options hash.
exports.del = (obj, key) ->
  val =  obj[key]
  delete obj[key]
  val

# Typical Array::some
exports.some = Array::some ? (fn) ->
  return true for e in this when fn e
  false

# Helper function for extracting code from Literate CoffeeScript by stripping
# out all non-code blocks, producing a string of CoffeeScript code that can
# be compiled “normally.”
exports.invertLiterate = (code) ->
  out = []
  blankLine = /^\s*$/
  indented = /^[\t ]/
  listItemStart = /// ^
    (?:\t?|\ {0,3})   # Up to one tab, or up to three spaces, or neither;
    (?:
      [\*\-\+] |      # followed by `*`, `-` or `+`;
      [0-9]{1,9}\.    # or by an integer up to 9 digits long, followed by a period;
    )
    [\ \t]            # followed by a space or a tab.
  ///
  insideComment = no
  for line in code.split('\n')
    if blankLine.test(line)
      insideComment = no
      out.push line
    else if insideComment or listItemStart.test(line)
      insideComment = yes
      out.push "# #{line}"
    else if not insideComment and indented.test(line)
      out.push line
    else
      insideComment = yes
      out.push "# #{line}"
  out.join '\n'

# Merge two jison-style location data objects together.
# If `last` is not provided, this will simply return `first`.
buildLocationData = (first, last) ->
  if not last
    first
  else
    first_line: first.first_line
    first_column: first.first_column
    last_line: last.last_line
    last_column: last.last_column
    range: [
      first.range[0]
      last.range[1]
    ]

buildLocationHash = (loc) ->
  "#{loc.first_line}x#{loc.first_column}-#{loc.last_line}x#{loc.last_column}"

# This returns a function which takes an object as a parameter, and if that
# object is an AST node, updates that object's locationData.
# The object is returned either way.
exports.addDataToNode = (parserState, first, last, {forceUpdateLocation} = {}) ->
  (obj) ->
    # Add location data
    if obj?.updateLocationDataIfMissing? and first?
      obj.updateLocationDataIfMissing buildLocationData(first, last), force: forceUpdateLocation

    # Add comments data
    unless parserState.tokenComments
      parserState.tokenComments = {}
      for token in parserState.parser.tokens when token.comments
        tokenHash = buildLocationHash token[2]
        unless parserState.tokenComments[tokenHash]?
          parserState.tokenComments[tokenHash] = token.comments
        else
          parserState.tokenComments[tokenHash].push token.comments...

    if obj.locationData?
      objHash = buildLocationHash obj.locationData
      if parserState.tokenComments[objHash]?
        attachCommentsToNode parserState.tokenComments[objHash], obj

    obj

exports.attachCommentsToNode = attachCommentsToNode = (comments, node) ->
  return if not comments? or comments.length is 0
  node.comments ?= []
  node.comments.push comments...

# Convert jison location data to a string.
# `obj` can be a token, or a locationData.
exports.locationDataToString = (obj) ->
  if ("2" of obj) and ("first_line" of obj[2]) then locationData = obj[2]
  else if "first_line" of obj then locationData = obj

  if locationData
    "#{locationData.first_line + 1}:#{locationData.first_column + 1}-" +
    "#{locationData.last_line + 1}:#{locationData.last_column + 1}"
  else
    "No location data"

# A `.coffee.md` compatible version of `basename`, that returns the file sans-extension.
exports.baseFileName = (file, stripExt = no, useWinPathSep = no) ->
  pathSep = if useWinPathSep then /\\|\// else /\//
  parts = file.split(pathSep)
  file = parts[parts.length - 1]
  return file unless stripExt and file.indexOf('.') >= 0
  parts = file.split('.')
  parts.pop()
  parts.pop() if parts[parts.length - 1] is 'coffee' and parts.length > 1
  parts.join('.')

# Determine if a filename represents a CoffeeScript file.
exports.isCoffee = (file) -> /\.((lit)?coffee|coffee\.md)$/.test file

# Determine if a filename represents a Literate CoffeeScript file.
exports.isLiterate = (file) -> /\.(litcoffee|coffee\.md)$/.test file

# Throws a SyntaxError from a given location.
# The error's `toString` will return an error message following the "standard"
# format `<filename>:<line>:<col>: <message>` plus the line with the error and a
# marker showing where the error is.
exports.throwSyntaxError = (message, location) ->
  error = new SyntaxError message
  error.location = location
  error.toString = syntaxErrorToString

  # Instead of showing the compiler's stacktrace, show our custom error message
  # (this is useful when the error bubbles up in Node.js applications that
  # compile CoffeeScript for example).
  error.stack = error.toString()

  throw error

# Update a compiler SyntaxError with source code information if it didn't have
# it already.
exports.updateSyntaxError = (error, code, filename) ->
  # Avoid screwing up the `stack` property of other errors (i.e. possible bugs).
  if error.toString is syntaxErrorToString
    error.code or= code
    error.filename or= filename
    error.stack = error.toString()
  error

syntaxErrorToString = ->
  return Error::toString.call @ unless @code and @location

  {first_line, first_column, last_line, last_column} = @location
  last_line ?= first_line
  last_column ?= first_column

  filename = @filename or '[stdin]'
  codeLine = @code.split('\n')[first_line]
  start    = first_column
  # Show only the first line on multi-line errors.
  end      = if first_line is last_line then last_column + 1 else codeLine.length
  marker   = codeLine[...start].replace(/[^\s]/g, ' ') + repeat('^', end - start)

  # Check to see if we're running on a color-enabled TTY.
  if process?
    colorsEnabled = process.stdout?.isTTY and not process.env?.NODE_DISABLE_COLORS

  if @colorful ? colorsEnabled
    colorize = (str) -> "\x1B[1;31m#{str}\x1B[0m"
    codeLine = codeLine[...start] + colorize(codeLine[start...end]) + codeLine[end..]
    marker   = colorize marker

  """
    #{filename}:#{first_line + 1}:#{first_column + 1}: error: #{@message}
    #{codeLine}
    #{marker}
  """

exports.nameWhitespaceCharacter = (string) ->
  switch string
    when ' ' then 'space'
    when '\n' then 'newline'
    when '\r' then 'carriage return'
    when '\t' then 'tab'
    else string

exports.getNumberValue = (number) ->
  orig = number
  return number if isNumber number
  invert = no
  unless isString number
    number = do ->
      number = number.unwrap()
      if number.operator
        invert = yes if number.operator is '-'
        number.first.unwrap().value
      else
        number.value
  base = switch number.charAt 1
    when 'b' then 2
    when 'o' then 8
    when 'x' then 16
    else null

  val = if base? then parseInt(number[2..], base) else parseFloat(number)
  return val unless invert
  val * -1

exports.dump = dump = (...args, obj) -> console.log ...args, util.inspect obj, no, null

exports.locationDataToBabylon = ({first_line, first_column, last_line, last_column, range}) -> {
  loc:
    start:
      line: first_line + 1
      column: first_column
    end:
      line: last_line + 1
      column: last_column
  range
  start: range[0]
  end: range[1] + 1
}

exports.isArray = isArray = (obj) -> Array.isArray obj
exports.isNumber = isNumber = (obj) -> Object::toString.call(obj) is '[object Number]'
exports.isString = isString = (obj) -> Object::toString.call(obj) is '[object String]'
exports.isBoolean = isBoolean = (obj) -> obj is yes or obj is no or Object::toString.call(obj) is '[object Boolean]'
exports.isPlainObject = isPlainObject = (obj) -> typeof obj is 'object' and !!obj and not isArray(obj) and not isNumber(obj) and not isString(obj) and not isBoolean(obj)

exports.mapValues = (obj, fn) ->
  Object.keys(obj).reduce (result, key) ->
    result[key] = fn obj[key], key
    result
  , {}

locationFields = ['loc', 'range', 'start', 'end']
exports.traverseBabylonAst = traverseBabylonAst = (node, func) ->
  if isArray node
    return (traverseBabylonAst(item, func) for item in node)
  func node
  if isPlainObject node
    traverseBabylonAst(child, func) for own _, child of node
exports.traverseBabylonAsts = traverseBabylonAsts = (node, correspondingNode, func) ->
  if isArray node
    return unless isArray correspondingNode
    return (traverseBabylonAsts(item, correspondingNode[index], func) for item, index in node)
  func node, correspondingNode
  if isPlainObject node
    return unless isPlainObject correspondingNode
    traverseBabylonAsts(child, correspondingNode[key], func) for own key, child of node when key not in locationFields
