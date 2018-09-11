# `nodes.coffee` contains all of the node classes for the syntax tree. Most
# nodes are created as the result of actions in the [grammar](grammar.html),
# but some are created by other nodes as a method of code generation. To convert
# the syntax tree into a string of JavaScript code, call `compile()` on the root.

Error.stackTraceLimit = Infinity

{Scope} = require './scope'
{isUnassignable, JS_FORBIDDEN} = require './lexer'
prettier = require 'prettier'
babylon = require 'babylon'

# Import the helpers we plan to use.
{compact, flatten, extend, merge, del, starts, ends, some,
addDataToNode, attachCommentsToNode, locationDataToString,
throwSyntaxError,  replaceUnicodeCodePointEscapes,
locationDataToAst, astLocationFields, mergeAstLocationData
isFunction, isPlainObject, isBoolean,
getNumberValue, dump,
mapValues, traverseBabylonAst, makeDelimitedLiteral,
mergeLocationData,
assignEmptyTrailingLocationData} = require './helpers'

# Functions required by parser.
exports.extend = extend
exports.addDataToNode = addDataToNode

# Constant functions for nodes that don’t need customization.
YES     = -> yes
NO      = -> no
THIS    = -> this
NEGATE  = -> @negated = not @negated; this

# Levels indicate a node's position in the AST. Useful for knowing if
# parens are necessary or superfluous.
LEVEL_TOP    = 1  # ...;
LEVEL_PAREN  = 2  # (...)
LEVEL_LIST   = 3  # [...]
LEVEL_COND   = 4  # ... ? x : y
LEVEL_OP     = 5  # !...
LEVEL_ACCESS = 6  # ...[0]

#### CodeFragment

# The various nodes defined below all compile to a collection of **CodeFragment** objects.
# A CodeFragments is a block of generated code, and the location in the source file where the code
# came from. CodeFragments can be assembled together into working code just by catting together
# all the CodeFragments' `code` snippets, in order.
exports.CodeFragment = class CodeFragment
  constructor: (parent, code) ->
    @code = "#{code}"
    @type = parent?.constructor?.name or 'unknown'
    @locationData = parent?.locationData
    @comments = parent?.comments

  toString: ->
    # This is only intended for debugging.
    "#{@code}#{if @locationData then ": " + locationDataToString(@locationData) else ''}"

# Convert an array of CodeFragments into a string.
fragmentsToText = (fragments) ->
  (fragment.code for fragment in fragments).join('')

#### Base

# The **Base** is the abstract base class for all nodes in the syntax tree.
# Each subclass implements the `compileNode` method, which performs the
# code generation for that node. To compile a node to JavaScript,
# call `compile` on it, which wraps `compileNode` in some generic extra smarts,
# to know when the generated code needs to be wrapped up in a closure.
# An options hash is passed and cloned throughout, containing information about
# the environment from higher in the tree (such as if a returned value is
# being requested by the surrounding function), information about the current
# scope, and indentation level.
exports.Base = class Base

  compile: (o, lvl) ->
    fragmentsToText @compileToFragments o, lvl

  # Occasionally a node is compiled multiple times, for example to get the name
  # of a variable to add to scope tracking. When we know that a “premature”
  # compilation won’t result in comments being output, set those comments aside
  # so that they’re preserved for a later `compile` call that will result in
  # the comments being included in the output.
  compileWithoutComments: (o, lvl, method = 'compile') ->
    if @comments
      @ignoreTheseCommentsTemporarily = @comments
      delete @comments
    unwrapped = @unwrapAll()
    if unwrapped.comments
      unwrapped.ignoreTheseCommentsTemporarily = unwrapped.comments
      delete unwrapped.comments

    fragments = @[method] o, lvl

    if @ignoreTheseCommentsTemporarily
      @comments = @ignoreTheseCommentsTemporarily
      delete @ignoreTheseCommentsTemporarily
    if unwrapped.ignoreTheseCommentsTemporarily
      unwrapped.comments = unwrapped.ignoreTheseCommentsTemporarily
      delete unwrapped.ignoreTheseCommentsTemporarily

    fragments

  compileNodeWithoutComments: (o, lvl) ->
    @compileWithoutComments o, lvl, 'compileNode'

  # Common logic for determining whether to wrap this node in a closure before
  # compiling it, or to compile directly. We need to wrap if this node is a
  # *statement*, and it's not a *pureStatement*, and we're not at
  # the top level of a block (which would be unnecessary), and we haven't
  # already been asked to return the result (because statements know how to
  # return results).
  compileToFragments: (o, lvl) ->
    o        = extend {}, o
    o.level  = lvl if lvl
    node     = @unfoldSoak(o) or this
    node.tab = o.indent

    fragments = if o.level is LEVEL_TOP or not node.isStatement(o)
      node.compileNode o
    else
      node.compileClosure o
    @compileCommentFragments o, node, fragments
    fragments

  compileToBabylon: (o, level) ->
    o = extend {}, o
    o.level = level if level
    node = @unfoldSoak(o) or this

    @withBabylonComments o, do =>
      return node.compileClosureToBabylon o unless o.level is LEVEL_TOP or not node.isStatement o
      @withAstLocationData node._compileToBabylon o

  _compileToBabylon: (o) ->
    @withAstType @_toAst(o), o

  withBabylonComments: (o, compiled, {comments = @comments} = {}) ->
    return compiled unless comments
    {start} = (compiled ?= {})
    comments =
      # compact(
      for comment in comments when comment not in @compiledBabylonComments and not comment.includeWithDeclaration
        @compiledBabylonComments.push comment
        compiledComment = new (if comment.here then HereComment else LineComment)(comment).compileToBabylon o
        continue unless compiledComment?
        leading = comment.forceLeading or compiledComment.end <= start
        compiledComment.leading = leading
        compiledComment.trailing = not leading
        compiledComment
    return compiled unless comments.length
    if Array.isArray compiled
      [...rest, last] = compiled
      [...rest, {...last, comments}]
    else if compiled
      {...compiled, comments}
    else
      {comments}

  withEmptyBabylonLocationData: (compiled) ->
    @withAstLocationData compiled, emptyLocationData

  withoutBabylonLocationData: (compiled) ->
    return compiled unless compiled?.start?
    compiled.start = compiled.end = compiled.loc = compiled.range = null
    compiled

  withCopiedBabylonLocationData: (compiled, other) ->
    compiled[field] = other[field] for field in astLocationFields
    compiled

  withLocationData: (node, {force} = {}) ->
    node.forceUpdateLocation = yes if force
    node.updateLocationDataIfMissing @locationData

  withLocationDataFrom: ({locationData}, {force} = {}) ->
    @forceUpdateLocation = yes if force
    @updateLocationDataIfMissing locationData

  withEmptyTrailingLocationDataFrom: (other) ->
    assignEmptyTrailingLocationData @, other

  mergeLocationDataFrom: (node) ->
    mergeLocationData @, node

  withEmptyLocationData: ->
    @withLocationDataFrom emptyLocationData

  sniffDirectives: (expressions, {replace, notFinalExpression} = {}) ->
    directives = []
    index = 0
    lastIndex = expressions.length - 1
    while expr = expressions[index]
      break if index is lastIndex and notFinalExpression
      break unless expr instanceof Value and expr.isString()
      if expr.hoisted
        index++
      else
        if replace
          expressions[index++] = expr.withLocationData new Directive expr
        else
          directives.push expressions.splice(index, 1)...
    directives

  compileClosureToBabylon: (o) ->
    if jumpNode = @jumps()
      jumpNode.error 'cannot use a pure statement in an expression'
    o.sharedScope = yes

    func = new Code [], Block.wrap [this]
    if @contains ((node) -> node instanceof SuperCall)
      func.bound = yes
    wrapInYieldFromOrAwait = switch
      when func.isGenerator
        (node) -> new Op 'yieldfrom', node
      when func.isAsync
        (node) -> new Op 'await', node
      else
        (node) -> node
    @withLocationData(wrapInYieldFromOrAwait(
      if @contains isLiteralArguments
        new Call(
          new Value func, [new Access new PropertyName 'apply']
          [new ThisLiteral, new IdentifierLiteral 'arguments']
        )
      else if @contains isLiteralThis
        new Call(
          new Value func, [new Access new PropertyName 'call']
          [new ThisLiteral]
        )
      else
        new Call func, []
    )).compileToBabylon o

  compileToFragmentsWithoutComments: (o, lvl) ->
    @compileWithoutComments o, lvl, 'compileToFragments'

  # Statements converted into expressions via closure-wrapping share a scope
  # object with their parent closure, to preserve the expected lexical scope.
  compileClosure: (o) ->
    if jumpNode = @jumps()
      jumpNode.error 'cannot use a pure statement in an expression'
    o.sharedScope = yes
    func = new Code [], Block.wrap [this]
    args = []
    if @contains ((node) -> node instanceof SuperCall)
      func.bound = yes
    else if (argumentsNode = @contains isLiteralArguments) or @contains isLiteralThis
      args = [new ThisLiteral]
      if argumentsNode
        meth = 'apply'
        args.push new IdentifierLiteral 'arguments'
      else
        meth = 'call'
      func = new Value func, [new Access new PropertyName meth]
    parts = (new Call func, args).compileNode o

    switch
      when func.isGenerator or func.base?.isGenerator
        parts.unshift @makeCode "(yield* "
        parts.push    @makeCode ")"
      when func.isAsync or func.base?.isAsync
        parts.unshift @makeCode "(await "
        parts.push    @makeCode ")"
    parts

  compileCommentFragments: (o, node, fragments) ->
    return fragments unless node.comments
    # This is where comments, that are attached to nodes as a `comments`
    # property, become `CodeFragment`s. “Inline block comments,” e.g.
    # `/* */`-delimited comments that are interspersed within code on a line,
    # are added to the current `fragments` stream. All other fragments are
    # attached as properties to the nearest preceding or following fragment,
    # to remain stowaways until they get properly output in `compileComments`
    # later on.
    unshiftCommentFragment = (commentFragment) ->
      if commentFragment.unshift
        # Find the first non-comment fragment and insert `commentFragment`
        # before it.
        unshiftAfterComments fragments, commentFragment
      else
        if fragments.length isnt 0
          precedingFragment = fragments[fragments.length - 1]
          if commentFragment.newLine and precedingFragment.code isnt '' and
             not /\n\s*$/.test precedingFragment.code
            commentFragment.code = "\n#{commentFragment.code}"
        fragments.push commentFragment

    for comment in node.comments when comment not in @compiledComments
      @compiledComments.push comment # Don’t output this comment twice.
      # For block/here comments, denoted by `###`, that are inline comments
      # like `1 + ### comment ### 2`, create fragments and insert them into
      # the fragments array.
      # Otherwise attach comment fragments to their closest fragment for now,
      # so they can be inserted into the output later after all the newlines
      # have been added.
      if comment.here # Block comment, delimited by `###`.
        commentFragment = new HereComment(comment).compileNode o
      else # Line comment, delimited by `#`.
        commentFragment = new LineComment(comment).compileNode o
      if (commentFragment.isHereComment and not commentFragment.newLine) or
         node.includeCommentFragments()
        # Inline block comments, like `1 + /* comment */ 2`, or a node whose
        # `compileToFragments` method has logic for outputting comments.
        unshiftCommentFragment commentFragment
      else
        fragments.push @makeCode '' if fragments.length is 0
        if commentFragment.unshift
          fragments[0].precedingComments ?= []
          fragments[0].precedingComments.push commentFragment
        else
          fragments[fragments.length - 1].followingComments ?= []
          fragments[fragments.length - 1].followingComments.push commentFragment
    fragments

  # If the code generation wishes to use the result of a complex expression
  # in multiple places, ensure that the expression is only ever evaluated once,
  # by assigning it to a temporary variable. Pass a level to precompile.
  #
  # If `level` is passed, then returns `[val, ref]`, where `val` is the compiled value, and `ref`
  # is the compiled reference. If `level` is not passed, this returns `[val, ref]` where
  # the two values are raw nodes which have not been compiled.
  cache: (o, level, opts = {}) ->
    if isPlainObject level
      opts = level
      {level} = opts
    {shouldCache, onlyIfCached} = opts
    complex = if shouldCache? then shouldCache this else @shouldCache()
    if complex
      ref = new IdentifierLiteral o.scope.freeVariable 'ref'
      sub = @withLocationData new Assign ref, this
      if level then [sub.compileToFragments(o, level), [@makeCode(ref.value)]] else [sub, ref]
    else
      ref = if level then @compileToFragments o, level else this
      [
        if onlyIfCached then null else ref
        ref
      ]

  # Occasionally it may be useful to make an expression behave as if it was 'hoisted', whereby the
  # result of the expression is available before its location in the source, but the expression's
  # variable scope corresponds the source position. This is used extensively to deal with executable
  # class bodies in classes.
  #
  # Calling this method mutates the node, proxying the `compileNode` and `compileToFragments`
  # methods to store their result for later replacing the `target` node, which is returned by the
  # call.
  hoist: ->
    @hoisted = yes
    target   = new HoistTarget @

    compileNode        = @compileNode
    compileToFragments = @compileToFragments

    @compileNode = (o) ->
      target.update compileNode, o

    @compileToFragments = (o) ->
      target.update compileToFragments, o

    compileToBabylon = @compileToBabylon
    @compileToBabylon = (o) ->
      target.updateBabylon compileToBabylon, o

    target

  cacheToCodeFragments: (cacheValues) ->
    [fragmentsToText(cacheValues[0]), fragmentsToText(cacheValues[1])]

  # Construct a node that returns the current node's result.
  # Note that this is overridden for smarter behavior for
  # many statement nodes (e.g. If, For)...
  makeReturn: ({accumulator, mark} = {}) ->
    return @canBeReturned = yes if mark
    me = @unwrapAll()
    @withLocationData(
      if accumulator
        new Call new Value(new IdentifierLiteral(accumulator), [new Access new PropertyName 'push']), [me]
      else
        new Return me
    )

  # Does this node, or any of its children, contain a node of a certain kind?
  # Recursively traverses down the *children* nodes and returns the first one
  # that verifies `pred`. Otherwise return undefined. `contains` does not cross
  # scope boundaries.
  contains: (pred) ->
    node = undefined
    @traverseChildren no, (n) ->
      if pred n
        node = n
        return no
    node

  # Pull out the last node of a node list.
  lastNode: (list) ->
    if list.length is 0 then null else list[list.length - 1]

  # Debugging representation of the node, for inspecting the parse tree.
  # This is what `coffee --nodes` prints out.
  toString: (idt = '', name = @constructor.name) ->
    tree = '\n' + idt + name
    tree += '?' if @soak
    @eachChild (node) -> tree += node.toString idt + TAB
    tree

  # Plain JavaScript object representation of the node, that can be serialized
  # as JSON. This is used for generating an abstract syntax tree (AST).
  # This is what the `ast` option in the Node API returns.
  toJSON: (o) ->
    # We try to follow the [Babel AST spec](https://github.com/babel/babel/blob/master/packages/babylon/ast/spec.md)
    # as closely as possible, for improved interoperability with other tools.
    @toAst o

  # Returns the full AST for the node.
  toAst: (o, level) ->
    return @compileToBabylon o, level if o.compiling
    o = extend {}, o
    o.level = level if level
    @makeReturn mark: yes if @isStatement(o) and o.level isnt LEVEL_TOP
    @withAstLocationData @withAstReturns @withAstType @_toAst(o), o

  # By default, a node class's AST `type` is the class name
  astType: -> @constructor.name

  # Adds `type` to an AST.
  # A node class typically defines `astType` (as a string or callback) if it
  # needs to override the default-generated `type` (ie its constructor name)
  withAstType: (ast, o) ->
    return ast unless ast
    return ast if Array.isArray ast
    return ast if ast.type
    return ast unless @emptyAst or do ->
      return yes for key in Object.keys(ast) when key not in ['comments', astLocationFields...]

    merge ast,
      type: @astType?(o) ? @astType

  # Returns the "content" (ie not `type` or location data) of the AST for the node.
  # By default, recursively generates AST nodes for `children`.
  # To override, a node class can either:
  #   - define `astChildren` to specify how to generate full child nodes, and/or
  #     `astProps` to specify how to generate non-child-node fields
  #   - override the `_toAst()` method
  _toAst: (o) ->
    merge(
      @getAstChildren o
      @getAstProps o
    )

  # Returns the child-nodes fields of the AST node.
  # By default, recursively generates AST nodes for `children`.
  # To override, a node class defines `astChildren`, which can be either:
  # - an array of property names (like `children`) which should have their generated
  #   AST nodes included recursively.
  # - an object whose keys are the desired AST field names and whose values are either:
  #   - a string, which is the name of the node object property whose generated AST node
  #     should be the corresponding value included in the AST
  #   - an object with `key` and/or `level` fields. `key` corresponds to the simple string
  #     value above, ie it's the name of a node object property. `level` is the desired
  #     AST "compilation" level for that child node, eg `LEVEL_PAREN`
  # - a callback function, which should return all the AST child-node fields
  getAstChildren: (o) ->
    return @astChildren o if isFunction @astChildren
    childAsts = {}
    addChildAst = ({propName, key = propName, level, default: defaultVal}) =>
      propName ?= key
      val = @[propName]
      childAsts[key] =
        if Array.isArray val
          item.toAst o, level for item in val
        else
          if val?
            val.toAst o, level
          else
            defaultVal

    children = @astChildren ? @children
    if Array.isArray children
      addChildAst {propName} for propName in children
    else
      for key, propName of children
        {propName, level, default: defaultVal} = propName if isPlainObject propName
        addChildAst {propName, key, level, default: defaultVal}
    childAsts

  astProps: []
  # Returns the "simple" (ie non-child-nodes) fields of the AST node.
  # By default, returns an empty object.
  # To override, a node class defines `astProps`, which can be either:
  # - an array of property names which should have their values included.
  # - an object whose keys are the desired AST field names and whose values are
  #   the corresponding "mapped" node class property names whose values should be included.
  # - a callback function, which should return all the AST non-child-node fields
  getAstProps: (o) ->
    return @astProps o if isFunction @astProps
    astFields = {}
    if Array.isArray @astProps
      for propName in @astProps
        astFields[propName] = @[propName]
    else
      for key, propName of @astProps
        astFields[key] = @[propName]
    astFields

  withAstLocationData: (ast, node) ->
    return (@withAstLocationData(item, node) for item in ast) if Array.isArray ast
    {locationData} = node ? @
    return ast unless locationData and ast and not ast.start?
    merge ast, locationDataToAst locationData

  withAstReturns: (ast) ->
    return ast unless ast
    ast.returns = yes if @canBeReturned
    ast

  # Passes each child to a function, breaking when the function returns `false`.
  eachChild: (func) ->
    return this unless @children
    for attr in @children when @[attr]
      for child in flatten [@[attr]]
        return this if func(child) is false
    this

  traverseChildren: (crossScope, func) ->
    @eachChild (child) ->
      recur = func(child)
      child.traverseChildren(crossScope, func) unless recur is no

  # `replaceInContext` will traverse children looking for a node for which `match` returns
  # true. Once found, the matching node will be replaced by the result of calling `replacement`.
  replaceInContext: (match, replacement) ->
    return false unless @children
    for attr in @children when children = @[attr]
      if Array.isArray children
        for child, i in children
          if match child
            children[i..i] = replacement child, @
            return true
          else
            return true if child.replaceInContext match, replacement
      else if match children
        @[attr] = replacement children, @
        return true
      else
        return true if children.replaceInContext match, replacement

  invert: ->
    @withLocationData new Op '!', this

  unwrapAll: ->
    node = this
    continue until node is node = node.unwrap()
    node

  # Default implementations of the common node properties and methods. Nodes
  # will override these with custom logic, if needed.

  # `children` are the properties to recurse into when tree walking. The
  # `children` list *is* the structure of the AST. The `parent` pointer, and
  # the pointer to the `children` are how you can traverse the tree.
  children: []

  # `isStatement` has to do with “everything is an expression”. A few things
  # can’t be expressions, such as `break`. Things that `isStatement` returns
  # `true` for are things that can’t be used as expressions. There are some
  # error messages that come from `nodes.coffee` due to statements ending up
  # in expression position.
  isStatement: NO

  # Track comments that have been compiled into fragments, to avoid outputting
  # them twice.
  compiledComments: []
  compiledBabylonComments: []

  # `includeCommentFragments` lets `compileCommentFragments` know whether this node
  # has special awareness of how to handle comments within its output.
  includeCommentFragments: NO

  # `jumps` tells you if an expression, or an internal part of an expression
  # has a flow control construct (like `break`, or `continue`, or `return`,
  # or `throw`) that jumps out of the normal flow of control and can’t be
  # used as a value. This is important because things like this make no sense;
  # we have to disallow them.
  jumps: NO

  # If `node.shouldCache() is false`, it is safe to use `node` more than once.
  # Otherwise you need to store the value of `node` in a variable and output
  # that variable several times instead. Kind of like this: `5` need not be
  # cached. `returnFive()`, however, could have side effects as a result of
  # evaluating it more than once, and therefore we need to cache it. The
  # parameter is named `shouldCache` rather than `mustCache` because there are
  # also cases where we might not need to cache but where we want to, for
  # example a long expression that may well be idempotent but we want to cache
  # for brevity.
  shouldCache: YES

  isChainable: NO
  isAssignable: NO
  isNumber: NO

  unwrap: THIS
  unfoldSoak: NO

  # Is this node used to assign a certain variable?
  assigns: NO

  # For this node and all descendents, set the location data to `locationData`
  # if the location data is not already set.
  updateLocationDataIfMissing: (locationData, {force} = {}) ->
    @forceUpdateLocation = yes if force
    return this if @locationData and not @forceUpdateLocation
    delete @forceUpdateLocation
    @locationData = locationData

    @eachChild (child) ->
      child.updateLocationDataIfMissing locationData

  # Add location data from another node
  withLocationDataFrom: ({locationData}) ->
    @updateLocationDataIfMissing locationData

  # Throw a SyntaxError associated with this node’s location.
  error: (message) ->
    throwSyntaxError message, @locationData

  makeCode: (code) ->
    new CodeFragment this, code

  wrapInParentheses: (fragments) ->
    [@makeCode('('), fragments..., @makeCode(')')]

  wrapInBraces: (fragments) ->
    [@makeCode('{'), fragments..., @makeCode('}')]

  wrapInCommentBoundingBraces: (fragments) ->
    fragments = @wrapInBraces fragments
    # Flag the `{` and `}` fragments as bounds for `compileComments`
    # to treat them as bounds. Don’t trust `fragment.type`, which can
    # report minified variable names when this compiler is minified.
    fragments[0].isCommentBoundary = 'start'
    fragments[fragments.length - 1].isCommentBoundary = 'end'
    fragments

  # `fragmentsList` is an array of arrays of fragments. Each array in fragmentsList will be
  # concatenated together, with `joinStr` added in between each, to produce a final flat array
  # of fragments.
  joinFragmentArrays: (fragmentsList, joinStr) ->
    answer = []
    for fragments, i in fragmentsList
      if i then answer.push @makeCode joinStr
      answer = answer.concat fragments
    answer

  wrapInParensIf: (shouldWrap) -> (node) ->
    if shouldWrap then new Parens node else node

#### HoistTarget

# A **HoistTargetNode** represents the output location in the node tree for a hoisted node.
# See Base#hoist.
exports.HoistTarget = class HoistTarget extends Base
  # Expands hoisted fragments in the given array
  @expand = (fragments) ->
    for fragment, i in fragments by -1 when fragment.fragments
      fragments[i..i] = @expand fragment.fragments
    fragments

  @expandBabylon = (compiled) =>
    return (@expandBabylon obj for obj in compiled) if Array.isArray compiled
    return compiled unless isPlainObject compiled
    return @expandBabylon compiled._hoistTarget if compiled?._hoistTarget
    mapValues compiled, @expandBabylon

  constructor: (@source) ->
    super()

    # Holds presentational options to apply when the source node is compiled.
    @options = {}

    # Placeholder fragments to be replaced by the source node’s compilation.
    @targetFragments = fragments: []
    @targetBabylon = _hoistTarget: null

  isStatement: (o) ->
    @source.isStatement o

  # Update the target fragments with the result of compiling the source.
  # Calls the given compile function with the node and options (overriden with the target
  # presentational options).
  update: (compile, o) ->
    @targetFragments.fragments = compile.call @source, merge o, @options

  updateBabylon: (compile, o) ->
    @targetBabylon._hoistTarget = compile.call @source, merge o, @options

  _compileToBabylon: (o) ->
    @compileToBabylon o

  compileToBabylon: (o, level) ->
    @options.level = level ? o.level
    @targetBabylon

  compileClosureToBabylon: (o) ->
    @compileToBabylon o

  # Copies the target indent and level, and returns the placeholder fragments
  compileToFragments: (o, level) ->
    @options.indent = o.indent
    @options.level  = level ? o.level
    [ @targetFragments ]

  compileNode: (o) ->
    @compileToFragments o

  compileClosure: (o) ->
    @compileToFragments o

#### Block

# The block is the list of expressions that forms the body of an
# indented block of code -- the implementation of a function, a clause in an
# `if`, `switch`, or `try`, and so on...
exports.Block = class Block extends Base
  constructor: (nodes) ->
    super()

    @expressions = compact flatten nodes or []

  children: ['expressions']

  # Tack an expression on to the end of this expression list.
  push: (node) ->
    @expressions.push node
    this

  # Remove and return the last expression of this expression list.
  pop: ->
    @expressions.pop()

  # Add an expression at the beginning of this expression list.
  unshift: (node) ->
    @expressions.unshift node
    this

  # If this Block consists of just a single node, unwrap it by pulling
  # it back out.
  unwrap: ->
    if @expressions.length is 1 then @expressions[0] else this

  # Is this an empty block of code?
  isEmpty: ->
    not @expressions.length

  isStatement: (o) ->
    for exp in @expressions when exp.isStatement o
      return yes
    no

  jumps: (o) ->
    for exp in @expressions
      return jumpNode if jumpNode = exp.jumps o

  # A Block node does not return its entire body, rather it
  # ensures that the final expression is returned.
  makeReturn: (opts) ->
    len = @expressions.length
    [..., lastExp] = @expressions
    lastExp = lastExp?.unwrap() or no
    # We also need to check that we’re not returning a CSX tag if there’s an
    # adjacent one at the same level; JSX doesn’t allow that.
    if lastExp and lastExp instanceof Parens and lastExp.body.expressions.length > 1
      {body:{expressions}} = lastExp
      [..., penult, last] = expressions
      penult = penult.unwrap()
      last = last.unwrap()
      if penult instanceof Call and penult.csx and last instanceof Call and last.csx
        expressions[expressions.length - 1].error 'Adjacent JSX elements must be wrapped in an enclosing tag'
    if opts?.mark
      return @expressions[len - 1]?.makeReturn opts
    while len--
      expr = @expressions[len]
      @expressions[len] = expr.makeReturn opts
      @expressions.splice(len, 1) if expr instanceof Return and not expr.expression
      break
    this

  # A **Block** is the only node that can serve as the root.
  compileToFragments: (o = {}, level) ->
    if o.scope then super o, level else @compileRoot o

  # Compile all expressions within the **Block** body. If we need to return
  # the result, and it’s an expression, simply return it. If it’s a statement,
  # ask the statement to do so.
  compileNode: (o) ->
    @tab  = o.indent
    top   = o.level is LEVEL_TOP
    compiledNodes = []

    for node, index in @expressions
      if node.hoisted
        # This is a hoisted expression.
        # We want to compile this and ignore the result.
        node.compileToFragments o
        continue
      node = (node.unfoldSoak(o) or node)
      if node instanceof Block
        # This is a nested block. We don’t do anything special here like
        # enclose it in a new scope; we just compile the statements in this
        # block along with our own.
        compiledNodes.push node.compileNode o
      else if top
        node.front = yes
        fragments = node.compileToFragments o
        unless node.isStatement o
          fragments = indentInitial fragments, @
          [..., lastFragment] = fragments
          unless lastFragment.code is '' or lastFragment.isComment
            fragments.push @makeCode ';'
        compiledNodes.push fragments
      else
        compiledNodes.push node.compileToFragments o, LEVEL_LIST
    if top
      if @spaced
        return [].concat @joinFragmentArrays(compiledNodes, '\n\n'), @makeCode('\n')
      else
        return @joinFragmentArrays(compiledNodes, '\n')
    if compiledNodes.length
      answer = @joinFragmentArrays(compiledNodes, ', ')
    else
      answer = [@makeCode 'void 0']
    if compiledNodes.length > 1 and o.level >= LEVEL_LIST then @wrapInParentheses answer else answer

  prettier: (o) ->
    code = del o, 'code'
    returnWithAst = del o, 'returnWithAst'
    { opts } = prettier.__debug.parse ''
    ast = @compileToBabylon merge o, forPrettier: yes
    prettier.__debug.attachComments code, ast, opts
    formatted = prettier.__debug.formatAST(ast, merge opts, originalText: code).formatted
    return formatted unless returnWithAst
    {ast, formatted}

  compile: (o, lvl) ->
    return @prettier o if o.usePrettier and not o.scope
    super o, lvl

  compileToBabylon: (o, level) ->
    return @withBabylonComments o, @compileRootToBabylon o unless o.scope
    super o, level

  toAst: (o, level) ->
    return @rootToAst o unless o.scope
    super o, level

  _toAst: (o) ->
    top = o.level is LEVEL_TOP

    if not top and @expressions.length
      # return @withLocationData(new UndefinedLiteral).compileToBabylon o unless @expressions.length
      return (new Sequence @expressions).toAst o

    super o

  astType: ->
    if @isClassBody
      'ClassBody'
    else
      'BlockStatement'
  astChildren: (o) -> {
    body: @bodyToAst o
    @directives
  }

  initializeScope: (o) ->
    o.scope   = new Scope null, this, null, o.referencedVars ? []
    # Mark given local variables in the root scope as parameters so they don’t
    # end up being declared on this block.
    o.scope.parameter name for name in o.locals or []

  extractComments: (compiled) ->
    comments = []
    traverseBabylonAst compiled, (node) ->
      {comments} = node
      return unless comments
      comments.push comments...
      return 'REMOVE' unless node.type
      node.comments = null
    comments

  compileRootToBabylon: (o) ->
    # dump root: @
    # @spaced   = yes
    @initializeScope o
    o.compilingBabylon = o.compiling = yes

    compiledBody = HoistTarget.expandBabylon @compileWithDeclarationsToBabylon merge o, root: yes
    compiledBody = @hoistBabylonComments compiledBody if compiledBody.length
    if compiledBody.length is 1 and not compiledBody[0].type
      programComments =
        for comment in compiledBody[0].comments
          comment.leading = comment.trailing = no
          comment
      compiledBody = []
    program = @includeCommentsInLocationData @withAstLocationData {
      type: 'Program'
      sourceType: 'module'
      body: compiledBody
      @directives
      comments: programComments
    }

    comments = []
    # comments = @extractComments compiledBody
    # if program.body.length
    #   for comment in comments when comment.start is 0
    #     comment.__prettierNodes =
    #       enclosingNode: program
    #       followingNode: program.body[0]
    #       __hasFollowingNewline: yes
    #     break
    @withCopiedBabylonLocationData {
      type: 'File'
      program, comments
    }, program

  rootToAst: (o) ->
    @initializeScope o

    body = @bodyToAst merge o, level: LEVEL_TOP, root: yes
    comments = @commentsToAst()

    program = @withAstLocationData {
      type: 'Program'
      sourceType: 'module'
      body, @directives
    }
    mergeAstLocationData program, comment for comment in comments

    @withCopiedBabylonLocationData {
      type: 'File'
      program, comments
    }, program

  commentsToAst: ->
    return [] unless @allComments?.length

    for {here, content, locationData, heregex, indent} in @allComments when not heregex
      {
        type:
          if here
            'CommentBlock'
          else
            'CommentLine'
        value: content
        locationDataToAst(locationData)...
        indent
      }

  bodyToAst: (o) ->
    root = del o, 'root'
    checkForDirectives = del o, 'checkForDirectives'

    @directives = []
    @sniffDirectives @expressions, replace: yes, notFinalExpression: checkForDirectives if root or checkForDirectives

    flatten(
      for node in @expressions then do =>
        node.topLevel = root
        ast = node.toAst o
        return [] unless ast
        return @extractDirectives ast.body, o if node instanceof Block or ast.type is 'BlockStatement'
        return ast if node.isStatement(o) or node instanceof Class
        ast = @extractDirectives ast, o
        return [] unless ast
        return @asExpressionStatement ast unless Array.isArray ast
        @asExpressionStatement item for item in ast
    )

  _compileToBabylon: (o) ->
    root = del o, 'root'
    withDeclarations = del o, 'withDeclarations'
    top = o.level is LEVEL_TOP

    if not top and not root
      return @withLocationData(new UndefinedLiteral).compileToBabylon o unless @expressions.length
      return @wrapInParensIf(o.level >= LEVEL_LIST)(new Sequence(@expressions)).compileToBabylon o

    @directives = []
    @sniffDirectives @expressions, replace: yes if withDeclarations
    if root and not o.bare
      code = new Code [], this
      code.noReturn = true
      return @compileBodyToBabylon merge o, {expressions: [
        new Call(
          new Value(
            code
            [new Access new PropertyName 'call']
          )
          [new ThisLiteral]
        ).withLocationDataFrom @
      ], classScope: o.scope, root}
    body = @compileBodyToBabylon merge o, {root}
    body = [...@compileDeclarationsToBabylon(o), ...body] if withDeclarations
    return body if root
    @includeCommentsInLocationData @withAstLocationData @withAstType {
      body
      @directives
    }

  compileWithDeclarationsToBabylon: (o) ->
    @withBabylonComments o, @_compileToBabylon merge o, level: LEVEL_TOP, withDeclarations: yes

  compileScopeDeclarationsToBabylon: (o) ->
    for declaredVariable in o.scope.declaredVariables()
      @withBabylonComments o, @withEmptyBabylonLocationData(
        type: 'VariableDeclarator'
        id:
          @withEmptyBabylonLocationData
            type: 'Identifier'
            name: declaredVariable
        init: null
      ), comments:
        for comment in o.scope.commentNodes[declaredVariable] ? [] when comment
          comment.includeWithDeclaration = no
          comment

  compileScopeAssignedVariablesToBabylon: (o) ->
    @withEmptyBabylonLocationData {
      type: 'VariableDeclarator'
      id: @withEmptyBabylonLocationData {
        type: 'Identifier'
        name
      }
      init: value.compileToBabylon o
    } for {name, value} in o.scope.assignedVariableObjects()

  compileDeclarationsToBabylon: (o) ->
    {scope} = o
    return [] unless scope.expressions is this

    declars = scope.hasDeclarations()
    assigns = scope.hasAssignments
    return [] unless declars or assigns

    [
      @withEmptyBabylonLocationData
        type: 'VariableDeclaration'
        declarations: [
          ...@compileScopeDeclarationsToBabylon(o)
          ...@compileScopeAssignedVariablesToBabylon(o)
        ]
        kind: 'var'
    ]

  hoistBabylonComments: (compiled, {onlyTrailing, onlyLeading} = {}) ->
    targetNode =
      if Array.isArray compiled
        (do -> return item for item in compiled when item.type) ? compiled[0]
      else compiled
    comments = targetNode.comments ? []
    isDummyLocationData = targetNode.start < 0
    traverseBabylonAst compiled, (node, {parent, key}) =>
      return 'STOP' if parent?.type is 'TemplateLiteral'
      return 'STOP' if parent?.type in ['FunctionExpression', 'ArrowFunctionExpression'] and key is 'params'
      return 'STOP' if parent?.type is 'ClassExpression' and key is 'id'
      # return 'STOP' if parent?.type is 'ClassMethod' and key is 'key'
      onlyAlreadyLeading = yes if parent?.type is 'ClassMethod' and key is 'key'
      if parent?.type is 'AssignmentExpression' and key is 'left'
        @hoistBabylonComments node
        return 'STOP'
      if parent?.type is 'ArrayExpression' and key is 'elements'
        @hoistBabylonComments node
        return 'STOP'
      if parent?.type is 'JSXExpressionContainer' and node.type?
        @hoistBabylonComments node
        return 'STOP'
      if parent?.type is 'ClassMethod' and key is 'params'
        @hoistBabylonComments node, onlyTrailing: yes
        return
      if node.type is 'ObjectProperty'
        @hoistBabylonComments node#, onlyTrailing: yes
        return
      if node.type is 'ArrowFunctionExpression'
        @hoistBabylonComments node, onlyLeading: yes
        return
      if node.type in BABYLON_STATEMENT_TYPES
        @hoistBabylonComments node
        if key is 'body' and parent?.type is 'ArrowFunctionExpression'
          makeLeadingIntoDangling = yes
        else
          return 'STOP'
      return (if node.loc? and not node.type? then 'REMOVE') unless node.comments?.length
      # dump 'hoisting comments', {compiled, targetNode, node, comments, makeLeadingIntoDangling}
      nonmatching = [] if onlyTrailing or onlyLeading or onlyAlreadyLeading or makeLeadingIntoDangling
      comments.push (
        for comment in node.comments
          leading = comment.forceLeading or comment.end <= targetNode.start or isDummyLocationData
          if (onlyTrailing and leading or onlyLeading and not leading or onlyAlreadyLeading and not comment.leading) and not (makeLeadingIntoDangling and comment.leading)
            nonmatching.push comment
            continue
          if makeLeadingIntoDangling
            comment.leading = comment.trailing = no
          else
            comment.leading = leading
            comment.trailing = not leading
          comment)...
      return 'REMOVE' unless node.type
      node.comments = if nonmatching?.length then nonmatching else null
    , skip: [compiled, targetNode]
    targetNode.comments = comments
    compiled
    # {...compiled, comments}

  asExpressionStatement: (compiled) ->
    @includeCommentsInLocationData @hoistBabylonComments do ->
      return compiled unless compiled.type
      return compiled if compiled.type in ['VariableDeclaration', 'ImportDeclaration', 'ClassMethod']
      type: 'ExpressionStatement'
      expression: compiled
      loc: compiled.loc
      range: compiled.range
      start: compiled.start
      end: compiled.end

  includeCommentsInLocationData: (node) ->
    {start, end} = node
    traverseBabylonAst node, ({comments}) ->
      return unless comments
      for comment in comments
        if comment.start < start
          node.start = comment.start
          node.range = [comment.range[0], node.range[1]]
          node.loc = {...node.loc, start: comment.loc.start}
        if comment.end > end
          node.end = comment.end
          node.range = [node.range[0], comment.range[1]]
          node.loc = {...node.loc, end: comment.loc.end}
    node

  compileBodyToBabylon: (o) ->
    expressions = del o, 'expressions'
    root = del o, 'root'
    expressions ?= @expressions
    flatten(
      for node in expressions then do =>
        node.topLevel = root
        compiled = node.compileToBabylon o
        return [] unless compiled
        return [] if node.hoisted
        return @extractDirectives compiled.body, o if node instanceof Block or compiled.type is 'BlockStatement'
        # return @includeCommentsInLocationData compiled if node.isStatement o
        return @hoistBabylonComments compiled if node.isStatement o
        compiled = @extractDirectives compiled, o
        return [] unless compiled
        return @asExpressionStatement compiled unless Array.isArray compiled
        @asExpressionStatement item for item in compiled
    )

  extractDirectives: (nodes, o) ->
    return (@extractDirectives node, o for node in nodes) if Array.isArray nodes
    return nodes unless nodes?.type is 'Directive'
    @directives.push nodes
    null

  # If we happen to be the top-level **Block**, wrap everything in a safety
  # closure, unless requested not to. It would be better not to generate them
  # in the first place, but for now, clean up obvious double-parentheses.
  compileRoot: (o) ->
    o.indent  = if o.bare then '' else TAB
    o.level   = LEVEL_TOP
    o.compiling = yes
    @spaced   = yes
    @initializeScope(o)
    fragments = @compileWithDeclarations o
    HoistTarget.expand fragments
    fragments = @compileComments fragments
    return fragments if o.bare
    [].concat @makeCode("(function() {\n"), fragments, @makeCode("\n}).call(this);\n")

  # Compile the expressions body for the contents of a function, with
  # declarations of all inner variables pushed up to the top.
  compileWithDeclarations: (o) ->
    fragments = []
    post = []
    for exp, i in @expressions
      exp = exp.unwrap()
      break unless exp instanceof Literal
    o = merge(o, level: LEVEL_TOP)
    if i
      rest = @expressions.splice i, 9e9
      [spaced,    @spaced] = [@spaced, no]
      [fragments, @spaced] = [@compileNode(o), spaced]
      @expressions = rest
    post = @compileNode o
    {scope} = o
    if scope.expressions is this
      declars = o.scope.hasDeclarations()
      assigns = scope.hasAssignments
      if declars or assigns
        fragments.push @makeCode '\n' if i
        fragments.push @makeCode "#{@tab}var "
        if declars
          declaredVariables = scope.declaredVariables()
          for declaredVariable, declaredVariablesIndex in declaredVariables
            fragments.push @makeCode declaredVariable
            if Object::hasOwnProperty.call o.scope.comments, declaredVariable
              fragments.push o.scope.comments[declaredVariable]...
            if declaredVariablesIndex isnt declaredVariables.length - 1
              fragments.push @makeCode ', '
        if assigns
          fragments.push @makeCode ",\n#{@tab + TAB}" if declars
          fragments.push @makeCode scope.assignedVariables().join(",\n#{@tab + TAB}")
        fragments.push @makeCode ";\n#{if @spaced then '\n' else ''}"
      else if fragments.length and post.length
        fragments.push @makeCode "\n"
    fragments.concat post

  compileComments: (fragments) ->
    for fragment, fragmentIndex in fragments
      # Insert comments into the output at the next or previous newline.
      # If there are no newlines at which to place comments, create them.
      if fragment.precedingComments
        # Determine the indentation level of the fragment that we are about
        # to insert comments before, and use that indentation level for our
        # inserted comments. At this point, the fragments’ `code` property
        # is the generated output JavaScript, and CoffeeScript always
        # generates output indented by two spaces; so all we need to do is
        # search for a `code` property that begins with at least two spaces.
        fragmentIndent = ''
        for pastFragment in fragments[0...(fragmentIndex + 1)] by -1
          indent = /^ {2,}/m.exec pastFragment.code
          if indent
            fragmentIndent = indent[0]
            break
          else if '\n' in pastFragment.code
            break
        code = "\n#{fragmentIndent}" + (
            for commentFragment in fragment.precedingComments
              if commentFragment.isHereComment and commentFragment.multiline
                multident commentFragment.code, fragmentIndent, no
              else
                commentFragment.code
          ).join("\n#{fragmentIndent}").replace /^(\s*)$/gm, ''
        for pastFragment, pastFragmentIndex in fragments[0...(fragmentIndex + 1)] by -1
          newLineIndex = pastFragment.code.lastIndexOf '\n'
          if newLineIndex is -1
            # Keep searching previous fragments until we can’t go back any
            # further, either because there are no fragments left or we’ve
            # discovered that we’re in a code block that is interpolated
            # inside a string.
            if pastFragmentIndex is 0
              pastFragment.code = '\n' + pastFragment.code
              newLineIndex = 0
            else if pastFragment.isCommentBoundary is 'start'
              code = code[1..] + '\n' # Move newline to end.
              newLineIndex = 1
            else
              continue
          delete fragment.precedingComments
          pastFragment.code = pastFragment.code[0...newLineIndex] +
            code + pastFragment.code[newLineIndex..]
          break

      # Yes, this is awfully similar to the previous `if` block, but if you
      # look closely you’ll find lots of tiny differences that make this
      # confusing if it were abstracted into a function that both blocks share.
      if fragment.followingComments
        # Does the first trailing comment follow at the end of a line of code,
        # like `; // Comment`, or does it start a new line after a line of code?
        trail = fragment.followingComments[0].trail
        fragmentIndent = ''
        # Find the indent of the next line of code, if we have any non-trailing
        # comments to output. We need to first find the next newline, as these
        # comments will be output after that; and then the indent of the line
        # that follows the next newline.
        unless trail and fragment.followingComments.length is 1
          onNextLine = no
          for upcomingFragment in fragments[fragmentIndex...]
            unless onNextLine
              if '\n' in upcomingFragment.code
                onNextLine = yes
              else
                continue
            else
              indent = /^ {2,}/m.exec upcomingFragment.code
              if indent
                fragmentIndent = indent[0]
                break
              else if '\n' in upcomingFragment.code
                break
        # Is this comment following the indent inserted by bare mode?
        # If so, there’s no need to indent this further.
        code = if fragmentIndex is 1 and /^\s+$/.test fragments[0].code
          ''
        else if trail
          ' '
        else
          "\n#{fragmentIndent}"
        # Assemble properly indented comments.
        code += (
            for commentFragment in fragment.followingComments
              if commentFragment.isHereComment and commentFragment.multiline
                multident commentFragment.code, fragmentIndent, no
              else
                commentFragment.code
          ).join("\n#{fragmentIndent}").replace /^(\s*)$/gm, ''
        for upcomingFragment, upcomingFragmentIndex in fragments[fragmentIndex...]
          newLineIndex = upcomingFragment.code.indexOf '\n'
          if newLineIndex is -1
            # Keep searching upcoming fragments until we can’t go any
            # further, either because there are no fragments left or we’ve
            # discovered that we’re in a code block that is interpolated
            # inside a string.
            if upcomingFragmentIndex is fragments.length - 1
              upcomingFragment.code = upcomingFragment.code + '\n'
              newLineIndex = upcomingFragment.code.length
            else if upcomingFragment.isCommentBoundary is 'end'
              code = "#{code}\n"
              newLineIndex = 0
            else
              continue
          delete fragment.followingComments
          # Avoid inserting extra blank lines.
          code = code.replace /^\n/, '' if upcomingFragment.code is '\n'
          upcomingFragment.code = upcomingFragment.code[0...newLineIndex] +
            code + upcomingFragment.code[newLineIndex..]
          break

    fragments

  # Wrap up the given nodes as a **Block**, unless it already happens
  # to be one.
  @wrap: (nodes) ->
    return nodes[0] if nodes.length is 1 and nodes[0] instanceof Block
    new Block nodes

#### Literal

# `Literal` is a base class for static values that can be passed through
# directly into JavaScript without translation, such as: strings, numbers,
# `true`, `false`, `null`...
exports.Literal = class Literal extends Base
  constructor: (@value) ->
    super()

  shouldCache: NO

  assigns: (name) ->
    name is @value

  astProps: ['value']

  # TODO: throw error if eg _compileToBabylon() called on bare Literal?

  compileNode: (o) ->
    [@makeCode @value]

  astProps: ['value']

  toString: ->
    # This is only intended for debugging.
    " #{if @isStatement() then super() else @constructor.name}: #{@value}"

exports.NumberLiteral = class NumberLiteral extends Literal
  astType: 'NumericLiteral'
  astProps: ->
    # TODO: unify the type of @value in the constructor (could be string or number)?
    numberValue = getNumberValue @value

    value: numberValue
    extra:
      rawValue: numberValue
      raw: "#{@value}"

exports.InfinityLiteral = class InfinityLiteral extends NumberLiteral
  compileNode: ->
    [@makeCode '2e308']

  astType: 'Identifier'
  astProps: ->
    name: 'Infinity'

  _compileToBabylon: (o) ->
    new NumberLiteral('2e308').compileToBabylon o

exports.NaNLiteral = class NaNLiteral extends NumberLiteral
  constructor: ->
    super 'NaN'

  compileNode: (o) ->
    code = [@makeCode '0/0']
    if o.level >= LEVEL_OP then @wrapInParentheses code else code

  astType: 'Identifier'
  astProps: ->
    name: 'NaN'

  _compileToBabylon: (o) ->
    new Op('/', new NumberLiteral('0'), new NumberLiteral('0')).compileToBabylon o

exports.StringLiteral = class StringLiteral extends Literal
  constructor: (@originalValue, {@quote, @initialChunk, @finalChunk, @indent, @double, @heregex} = {}) ->
    super ''
    @fromSourceString = @quote?
    @quote ?= '"'
    heredoc = @quote.length is 3

    val = @originalValue
    if @heregex
      val = val.replace HEREGEX_OMIT, '$1$2'
      val = replaceUnicodeCodePointEscapes val, flags: @heregex.flags
      @heregexPattern = val
    else
      val = val.replace STRING_OMIT, '$1'
      val =
        unless @fromSourceString
          val
        else if heredoc
          indentRegex = /// \n#{@indent} ///g if @indent

          val = val.replace indentRegex, '\n' if indentRegex
          val = val.replace LEADING_BLANK_LINE,  '' if @initialChunk
          val = val.replace TRAILING_BLANK_LINE, '' if @finalChunk
          val
        else
          val.replace SIMPLE_STRING_OMIT, (match, offset) =>
            if (@initialChunk and offset is 0) or
               (@finalChunk and offset + match.length is val.length)
              ''
            else
              ' '
    @value = @delimit val

  delimit: (val, opts = {}) ->
    makeDelimitedLiteral val, merge {
      delimiter: @quote.charAt 0
      @double
    }, opts

  compileNode: (o) ->
    return [@makeCode @unquote(yes, yes)] if @csx
    super o

  CSXTextToAst: (o) ->
    unquoted = @unquote yes, yes
    type: 'JSXText'
    value: unquoted
    extra:
      raw: unquoted

  astProps: (o) ->
    value:
      if o.compiling
        @unquote()
      else
        @originalValue
    extra:
      raw:
        if o.compiling
          @value
        else
          @delimit @originalValue, justEscapeDelimiter: yes

  _toAst: (o) ->
    return @CSXTextToAst o if @csx
    if not o.compiling and @quote.length is 3 and @originalValue.indexOf('\n') > -1
      return @withLocationData(StringWithInterpolations.fromStringLiteral @).toAst o
    super o

  unquote: (doubleQuote = no, csx = no) ->
    unquoted = @value[1...-1]
    unquoted = unquoted.replace /\\"/g, '"'  if doubleQuote
    unquoted = unquoted.replace /\\n/g, '\n' if csx
    unquoted

  isEmpty: ->
    not @unquote().length

exports.RegexLiteral = class RegexLiteral extends Literal
  constructor: (value, {@delimiter = '/'} = {}) ->
    super ''
    heregex = @delimiter is '///'
    endDelimiterIndex = value.lastIndexOf '/'
    @flags = value[endDelimiterIndex + 1..]
    val = @originalValue = value[1...endDelimiterIndex]
    val = val.replace HEREGEX_OMIT, '$1$2' if heregex
    val = replaceUnicodeCodePointEscapes val, {@flags}
    @value = "#{makeDelimitedLiteral val, delimiter: '/'}#{@flags}"

  REGEX_REGEX: /^\/(.*)\/\w*$/
  _toAst: (o) ->
    [, pattern] = @REGEX_REGEX.exec @value
    {
      type: 'RegExpLiteral'
      value: undefined
      pattern, @flags, @delimiter
      originalPattern: @originalValue
      extra:
        raw: @value
        originalRaw: "#{@delimiter}#{@originalValue}#{@delimiter}#{@flags}"
        rawValue: undefined
    }

exports.PassthroughLiteral = class PassthroughLiteral extends Literal
  constructor: (@originalValue, {@here, @generated} = {}) ->
    super ''
    @value = @originalValue.replace /\\+(`|$)/g, (string) ->
      # `string` is always a value like '\`', '\\\`', '\\\\\`', etc.
      # By reducing it to its latter half, we turn '\`' to '`', '\\\`' to '\`', etc.
      string[-Math.ceil(string.length / 2)..]

  withEnhancedComments: (compiled) ->
    traverseBabylonAst compiled, (node) ->
      return unless node.start and not node.range
      node.range = [node.start, node.end]
      node.leading = yes
    compiled

  astProps: (o) -> {
    value: if o.compiling then @value else @originalValue
    @here
  }

  _toAst: (o) ->
    return null unless @value.length
    super o

  _compileToBabylon: (o) ->
    return null unless @value.length
    return @withEnhancedComments @parsedJS() if o.forPrettier
    super o

  parsedJS: ->
    # TODO: location data is incorrect (starts from 0 at beginning of backticked JS)
    try
      parsed = babylon.parse(@value, sourceType: 'module', ranges: yes).program.body
      if parsed?.length
        return parsed[0].expression if parsed.length is 1 and parsed[0].type is 'ExpressionStatement'
        return parsed
    catch
    try
      return babylon.parseExpression @value, ranges: yes
    catch
    babylon.parse("class A {#{@value}}", sourceType: 'module', ranges: yes).program.body[0].body.body[0]
    # TODO: wrap this last one in a try and if it fails throw a useful error about not being able to parse backticked JS as an expression

exports.IdentifierLiteral = class IdentifierLiteral extends Literal
  isAssignable: YES

  eachName: (iterator) ->
    iterator @

  astType: ->
    if @csx
      'JSXIdentifier'
    else
      'Identifier'

  astProps:
    name: 'value'
    declaration: 'isDeclaration'

exports.CSXTag = class CSXTag extends IdentifierLiteral
  _compileToBabylon: (o) ->
    type: 'JSXIdentifier'
    name: @value

exports.PropertyName = class PropertyName extends Literal
  isAssignable: YES

  astType: 'Identifier'
  astProps:
    name: 'value'

exports.ComputedPropertyName = class ComputedPropertyName extends PropertyName
  compileNode: (o) ->
    [@makeCode('['), @value.compileToFragments(o, LEVEL_LIST)..., @makeCode(']')]

  _toAst: (o) ->
    @value.toAst o

exports.StatementLiteral = class StatementLiteral extends Literal
  isStatement: YES

  makeReturn: THIS

  jumps: (o) ->
    return this if @value is 'break' and not (o?.loop or o?.block)
    return this if @value is 'continue' and not o?.loop

  compileNode: (o) ->
    [@makeCode "#{@tab}#{@value};"]

  astType: ->
    switch @value
      when 'continue' then 'ContinueStatement'
      when 'break'    then 'BreakStatement'
      # TODO: no tests broke without this, include test with debugger statement?
      when 'debugger' then 'DebuggerStatement'
      # TODO: any others? throw error in else if we fall off the end of this switch?

exports.ThisLiteral = class ThisLiteral extends Literal
  constructor: (value) ->
    super 'this'
    @shorthand = value is '@'

  compileNode: (o) ->
    code = if o.scope.method?.bound then o.scope.method.context else @value
    [@makeCode code]

  _toAst: (o) ->
    {compiling} = o
    value =
      if o.scope.method?.bound
        o.scope.method.context
      else
        @value
    if value is 'this' or not compiling
      {
        type: 'ThisExpression'
        (if compiling then {} else {@shorthand})...
      }
    else
      type: 'Identifier' # TODO: refine/share code?
      name: value

exports.UndefinedLiteral = class UndefinedLiteral extends Literal
  constructor: ->
    super 'undefined'

  _compileToBabylon: (o) ->
    new Op('void', new NumberLiteral('0')).compileToBabylon o # TODO: capture LEVEL_ACCESS condition

  compileNode: (o) ->
    [@makeCode if o.level >= LEVEL_ACCESS then '(void 0)' else 'void 0']

  astType: 'Identifier'
  astProps:
    name: 'value'

exports.NullLiteral = class NullLiteral extends Literal
  constructor: ->
    super 'null'

  astProps: []
  emptyAst: yes

exports.BooleanLiteral = class BooleanLiteral extends Literal
  constructor: (value, {@originalValue} = {}) ->
    super value
    @originalValue ?= @value

  astProps: (o) ->
    value: if @value is 'true' then yes else no
    name: @originalValue

exports.SuperLiteral = class SuperLiteral extends Literal
  astType: 'Super'

exports.DefaultLiteral = class DefaultLiteral extends Literal
  astType: 'Identifier'
  astProps: ->
    name: 'default'

exports.Directive = class Directive extends Base
  constructor: (@value) ->
    super()
  
  astChildren: (o) ->
    value: {
      ...@value.toAst o
      type: 'DirectiveLiteral'
    }

#### Return

# A `return` is a *pureStatement*—wrapping it in a closure wouldn’t make sense.
exports.Return = class Return extends Base
  constructor: (@expression) ->
    super()

  children: ['expression']

  isStatement:     YES
  makeReturn:      THIS
  jumps:           THIS

  compileToFragments: (o, level) ->
    expr = @expression?.makeReturn()
    if expr and expr not instanceof Return then expr.compileToFragments o, level else super o, level

  compileToBabylon: (o, level) ->
    expr = @expression?.makeReturn()
    if expr and expr not instanceof Return then expr.compileToBabylon o, level else super o, level

  astType: 'ReturnStatement'
  astChildren:
    argument:
      propName: 'expression'
      level: LEVEL_PAREN

  compileNode: (o) ->
    answer = []
    # TODO: If we call `expression.compile()` here twice, we’ll sometimes
    # get back different results!
    if @expression
      answer = @expression.compileToFragments o, LEVEL_PAREN
      unshiftAfterComments answer, @makeCode "#{@tab}return "
      # Since the `return` got indented by `@tab`, preceding comments that are
      # multiline need to be indented.
      for fragment in answer
        if fragment.isHereComment and '\n' in fragment.code
          fragment.code = multident fragment.code, @tab
        else if fragment.isLineComment
          fragment.code = "#{@tab}#{fragment.code}"
        else
          break
    else
      answer.push @makeCode "#{@tab}return"
    answer.push @makeCode ';'
    answer

# `yield return` works exactly like `return`, except that it turns the function
# into a generator.
exports.YieldReturn = class YieldReturn extends Return
  _toAst: (o) ->
    unless o.scope.parent?
      @error 'yield can only occur inside functions'
    super o

  toAst: (o, level) ->
    return super o, level if o.compiling
    new Op 'yield', new Return @expression
    .withLocationDataFrom @
    .toAst o, level

  compileNode: (o) ->
    unless o.scope.parent?
      @error 'yield can only occur inside functions'
    super o

exports.AwaitReturn = class AwaitReturn extends Return
  _toAst: (o) ->
    unless o.scope.parent?
      @error 'await can only occur inside functions'
    super o

  toAst: (o, level) ->
    return super o, level if o.compiling
    new Op 'await', new Return @expression
    .withLocationDataFrom @
    .toAst o, level

  compileNode: (o) ->
    unless o.scope.parent?
      @error 'await can only occur inside functions'
    super o


#### Value

# A value, variable or literal or parenthesized, indexed or dotted into,
# or vanilla.
exports.Value = class Value extends Base
  constructor: (base, props, tag, isDefaultValue = no) ->
    super()
    return base if not props and base instanceof Value
    @base           = base
    @properties     = props or []
    @[tag]          = yes if tag
    @isDefaultValue = isDefaultValue
    # If this is a `@foo =` assignment, if there are comments on `@` move them
    # to be on `foo`.
    if @base?.comments and @base instanceof ThisLiteral and @properties[0]?.name?
      moveComments @base, @properties[0].name

  children: ['base', 'properties']

  # Add a property (or *properties* ) `Access` to the list.
  add: (props) ->
    @properties = @properties.concat props
    @forceUpdateLocation = yes
    this

  hasProperties: ->
    @properties.length isnt 0

  bareLiteral: (type) ->
    not @properties.length and @base instanceof type

  # Some boolean checks for the benefit of other nodes.
  isArray        : -> @bareLiteral(Arr)
  isRange        : -> @bareLiteral(Range)
  shouldCache    : -> @hasProperties() or @base.shouldCache()
  isAssignable   : -> @hasProperties() or @base.isAssignable()
  isNumber       : -> @bareLiteral(NumberLiteral)
  isString       : -> @bareLiteral(StringLiteral)
  isRegex        : -> @bareLiteral(RegexLiteral)
  isUndefined    : -> @bareLiteral(UndefinedLiteral)
  isNull         : -> @bareLiteral(NullLiteral)
  isBoolean      : -> @bareLiteral(BooleanLiteral)
  isAtomic       : ->
    for node in @properties.concat @base
      return no if node.soak or node instanceof Call
    yes

  isNotCallable  : -> @isNumber() or @isString() or @isRegex() or
                      @isArray() or @isRange() or @isSplice() or @isObject() or
                      @isUndefined() or @isNull() or @isBoolean()

  isStatement : (o)    -> not @properties.length and @base.isStatement o
  assigns     : (name) -> not @properties.length and @base.assigns name
  jumps       : (o)    -> not @properties.length and @base.jumps o

  isObject: (onlyGenerated) ->
    return no if @properties.length
    (@base instanceof Obj) and (not onlyGenerated or @base.generated)

  isElision: ->
    return no unless @base instanceof Arr
    @base.hasElision()

  isSplice: ->
    [..., lastProp] = @properties
    lastProp instanceof Slice

  looksStatic: (className) ->
    return no unless (@this or @base instanceof ThisLiteral or (byClassName = @base.value is className)) and
      @properties.length is 1 and @properties[0].name?.value isnt 'prototype'
    if byClassName then {className} else yes

  # The value can be unwrapped as its inner node, if there are no attached
  # properties.
  unwrap: ->
    if @properties.length then this else @base

  # A reference has base part (`this` value) and name part.
  # We cache them separately for compiling complex expressions.
  # `a()[b()] ?= c` -> `(_base = a())[_name = b()] ? _base[_name] = c`
  cacheReference: (o) ->
    [..., name] = @properties
    if @properties.length < 2 and not @base.shouldCache() and not name?.shouldCache()
      return [this, this]  # `a` `a.b`
    base = new Value @base, @properties[...-1]
    if base.shouldCache()  # `a().b`
      bref = new IdentifierLiteral o.scope.freeVariable 'base'
      base = new Value new Parens new Assign bref, base
    return [base, bref] unless name  # `a()`
    if name.shouldCache()  # `a[b()]`
      nref = new IdentifierLiteral o.scope.freeVariable 'name'
      name = new Index new Assign nref, name.index
      nref = new Index nref
    [base.add(name), new Value(bref or base.base, [nref or name])]

  # We compile a value to JavaScript by compiling and joining each property.
  # Things get much more interesting if the chain of properties has *soak*
  # operators `?.` interspersed. Then we have to take care not to accidentally
  # evaluate anything twice when building the soak chain.
  compileNode: (o) ->
    @base.front = @front
    props = @properties
    if props.length and @base.cached?
      # Cached fragments enable correct order of the compilation,
      # and reuse of variables in the scope.
      # Example:
      # `a(x = 5).b(-> x = 6)` should compile in the same order as
      # `a(x = 5); b(-> x = 6)`
      # (see issue #4437, https://github.com/jashkenas/coffeescript/issues/4437)
      fragments = @base.cached
    else
      fragments = @base.compileToFragments o, (if props.length then LEVEL_ACCESS else null)
    if props.length and SIMPLENUM.test fragmentsToText fragments
      fragments.push @makeCode '.'
    for prop in props
      fragments.push (prop.compileToFragments o)...

    fragments

  _toAst: (o) ->
    props = @properties
    ret = @base.toAst o, if props.length then LEVEL_ACCESS else null
    for prop, propIndex in props
      ret =
        if prop instanceof Slice and o.compiling
          prop.compileValueToBabylon o, ret
        else
          mergeAstLocationData(
            prop.withAstLocationData
              type: 'MemberExpression'
              object: ret
              property: prop.toAst o
              computed: prop instanceof Index or prop.name?.unwrap() not instanceof PropertyName
              optional: !!prop.soak
              shorthand: !!prop.shorthand
            ret
          )
      if propIndex is 0 and @base instanceof Parens and @base.locationData?
        mergeAstLocationData ret, locationDataToAst @base.locationData
    ret

  # Unfold a soak into an `If`: `a?.b` -> `a.b if a?`
  unfoldSoak: (o) ->
    @unfoldedSoak ?= do =>
      ifn = @base.unfoldSoak o
      if ifn
        ifn.body.properties.push @properties...
        return ifn
      for prop, i in @properties when prop.soak
        prop.soak = off
        fst = new Value @base, @properties[...i]
        snd = new Value @base, @properties[i..]
        if fst.shouldCache()
          ref = new IdentifierLiteral o.scope.freeVariable 'ref'
          fst = new Parens new Assign ref, fst
          snd.base = ref
        return @withLocationData new If new Existence(fst), snd, soak: on
      no

  eachName: (iterator, {checkAssignability = yes} = {}) ->
    if @hasProperties()
      iterator @
    else if not checkAssignability or @base.isAssignable()
      @base.eachName iterator
    else
      @error 'tried to assign to unassignable value'

#### HereComment

# Comment delimited by `###` (becoming `/* */`).
exports.HereComment = class HereComment extends Base
  constructor: ({ @content, @newLine, @unshift, @locationData, @indent }) ->
    super()

  _compileToBabylon: (o) ->
    hasLeadingMarks = /\n\s*[#|\*]/.test @content
    @content = @content.replace /^([ \t]*)#(?=\s)/gm, '$1 *' if hasLeadingMarks
    @content += ' ' if hasLeadingMarks
    {
      type: 'CommentBlock'
      value: @content
      leading: yes
      # @indent
    }

  compileNode: (o) ->
    multiline = '\n' in @content
    # Unindent multiline comments. They will be reindented later.
    if multiline
      indent = null
      for line in @content.split '\n'
        leadingWhitespace = /^\s*/.exec(line)[0]
        if not indent or leadingWhitespace.length < indent.length
          indent = leadingWhitespace
      @content = @content.replace /// \n #{indent} ///g, '\n' if indent

    hasLeadingMarks = /\n\s*[#|\*]/.test @content
    @content = @content.replace /^([ \t]*)#(?=\s)/gm, ' *' if hasLeadingMarks

    @content = "/*#{@content}#{if hasLeadingMarks then ' ' else ''}*/"
    fragment = @makeCode @content
    fragment.newLine = @newLine
    fragment.unshift = @unshift
    fragment.multiline = multiline
    # Don’t rely on `fragment.type`, which can break when the compiler is minified.
    fragment.isComment = fragment.isHereComment = yes
    fragment

#### LineComment

# Comment running from `#` to the end of a line (becoming `//`).
exports.LineComment = class LineComment extends Base
  constructor: ({ @content, @newLine, @unshift, @locationData }) ->
    super()

  _compileToBabylon: (o) ->
    return unless @content
    type: 'CommentLine'
    value: @content
    leading: yes
    __hasPrecedingNewline: @newLine

  compileNode: (o) ->
    fragment = @makeCode(if /^\s*$/.test @content then '' else "//#{@content}")
    fragment.newLine = @newLine
    fragment.unshift = @unshift
    fragment.trail = not @newLine and not @unshift
    # Don’t rely on `fragment.type`, which can break when the compiler is minified.
    fragment.isComment = fragment.isLineComment = yes
    fragment

#### Call

# Node for a function invocation.
exports.Call = class Call extends Base
  constructor: (@variable, @args = [], @soak, @token) ->
    super()

    @implicit = @args.implicit
    @isNew = no
    if @variable instanceof Value and @variable.isNotCallable()
      @variable.error "literal is not a function"

    @csx = @variable.base instanceof CSXTag

    # `@variable` never gets output as a result of this node getting created as
    # part of `RegexWithInterpolations`, so for that case move any comments to
    # the `args` property that gets passed into `RegexWithInterpolations` via
    # the grammar.
    if @variable.base?.value is 'RegExp' and @args.length isnt 0
      moveComments @variable, @args[0]

  children: ['variable', 'args']

  # When setting the location, we sometimes need to update the start location to
  # account for a newly-discovered `new` operator to the left of us. This
  # expands the range on the left, but not the right.
  updateLocationDataIfMissing: (locationData) ->
    if @locationData and @needsUpdatedStartLocation
      @locationData.first_line = locationData.first_line
      @locationData.first_column = locationData.first_column
      @locationData.range = [
        locationData.range[0]
        @locationData.range[1]
      ]
      base = @variable?.base or @variable
      if base.needsUpdatedStartLocation
        @variable.locationData.first_line = locationData.first_line
        @variable.locationData.first_column = locationData.first_column
        @variable.locationData.range = [
          locationData.range[0]
          @variable.locationData.range[1]
        ]
        base.updateLocationDataIfMissing locationData
      delete @needsUpdatedStartLocation
    super locationData

  # Tag this invocation as creating a new instance.
  newInstance: ->
    base = @variable?.base or @variable
    if base instanceof Call and not base.isNew
      base.newInstance()
    else
      @isNew = true
    @needsUpdatedStartLocation = true
    this

  # Soaked chained invocations unfold into if/else ternary structures.
  unfoldSoak: (o) ->
    if @soak
      if @variable instanceof Super
        left = rite = @variable
        @variable.setAccessor o
        @variable.error "Unsupported reference to 'super'" unless @variable.accessor?
      else
        return ifn if ifn = unfoldSoak o, this, 'variable'
        [left, rite] = new Value(@variable).cacheReference o
      rite = new Call rite, @args
      rite.isNew = @isNew
      left = new Op '===',
        new Op 'typeof', left
        new StringLiteral 'function'
      return new If left, new Value(rite), soak: yes
    call = this
    list = []
    loop
      if call.variable instanceof Call
        list.push call
        call = call.variable
        continue
      break unless call.variable instanceof Value
      list.push call
      break unless (call = call.variable.base) instanceof Call
    for call in list.reverse()
      if ifn
        if call.variable instanceof Call
          call.variable = ifn
        else
          call.variable.base = ifn
      ifn = unfoldSoak o, call, 'variable'
    ifn

  _toAst: (o) ->
    return @CSXToAst o if @csx
    super o

  astType: ->
    if @isNew
      @variable.error "Unsupported reference to 'super'" if @variable instanceof Super
      'NewExpression'
    else
      'CallExpression'

  astChildren:
    callee:
      propName: 'variable'
      level: LEVEL_ACCESS
    arguments:
      propName: 'args'
      level: LEVEL_LIST

  astProps:
    optional: 'soak'
    implicit: 'implicit'

  # Compile a vanilla function call.
  compileNode: (o) ->
    return @compileCSX o if @csx
    @variable?.front = @front
    compiledArgs = []
    # If variable is `Accessor` fragments are cached and used later
    # in `Value::compileNode` to ensure correct order of the compilation,
    # and reuse of variables in the scope.
    # Example:
    # `a(x = 5).b(-> x = 6)` should compile in the same order as
    # `a(x = 5); b(-> x = 6)`
    # (see issue #4437, https://github.com/jashkenas/coffeescript/issues/4437)
    varAccess = @variable?.properties?[0] instanceof Access
    argCode = (arg for arg in (@args || []) when arg instanceof Code)
    if argCode.length > 0 and varAccess and not @variable.base.cached
      [cache] = @variable.base.cache o, LEVEL_ACCESS, shouldCache: -> no
      @variable.base.cached = cache

    for arg, argIndex in @args
      if argIndex then compiledArgs.push @makeCode ", "
      compiledArgs.push (arg.compileToFragments o, LEVEL_LIST)...

    fragments = []
    if @isNew
      @variable.error "Unsupported reference to 'super'" if @variable instanceof Super
      fragments.push @makeCode 'new '
    fragments.push @variable.compileToFragments(o, LEVEL_ACCESS)...
    fragments.push @makeCode('('), compiledArgs..., @makeCode(')')
    fragments

  CSXToAst: (o) ->
    [attributes, content] = @args
    tagName = @variable.base
    tagName.locationData = @args.openingBracketLocationData
    {
      ...(
        unless tagName.value.length
          type: 'JSXFragment'
          openingFragment: tagName.withAstLocationData
            type: 'JSXOpeningFragment'
          closingFragment: tagName.withAstLocationData
            type: 'JSXClosingFragment'
        else
          openingElement =
            tagName.withAstLocationData
              type: 'JSXOpeningElement'
              name: tagName.toAst o#, LEVEL_ACCESS
              selfClosing: not content
          openingElement.attributes = flatten(
            if attributes.base instanceof Arr
              mergeAstLocationData openingElement, locationDataToAst attributes.base.locationData
              for obj in attributes.base.objects
                {base: attr} = obj
                attrProps = attr?.properties or []
                if not (attr instanceof Obj or attr instanceof IdentifierLiteral) or (attr instanceof Obj and not attr.generated and (attrProps.length > 1 or not (attrProps[0] instanceof Splat)))
                  obj.error """
                    Unexpected token. Allowed CSX attributes are: id="val", src={source}, {props...} or attribute.
                  """
                attr.csx = yes
                compiled = attr.toAst o#, LEVEL_PAREN
                mergeAstLocationData openingElement, compiled
                if attr instanceof IdentifierLiteral
                  attr.withAstLocationData
                    type: 'JSXAttribute'
                    name: compiled
                else
                  compiled
            else [])
          if content
            closingElementBabylonLocationData = locationDataToAst @args.closingBracketLocationData
            closingElement =
              @withCopiedBabylonLocationData(
                type: 'JSXClosingElement'
                name: @withCopiedBabylonLocationData(
                  tagName.toAst o
                  closingElementBabylonLocationData # TODO: this is inaccurate but not sure where to store the closing tagname location data
                )
                closingElementBabylonLocationData
              )
          {
            type: 'JSXElement'
            openingElement, closingElement
          }
      )
      children:
        if content and not content.base.isEmpty?()
          content.base.csx = yes
          compact flatten [
            content.toAst o#, LEVEL_LIST
          ]
        else []
    }

  compileCSX: (o) ->
    [attributes, content] = @args
    attributes.base.csx = yes
    content?.base.csx = yes
    fragments = [@makeCode('<')]
    fragments.push (tag = @variable.compileToFragments(o, LEVEL_ACCESS))...
    if attributes.base instanceof Arr
      for obj in attributes.base.objects
        attr = obj.base
        attrProps = attr?.properties or []
        # Catch invalid CSX attributes: <div {a:"b", props} {props} "value" />
        if not (attr instanceof Obj or attr instanceof IdentifierLiteral) or (attr instanceof Obj and not attr.generated and (attrProps.length > 1 or not (attrProps[0] instanceof Splat)))
          obj.error """
            Unexpected token. Allowed CSX attributes are: id="val", src={source}, {props...} or attribute.
          """
        obj.base.csx = yes if obj.base instanceof Obj
        fragments.push @makeCode ' '
        fragments.push obj.compileToFragments(o, LEVEL_PAREN)...
    if content
      fragments.push @makeCode('>')
      fragments.push content.compileNode(o, LEVEL_LIST)...
      fragments.push [@makeCode('</'), tag..., @makeCode('>')]...
    else
      fragments.push @makeCode(' />')
    fragments

#### Super

# Takes care of converting `super()` calls into calls against the prototype's
# function of the same name.
# When `expressions` are set the call will be compiled in such a way that the
# expressions are evaluated without altering the return value of the `SuperCall`
# expression.
exports.SuperCall = class SuperCall extends Call
  children: Call::children.concat ['expressions']

  isStatement: (o) ->
    @expressions?.length and o.level is LEVEL_TOP

  _compileToBabylon: (o) ->
    compilingExpressions = del o, 'compilingSuperCallExpressions'
    return super o unless @expressions?.length and not compilingExpressions

    superCall = @
    if o.level > LEVEL_TOP
      [superCall, ref] = @cache o, shouldCache: YES

    o.compilingSuperCallExpressions = yes
    new Block(compact [
      superCall
      @expressions...
      ref
    ]).compileToBabylon o, if o.level is LEVEL_TOP then o.level else LEVEL_LIST

  compileNode: (o) ->
    return super o unless @expressions?.length

    superCall   = new Literal fragmentsToText super o
    replacement = new Block @expressions.slice()

    if o.level > LEVEL_TOP
      # If we might be in an expression we need to cache and return the result
      [superCall, ref] = superCall.cache o, shouldCache: YES
      replacement.push ref

    replacement.unshift superCall
    replacement.compileToFragments o, if o.level is LEVEL_TOP then o.level else LEVEL_LIST

exports.Super = class Super extends Base
  constructor: (@accessor) ->
    super()

  children: ['accessor']

  _toAst: (o) ->
    @setAccessor o

    if @accessor?.name?.comments
      # A `super()` call gets compiled to e.g. `super.method()`, which means
      # the `method` property name gets compiled for the first time here, and
      # again when the `method:` property of the class gets compiled. Since
      # this compilation happens first, comments attached to `method:` would
      # get incorrectly output near `super.method()`, when we want them to
      # get output on the second pass when `method:` is output. So set them
      # aside during this compilation pass, and put them back on the object so
      # that they’re there for the later compilation.
      salvagedComments = @accessor.name.comments
      delete @accessor.name.comments
    compiled =
      new Value new SuperLiteral, if @accessor then [@accessor] else []
      .withLocationDataFrom @
      .toAst o
    attachCommentsToNode salvagedComments, @accessor.name if salvagedComments
    compiled

  setAccessor: (o) ->
    method = o.scope.namedMethod()
    @error 'cannot use super outside of an instance method' unless method?.isMethod
    return unless o.compiling

    unless method.ctor? or @accessor?
      {name, variable} = method
      if name.shouldCache() or (name instanceof Index and name.index.isAssignable())
        nref = new IdentifierLiteral o.scope.parent.freeVariable 'name'
        name.index = new Assign nref, name.index
      @accessor = if nref? then new Index nref else name

  compileNode: (o) ->
    @setAccessor o

    if @accessor?.name?.comments
      # A `super()` call gets compiled to e.g. `super.method()`, which means
      # the `method` property name gets compiled for the first time here, and
      # again when the `method:` property of the class gets compiled. Since
      # this compilation happens first, comments attached to `method:` would
      # get incorrectly output near `super.method()`, when we want them to
      # get output on the second pass when `method:` is output. So set them
      # aside during this compilation pass, and put them back on the object so
      # that they’re there for the later compilation.
      salvagedComments = @accessor.name.comments
      delete @accessor.name.comments
    fragments = (new Value (new Literal 'super'), if @accessor then [ @accessor ] else [])
    .compileToFragments o
    attachCommentsToNode salvagedComments, @accessor.name if salvagedComments
    fragments

#### RegexWithInterpolations

# Regexes with interpolations are in fact just a variation of a `Call` (a
# `RegExp()` call to be precise) with a `StringWithInterpolations` inside.
exports.RegexWithInterpolations = class RegexWithInterpolations extends Base
  constructor: (@call) ->
    super()

  children: ['call']

  astType: 'InterpolatedRegExpLiteral'

  astChildren: (o) ->
    interpolatedPattern: @call.args[0].toAst o

  astProps: (o) ->
    flags: @call.args[1]?.unwrap().originalValue ? ''
    delimiter: '///'

  _toAst: (o) ->
    return @call.toAst o if o.compiling
    super o

  compileNode: (o) ->
    @call.compileNode o

#### TaggedTemplateCall

exports.TaggedTemplateCall = class TaggedTemplateCall extends Call
  constructor: (variable, arg, soak) ->
    arg = StringWithInterpolations.fromStringLiteral arg if arg instanceof StringLiteral
    super variable, [ arg ], soak

  astType: 'TaggedTemplateExpression'
  astChildren: (o) ->
    tag: @variable.toAst o, LEVEL_ACCESS
    quasi: @args[0].toAst o, LEVEL_LIST

  compileNode: (o) ->
    @variable.compileToFragments(o, LEVEL_ACCESS).concat @args[0].compileToFragments(o, LEVEL_LIST)

#### Extends

# Node to extend an object's prototype with an ancestor object.
# After `goog.inherits` from the
# [Closure Library](https://github.com/google/closure-library/blob/master/closure/goog/base.js).
exports.Extends = class Extends extends Base
  constructor: (@child, @parent) ->
    super()

  children: ['child', 'parent']

  # Hooks one constructor into another's prototype chain.
  compileToFragments: (o) ->
    new Call(new Value(new Literal utility 'extend', o), [@child, @parent]).compileToFragments o

#### Access

# A `.` access into a property of a value, or the `::` shorthand for
# an access into the object's prototype.
exports.Access = class Access extends Base
  constructor: (@name, {@soak, @shorthand} = {}) ->
    super()

  children: ['name']

  compileToFragments: (o) ->
    name = @name.compileToFragments o
    node = @name.unwrap()
    if node instanceof PropertyName
      [@makeCode('.'), name...]
    else
      [@makeCode('['), name..., @makeCode(']')]

  _toAst: (o) ->
    @name.toAst o

  shouldCache: NO

#### Index

# A `[ ... ]` indexed access into an array or object.
exports.Index = class Index extends Base
  constructor: (@index) ->
    super()

  children: ['index']

  compileToFragments: (o) ->
    [].concat @makeCode("["), @index.compileToFragments(o, LEVEL_PAREN), @makeCode("]")

  _toAst: (o) ->
    @index.toAst o

  shouldCache: ->
    @index.shouldCache()

#### Range

# A range literal. Ranges can be used to extract portions (slices) of arrays,
# to specify a range for comprehensions, or as a value, to be expanded into the
# corresponding array of integers at runtime.
exports.Range = class Range extends Base

  children: ['from', 'to']

  constructor: (@from, @to, tag) ->
    super()

    @exclusive = tag is 'exclusive'
    @equals = if @exclusive then '' else '='

  astProps: ['exclusive']

  # Compiles the range's source variables -- where it starts and where it ends.
  # But only if they need to be cached to avoid double evaluation.
  compileVariables: (o) ->
    o = merge o, top: true
    shouldCache = del o, 'shouldCache'
    [@fromC, @fromVar] = @cacheToCodeFragments @from.cache o, LEVEL_LIST, {shouldCache}
    [@toC, @toVar]     = @cacheToCodeFragments @to.cache o, LEVEL_LIST, {shouldCache}
    [@step, @stepVar]  = @cacheToCodeFragments step.cache o, LEVEL_LIST, {shouldCache} if step = del o, 'step'
    @fromNum = if @from.isNumber() then Number @fromVar else null
    @toNum   = if @to.isNumber()   then Number @toVar   else null
    @stepNum = if step?.isNumber() then Number @stepVar else null

  compileVariablesForBabylon: (o) ->
    o = merge o, top: true
    @step = del o, 'step'
    @fromNum = getNumberValue @from if @from.isNumber()
    @toNum   = getNumberValue @to   if @to.isNumber()
    @stepNum = getNumberValue @step if @step?.isNumber()

  # When compiled normally, the range returns the contents of the *for loop*
  # needed to iterate over the values in the range. Used by comprehensions.
  compileNode: (o) ->
    @compileVariables o unless @fromVar
    return @compileArray(o) unless o.index

    # Set up endpoints.
    known    = @fromNum? and @toNum?
    idx      = del o, 'index'
    idxName  = del o, 'name'
    namedIndex = idxName and idxName isnt idx
    varPart  =
      if known and not namedIndex
        "var #{idx} = #{@fromC}"
      else
        "#{idx} = #{@fromC}"
    varPart += ", #{@toC}" if @toC isnt @toVar
    varPart += ", #{@step}" if @step isnt @stepVar
    [lt, gt] = ["#{idx} <#{@equals}", "#{idx} >#{@equals}"]

    # Generate the condition.
    [from, to] = [@fromNum, @toNum]
    # Always check if the `step` isn't zero to avoid the infinite loop.
    stepNotZero = "#{ @stepNum ? @stepVar } !== 0"
    stepCond = "#{ @stepNum ? @stepVar } > 0"
    lowerBound = "#{lt} #{ if known then to else @toVar }"
    upperBound = "#{gt} #{ if known then to else @toVar }"
    condPart =
      if @step?
        if @stepNum? and @stepNum isnt 0
          if @stepNum > 0 then "#{lowerBound}" else "#{upperBound}"
        else
          "#{stepNotZero} && (#{stepCond} ? #{lowerBound} : #{upperBound})"
      else
        if known
          "#{ if from <= to then lt else gt } #{to}"
        else
          "(#{@fromVar} <= #{@toVar} ? #{lowerBound} : #{upperBound})"

    cond = "#{@fromVar} <= #{@toVar}"

    # Generate the step.
    stepPart = if @stepVar
      "#{idx} += #{@stepVar}"
    else if known
      if namedIndex
        if from <= to then "++#{idx}" else "--#{idx}"
      else
        if from <= to then "#{idx}++" else "#{idx}--"
    else
      if namedIndex
        "#{cond} ? ++#{idx} : --#{idx}"
      else
        "#{cond} ? #{idx}++ : #{idx}--"

    varPart  = "#{idxName} = #{varPart}" if namedIndex
    stepPart = "#{idxName} = #{stepPart}" if namedIndex

    # The final loop body.
    [@makeCode "#{varPart}; #{condPart}; #{stepPart}"]

  compileForToBabylon: (o) ->
    indexVar = del o, 'indexVar'
    keyVar = del o, 'keyVar'
    shouldCache = del o, 'shouldCache'
    named = keyVar and keyVar isnt indexVar
    wrapInAssignToKeyVar = do ->
      return ((x) -> x) unless named

      (x) -> new Assign(keyVar, x)
    known =
      if @stepNum?
        if @stepNum > 0 then '<' else '>'
      else if @fromNum? and @toNum? and not (@step and not @stepNum?)
        if @fromNum <= @toNum then '<' else '>'

    [cachedFromVarAssign, fromVar] = @from.cache o, {shouldCache}
    [cachedToVarAssign,   toVar  ] = @to.cache   o, {shouldCache, onlyIfCached: yes}
    [cachedStepVarAssign, stepVar] = @step.cache o, {shouldCache, onlyIfCached: yes} if @step
    wrapInStepGuard =
      if @step and not @stepNum
        (node) => new Op '&&',
          new Op '!==', stepVar, new NumberLiteral '0'
          node
      else
        (node) -> node

    init:
      new Sequence([
        @from.withLocationData(wrapInAssignToKeyVar(
          new Assign indexVar, cachedFromVarAssign
        ))
        ...(if cachedToVarAssign   then [cachedToVarAssign]   else [])
        ...(if cachedStepVarAssign then [cachedStepVarAssign] else [])
      ]).compileToBabylon o
    test:
      @to.withLocationData(wrapInStepGuard(
        if known
          new Op("#{known}#{@equals}", indexVar, toVar)
        else
          new If(
            if @step
              new Op '>', stepVar, new NumberLiteral '0'
            else
              new Op '<=', fromVar, toVar
            new Op "<#{@equals}", indexVar, toVar
          ).addElse(
            new Op ">#{@equals}", indexVar, toVar
          )
      )).compileToBabylon o, LEVEL_PAREN
    update:
      @withLocationData(wrapInAssignToKeyVar(
        if @step
          new Op '+=', indexVar, stepVar
        else if known
          new Op(
            if known is '<' then '++' else '--'
            indexVar, null, not named
          )
        else
          new If(
            new Op '<=', fromVar, toVar
            new Op '++', indexVar, null, not named
          ).addElse(
            new Op '--', indexVar, null, not named
          )
      )).compileToBabylon o, LEVEL_PAREN

  _compileToBabylon: (o) ->
    @compileVariablesForBabylon o
    return @compileArrayToBabylon(o) unless o.indexVar
    @compileForToBabylon o

  compileArrayToBabylon: (o) ->
    known = @fromNum? and @toNum?
    if known and Math.abs(@fromNum - @toNum) <= 20
      range = [@fromNum..@toNum]
      range.pop() if @exclusive
      return new Arr(
        new NumberLiteral "#{num}" for num in range
      ).compileToBabylon o

    @withLocationData(new Parens new For(
      null
      {
        source: new Value this
        accumulateIndex: yes
        @step
      }
    )).compileToBabylon o

  # When used as a value, expand the range into the equivalent array.
  compileArray: (o) ->
    known = @fromNum? and @toNum?
    if known and Math.abs(@fromNum - @toNum) <= 20
      range = [@fromNum..@toNum]
      range.pop() if @exclusive
      return [@makeCode "[#{ range.join(', ') }]"]
    idt    = @tab + TAB
    i      = o.scope.freeVariable 'i', single: true, reserve: no
    result = o.scope.freeVariable 'results', reserve: no
    pre    = "\n#{idt}var #{result} = [];"
    if known
      o.index = i
      body    = fragmentsToText @compileNode o
    else
      vars    = "#{i} = #{@fromC}" + if @toC isnt @toVar then ", #{@toC}" else ''
      cond    = "#{@fromVar} <= #{@toVar}"
      body    = "var #{vars}; #{cond} ? #{i} <#{@equals} #{@toVar} : #{i} >#{@equals} #{@toVar}; #{cond} ? #{i}++ : #{i}--"
    post   = "{ #{result}.push(#{i}); }\n#{idt}return #{result};\n#{o.indent}"
    hasArgs = (node) -> node?.contains isLiteralArguments
    args   = ', arguments' if hasArgs(@from) or hasArgs(@to)
    [@makeCode "(function() {#{pre}\n#{idt}for (#{body})#{post}}).apply(this#{args ? ''})"]

#### Slice

# An array slice literal. Unlike JavaScript's `Array#slice`, the second parameter
# specifies the index of the end of the slice, just as the first parameter
# is the index of the beginning.
exports.Slice = class Slice extends Base

  children: ['range']

  constructor: (@range) ->
    super()

  _toAst: (o) ->
    @range.toAst o

  compileValueToBabylon: (o, compiledValue) ->
    {to, from, exclusive} = @range

    toNum = do ->
      return unless to?.isNumber()
      getNumberValue to

    args = [from ? new NumberLiteral '0']
    args.push(
      if exclusive
        to
      else if toNum?
        new NumberLiteral toNum + 1
      else
        new Op '||',
          new Op '+',
            new Op '+', to
            new NumberLiteral '1'
          new NumberLiteral '9e9'
    ) if to and not (not exclusive and toNum is -1)

    @withAstLocationData
      type: 'CallExpression'
      callee:
        type: 'MemberExpression'
        object: compiledValue
        property: new IdentifierLiteral('slice').compileToBabylon o
      arguments: arg.compileToBabylon o for arg in args

  # We have to be careful when trying to slice through the end of the array,
  # `9e9` is used because not all implementations respect `undefined` or `1/0`.
  # `9e9` should be safe because `9e9` > `2**32`, the max array length.
  compileNode: (o) ->
    {to, from} = @range
    # Handle an expression in the property access, e.g. `a[!b in c..]`.
    if from?.shouldCache()
      from = new Value new Parens from
    if to?.shouldCache()
      to = new Value new Parens to
    fromCompiled = from?.compileToFragments(o, LEVEL_PAREN) or [@makeCode '0']
    if to
      compiled     = to.compileToFragments o, LEVEL_PAREN
      compiledText = fragmentsToText compiled
      if not (not @range.exclusive and +compiledText is -1)
        toStr = ', ' + if @range.exclusive
          compiledText
        else if to.isNumber()
          "#{+compiledText + 1}"
        else
          compiled = to.compileToFragments o, LEVEL_ACCESS
          "+#{fragmentsToText compiled} + 1 || 9e9"
    [@makeCode ".slice(#{ fragmentsToText fromCompiled }#{ toStr or '' })"]

#### Obj

# An object literal, nothing fancy.
exports.Obj = class Obj extends Base
  constructor: (@properties = [], {@generated = no, @isClassBody} = {}) ->
    super()

    @objects = @properties

  children: ['properties']

  isAssignable: ->
    for prop in @properties
      # Check for reserved words.
      message = isUnassignable prop.unwrapAll().value
      prop.error message if message

      prop = prop.value if prop instanceof Assign and
        prop.context is 'object' and
        prop.value?.base not instanceof Arr
      return no unless prop.isAssignable()
    yes

  shouldCache: ->
    not @isAssignable()

  # Check if object contains splat.
  hasSplat: ->
    return yes for prop in @properties when prop instanceof Splat
    no

  astType: ->
    if @lhs
      'ObjectPattern'
    else
      'ObjectExpression'

  astChildren: (o) ->
    properties:
      for prop in @expandProperties(o) then do =>
        return prop.toAst o if prop instanceof Splat
        {variable, value, shorthand} = prop
        isComputedPropertyName = variable instanceof Value and variable.base instanceof ComputedPropertyName

        compiledKey =
          (if isComputedPropertyName
            variable.base.value
          else
            variable.unwrap()
          ).toAst o, LEVEL_LIST
        isAssignmentPattern = prop instanceof Assign and prop.context isnt 'object' # TODO: restructure this Assign in expandProperties() to avoid this special case?
        # key = merge {}, compiledKey
        # key.declaration = no if key.declaration
        compiledValue = value.toAst o, LEVEL_LIST
        prop.withAstLocationData
          type: 'ObjectProperty'
          key: compiledKey
          value:
            if isAssignmentPattern
              type: 'AssignmentPattern'
              left: compiledKey
              right: compiledValue
            else
              compiledValue
          shorthand: !!shorthand
          computed: do =>
            return yes if isComputedPropertyName
            return no if @isClassBody
            return no if not o.compiling# and variable.unwrap() instanceof StringWithInterpolations
            variable.shouldCache()

  astProps:
    implicit: 'generated'

  _toAst: (o) ->
    return @CSXAttributesToAst o if @csx
    super o

  _compileToBabylon: (o) ->
    return @CSXAttributesToAst o if @csx
    @reorderProperties() if @hasSplat() and @lhs
    @propagateLhs()

    super o

  expandProperties: (o) ->
    {compiling} = o
    return @properties if not compiling and @isClassBody
    for prop in @properties then do =>
      key = if prop instanceof Assign and prop.context is 'object'
        prop.variable
      else if prop instanceof Assign
        prop.operatorToken.error "unexpected #{prop.operatorToken.value}" unless @lhs
        prop.shorthand = yes
        prop.variable
      else
        prop
      if key instanceof Value and key.hasProperties()
        key.error 'invalid object key' unless prop.context isnt 'object' and key.this
        prop.nestedLhs = yes
        if compiling
          key  = key.properties[0].name
          prop = prop.withLocationData new Assign key, prop, context: 'object'
        else
          return new Assign prop, prop, context: 'object', shorthand: yes
      return prop unless key is prop
      prop.withLocationData(
        if prop.shouldCache() and compiling
          [key, value] = prop.base.cache o
          key  = key.withLocationData new PropertyName key.value if key instanceof IdentifierLiteral
          new Assign key, value, context: 'object'
        else if prop instanceof Value and prop.base instanceof ComputedPropertyName and compiling
          # `{ [foo()] }` output as `{ [ref = foo()]: ref }`.
          if prop.base.value.shouldCache()
            [key, value] = prop.base.value.cache o
            key = key.withLocationData new Value new ComputedPropertyName key.value if key instanceof IdentifierLiteral
            new Assign key, value, context: 'object'
          else
            # `{ [expression] }` output as `{ [expression]: expression }`.
            new Assign(
              if prop.base.value.isNumber() or prop.base.value.isString()
                prop.base.value
              else
                prop
              prop.base.value
              context: 'object'
            )
        else if prop instanceof Splat
          prop
        else
          new Assign prop, prop, context: 'object', shorthand: not compiling or prop.bareLiteral? IdentifierLiteral
      )

  propagateLhs: (setLhs) ->
    @lhs = yes if setLhs
    return unless @lhs

    for prop in @properties
      if prop instanceof Assign and prop.context is 'object'
        {value} = prop
        unwrappedVal = value.unwrapAll()
        if unwrappedVal instanceof Arr or unwrappedVal instanceof Obj
          unwrappedVal.propagateLhs yes
        else if unwrappedVal instanceof Assign
          unwrappedVal.nestedLhs = yes
      else if prop instanceof Splat
        prop.lhs = yes

  # Move rest property to the end of the list.
  # `{a, rest..., b} = obj` -> `{a, b, rest...} = obj`
  # `foo = ({a, rest..., b}) ->` -> `foo = {a, b, rest...}) ->`
  reorderProperties: ->
    props = @properties
    lastIndex = props.length - 1
    prevLast = props[lastIndex]
    splatProps = (i for prop, i in props when prop instanceof Splat)
    props[splatProps[1]].error "multiple spread elements are disallowed" if splatProps?.length > 1
    splatProp = props.splice splatProps[0], 1
    @objects = @properties = ([].concat props, splatProp).map (prop, index) ->
      return prop unless index is lastIndex
      prevLast.withLocationData prop, force: yes

  compileNode: (o) ->
    # CSX attributes <div id="val" attr={aaa} {props...} />
    return @compileCSXAttributes o if @csx

    @reorderProperties() if @hasSplat() and @lhs
    props = @properties
    if @generated
      for node in props when node instanceof Value
        node.error 'cannot have an implicit value in an implicit object'

    idt      = o.indent += TAB
    lastNode = @lastNode @properties

    # If this object is the left-hand side of an assignment, all its children
    # are too.
    @propagateLhs()

    isCompact = yes
    for prop in @properties
      if prop instanceof Assign and prop.context is 'object'
        isCompact = no

    answer = []
    answer.push @makeCode if isCompact then '' else '\n'
    for prop, i in props
      join = if i is props.length - 1
        ''
      else if isCompact
        ', '
      else if prop is lastNode
        '\n'
      else
        ',\n'
      indent = if isCompact then '' else idt

      key = if prop instanceof Assign and prop.context is 'object'
        prop.variable
      else if prop instanceof Assign
        prop.operatorToken.error "unexpected #{prop.operatorToken.value}" unless @lhs
        prop.variable
      else
        prop
      if key instanceof Value and key.hasProperties()
        key.error 'invalid object key' unless prop.context isnt 'object' and key.this
        key  = key.properties[0].name
        prop = new Assign key, prop, context: 'object'
      if key is prop
        if prop.shouldCache()
          [key, value] = prop.base.cache o
          key  = new PropertyName key.value if key instanceof IdentifierLiteral
          prop = new Assign key, value, context: 'object'
        else if key instanceof Value and key.base instanceof ComputedPropertyName
          # `{ [foo()] }` output as `{ [ref = foo()]: ref }`.
          if prop.base.value.shouldCache()
            [key, value] = prop.base.value.cache o
            key  = new Value new ComputedPropertyName key.value if key instanceof IdentifierLiteral
            prop = new Assign key, value, context: 'object'
          else
            # `{ [expression] }` output as `{ [expression]: expression }`.
            prop = new Assign key, prop.base.value, context: 'object'
        else if not prop.bareLiteral?(IdentifierLiteral) and prop not instanceof Splat
          prop = new Assign prop, prop, context: 'object'
      if indent then answer.push @makeCode indent
      answer.push prop.compileToFragments(o, LEVEL_TOP)...
      if join then answer.push @makeCode join
    answer.push @makeCode if isCompact then '' else "\n#{@tab}"
    answer = @wrapInBraces answer
    if @front then @wrapInParentheses answer else answer

  assigns: (name) ->
    for prop in @properties when prop.assigns name then return yes
    no

  eachName: (iterator) ->
    for prop in @properties
      prop = prop.value if prop instanceof Assign and prop.context is 'object'
      prop = prop.unwrapAll()
      prop.eachName iterator if prop.eachName?

  CSXAttributesToAst: (o) ->
    for prop in @properties
      prop.csx = yes
      prop.toAst o#, LEVEL_TOP

  compileCSXAttributes: (o) ->
    props = @properties
    answer = []
    for prop, i in props
      prop.csx = yes
      join = if i is props.length - 1 then '' else ' '
      prop = new Literal "{#{prop.compile(o)}}" if prop instanceof Splat
      answer.push prop.compileToFragments(o, LEVEL_TOP)...
      answer.push @makeCode join
    if @front then @wrapInParentheses answer else answer

#### Arr

# An array literal.
exports.Arr = class Arr extends Base
  constructor: (objs, {@lhs = no} = {}) ->
    super()
    @objects = objs or []
    @propagateLhs()

  children: ['objects']

  hasElision: ->
    return yes for obj in @objects when obj instanceof Elision
    no

  isAssignable: ->
    return no unless @objects.length

    for obj, i in @objects
      return no if obj instanceof Splat and i + 1 isnt @objects.length
      return no unless obj.isAssignable() and (not obj.isAtomic or obj.isAtomic())
    yes

  shouldCache: ->
    not @isAssignable()

  # If this array is the left-hand side of an assignment, all its children
  # are too.
  propagateLhs: (setLhs) ->
    @lhs = yes if setLhs
    return unless @lhs
    for obj in @objects
      obj.lhs = yes if obj instanceof Splat
      unwrappedObj = obj.unwrapAll()
      if unwrappedObj instanceof Arr or unwrappedObj instanceof Obj
        unwrappedObj.propagateLhs yes
      else if unwrappedObj instanceof Assign
        unwrappedObj.nestedLhs = yes

  astChildren:
    elements:
      propName: 'objects'
      level: LEVEL_LIST

  astType: ->
    if @lhs
      'ArrayPattern'
    else
      'ArrayExpression'

  compileNode: (o) ->
    return [@makeCode '[]'] unless @objects.length
    o.indent += TAB
    fragmentIsElision = (fragment) -> fragmentsToText(fragment).trim() is ','
    # Detect if `Elisions` at the beginning of the array are processed (e.g. [, , , a]).
    passedElision = no

    answer = []
    for obj, objIndex in @objects
      unwrappedObj = obj.unwrapAll()
      # Let `compileCommentFragments` know to intersperse block comments
      # into the fragments created when compiling this array.
      if unwrappedObj.comments and
         unwrappedObj.comments.filter((comment) -> not comment.here).length is 0
        unwrappedObj.includeCommentFragments = YES

    compiledObjs = (obj.compileToFragments o, LEVEL_LIST for obj in @objects)
    olen = compiledObjs.length
    # If `compiledObjs` includes newlines, we will output this as a multiline
    # array (i.e. with a newline and indentation after the `[`). If an element
    # contains line comments, that should also trigger multiline output since
    # by definition line comments will introduce newlines into our output.
    # The exception is if only the first element has line comments; in that
    # case, output as the compact form if we otherwise would have, so that the
    # first element’s line comments get output before or after the array.
    includesLineCommentsOnNonFirstElement = no
    for fragments, index in compiledObjs
      for fragment in fragments
        if fragment.isHereComment
          fragment.code = fragment.code.trim()
        else if index isnt 0 and includesLineCommentsOnNonFirstElement is no and hasLineComments fragment
          includesLineCommentsOnNonFirstElement = yes
      # Add ', ' if all `Elisions` from the beginning of the array are processed (e.g. [, , , a]) and
      # element isn't `Elision` or last element is `Elision` (e.g. [a,,b,,])
      if index isnt 0 and passedElision and (not fragmentIsElision(fragments) or index is olen - 1)
        answer.push @makeCode ', '
      passedElision or= not fragmentIsElision fragments
      answer.push fragments...
    if includesLineCommentsOnNonFirstElement or '\n' in fragmentsToText(answer)
      for fragment, fragmentIndex in answer
        if fragment.isHereComment
          fragment.code = "#{multident(fragment.code, o.indent, no)}\n#{o.indent}"
        else if fragment.code is ', ' and not fragment?.isElision
          fragment.code = ",\n#{o.indent}"
      answer.unshift @makeCode "[\n#{o.indent}"
      answer.push @makeCode "\n#{@tab}]"
    else
      for fragment in answer when fragment.isHereComment
        fragment.code = "#{fragment.code} "
      answer.unshift @makeCode '['
      answer.push @makeCode ']'
    answer

  assigns: (name) ->
    for obj in @objects when obj.assigns name then return yes
    no

  eachName: (iterator) ->
    for obj in @objects
      obj = obj.unwrapAll()
      obj.eachName iterator

#### Class

# The CoffeeScript class definition.
# Initialize a **Class** with its name, an optional superclass, and a body.

exports.Class = class Class extends Base
  children: ['variable', 'parent', 'body']

  constructor: (@variable, @parent, @body) ->
    super()
    unless @body
      @body = new Block
      @generatedBody = yes

  compileNode: (o) ->
    @name          = @determineName()
    executableBody = @walkBody o

    # Special handling to allow `class expr.A extends A` declarations
    parentName    = @parent.base.value if @parent instanceof Value and not @parent.hasProperties()
    @hasNameClash = @name? and @name is parentName

    node = @

    if executableBody or @hasNameClash
      node = new ExecutableClassBody node, executableBody
    else if not @name? and o.level is LEVEL_TOP
      # Anonymous classes are only valid in expressions
      node = new Parens node

    if @boundMethods.length and @parent
      @variable ?= new IdentifierLiteral o.scope.freeVariable '_class'
      [@variable, @variableRef] = @variable.cache o unless @variableRef?

    if @variable
      node = new Assign @variable, node, { @moduleDeclaration }

    @compileNode = @compileClassDeclaration
    try
      return node.compileToFragments o
    finally
      delete @compileNode

  _compileToBabylon: (o) ->
    @name = @determineName()
    executableBody = @walkBody o

    parentName    = @parent.base.value if @parent instanceof Value and not @parent.hasProperties()
    @hasNameClash = @name? and @name is parentName

    @body.isClassBody = yes

    node = @

    if executableBody or @hasNameClash
      node = new ExecutableClassBody node, executableBody

    if @boundMethods.length and @parent
      @variable ?= new IdentifierLiteral o.scope.freeVariable '_class'
      [@variable, @variableRef] = @variable.cache o unless @variableRef?

    if @variable and (executableBody or @name isnt @variable.unwrap?().value or o.level is LEVEL_TOP)
      node = new Assign @variable, node, { @moduleDeclaration }

    @_compileToBabylon = @compileClassDeclarationToBabylon

    try
      return node.compileToBabylon o
    finally
      delete @_compileToBabylon

  astType: (o) ->
    if o.level is LEVEL_TOP
      'ClassDeclaration'
    else
      'ClassExpression'

  astChildren:
    id: 'variable'
    superClass:
      propName: 'parent'
      level: LEVEL_PAREN
    body:
      level: LEVEL_TOP

  declareName: (o) ->
    return unless (name = @variable?.unwrap()) instanceof IdentifierLiteral
    alreadyDeclared = o.scope.find name.value
    name.isDeclaration = not alreadyDeclared

  _toAst: (o) ->
    @declareName o
    @fixBodyLocationData()
    @name = @determineName()
    @body.isClassBody = yes
    @walkBody o
    @sniffDirectives @body.expressions, replace: yes
    @ctor?.noReturn = true
    super o

  fixBodyLocationData: ->
    return unless @generatedBody

    @body.withEmptyTrailingLocationDataFrom @

  compileClassDeclarationToBabylon: (o) ->
    @prepareConstructor()
    @proxyBoundMethods() if @boundMethods.length
    id = @variable.withLocationData new IdentifierLiteral @name if @name
    if @variable?.comments? and id
      (id.comments ?= []).push @variable.comments...
      @variable.comments.length = 0
      @variable.base?.comments?.length = 0

    @withAstType
      id: id.compileToBabylon o if id
      superClass: @parent.compileToBabylon o if @parent
      body: @body.compileToBabylon o, LEVEL_TOP
      o

  prepareConstructor: ->
    @ctor ?= @makeDefaultConstructor() if @externalCtor or @boundMethods.length
    @ctor?.noReturn = true

  compileClassDeclaration: (o) ->
    @prepareConstructor()
    @proxyBoundMethods() if @boundMethods.length

    o.indent += TAB

    result = []
    result.push @makeCode "class "
    result.push @makeCode @name if @name
    @compileCommentFragments o, @variable, result if @variable?.comments?
    result.push @makeCode ' ' if @name
    result.push @makeCode('extends '), @parent.compileToFragments(o)..., @makeCode ' ' if @parent

    result.push @makeCode '{'
    unless @body.isEmpty()
      @body.spaced = true
      result.push @makeCode '\n'
      result.push @body.compileToFragments(o, LEVEL_TOP)...
      result.push @makeCode "\n#{@tab}"
    result.push @makeCode '}'

    result

  # Figure out the appropriate name for this class
  determineName: ->
    return null unless @variable
    [..., tail] = @variable.properties
    node = if tail
      tail instanceof Access and tail.name
    else
      @variable.base
    unless node instanceof IdentifierLiteral or node instanceof PropertyName
      return null
    name = node.value
    unless tail
      message = isUnassignable name
      @variable.error message if message
    if name in JS_FORBIDDEN then "_#{name}" else name

  walkBody: (o) ->
    @ctor          = null
    @boundMethods  = []
    executableBody = null

    initializer     = []
    { expressions } = @body
    {compiling} = o

    i = 0
    for expression in expressions.slice()
      if expression instanceof Value and expression.isObject true
        { properties } = expression.base
        exprs     = []
        end       = 0
        start     = 0
        pushSlice = ->
          if end > start
            obj = new Obj properties[start...end], generated: true, isClassBody: true
            obj.mergeLocationDataFrom prop for prop in properties[start...end]
            obj = obj.withLocationData new Value obj
            exprs.push obj

        while assign = properties[end]
          if initializerExpression = @addInitializerExpression assign
            pushSlice()
            exprs.push initializerExpression
            initializer.push initializerExpression
            start = end + 1
          end++
        pushSlice()

        expressions[i..i] = exprs
        i += exprs.length
      else
        if initializerExpression = @addInitializerExpression expression
          initializer.push initializerExpression
          expressions[i] = initializerExpression
        i += 1

    for method in initializer when method instanceof Code
      if method.ctor
        method.error 'Cannot define more than one constructor in a class' if @ctor
        @ctor = method
      else if method.isStatic and method.bound
        method.context = @name
      else if method.bound
        @boundMethods.push method

    return unless compiling
    if initializer.length isnt expressions.length
      @body.expressions = (expression.hoist() for expression in initializer)
      new Block expressions

  # Add an expression to the class initializer
  #
  # This is the key method for determining whether an expression in a class
  # body should appear in the initializer or the executable body. If the given
  # `node` is valid in a class body the method will return a (new, modified,
  # or identical) node for inclusion in the class initializer, otherwise
  # nothing will be returned and the node will appear in the executable body.
  #
  # At time of writing, only methods (instance and static) are valid in ES
  # class initializers. As new ES class features (such as class fields) reach
  # Stage 4, this method will need to be updated to support them. We
  # additionally allow `PassthroughLiteral`s (backticked expressions) in the
  # initializer as an escape hatch for ES features that are not implemented
  # (e.g. getters and setters defined via the `get` and `set` keywords as
  # opposed to the `Object.defineProperty` method).
  addInitializerExpression: (node) ->
    if node.unwrapAll() instanceof PassthroughLiteral
      node
    else if @validInitializerMethod node
      @addInitializerMethod node
    else
      null

  # Checks if the given node is a valid ES class initializer method.
  validInitializerMethod: (node) ->
    return no unless node instanceof Assign and node.value instanceof Code
    {value: {bound}, context, variable} = node
    return yes if context is 'object' and not variable.hasProperties()
    return no if bound and not @name
    return variable.looksStatic @name

  # Returns a configured class initializer method
  addInitializerMethod: ({variable, value: method, operatorToken}) ->
    method.isMethod = yes
    method.isStatic = variable.looksStatic @name

    if method.isStatic
      method.name = variable.properties[0]
    else
      methodName  = variable.base
      method.name = methodName.withLocationData(
        new (if methodName.shouldCache() then Index else Access) methodName
      )
      isConstructor =
        if methodName instanceof StringLiteral
          methodName.originalValue is 'constructor'
        else
          methodName.value is 'constructor'
      method.ctor = (if @parent then 'derived' else 'base') if isConstructor
      method.error 'Cannot define a constructor as a bound (fat arrow) function' if method.bound and method.ctor

    (method.name.comments ?= []).push operatorToken.comments... if operatorToken?.comments
    method.operatorToken = operatorToken
    method

  makeDefaultConstructor: ->
    ctor = @addInitializerMethod @withLocationData new Assign (new Value new PropertyName 'constructor'), new Code
    @body.unshift ctor

    if @parent
      ctor.body.push @withLocationData new SuperCall new Super, [new Splat new IdentifierLiteral 'arguments']

    if @externalCtor
      applyCtor = new Value @externalCtor, [ new Access new PropertyName 'apply' ]
      applyArgs = [ new ThisLiteral, new IdentifierLiteral 'arguments' ]
      ctor.body.push @externalCtor.withLocationData new Call applyCtor, applyArgs
      ctor.body.makeReturn()

    ctor

  proxyBoundMethods: ->
    @ctor.thisAssignments = for method in @boundMethods
      method.classVariable = @variableRef if @parent

      name = new Value(new ThisLiteral, [ method.name ])
      @withLocationData new Assign name, new Call(new Value(name, [new Access new PropertyName 'bind']), [new ThisLiteral])

    null

exports.ExecutableClassBody = class ExecutableClassBody extends Base
  children: [ 'class', 'body' ]

  defaultClassVariableName: '_Class'

  constructor: (@class, @body = new Block) ->
    super()

  _compileToBabylon: (o) ->
    if jumpNode = @body.jumps()
      jumpNode.error 'Class bodies cannot contain pure statements'
    if argumentsNode = @body.contains isLiteralArguments
      argumentsNode.error "Class bodies shouldn't reference arguments"

    wrapper = @class.withLocationData new Code [], @body
    o.classScope = wrapper.makeScope o.scope
    @name = @class.name ? o.classScope.freeVariable @defaultClassVariableName
    ident = @class.withLocationData new IdentifierLiteral @name
    directives = @walkBody()
    @setContext()

    args = [@class.withLocationData new ThisLiteral]
    if @class.hasNameClash
      parent = new IdentifierLiteral o.classScope.freeVariable 'superClass'
      wrapper.params.push new Param parent
      args.push @class.parent
      @class.parent = parent

    if @externalCtor
      externalCtor = @externalCtor.withLocationData new IdentifierLiteral o.classScope.freeVariable 'ctor', reserve: no
      @class.externalCtor = externalCtor
      @externalCtor.variable.base = externalCtor

    @body.expressions.unshift(
      if @name isnt @class.name
        @class.withLocationData new Assign (new IdentifierLiteral @name), @class
      else
        @class
    )
    @body.expressions.unshift (new Directive(directive).withLocationDataFrom(directive) for directive in directives)...
    @body.expressions.push ident

    new Parens(new Call(
      new Value(
        wrapper
        [new Access new PropertyName 'call'])
      args
    )).withLocationDataFrom(@class).compileToBabylon o

  compileNode: (o) ->
    if jumpNode = @body.jumps()
      jumpNode.error 'Class bodies cannot contain pure statements'
    if argumentsNode = @body.contains isLiteralArguments
      argumentsNode.error "Class bodies shouldn't reference arguments"

    params  = []
    args    = [new ThisLiteral]
    wrapper = new Code params, @body
    klass   = new Parens new Call (new Value wrapper, [new Access new PropertyName 'call']), args

    @body.spaced = true

    o.classScope = wrapper.makeScope o.scope

    @name      = @class.name ? o.classScope.freeVariable @defaultClassVariableName
    ident      = new IdentifierLiteral @name
    directives = @walkBody()
    @setContext()

    if @class.hasNameClash
      parent = new IdentifierLiteral o.classScope.freeVariable 'superClass'
      wrapper.params.push new Param parent
      args.push @class.parent
      @class.parent = parent

    if @externalCtor
      externalCtor = new IdentifierLiteral o.classScope.freeVariable 'ctor', reserve: no
      @class.externalCtor = externalCtor
      @externalCtor.variable.base = externalCtor

    if @name isnt @class.name
      @body.expressions.unshift new Assign (new IdentifierLiteral @name), @class
    else
      @body.expressions.unshift @class
    @body.expressions.unshift directives...
    @body.push ident

    klass.compileToFragments o

  # Traverse the class's children and:
  # - Hoist valid ES properties into `@properties`
  # - Hoist static assignments into `@properties`
  # - Convert invalid ES properties into class or prototype assignments
  walkBody: ->
    directives = @sniffDirectives @body.expressions
    @traverseChildren false, (child) =>
      return false if child instanceof Class or child instanceof HoistTarget

      cont = true
      if child instanceof Block
        for node, i in child.expressions
          if node instanceof Value and node.isObject(true)
            cont = false
            child.expressions[i] = @addProperties node.base.properties
          else if node instanceof Assign and node.variable.looksStatic @name
            node.value.isStatic = yes
        child.expressions = flatten child.expressions
      cont

    directives

  setContext: ->
    @body.traverseChildren false, (node) =>
      if node instanceof ThisLiteral
        node.value   = @name
      else if node instanceof Code and node.bound and node.isStatic
        node.context = @name

  # Make class/prototype assignments for invalid ES properties
  addProperties: (assigns) ->
    result = for assign in assigns
      variable = assign.variable
      base     = variable.base
      value    = assign.value
      delete assign.context

      if base.value is 'constructor'
        if value instanceof Code
          base.error 'constructors must be defined at the top level of a class body'

        # The class scope is not available yet, so return the assignment to update later
        assign = @externalCtor = assign.withLocationData new Assign new Value, value
      else if not assign.variable.this
        name      = new (if base.shouldCache() then Index else Access) base
        prototype = new Access new PropertyName 'prototype'
        variable  = new Value new ThisLiteral(), [ prototype, name ]

        assign.variable = variable
      else if assign.value instanceof Code
        assign.value.isStatic = true

      assign
    compact result

#### Import and Export

exports.ModuleDeclaration = class ModuleDeclaration extends Base
  constructor: (@clause, @source) ->
    super()
    @checkSource()

  children: ['clause', 'source']

  isStatement: YES
  jumps:       THIS
  makeReturn:  THIS

  checkSource: ->
    if @source? and @source instanceof StringWithInterpolations
      @source.error 'the name of the module to be imported from must be an uninterpolated string'

  checkScope: (o, moduleDeclarationType) ->
    return if @topLevel
    if o.indent?.length isnt 0
      @error "#{moduleDeclarationType} statements must be at top-level scope"

exports.ImportDeclaration = class ImportDeclaration extends ModuleDeclaration
  astChildren:
    specifiers:
      propName: 'clause'
      default: []
    source: 'source'
  astProps: ->
    importKind: 'value' if @clause

  _toAst: (o) ->
    @checkScope o, 'import'
    o.importedSymbols = []

    super o

  compileNode: (o) ->
    @checkScope o, 'import'
    o.importedSymbols = []

    code = []
    code.push @makeCode "#{@tab}import "
    code.push @clause.compileNode(o)... if @clause?

    if @source?.value?
      code.push @makeCode ' from ' unless @clause is null
      code.push @makeCode @source.value

    code.push @makeCode ';'
    code

exports.ImportClause = class ImportClause extends Base
  constructor: (@defaultBinding, @namedImports) ->
    super()

  children: ['defaultBinding', 'namedImports']

  _toAst: (o) ->
    compact flatten [
      @defaultBinding?.toAst o
      @namedImports?.toAst o
    ]

  compileNode: (o) ->
    code = []

    if @defaultBinding?
      code.push @defaultBinding.compileNode(o)...
      code.push @makeCode ', ' if @namedImports?

    if @namedImports?
      code.push @namedImports.compileNode(o)...

    code

exports.ExportDeclaration = class ExportDeclaration extends ModuleDeclaration
  compileNode: (o) ->
    @checkScope o, 'export'

    code = []
    code.push @makeCode "#{@tab}export "
    code.push @makeCode 'default ' if @ instanceof ExportDefaultDeclaration

    if @ not instanceof ExportDefaultDeclaration and
       (@clause instanceof Assign or @clause instanceof Class)
      # Prevent exporting an anonymous class; all exported members must be named
      if @clause instanceof Class and not @clause.variable
        @clause.error 'anonymous classes cannot be exported'

      code.push @makeCode 'var '
      @clause.moduleDeclaration = 'export'

    if @clause.body? and @clause.body instanceof Block
      code = code.concat @clause.compileToFragments o, LEVEL_TOP
    else
      code = code.concat @clause.compileNode o

    code.push @makeCode " from #{@source.value}" if @source?.value?
    code.push @makeCode ';'
    code

exports.ExportNamedDeclaration = class ExportNamedDeclaration extends ExportDeclaration
  _toAst: (o) ->
    @checkScope o, 'export'
    if @clause instanceof Class and not @clause.variable
      @clause.error 'anonymous classes cannot be exported'

    @clause.moduleDeclaration = 'export'

    super o

  astChildren: (o) -> {
    ...(
      if @clause instanceof ExportSpecifierList
        specifiers: @clause.toAst o
      else
        specifiers: []
        declaration: @clause.toAst o
    )
    source: @source?.toAst o
  }
  astProps: ->
    exportKind: 'value'

exports.ExportDefaultDeclaration = class ExportDefaultDeclaration extends ExportDeclaration
  astChildren:
    declaration: 'clause'

  _toAst: (o) ->
    @checkScope o, 'export'
    @clause.isExport = yes

    super o

exports.ExportAllDeclaration = class ExportAllDeclaration extends ExportDeclaration
  astChildren: ['source']
  astProps: ->
    exportKind: 'value'

  _toAst: (o) ->
    @checkScope o, 'export'
    super o

exports.ModuleSpecifierList = class ModuleSpecifierList extends Base
  constructor: (@specifiers) ->
    super()

  children: ['specifiers']

  _toAst: (o) ->
    specifier.toAst o for specifier in @specifiers

  compileNode: (o) ->
    code = []
    o.indent += TAB
    compiledList = (specifier.compileToFragments o, LEVEL_LIST for specifier in @specifiers)

    if @specifiers.length isnt 0
      code.push @makeCode "{\n#{o.indent}"
      for fragments, index in compiledList
        code.push @makeCode(",\n#{o.indent}") if index
        code.push fragments...
      code.push @makeCode "\n}"
    else
      code.push @makeCode '{}'
    code

exports.ImportSpecifierList = class ImportSpecifierList extends ModuleSpecifierList

exports.ExportSpecifierList = class ExportSpecifierList extends ModuleSpecifierList

exports.ModuleSpecifier = class ModuleSpecifier extends Base
  constructor: (@original, @alias, @moduleDeclarationType) ->
    super()

    if @original.comments or @alias?.comments
      @comments = []
      @comments.push @original.comments... if @original.comments
      @comments.push @alias.comments...    if @alias?.comments

    # The name of the variable entering the local scope
    @identifier = if @alias? then @alias.value else @original.value

  children: ['original', 'alias']

  addIdentifierToScope: (o) ->
    o.scope.find @identifier, @moduleDeclarationType

  _toAst: (o) ->
    @addIdentifierToScope o
    super o

  compileNode: (o) ->
    @addIdentifierToScope o
    code = []
    code.push @makeCode @original.value
    code.push @makeCode " as #{@alias.value}" if @alias?
    code

exports.ImportSpecifier = class ImportSpecifier extends ModuleSpecifier
  constructor: (imported, local) ->
    super imported, local, 'import'

  addIdentifierToScope: (o) ->
    # Per the spec, symbols can’t be imported multiple times
    # (e.g. `import { foo, foo } from 'lib'` is invalid)
    if @identifier in o.importedSymbols or o.scope.check @identifier
      @error "'#{@identifier}' has already been declared"
    else
      o.importedSymbols.push @identifier
    super o

  astChildren: (o) ->
    compiledOriginal = @original.toAst o
    imported: compiledOriginal
    local: @alias?.toAst(o) ? compiledOriginal

exports.ImportDefaultSpecifier = class ImportDefaultSpecifier extends ImportSpecifier
  astChildren:
    local: 'original'

exports.ImportNamespaceSpecifier = class ImportNamespaceSpecifier extends ImportSpecifier
  astChildren: (o) ->
    local: do =>
      return @alias.toAst o if @alias
      @original.toAst o

exports.ExportSpecifier = class ExportSpecifier extends ModuleSpecifier
  constructor: (local, exported) ->
    super local, exported, 'export'

  astChildren: (o) ->
    compiledOriginal = @original.toAst o
    local: compiledOriginal
    exported: @alias?.toAst(o) ? compiledOriginal

#### Assign

# The **Assign** is used to assign a local variable to value, or to set the
# property of an object -- including within object literals.
exports.Assign = class Assign extends Base
  constructor: (@variable, @value, options = {}) ->
    super()
    {@context, @param, @subpattern, @operatorToken, @moduleDeclaration, @shorthand, @originalContext = @context} = options
    @propagateLhs()

  children: ['variable', 'value']

  isAssignable: YES

  isStatement: (o) ->
    return no unless o.compiling
    o?.level is LEVEL_TOP and @context? and (@moduleDeclaration or "?" in @context)

  checkAssignability: (o, varBase) ->
    if o.scope.type(varBase.value) is 'import'
      varBase.error "'#{varBase.value}' is read-only"

  assigns: (name) ->
    @[if @context is 'object' then 'value' else 'variable'].assigns name

  unfoldSoak: (o) ->
    unfoldSoak o, this, 'variable'

  isDefaultAssignment: -> @param or @nestedLhs
  astType: ->
    if @isDefaultAssignment()
      'AssignmentPattern'
    else
      'AssignmentExpression'
  astChildren:
    right:
      propName: 'value'
      level: LEVEL_LIST
    left:
      propName: 'variable'
      level: LEVEL_LIST
  astProps: (o) ->
    return {} if @isDefaultAssignment()
    operator: (if o.compiling then @context else @originalContext) or '='

  propagateLhs: ->
    return unless @variable?.isArray?() or @variable?.isObject?()
    # This is the left-hand side of an assignment; let `Arr` and `Obj`
    # know that, so that those nodes know that they’re assignable as
    # destructured variables.
    @variable.base.propagateLhs yes

  _toAst: (o) ->
    return @CSXAttributeToAst o if @csx
    @addScopeVariables o, checkAssignability: no if not @context or @context is '**='
    super o

  _compileToBabylon: (o) ->
    return @CSXAttributeToAst o if @csx
    if @variable instanceof Value
      if @variable.isArray() or @variable.isObject()
        unless @variable.isAssignable()
          if @variable.isObject() and @variable.base.hasSplat()
            return @compileObjectDestructToBabylon o
          else
            return @compileDestructuringToBabylon o

      return @compileSpliceToBabylon      o if @variable.isSplice()
      return @compileConditionalToBabylon o if @context in ['||=', '&&=', '?=']
      return @compileSpecialMathToBabylon o if @context in ['//=', '%%=']

    @addScopeVariables o# unless @context

    if @moduleDeclaration
      return
        type: 'VariableDeclaration'
        declarations: [
          @withAstLocationData
            type: 'VariableDeclarator'
            id:   @variable.compileToBabylon o
            init: @value.compileToBabylon o
        ]
        kind: 'var'

    super o

  CSXAttributeToAst: (o) ->
    type: 'JSXAttribute'
    name: @variable.base.withAstLocationData
      type: 'JSXIdentifier'
      name: @variable.base.value
    value: do =>
      val = @value.base
      val.csxAttribute = yes
      compiled = astAsBlock val, o
      return compiled if val instanceof StringLiteral
      val.withAstLocationData
        type: 'JSXExpressionContainer'
        expression: compiled

  addScopeVariables: (o, {checkAssignability = yes} = {}) ->
    varBase = @variable.unwrapAll()
    if checkAssignability and not varBase.isAssignable()
      @variable.error "'#{@variable.compile o}' can't be assigned"

    varBase.eachName (name) =>
      return if name.hasProperties?()

      message = isUnassignable name.value
      name.error message if message

      # `moduleDeclaration` can be `'import'` or `'export'`.
      @checkAssignability o, name
      if @moduleDeclaration
        o.scope.add name.value, @moduleDeclaration
        name.isDeclaration = yes
      else if @param
        o.scope.add name.value,
          if @param is 'alwaysDeclare'
            'var'
          else
            'param'
      else
        alreadyDeclared = o.scope.find name.value
        name.isDeclaration ?= not alreadyDeclared
        # If this assignment identifier has one or more herecomments
        # attached, output them as part of the declarations line (unless
        # other herecomments are already staged there) for compatibility
        # with Flow typing. Don’t do this if this assignment is for a
        # class, e.g. `ClassName = class ClassName {`, as Flow requires
        # the comment to be between the class name and the `{`.
        if name.comments and not o.scope.comments[name.value] and
           @value not instanceof Class and
           name.comments.every((comment) -> comment.here and not comment.multiline)
          commentsNode = new IdentifierLiteral name.value
          commentsNode.comments = name.comments
          commentFragments = []
          @compileCommentFragments o, commentsNode, commentFragments
          o.scope.comments[name.value] = commentFragments
          o.scope.commentNodes[name.value] = name.comments
          comment.includeWithDeclaration = yes for comment in name.comments

  # Compile an assignment, delegating to `compileDestructuring` or
  # `compileSplice` if appropriate. Keep track of the name of the base object
  # we've been assigned to, for correct internal references. If the variable
  # has not been seen yet within the current scope, declare it.
  compileNode: (o) ->
    isValue = @variable instanceof Value
    if isValue
      # If `@variable` is an array or an object, we’re destructuring;
      # if it’s also `isAssignable()`, the destructuring syntax is supported
      # in ES and we can output it as is; otherwise we `@compileDestructuring`
      # and convert this ES-unsupported destructuring into acceptable output.
      if @variable.isArray() or @variable.isObject()
        unless @variable.isAssignable()
          if @variable.isObject() and @variable.base.hasSplat()
            return @compileObjectDestruct o
          else
            return @compileDestructuring o

      return @compileSplice       o if @variable.isSplice()
      return @compileConditional  o if @context in ['||=', '&&=', '?=']
      return @compileSpecialMath  o if @context in ['//=', '%%=']

    @addScopeVariables(o) if not @context or @context is '**='
    if @value instanceof Code
      if @value.isStatic
        @value.name = @variable.properties[0]
      else if @variable.properties?.length >= 2
        [properties..., prototype, name] = @variable.properties
        @value.name = name if prototype.name?.value is 'prototype'

    @value.base.csxAttribute = yes if @csx
    val = @value.compileToFragments o, LEVEL_LIST
    compiledName = @variable.compileToFragments o, LEVEL_LIST

    if @context is 'object'
      if @variable.shouldCache()
        compiledName.unshift @makeCode '['
        compiledName.push @makeCode ']'
      return compiledName.concat @makeCode(if @csx then '=' else ': '), val

    answer = compiledName.concat @makeCode(" #{ @context or '=' } "), val
    # Per https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Operators/Destructuring_assignment#Assignment_without_declaration,
    # if we’re destructuring without declaring, the destructuring assignment must be wrapped in parentheses.
    # The assignment is wrapped in parentheses if 'o.level' has lower precedence than LEVEL_LIST (3)
    # (i.e. LEVEL_COND (4), LEVEL_OP (5) or LEVEL_ACCESS (6)), or if we're destructuring object, e.g. {a,b} = obj.
    if o.level > LEVEL_LIST or isValue and @variable.base instanceof Obj and not @nestedLhs and not (@param is yes)
      @wrapInParentheses answer
    else
      answer

  compileDestructuringToBabylon: (o) ->
    {value}   = this
    {objects} = @variable.base
    assigns   = []

    return @wrapInParensIf(o.level >= LEVEL_OP)(value).compileToBabylon o unless objects.length

    if objects.length is 1 and objects[0] instanceof Expansion
      objects[0].error 'Destructuring assignment has no target'

    if value.unwrap() not instanceof IdentifierLiteral or @variable.assigns(value.unwrap().value)
      [cachedValueAssign, value] = value.cache o, shouldCache: YES
      assigns.push cachedValueAssign

    splats = (i for obj, i in objects when obj instanceof Splat)
    expans = (i for obj, i in objects when obj instanceof Expansion)
    splatsAndExpans = [splats..., expans...]
    # if splatsAndExpans.length > 1
    #   objects[splatsAndExpans.sort()[1]].error "multiple splats/expansions are disallowed in an assignment"
    isSplat = splats.length > 0
    isExpans = expans.length > 0

    slicer = (type) -> (slicee, ...args) ->
      new Value utilityBabylon type, merge o, calledWithArgs: [slicee, ...(new NumberLiteral arg for arg in args)]

    getSlice = slicer 'slice'
    getSplice = slicer 'splice'

    # Check if `objects` array contains any instance of `Assign`, e.g. {a:1}.
    hasObjAssigns = (objs) ->
      (i for obj, i in objs when obj instanceof Assign and obj.context is 'object')

    # Check if `objects` array contains any unassignable object.
    objIsUnassignable = (objs) ->
      return yes for obj in objs when not obj.isAssignable()
      no

    # `objects` are complex when there is object assign ({a:1}),
    # unassignable object, or just a single node.
    complexObjects = (objs) ->
      hasObjAssigns(objs).length or objIsUnassignable(objs) or objects.length is 1

    pushAssign = (variable, value) =>
      assigns.push new Assign variable, value, {@param}#, subpattern: yes

    if isSplat
      splatVar = objects[splats[0]].name.unwrap()
      if splatVar instanceof Arr or splatVar instanceof Obj
        splatVarRef = new IdentifierLiteral o.scope.freeVariable 'ref'
        objects[splats[0]].name = splatVarRef
        splatVarAssign = -> pushAssign new Value(splatVar), splatVarRef

    loopObjects = (objs, rhs) ->
      for obj, i in objs when obj not instanceof Elision
        if obj instanceof Assign and obj.context is 'object'
          {value: variable} = obj
          {variable} = variable if variable instanceof Assign
          idx =
            if variable.this
              variable.properties[0].name
            else
              new PropertyName variable.unwrap().value
          acc = idx.unwrap() instanceof PropertyName
          val = new Value value, [new (if acc then Access else Index) idx]
        else
          [variable, val] =
            if obj instanceof Splat
              [new Value(obj.name), getSlice rhs, i]
            else
              [obj, new Value rhs, [new Index new NumberLiteral i]]
        message = isUnassignable variable.unwrap().value
        variable.error message if message
        pushAssign variable, val

    processObjects = (objs, rhs = value) ->
      if complexObjects objs
        loopObjects objs, rhs
      else
        pushAssign(
          new Value new Arr(objs, lhs: yes)
          rhs
        )

    if splatsAndExpans.length
      expansIndex = splatsAndExpans[0]
      leftObjs = objects.slice 0, expansIndex + (if isSplat then 1 else 0)
      rightObjs = objects.slice expansIndex + 1
      processObjects leftObjs if leftObjs.length isnt 0
      processObjects(rightObjs,
        if isSplat
          getSplice objects[expansIndex].unwrapAll(), rightObjs.length * -1
        else
          getSlice value, rightObjs.length * -1
      ) if rightObjs.length isnt 0
    else
      processObjects objects

    splatVarAssign?()
    assigns.push value unless o.level is LEVEL_TOP# or @subpattern
    @withLocationData(new Block assigns).compileToBabylon o

  compileObjectDestructToBabylon: (o) ->
    @variable.base.reorderProperties()
    {properties: props} = @variable.base
    [..., splat] = props
    splatProp = splat.name
    assigns = []
    refVal = new Value new IdentifierLiteral o.scope.freeVariable 'ref'
    props.splice -1, 1, new Splat refVal
    assigns.push new Assign new Value(new Obj props), @value
    assigns.push new Assign new Value(splatProp), refVal
    new Block(assigns).compileToBabylon o

  # Object rest property is not assignable: `{{a}...}`
  compileObjectDestruct: (o) ->
    @variable.base.reorderProperties()
    {properties: props} = @variable.base
    [..., splat] = props
    splatProp = splat.name
    assigns = []
    refVal = new Value new IdentifierLiteral o.scope.freeVariable 'ref'
    props.splice -1, 1, new Splat refVal
    assigns.push new Assign(new Value(new Obj props), @value).compileToFragments o, LEVEL_LIST
    assigns.push new Assign(new Value(splatProp), refVal).compileToFragments o, LEVEL_LIST
    @joinFragmentArrays assigns, ', '

  # Brief implementation of recursive pattern matching, when assigning array or
  # object literals to a value. Peeks at their properties to assign inner names.
  compileDestructuring: (o) ->
    top       = o.level is LEVEL_TOP
    {value}   = this
    {objects} = @variable.base
    olen      = objects.length

    # Special-case for `{} = a` and `[] = a` (empty patterns).
    # Compile to simply `a`.
    if olen is 0
      code = value.compileToFragments o
      return if o.level >= LEVEL_OP then @wrapInParentheses code else code
    [obj] = objects

    # Disallow `[...] = a` for some reason. (Could be equivalent to `[] = a`?)
    if olen is 1 and obj instanceof Expansion
      obj.error 'Destructuring assignment has no target'

    # Count all `Splats`: [a, b, c..., d, e]
    splats = (i for obj, i in objects when obj instanceof Splat)
    # Count all `Expansions`: [a, b, ..., c, d]
    expans = (i for obj, i in objects when obj instanceof Expansion)
    # Combine splats and expansions.
    splatsAndExpans = [splats..., expans...]
    # Show error if there is more than one `Splat`, or `Expansion`.
    # Examples: [a, b, c..., d, e, f...], [a, b, ..., c, d, ...], [a, b, ..., c, d, e...]
    if splatsAndExpans.length > 1
      # Sort 'splatsAndExpans' so we can show error at first disallowed token.
      objects[splatsAndExpans.sort()[1]].error "multiple splats/expansions are disallowed in an assignment"

    isSplat = splats.length > 0
    isExpans = expans.length > 0

    vvar     = value.compileToFragments o, LEVEL_LIST
    vvarText = fragmentsToText vvar
    assigns  = []
    pushAssign = (variable, val) =>
      assigns.push new Assign(variable, val, param: @param, subpattern: yes).compileToFragments o, LEVEL_LIST

    if isSplat
      splatVar = objects[splats[0]].name.unwrap()
      if splatVar instanceof Arr or splatVar instanceof Obj
        splatVarRef = new IdentifierLiteral o.scope.freeVariable 'ref'
        objects[splats[0]].name = splatVarRef
        splatVarAssign = -> pushAssign new Value(splatVar), splatVarRef

    # At this point, there are several things to destructure. So the `fn()` in
    # `{a, b} = fn()` must be cached, for example. Make vvar into a simple
    # variable if it isn’t already.
    if value.unwrap() not instanceof IdentifierLiteral or @variable.assigns(vvarText)
      ref = o.scope.freeVariable 'ref'
      assigns.push [@makeCode(ref + ' = '), vvar...]
      vvar = [@makeCode ref]
      vvarText = ref

    slicer = (type) -> (vvar, start, end = no) ->
      vvar = new IdentifierLiteral vvar unless vvar instanceof Value
      args = [vvar, new NumberLiteral(start)]
      args.push new NumberLiteral end if end
      slice = new Value (new IdentifierLiteral utility type, o), [new Access new PropertyName 'call']
      new Value new Call slice, args

    # Helper which outputs `[].slice` code.
    compSlice = slicer "slice"

    # Helper which outputs `[].splice` code.
    compSplice = slicer "splice"

    # Check if `objects` array contains any instance of `Assign`, e.g. {a:1}.
    hasObjAssigns = (objs) ->
      (i for obj, i in objs when obj instanceof Assign and obj.context is 'object')

    # Check if `objects` array contains any unassignable object.
    objIsUnassignable = (objs) ->
      return yes for obj in objs when not obj.isAssignable()
      no

    # `objects` are complex when there is object assign ({a:1}),
    # unassignable object, or just a single node.
    complexObjects = (objs) ->
      hasObjAssigns(objs).length or objIsUnassignable(objs) or olen is 1

    # "Complex" `objects` are processed in a loop.
    # Examples: [a, b, {c, r...}, d], [a, ..., {b, r...}, c, d]
    loopObjects = (objs, vvar, vvarTxt) =>
      for obj, i in objs when obj not instanceof Elision
        # If `obj` is {a: 1}
        if obj instanceof Assign and obj.context is 'object'
          {value: vvar} = obj
          {variable: vvar} = vvar if vvar instanceof Assign
          idx =
            if vvar.this
              vvar.properties[0].name
            else
              new PropertyName vvar.unwrap().value
          acc = idx.unwrap() instanceof PropertyName
          vval = new Value value, [new (if acc then Access else Index) idx]
        else
          # `obj` is [a...], {a...} or a
          vvar = switch
            when obj instanceof Splat then new Value obj.name
            else obj
          vval = switch
            when obj instanceof Splat then compSlice(vvarTxt, i)
            else new Value new Literal(vvarTxt), [new Index new NumberLiteral i]
        message = isUnassignable vvar.unwrap().value
        vvar.error message if message
        pushAssign vvar, vval

    # "Simple" `objects` can be split and compiled to arrays, [a, b, c] = arr, [a, b, c...] = arr
    assignObjects = (objs, vvar, vvarTxt) =>
      vvar = new Value new Arr(objs, lhs: yes)
      vval = if vvarTxt instanceof Value then vvarTxt else new Value new Literal(vvarTxt)
      pushAssign vvar, vval

    processObjects = (objs, vvar, vvarTxt) ->
      if complexObjects objs
        loopObjects objs, vvar, vvarTxt
      else
        assignObjects objs, vvar, vvarTxt

    # In case there is `Splat` or `Expansion` in `objects`,
    # we can split array in two simple subarrays.
    # `Splat` [a, b, c..., d, e] can be split into  [a, b, c...] and [d, e].
    # `Expansion` [a, b, ..., c, d] can be split into [a, b] and [c, d].
    # Examples:
    # a) `Splat`
    #   CS: [a, b, c..., d, e] = arr
    #   JS: [a, b, ...c] = arr, [d, e] = splice.call(c, -2)
    # b) `Expansion`
    #   CS: [a, b, ..., d, e] = arr
    #   JS: [a, b] = arr, [d, e] = slice.call(arr, -2)
    if splatsAndExpans.length
      expIdx = splatsAndExpans[0]
      leftObjs = objects.slice 0, expIdx + (if isSplat then 1 else 0)
      rightObjs = objects.slice expIdx + 1
      processObjects leftObjs, vvar, vvarText if leftObjs.length isnt 0
      if rightObjs.length isnt 0
        # Slice or splice `objects`.
        refExp = switch
          when isSplat then compSplice new Value(objects[expIdx].name), rightObjs.length * -1
          when isExpans then compSlice vvarText, rightObjs.length * -1
        if complexObjects rightObjs
          restVar = refExp
          refExp = o.scope.freeVariable 'ref'
          assigns.push [@makeCode(refExp + ' = '), restVar.compileToFragments(o, LEVEL_LIST)...]
        processObjects rightObjs, vvar, refExp
    else
      # There is no `Splat` or `Expansion` in `objects`.
      processObjects objects, vvar, vvarText
    splatVarAssign?()
    assigns.push vvar unless top or @subpattern
    fragments = @joinFragmentArrays assigns, ', '
    if o.level < LEVEL_LIST then fragments else @wrapInParentheses fragments

  # When compiling a conditional assignment, take care to ensure that the
  # operands are only evaluated once, even though we have to reference them
  # more than once.
  compileConditional: (o) ->
    [left, right] = @variable.cacheReference o
    # Disallow conditional assignment of undefined variables.
    if not left.properties.length and left.base instanceof Literal and
           left.base not instanceof ThisLiteral and not o.scope.check left.base.value
      @variable.error "the variable \"#{left.base.value}\" can't be assigned with #{@context} because it has not been declared before"
    if "?" in @context
      o.isExistentialEquals = true
      new If(new Existence(left), right, type: 'if').addElse(new Assign(right, @value, context: '=')).compileToFragments o
    else
      fragments = new Op(@context[...-1], left, new Assign(right, @value, context: '=')).compileToFragments o
      if o.level <= LEVEL_LIST then fragments else @wrapInParentheses fragments

  compileConditionalToBabylon: (o) ->
    [left, right] = @variable.cacheReference o
    # Disallow conditional assignment of undefined variables.
    if not left.properties.length and left.base instanceof Literal and
           left.base not instanceof ThisLiteral and not o.scope.check left.base.value
      @variable.error "the variable \"#{left.base.value}\" can't be assigned with #{@context} because it has not been declared before"
    if "?" in @context
      o.isExistentialEquals = true
      new If(new Existence(left), right, type: 'if').addElse(new Assign(right, @value, context: '=')).compileToBabylon o
    else
      @wrapInParensIf(o.level <= LEVEL_LIST)(
        new Op(@context[...-1], left, new Assign(right, @value, context: '='))
      ).compileToBabylon o

  # Convert special math assignment operators like `a //= b` to the equivalent
  # extended form `a = a // b` and then compiles that.
  compileSpecialMath: (o) ->
    @specialMathAssign(o).compileToFragments o

  specialMathAssign: (o) ->
    [left, right] = @variable.cacheReference o
    new Assign left, new Op @context[...-1], right, @value

  compileSpecialMathToBabylon: (o) ->
    @specialMathAssign(o).compileToBabylon o

  # Compile the assignment from an array splice literal, using JavaScript's
  # `Array#splice` method.
  compileSplice: (o) ->
    {range: {from, to, exclusive}} = @variable.properties.pop()
    unwrappedVar = @variable.unwrapAll()
    if unwrappedVar.comments
      moveComments unwrappedVar, @
      delete @variable.comments
    name = @variable.compile o
    if from
      [fromDecl, fromRef] = @cacheToCodeFragments from.cache o, LEVEL_OP
    else
      fromDecl = fromRef = '0'
    if to
      if from?.isNumber() and to.isNumber()
        to = to.compile(o) - fromRef
        to += 1 unless exclusive
      else
        to = to.compile(o, LEVEL_ACCESS) + ' - ' + fromRef
        to += ' + 1' unless exclusive
    else
      to = "9e9"
    [valDef, valRef] = @value.cache o, LEVEL_LIST
    answer = [].concat @makeCode("#{utility 'splice', o}.apply(#{name}, [#{fromDecl}, #{to}].concat("), valDef, @makeCode(")), "), valRef
    if o.level > LEVEL_TOP then @wrapInParentheses answer else answer

  compileSpliceToBabylon: (o) ->
    {range: {from, to, exclusive}} = @variable.properties.pop()
    from ?= new NumberLiteral '0'
    fromNum = getNumberValue from if from.isNumber()
    toNum   = getNumberValue to   if to?.isNumber()
    [cachedFromAssign, from] = from.cache o
    [cachedValueAssign, value] = @value.cache o

    @wrapInParensIf(o.level > LEVEL_TOP)(new Sequence([
      utilityBabylon 'splice', merge o, appliedWithArgs: [
        @variable
        new Call(
          new Value(
            new Arr [
              cachedFromAssign
              if fromNum? and toNum?
                diff = toNum - fromNum
                new NumberLiteral if exclusive then diff else diff + 1
              else if to
                diff = new Op '-', to, from
                if exclusive then diff else new Op '+', diff, new NumberLiteral '1'
              else
                new NumberLiteral '9e9'
            ]
            [new Access new PropertyName 'concat']
          )
          [cachedValueAssign]
        )
      ]
      value
    ])).compileToBabylon o

  eachName: (iterator) ->
    @variable.unwrapAll().eachName iterator

  makeReturn: (opts) ->
    return super opts if opts?.accumulator or opts?.mark
    @withLocationData new Return new Parens @

#### FuncGlyph

exports.FuncGlyph = class FuncGlyph extends Base
  constructor: (@glyph) ->
    super()

#### Code

# A function definition. This is the only node that creates a new Scope.
# When for the purposes of walking the contents of a function body, the Code
# has no *children* -- they're within the inner scope.
exports.Code = class Code extends Base
  constructor: (params, body, @funcGlyph, @paramStart) ->
    super()

    @params      = params or []
    @body        = body or new Block
    @bound       = @funcGlyph?.glyph is '=>'
    @isGenerator = no
    @isAsync     = no
    @isMethod    = no

    @body.traverseChildren no, (node) =>
      if (node instanceof Op and node.isYield()) or node instanceof YieldReturn
        @isGenerator = yes
      if (node instanceof Op and node.isAwait()) or node instanceof AwaitReturn
        @isAsync = yes
      if node instanceof For and node.isAwait()
        @isAsync = yes

    @propagateLhs()

  children: ['params', 'body']

  isStatement: -> @isMethod

  jumps: NO

  makeScope: (parentScope) -> new Scope parentScope, @body, this

  compileParamsToBabylon: ({params, haveSplatParam, o}) ->
    for param, index in params
      scopeVariablesCount = o.scope.variables.length
      compiled = param.compileToBabylon o
      if scopeVariablesCount isnt o.scope.variables.length
        generatedVariables = o.scope.variables.splice scopeVariablesCount
        o.scope.parent.variables.push generatedVariables...
      compiled

  propagateLhs: ->
    for {name} in @params when name instanceof Arr or name instanceof Obj
      name.propagateLhs yes

  processParams: (o) ->
    exprs = []
    haveSplatParam = no
    paramsAfterSplat = []
    params = compact(
      for param in @params
        {name, value, splat} = param
        if splat or param instanceof Expansion
          if haveSplatParam
            param.error 'only one splat or expansion parameter is allowed per function definition'
          else if param instanceof Expansion and @params.length is 1
            param.error 'an expansion parameter cannot be the only parameter in a function definition'
          haveSplatParam = yes
          if param instanceof Expansion
            splatParamName = new Value new IdentifierLiteral o.scope.freeVariable 'args'
          else if name instanceof Arr or name instanceof Obj
            splatParamName = new Value new IdentifierLiteral o.scope.freeVariable 'arg'
            exprs.push new Assign new Value(name), splatParamName
          else
            splatParamName = param.asReference o
          o.scope.parameter splatParamName.unwrap().value
          new Splat splatParamName, lhs: yes
        else
          asRef =
            if param.shouldCache()
              param.asReference o
            else
              param.name
          processedParam =
            unless haveSplatParam
              ref =
                if value?
                  new Assign new Value(asRef), value, param: yes
                else
                  asRef
              if name instanceof Arr or name instanceof Obj
                # This parameter is destructured.
                unless param.shouldCache()
                  name.eachName ({value}) ->
                    o.scope.parameter value
              else
                paramToAddToScope = if param.value? then param else ref
                o.scope.parameter fragmentsToText paramToAddToScope.compileToFragmentsWithoutComments o

              ref
            else
              paramsAfterSplat.push param
              if value?
                condition = new Op '===', asRef, new UndefinedLiteral
                ifTrue = new Assign new Value(asRef), value
                exprs.push new If condition, ifTrue
              o.scope.add name.value, 'var', yes if name?.value?
              null
          if param.shouldCache()
            exprs.push new Assign new Value(name), asRef, param: 'alwaysDeclare'
          processedParam
    )

    @assignParamsAfterSplat {exprs, splatParamName, paramsAfterSplat, o} if paramsAfterSplat.length isnt 0

    {params, exprs, haveSplatParam}

  _compileToBabylon: (o) ->
    if @ctor
      @name.error 'Class constructor may not be async'       if @isAsync
      @name.error 'Class constructor may not be a generator' if @isGenerator

    if @bound
      @context = o.scope.method.context if o.scope.method?.bound
      @context = 'this' unless @context
    @updateOptions o
    wasEmpty = @body.isEmpty()
    {thisAssignments} = @expandThisParams o
    @body.expressions.unshift thisAssignments... unless @expandCtorSuper thisAssignments
    {params, exprs, haveSplatParam} = @processParams o
    @body.expressions.unshift exprs...
    if @isMethod and @bound and not @isStatic and @classVariable
      @body.expressions.unshift @withLocationData utilityBabylon 'boundMethodCheck', merge o, invokedWithArgs: [new Value(new ThisLiteral), @classVariable]
    @body.makeReturn() unless wasEmpty or @noReturn

    if @bound and @isGenerator
      yieldNode = @body.contains (node) -> node instanceof Op and node.operator is 'yield'
      (yieldNode or @).error 'yield cannot occur inside bound (fat arrow) functions'

    # ((if params.length then params[0] else @body).comments ?= []).push @paramStart.comments... if @paramStart?.comments?
    (@comments                                             ?= []).push @paramStart.comments... if @paramStart?.comments?
    (@body                                       .comments ?= []).push @funcGlyph.comments...  if @funcGlyph?.comments?

    {
      type:
        if @isMethod
          'ClassMethod'
        else if @bound
          'ArrowFunctionExpression'
        else if @isExport
          'FunctionDeclaration'
        else
          'FunctionExpression'
      generator: @isGenerator
      async: @isAsync
      params: @compileParamsToBabylon {params, haveSplatParam, o}
      body: @body.compileWithDeclarationsToBabylon o
      ...@methodAstFields o
    }

  astType: ->
    if @isMethod
      'ClassMethod'
    else
     'FunctionExpression'
  astProps: (o) -> {
    generator: @isGenerator
    async: @isAsync
    @bound
    id: null
    ...@methodAstFields o
  }
  astChildren: (o) ->
    @body.makeReturn mark: yes unless @body.isEmpty() or @noReturn
    params: @paramsToAst o
    body: {
      ...@body.toAst merge(o, checkForDirectives: yes), LEVEL_TOP
      indented: @body.locationData.first_line > @funcGlyph.locationData.first_line
    }

  paramsToAst: (o) ->
    for param in @params
      (do ->
        return param if param instanceof Expansion
        {name, value, splat} = param
        if splat
          new Splat name, lhs: yes, postfix: splat.postfix
          .withLocationDataFrom name
        else if value?
          new Assign name, value, param: yes
          .withLocationDataFrom name
          .mergeLocationDataFrom value
        else
          name
      ).toAst o

  methodAstFields: (o) ->
    return {} unless @isMethod

    [methodScope, o.scope] = [o.scope, o.scope.parent]
    compiledName = @name.toAst o
    o.scope = methodScope

    fields =
      kind:
        if @ctor
          'constructor'
        else
          'method'
      key: compiledName
      computed: do =>
        return no if not o.compiling and @name instanceof Index and @name.index instanceof StringWithInterpolations
        return yes if @name instanceof Index
        return yes if @name instanceof Access and @name.name instanceof ComputedPropertyName
        return no unless o.compiling
        return yes if @name instanceof Access and (@name.name instanceof NumberLiteral or @name.name instanceof StringLiteral)
        no
      static: @isStatic
    unless o.compiling
      fields.staticClassName = @isStatic.className if @isStatic?.className
      fields.operator = @operatorToken?.value ? '='
    fields

  _toAst: (o) ->
    @updateOptions o
    @processParams o # this is necessary to declare params on scope, probably could refactor to just do that
    @mergeLocationDataFrom @name if @isMethod
    super o

  expandThisParams: (o) ->
    thisAssignments  = @thisAssignments?.slice() ? []

    # Check for duplicate parameters and separate `this` assignments.
    paramNames = []
    @eachParamName (name, node, param, obj) =>
      node.error "multiple parameters named '#{name}'" if name in paramNames
      paramNames.push name

      if node.this
        name   = node.properties[0].name.value
        name   = "_#{name}" if name in JS_FORBIDDEN
        target = new IdentifierLiteral o.scope.freeVariable name, reserve: no
        # `Param` is object destructuring with a default value: ({@prop = 1}) ->
        # In a case when the variable name is already reserved, we have to assign
        # a new variable name to the destructured variable: ({prop:prop1 = 1}) ->
        if param.name instanceof Obj and obj instanceof Assign and obj.operatorToken.value is '='
          replacement = obj.withLocationData(
            new Assign(
              new IdentifierLiteral name
              new Assign target, obj.value
              context: 'object' #, operatorToken: new Literal ':'
            ))
          param.renameParam obj, replacement, expandAssign: no
        else
          replacement = node.withLocationData(target)
          param.renameParam node, replacement
        thisAssignments.push @funcGlyph.withLocationData new Assign(
          node
          new IdentifierLiteral target.value
        )

    {thisAssignments}

  updateOptions: (o) ->
    o.scope         = del(o, 'classScope') or @makeScope o.scope
    o.scope.shared  = del(o, 'sharedScope')
    o.indent        += TAB
    delete o.bare
    delete o.isExistentialEquals

  assignParamsAfterSplat: ({exprs, splatParamName, paramsAfterSplat, o}) ->
    # Create a destructured assignment, e.g. `[a..., b, c] = ref`
    exprs.unshift new Assign new Value(
        new Arr [new Splat(splatParamName), (param.asReference o for param in paramsAfterSplat)...]
      ), new Value splatParamName

  # Compilation creates a new scope unless explicitly asked to share with the
  # outer scope. Handles splat parameters in the parameter list by setting
  # such parameters to be the final parameter in the function definition, as
  # required per the ES2015 spec. If the CoffeeScript function definition had
  # parameters after the splat, they are declared via expressions in the
  # function body.
  compileNode: (o) ->
    if @ctor
      @name.error 'Class constructor may not be async'       if @isAsync
      @name.error 'Class constructor may not be a generator' if @isGenerator

    if @bound
      @context = o.scope.method.context if o.scope.method?.bound
      @context = 'this' unless @context

    @updateOptions o
    params           = []
    exprs            = []
    paramsAfterSplat = []
    haveSplatParam   = no

    {thisAssignments} = @expandThisParams o

    # Parse the parameters, adding them to the list of parameters to put in the
    # function definition; and dealing with splats or expansions, including
    # adding expressions to the function body to declare all parameter
    # variables that would have been after the splat/expansion parameter.
    # If we encounter a parameter that needs to be declared in the function
    # body for any reason, for example it’s destructured with `this`, also
    # declare and assign all subsequent parameters in the function body so that
    # any non-idempotent parameters are evaluated in the correct order.
    for param, i in @params
      # Was `...` used with this parameter? (Only one such parameter is allowed
      # per function.) Splat/expansion parameters cannot have default values,
      # so we need not worry about that.
      if param.splat or param instanceof Expansion
        if haveSplatParam
          param.error 'only one splat or expansion parameter is allowed per function definition'
        else if param instanceof Expansion and @params.length is 1
          param.error 'an expansion parameter cannot be the only parameter in a function definition'
        haveSplatParam = yes
        if param.splat
          if param.name instanceof Arr or param.name instanceof Obj
            # Splat arrays are treated oddly by ES; deal with them the legacy
            # way in the function body. TODO: Should this be handled in the
            # function parameter list, and if so, how?
            splatParamName = o.scope.freeVariable 'arg'
            params.push ref = new Value new IdentifierLiteral splatParamName
            exprs.push new Assign new Value(param.name), ref
          else
            params.push ref = param.asReference o
            splatParamName = fragmentsToText ref.compileNodeWithoutComments o
          if param.shouldCache()
            exprs.push new Assign new Value(param.name), ref
        else # `param` is an Expansion
          splatParamName = o.scope.freeVariable 'args'
          params.push new Value new IdentifierLiteral splatParamName

        o.scope.parameter splatParamName

      # Parse all other parameters; if a splat paramater has not yet been
      # encountered, add these other parameters to the list to be output in
      # the function definition.
      else
        asRef =
          if param.shouldCache()
            param.asReference o
          else
            param.name
        # If this parameter comes before the splat or expansion, it will go
        # in the function definition parameter list.
        unless haveSplatParam
          ref =
            if param.value?
              new Assign new Value(asRef), param.value, param: yes
            else
              asRef
          # Add this parameter’s reference(s) to the function scope.
          if param.name instanceof Arr or param.name instanceof Obj
            # This parameter is destructured.
            param.name.lhs = yes
            unless param.shouldCache()
              param.name.eachName (prop) ->
                o.scope.parameter prop.value
          else
            # This compilation of the parameter is only to get its name to add
            # to the scope name tracking; since the compilation output here
            # isn’t kept for eventual output, don’t include comments in this
            # compilation, so that they get output the “real” time this param
            # is compiled.
            paramToAddToScope = if param.value? then param else ref
            o.scope.parameter fragmentsToText paramToAddToScope.compileToFragmentsWithoutComments o
          params.push ref
        else
          paramsAfterSplat.push param
          # If this parameter had a default value, since it’s no longer in the
          # function parameter list we need to assign its default value
          # (if necessary) as an expression in the body.
          if param.value?
            condition = new Op '===', asRef, new UndefinedLiteral
            ifTrue = new Assign new Value(asRef), param.value
            exprs.push new If condition, ifTrue
          # Add this parameter to the scope, since it wouldn’t have been added
          # yet since it was skipped earlier.
          o.scope.add param.name.value, 'var', yes if param.name?.value?
        if param.shouldCache()
          exprs.push new Assign new Value(param.name), asRef, param: 'alwaysDeclare'

    # If there were parameters after the splat or expansion parameter, those
    # parameters need to be assigned in the body of the function.
    if paramsAfterSplat.length isnt 0
      # Create a destructured assignment, e.g. `[a, b, c] = [args..., b, c]`
      exprs.unshift new Assign new Value(
          new Arr [new Splat(new IdentifierLiteral(splatParamName)), (param.asReference o for param in paramsAfterSplat)...]
        ), new Value new IdentifierLiteral splatParamName

    # Add new expressions to the function body
    wasEmpty = @body.isEmpty()
    @body.expressions.unshift thisAssignments... unless @expandCtorSuper thisAssignments
    @body.expressions.unshift exprs...
    if @isMethod and @bound and not @isStatic and @classVariable
      boundMethodCheck = new Value new Literal utility 'boundMethodCheck', o
      @body.expressions.unshift new Call(boundMethodCheck, [new Value(new ThisLiteral), @classVariable])
    @body.makeReturn() unless wasEmpty or @noReturn

    # JavaScript doesn’t allow bound (`=>`) functions to also be generators.
    # This is usually caught via `Op::compileContinuation`, but double-check:
    if @bound and @isGenerator
      yieldNode = @body.contains (node) -> node instanceof Op and node.operator is 'yield'
      (yieldNode or @).error 'yield cannot occur inside bound (fat arrow) functions'

    # Assemble the output
    modifiers = []
    modifiers.push 'static' if @isMethod and @isStatic
    modifiers.push 'async'  if @isAsync
    unless @isMethod or @bound
      modifiers.push "function#{if @isGenerator then '*' else ''}"
    else if @isGenerator
      modifiers.push '*'

    signature = [@makeCode '(']
    # Block comments between a function name and `(` get output between
    # `function` and `(`.
    if @paramStart?.comments?
      @compileCommentFragments o, @paramStart, signature
    for param, i in params
      signature.push @makeCode ', ' if i isnt 0
      signature.push @makeCode '...' if haveSplatParam and i is params.length - 1
      # Compile this parameter, but if any generated variables get created
      # (e.g. `ref`), shift those into the parent scope since we can’t put a
      # `var` line inside a function parameter list.
      scopeVariablesCount = o.scope.variables.length
      signature.push param.compileToFragments(o)...
      if scopeVariablesCount isnt o.scope.variables.length
        generatedVariables = o.scope.variables.splice scopeVariablesCount
        o.scope.parent.variables.push generatedVariables...
    signature.push @makeCode ')'
    # Block comments between `)` and `->`/`=>` get output between `)` and `{`.
    if @funcGlyph?.comments?
      comment.unshift = no for comment in @funcGlyph.comments
      @compileCommentFragments o, @funcGlyph, signature

    body = @body.compileWithDeclarations o unless @body.isEmpty()

    # We need to compile the body before method names to ensure `super`
    # references are handled.
    if @isMethod
      [methodScope, o.scope] = [o.scope, o.scope.parent]
      name = @name.compileToFragments o
      if @name.comments?
        @compileCommentFragments o, @name, name
      name.shift() if name[0].code is '.'
      o.scope = methodScope

    answer = @joinFragmentArrays (@makeCode m for m in modifiers), ' '
    answer.push @makeCode ' ' if modifiers.length and name
    answer.push name... if name
    answer.push signature...
    answer.push @makeCode ' =>' if @bound and not @isMethod
    answer.push @makeCode ' {'
    answer.push @makeCode('\n'), body..., @makeCode("\n#{@tab}") if body?.length
    answer.push @makeCode '}'

    return indentInitial answer, @ if @isMethod
    if @front or (o.level >= LEVEL_ACCESS) then @wrapInParentheses answer else answer

  eachParamName: (iterator) ->
    param.eachName iterator for param in @params

  # Short-circuit `traverseChildren` method to prevent it from crossing scope
  # boundaries unless `crossScope` is `true`.
  traverseChildren: (crossScope, func) ->
    super(crossScope, func) if crossScope

  # Short-circuit `replaceInContext` method to prevent it from crossing context boundaries. Bound
  # functions have the same context.
  replaceInContext: (child, replacement) ->
    if @bound
      super child, replacement
    else
      false

  expandCtorSuper: (thisAssignments) ->
    return false unless @ctor

    @eachSuperCall Block.wrap(@params), (superCall) ->
      superCall.error "'super' is not allowed in constructor parameter defaults"

    seenSuper = @eachSuperCall @body, (superCall) =>
      superCall.error "'super' is only allowed in derived class constructors" if @ctor is 'base'
      superCall.expressions = thisAssignments

    haveThisParam = thisAssignments.length and thisAssignments.length isnt @thisAssignments?.length
    if @ctor is 'derived' and not seenSuper and haveThisParam
      param = thisAssignments[0].variable
      param.error "Can't use @params in derived class constructors without calling super"

    seenSuper

  # Find all super calls in the given context node;
  # returns `true` if `iterator` is called.
  eachSuperCall: (context, iterator) ->
    seenSuper = no

    context.traverseChildren yes, (child) =>
      if child instanceof SuperCall
        # `super` in a constructor (the only `super` without an accessor)
        # cannot be given an argument with a reference to `this`, as that would
        # be referencing `this` before calling `super`.
        unless child.variable.accessor
          childArgs = child.args.filter (arg) ->
            arg not instanceof Class and (arg not instanceof Code or arg.bound)
          Block.wrap(childArgs).traverseChildren yes, (node) =>
            node.error "Can't call super with @params in derived class constructors" if node.this
        seenSuper = yes
        iterator child
      else if child instanceof ThisLiteral and @ctor is 'derived' and not seenSuper
        child.error "Can't reference 'this' before calling super in derived class constructors"

      # `super` has the same target in bound (arrow) functions, so check them too
      child not instanceof SuperCall and (child not instanceof Code or child.bound)

    seenSuper

#### Param

# A parameter in a function definition. Beyond a typical JavaScript parameter,
# these parameters can also attach themselves to the context of the function,
# as well as be a splat, gathering up a group of parameters into an array.
exports.Param = class Param extends Base
  constructor: (@name, @value, @splat) ->
    super()

    message = isUnassignable @name.unwrapAll().value
    @name.error message if message
    if @name instanceof Obj and @name.generated
      token = @name.objects[0].operatorToken
      token.error "unexpected #{token.value}"

  children: ['name', 'value']

  toAst: (o) ->
    @name.toAst o, LEVEL_LIST

  compileToFragments: (o) ->
    @name.compileToFragments o, LEVEL_LIST

  compileToFragmentsWithoutComments: (o) ->
    @name.compileToFragmentsWithoutComments o, LEVEL_LIST

  asReference: (o) ->
    return @reference if @reference
    node = @name
    if node.this
      name = node.properties[0].name.value
      name = "_#{name}" if name in JS_FORBIDDEN
      node = new IdentifierLiteral o.scope.freeVariable name
    else if node.shouldCache()
      node = new IdentifierLiteral o.scope.freeVariable 'arg'
    node = new Value node
    node.updateLocationDataIfMissing @locationData
    @reference = node

  shouldCache: ->
    @name.shouldCache()

  # Iterates the name or names of a `Param`.
  # In a sense, a destructured parameter represents multiple JS parameters. This
  # method allows to iterate them all.
  # The `iterator` function will be called as `iterator(name, node)` where
  # `name` is the name of the parameter and `node` is the AST node corresponding
  # to that name.
  eachName: (iterator, name = @name) ->
    atParam = (obj, originalObj = null) => iterator "@#{obj.properties[0].name.value}", obj, @, originalObj
    # * simple literals `foo`
    return iterator name.value, name, @ if name instanceof Literal
    # * at-params `@foo`
    return atParam name if name instanceof Value
    for obj in name.objects ? []
      # Save original obj.
      nObj = obj
      # * destructured parameter with default value
      if obj instanceof Assign and not obj.context?
        obj = obj.variable
      # * assignments within destructured parameters `{foo:bar}`
      if obj instanceof Assign
        # ... possibly with a default value
        if obj.value instanceof Assign
          obj = obj.value.variable
        else
          obj = obj.value
        @eachName iterator, obj.unwrap()
      # * splats within destructured parameters `[xs...]`
      else if obj instanceof Splat
        node = obj.name.unwrap()
        iterator node.value, node, @
      else if obj instanceof Value
        # * destructured parameters within destructured parameters `[{a}]`
        if obj.isArray() or obj.isObject()
          @eachName iterator, obj.base
        # * at-params within destructured parameters `{@foo}`
        else if obj.this
          atParam obj, nObj
        # * simple destructured parameters {foo}
        else iterator obj.base.value, obj.base, @
      else if obj instanceof Elision
        obj
      else if obj not instanceof Expansion
        obj.error "illegal parameter #{obj.compile()}"
    return

  # Rename a param by replacing the given AST node for a name with a new node.
  # This needs to ensure that the the source for object destructuring does not change.
  renameParam: (node, newNode, {expandAssign = yes} = {}) ->
    isNode      = (candidate) -> candidate is node
    replacement = (node, parent) =>
      if parent instanceof Obj and expandAssign
        key = node
        key = node.properties[0].name if node.this
        # No need to assign a new variable for the destructured variable if the variable isn't reserved.
        # Examples:
        # `({@foo}) ->`  should compile to `({foo}) { this.foo = foo}`
        # `foo = 1; ({@foo}) ->` should compile to `foo = 1; ({foo:foo1}) { this.foo = foo1 }`
        newNode.withLocationData(
          if node.this and key.value is newNode.value
            new Value newNode
          else
            new Assign new Value(key), newNode, context: 'object'
        )
      else
        newNode

    @replaceInContext isNode, replacement

#### Splat

# A splat, either as a parameter to a function, an argument to a call,
# or as part of a destructuring assignment.
exports.Splat = class Splat extends Base
  constructor: (name, {@lhs, @postfix = true} = {}) ->
    super()
    @name = if name.compile then name else new Literal name

  children: ['name']

  shouldCache: -> no

  isAssignable: ->
    return no if @name instanceof Obj or @name instanceof Parens
    @name.isAssignable() and (not @name.isAtomic or @name.isAtomic())

  assigns: (name) ->
    @name.assigns name

  astType: ->
    if @csx
      'JSXSpreadAttribute'
    else if @lhs
      'RestElement'
    else
      'SpreadElement'

  astChildren:
    argument:
      propName: 'name'
      level: LEVEL_OP

  astProps: ->
    {@postfix}

  compileNode: (o) ->
    [@makeCode('...'), @name.compileToFragments(o, LEVEL_OP)...]

  unwrap: -> @name

#### Expansion

# Used to skip values inside an array destructuring (pattern matching) or
# parameter list.
exports.Expansion = class Expansion extends Base

  shouldCache: NO

  astType: 'RestElement'
  emptyAst: yes

  compileNode: (o) ->
    @error 'Expansion must be used inside a destructuring assignment or parameter list'

  asReference: (o) ->
    this

  eachName: (iterator) ->

#### Elision

# Array elision element (for example, [,a, , , b, , c, ,]).
exports.Elision = class Elision extends Base

  isAssignable: YES

  shouldCache: NO

  _toAst: (o) ->
    null

  compileToFragments: (o, level) ->
    fragment = super o, level
    fragment.isElision = yes
    fragment

  compileNode: (o) ->
    [@makeCode ', ']

  asReference: (o) ->
    this

  eachName: (iterator) ->

#### While

# A while loop, the only sort of low-level loop exposed by CoffeeScript. From
# it, all other loops can be manufactured. Useful in cases where you need more
# flexibility or more speed than a comprehension can provide.
exports.While = class While extends Base
  constructor: (@condition, {@invert, @guard, @isLoop} = {}) ->
    super()

  children: ['condition', 'guard', 'body']

  isStatement: YES

  processedCondition: ->
    @_processedCondition ?= if @invert then @condition.invert() else @condition

  makeReturn: (opts) ->
    if opts?.accumulator
      super opts
    else
      @returns = not @jumps()
      if opts?.mark
        @body.makeReturn opts if @returns
      else
        this

  addBody: (@body) ->
    this

  jumps: ->
    {expressions} = @body
    return no unless expressions.length
    for node in expressions
      return jumpNode if jumpNode = node.jumps loop: yes
    no

  astType: 'WhileStatement'

  astChildren:
    test:
      propName: 'condition'
      level: LEVEL_PAREN
    body:
      level: LEVEL_TOP
    guard: 'guard'

  astProps: -> {
    inverted: @invert
    @postfix
    loop: @isLoop
  }

  wrapInResultAccumulatingBlock: ({o, resultsVar, cachedSourceVarAssign, cachedStepVarAssign}) -> (compiled) =>
    return compiled unless @returns or cachedSourceVarAssign or cachedStepVarAssign

    [
      ...(if cachedSourceVarAssign then [
        type: 'ExpressionStatement' # TODO: make this generated?
        expression: cachedSourceVarAssign.compileToBabylon o
      ] else [])
      ...(if cachedStepVarAssign then [
        type: 'ExpressionStatement'
        expression: cachedStepVarAssign.compileToBabylon o
      ] else [])
      ...(if @returns then [
        type: 'ExpressionStatement'
        expression: (@source ? @).withLocationData(new Assign(resultsVar, new Arr())).compileToBabylon o
      ] else [])
      compiled
      ...(if @returns then [
        @withLocationData(new Return(resultsVar)).compileToBabylon o
      ] else [])
    ]

  _compileToBabylon: (o) ->
    if @returns
      resultsVar = new IdentifierLiteral o.scope.freeVariable 'results'
      @body.makeReturn accumulator: resultsVar.value

    @wrapInResultAccumulatingBlock({o, resultsVar}) @withAstType
      test: @processedCondition().compileToBabylon o, LEVEL_PAREN
      body: @bodyWithGuard().compileToBabylon o, LEVEL_TOP

  bodyWithGuard: ->
    return @body unless @guard

    return @guard.withLocationData Block.wrap [new If @guard, @body] unless @body.expressions.length > 1

    @body.expressions.unshift @guard.withLocationData new If (new Parens @guard).invert(), new StatementLiteral "continue"
    @body

  # The main difference from a JavaScript *while* is that the CoffeeScript
  # *while* can be used as a part of a larger expression -- while loops may
  # return an array containing the computed result of each iteration.
  compileNode: (o) ->
    o.indent += TAB
    set      = ''
    body =
      if @body.isEmpty()
        @makeCode ''
      else
        if @returns
          @body.makeReturn accumulator: rvar = o.scope.freeVariable 'results'
          set = "#{@tab}#{rvar} = [];\n"
        [].concat @makeCode("\n"), (@bodyWithGuard().compileToFragments o, LEVEL_TOP), @makeCode("\n#{@tab}")
    answer = [].concat @makeCode(set + @tab + "while ("), @processedCondition().compileToFragments(o, LEVEL_PAREN),
      @makeCode(") {"), body, @makeCode("}")
    if @returns
      answer.push @makeCode "\n#{@tab}return #{rvar};"
    answer

#### Op

# Simple Arithmetic and logical operations. Performs some conversion from
# CoffeeScript operations into their JavaScript equivalents.
exports.Op = class Op extends Base
  constructor: (op, first, second, flip, {@invertOperator, @originalOperator = op} = {}) ->
    super()

    if op is 'new'
      if ((firstCall = unwrapped = first.unwrap()) instanceof Call or (firstCall = unwrapped.base) instanceof Call) and not firstCall.do and not firstCall.isNew
        return new Value firstCall.newInstance(), if firstCall is unwrapped then [] else unwrapped.properties
      first = new Parens first if unwrapped instanceof Op and unwrapped.operator is 'do'

    @operator = CONVERSIONS[op] or op
    @first    = first
    @second   = second
    @flip     = !!flip
    return this

  # The map of conversions from CoffeeScript to JavaScript symbols.
  CONVERSIONS =
    '==':        '==='
    '!=':        '!=='
    'of':        'in'
    'yieldfrom': 'yield*'

  # The map of invertible operators.
  INVERSIONS =
    '!==': '==='
    '===': '!=='

  children: ['first', 'second']

  isNumber: ->
    @isUnary() and @operator in ['+', '-'] and
      @first instanceof Value and @first.isNumber()

  isAwait: ->
    @operator is 'await'

  isYield: ->
    @operator in ['yield', 'yield*']

  isUnary: ->
    not @second

  shouldCache: ->
    not @isNumber()

  # Am I capable of
  # [Python-style comparison chaining](https://docs.python.org/3/reference/expressions.html#not-in)?
  isChainable: ->
    @operator in ['<', '>', '>=', '<=', '===', '!==']

  invert: -> @withLocationData do =>
    if @isInOperator()
      @invertOperator = '!'
      return @
    if @isChainable() and @first.isChainable()
      allInvertable = yes
      curr = this
      while curr and curr.operator
        allInvertable and= (curr.operator of INVERSIONS)
        curr = curr.first
      return new Parens(this).invert() unless allInvertable
      curr = this
      while curr and curr.operator
        curr.invert = !curr.invert
        curr.operator = INVERSIONS[curr.operator]
        curr = curr.first
      this
    else if op = INVERSIONS[@operator]
      @operator = op
      if @first.unwrap() instanceof Op
        @first.invert()
      this
    else if @second
      new Parens(this).invert()
    else if @operator is '!' and (fst = @first.unwrap()) instanceof Op and
                                  fst.operator in ['!', 'in', 'instanceof']
      fst
    else
      new Op '!', this

  unfoldSoak: (o) ->
    @operator in ['++', '--', 'delete'] and unfoldSoak o, this, 'first'

  generateDo: (exp) ->
    passedParams = []
    func = if exp instanceof Assign and (ref = exp.value.unwrap()) instanceof Code
      ref
    else
      exp
    for param in func.params or []
      if param.value
        passedParams.push param.value
        delete param.value
      else
        passedParams.push param
    call = new Call exp, passedParams
    call.do = yes
    call

  isInOperator: ->
    @originalOperator is 'in'

  checkDeleteOperand: (o) ->
    if @operator is 'delete' and o.scope.check(@first.unwrapAll().value)
      @error 'delete operand may not be argument or var'

  checkUpdateAssignability: ->
    if @operator in ['--', '++']
      message = isUnassignable @first.unwrapAll().value
      @first.error message if message

  compileNode: (o) ->
    if @isInOperator()
      inNode = new In @first, @second
      return (if @invertOperator then inNode.invert() else inNode).compileNode o
    if @invertOperator
      @invertOperator = null
      return @invert().compileNode(o)
    return Op::generateDo(@first).compileNode o if @operator is 'do'
    isChain = @isChainable() and @first.isChainable()
    # In chains, there's no need to wrap bare obj literals in parens,
    # as the chained expression is wrapped.
    @first.front = @front unless isChain
    @checkDeleteOperand o
    @checkUpdateAssignability()
    return @compileContinuation o if @isYield() or @isAwait()
    return @compileUnary        o if @isUnary()
    return @compileChain        o if isChain
    switch @operator
      when '?'  then @compileExistence o, @second.isDefaultValue
      when '//' then @compileFloorDivision o
      when '%%' then @compileModulo o
      else
        lhs = @first.compileToFragments o, LEVEL_OP
        rhs = @second.compileToFragments o, LEVEL_OP
        answer = [].concat lhs, @makeCode(" #{@operator} "), rhs
        if o.level <= LEVEL_OP then answer else @wrapInParentheses answer

  astType: ->
    switch @operator
      when 'new'             then 'NewExpression'
      when '||', '&&', '?'   then 'LogicalExpression'
      when '++', '--'        then 'UpdateExpression'
      when 'await'           then 'AwaitExpression'
      when 'yield', 'yield*' then 'YieldExpression'
      else
        if @isUnary()        then 'UnaryExpression'
        else                      'BinaryExpression'

  _toAst: (o) ->
    @checkDeleteOperand o
    @checkUpdateAssignability()
    @checkContinuation o if @isYield() or @isAwait()
    super o

  astChildren: (o) ->
    firstAst = @first.toAst o, LEVEL_OP
    secondAst = @second?.toAst o, LEVEL_OP
    switch
      when @operator is 'new'
        callee: firstAst
        arguments: []
      when @isUnary()
        argument:
          if @isYield() or @isAwait()
            firstAst unless @first.unwrap().value is ''
          else
            firstAst
      else
        left: firstAst
        right: secondAst

  astProps: (o) ->
    operator =
      if o.compiling
        @operator
      else
        "#{if @invertOperator then "#{@invertOperator} " else ''}#{@originalOperator}"
    switch
      when @operator is 'new' or @isAwait()
        {}
      when @isYield()
        delegate: @operator is 'yield*'
      when @isUnary()
        {
          operator
          prefix: !@flip
        }
      else
        {operator}

  _compileToBabylon: (o) ->
    if @originalOperator is 'in'
      inNode = new In @first, @second
      return (if @invertOperator then inNode.invert() else inNode).compileToBabylon o
    if @invertOperator
      @invertOperator = null
      return @invert().compileToBabylon o
    return Op::generateDo(@first).compileToBabylon o if @operator is 'do'
    if @operator is '!' and @first instanceof Existence
      @first.negated = not @first.negated
      return @first.compileToBabylon o
    isChain = @isChainable() and @first.isChainable()
    return super o if @isUnary()
    return @compileChainToBabylon o if isChain

    switch @operator
      when '?'  then return @compileExistenceToBabylon o, @second.isDefaultValue
      when '//' then return @compileFloorDivisionToBabylon o
      when '%%' then return @compileModuloToBabylon o

    # return new Parens(this).compileToBabylon o if o.level > LEVEL_OP

    super o

  compileChainToBabylon: (o) ->
    [@first.second, shared] = @first.second.cache o

    new Op((if @invert then '&&' else '||'),
      @first
      new Op @operator,
        shared
        @second
    ).compileToBabylon o

  # Mimic Python's chained comparisons when multiple comparison operators are
  # used sequentially. For example:
  #
  #     bin/coffee -e 'console.log 50 < 65 > 10'
  #     true
  compileChain: (o) ->
    [@first.second, shared] = @first.second.cache o
    fst = @first.compileToFragments o, LEVEL_OP
    fragments = fst.concat @makeCode(" #{if @invert then '&&' else '||'} "),
      (shared.compileToFragments o), @makeCode(" #{@operator} "), (@second.compileToFragments o, LEVEL_OP)
    @wrapInParentheses fragments

  compileExistenceToBabylon: (o, checkOnlyUndefined) ->
    [cachedFirstAssign, first] = @first.cache o
    @withLocationData(
      new If(
        new Existence cachedFirstAssign, onlyUndefined: checkOnlyUndefined
        first
        type: 'if'
      )
      .addElse(@second)
    ).compileToBabylon o

  # Keep reference to the left expression, unless this an existential assignment
  compileExistence: (o, checkOnlyUndefined) ->
    if @first.shouldCache()
      ref = new IdentifierLiteral o.scope.freeVariable 'ref'
      fst = new Parens new Assign ref, @first
    else
      fst = @first
      ref = fst
    new If(new Existence(fst, onlyUndefined: checkOnlyUndefined), ref, type: 'if').addElse(@second).compileToFragments o

  # Compile a unary **Op**.
  compileUnary: (o) ->
    parts = []
    op = @operator
    parts.push [@makeCode op]
    if op is '!' and @first instanceof Existence
      @first.negated = not @first.negated
      return @first.compileToFragments o
    if o.level >= LEVEL_ACCESS
      return (new Parens this).compileToFragments o
    plusMinus = op in ['+', '-']
    parts.push [@makeCode(' ')] if op in ['new', 'typeof', 'delete'] or
                      plusMinus and @first instanceof Op and @first.operator is op
    if (plusMinus and @first instanceof Op) or (op is 'new' and @first.isStatement o)
      @first = new Parens @first
    parts.push @first.compileToFragments o, LEVEL_OP
    parts.reverse() if @flip
    @joinFragmentArrays parts, ''

  checkContinuation: (o) ->
    unless o.scope.parent?
      @error "#{@operator} can only occur inside functions"
    if o.scope.method?.bound and o.scope.method.isGenerator
      @error 'yield cannot occur inside bound (fat arrow) functions'

  compileContinuation: (o) ->
    parts = []
    op = @operator
    unless o.scope.parent?
      @error "#{@operator} can only occur inside functions"
    if o.scope.method?.bound and o.scope.method.isGenerator
      @error 'yield cannot occur inside bound (fat arrow) functions'
    if 'expression' in Object.keys(@first) and not (@first instanceof Throw)
      parts.push @first.expression.compileToFragments o, LEVEL_OP if @first.expression?
    else
      parts.push [@makeCode "("] if o.level >= LEVEL_PAREN
      parts.push [@makeCode op]
      parts.push [@makeCode " "] if @first.base?.value isnt ''
      parts.push @first.compileToFragments o, LEVEL_OP
      parts.push [@makeCode ")"] if o.level >= LEVEL_PAREN
    @joinFragmentArrays parts, ''

  compileFloorDivision: (o) ->
    @floorDivisionCall(o).compileToFragments o

  floorDivisionCall: (o) ->
    floor = new Value new IdentifierLiteral('Math'), [new Access new PropertyName 'floor']
    second = if @second.shouldCache() then new Parens @second else @second
    div = new Op '/', @first, second
    new Call floor, [div]

  compileFloorDivisionToBabylon: (o) ->
    @floorDivisionCall(o).compileToBabylon o

  compileModulo: (o) ->
    mod = new Value new Literal utility 'modulo', o
    new Call(mod, [@first, @second]).compileToFragments o

  compileModuloToBabylon: (o) ->
    mod = new Value utilityBabylon 'modulo', o
    new Call(mod, [@first, @second]).compileToBabylon o

  toString: (idt) ->
    super idt, @constructor.name + ' ' + @operator

#### In
exports.In = class In extends Base
  constructor: (@object, @array) ->
    super()

  children: ['object', 'array']

  invert: NEGATE

  isNonSplatArray: ->
    return no unless @array instanceof Value and @array.isArray() and @array.base.objects.length
    return no for obj in @array.base.objects when obj instanceof Splat
    yes

  _compileToBabylon: (o) ->
    if @isNonSplatArray()
      @compileOrTestToBabylon o
    else
      @compileLoopTestToBabylon o

  compileNode: (o) ->
    if @isNonSplatArray()
      @compileOrTest o
    else
      @compileLoopTest o

  compileOrTest: (o) ->
    [sub, ref] = @object.cache o, LEVEL_OP
    [cmp, cnj] = if @negated then [' !== ', ' && '] else [' === ', ' || ']
    tests = []
    for item, i in @array.base.objects
      if i then tests.push @makeCode cnj
      tests = tests.concat (if i then ref else sub), @makeCode(cmp), item.compileToFragments(o, LEVEL_ACCESS)
    if o.level < LEVEL_OP then tests else @wrapInParentheses tests

  compileOrTestToBabylon: (o) ->
    {objects: items} = @array.base
    [cachedObjectVarAssign, objectVar] = @object.cache o

    compareOp = if @negated then '!==' else '==='
    joinOp    = if @negated then '&&'  else '||'
    @withAstLocationData (do =>
      ret = null
      for item, index in items
        comparison = new Op compareOp,
          if index is 0 then cachedObjectVarAssign else objectVar
          item
        ret =
          if index is 0
            comparison
          else
            new Op joinOp, ret, comparison
      ret
    ).compileToBabylon o

  compileLoopTestToBabylon: (o) ->
    [cachedObjVarAssign, objVar] = @object.cache o, onlyIfCached: yes

    indexOfCheck = @withLocationData new Op (if @negated then '<' else '>='),
      utilityBabylon 'indexOf', merge o, calledWithArgs: [@array, objVar]
      new NumberLiteral '0'

    (if cachedObjVarAssign
      new Sequence [cachedObjVarAssign, indexOfCheck]
    else
      indexOfCheck
    ).compileToBabylon o

  compileLoopTest: (o) ->
    [sub, ref] = @object.cache o, LEVEL_LIST
    fragments = [].concat @makeCode(utility('indexOf', o) + ".call("), @array.compileToFragments(o, LEVEL_LIST),
      @makeCode(", "), ref, @makeCode(") " + if @negated then '< 0' else '>= 0')
    return fragments if fragmentsToText(sub) is fragmentsToText(ref)
    fragments = sub.concat @makeCode(', '), fragments
    if o.level < LEVEL_LIST then fragments else @wrapInParentheses fragments

  toString: (idt) ->
    super idt, @constructor.name + if @negated then '!' else ''

#### Try

# A classic *try/catch/finally* block.
exports.Try = class Try extends Base
  constructor: (@attempt, @errorVariable, @recovery, @ensure) ->
    super()
    @errorVariable?.unwrap().propagateLhs? yes

  children: ['attempt', 'recovery', 'ensure']

  isStatement: YES

  jumps: (o) -> @attempt.jumps(o) or @recovery?.jumps(o)

  makeReturn: (opts) ->
    if opts?.mark
      @attempt?.makeReturn opts
      @recovery?.makeReturn opts
      return
    @attempt  = @attempt .makeReturn opts if @attempt
    @recovery = @recovery.makeReturn opts if @recovery
    this

  astType: 'TryStatement'
  _toAst: (o) ->
    {compiling} = o
    if (@recovery or not @ensure) and compiling
      placeholder = new IdentifierLiteral(o.scope.freeVariable 'error', reserve: no).withEmptyLocationData()
      @recovery.unshift @recovery.withLocationData new Assign @errorVariable, placeholder if @errorVariable

    unless compiling
      @errorVariable?.eachName (name) ->
        alreadyDeclared = o.scope.find name.value
        name.isDeclaration = not alreadyDeclared

    block: @attempt.toAst o, LEVEL_TOP
    handler:
      if compiling
        (@recovery or @).withAstLocationData {
          type: 'CatchClause'
          param: placeholder.compileToBabylon o
          body: (@recovery or @withLocationData new Block).compileToBabylon o, LEVEL_TOP
        } if placeholder
      else if @recovery
        @recovery.withAstLocationData {
          type: 'CatchClause'
          param: @errorVariable?.toAst(o) ? null
          body: @recovery.toAst o, LEVEL_TOP
        }
    finalizer: @ensure?.toAst o, LEVEL_TOP

  # Compilation is more or less as you would expect -- the *finally* clause
  # is optional, the *catch* is not.
  compileNode: (o) ->
    o.indent  += TAB
    tryPart   = @attempt.compileToFragments o, LEVEL_TOP

    catchPart = if @recovery
      generatedErrorVariableName = o.scope.freeVariable 'error', reserve: no
      placeholder = new IdentifierLiteral generatedErrorVariableName
      if @errorVariable
        message = isUnassignable @errorVariable.unwrapAll().value
        @errorVariable.error message if message
        @recovery.unshift new Assign @errorVariable, placeholder
      [].concat @makeCode(" catch ("), placeholder.compileToFragments(o), @makeCode(") {\n"),
        @recovery.compileToFragments(o, LEVEL_TOP), @makeCode("\n#{@tab}}")
    else unless @ensure
      generatedErrorVariableName = o.scope.freeVariable 'error', reserve: no
      [@makeCode(" catch (#{generatedErrorVariableName}) {}")]
    else
      []

    ensurePart = if @ensure then ([].concat @makeCode(" finally {\n"), @ensure.compileToFragments(o, LEVEL_TOP),
      @makeCode("\n#{@tab}}")) else []

    [].concat @makeCode("#{@tab}try {\n"),
      tryPart,
      @makeCode("\n#{@tab}}"), catchPart, ensurePart

#### Throw

# Simple node to throw an exception.
exports.Throw = class Throw extends Base
  constructor: (@expression) ->
    super()

  children: ['expression']

  isStatement: YES
  jumps:       NO

  # A **Throw** is already a return, of sorts...
  makeReturn: THIS

  astType: 'ThrowStatement'
  astChildren:
    argument:
      propName: 'expression'
      level: LEVEL_LIST

  compileNode: (o) ->
    fragments = @expression.compileToFragments o, LEVEL_LIST
    unshiftAfterComments fragments, @makeCode 'throw '
    fragments.unshift @makeCode @tab
    fragments.push @makeCode ';'
    fragments

#### Existence

# Checks a variable for existence -- not `null` and not `undefined`. This is
# similar to `.nil?` in Ruby, and avoids having to consult a JavaScript truth
# table. Optionally only check if a variable is not `undefined`.
exports.Existence = class Existence extends Base
  constructor: (@expression, {onlyNotUndefined = no, @operatorToken} = {}) ->
    super()
    @comparisonTarget = if onlyNotUndefined then 'undefined' else 'null'
    salvagedComments = []
    @expression.traverseChildren yes, (child) ->
      if child.comments
        for comment in child.comments
          salvagedComments.push comment unless comment in salvagedComments
        delete child.comments
    attachCommentsToNode salvagedComments, @
    moveComments @expression, @

  children: ['expression']

  invert: NEGATE

  astChildren:
    argument: 'expression'

  _compileToBabylon: (o) ->
    compareOp = if @negated then '===' else '!=='
    joinOp    = if @negated then '||' else '&&'
    comparison =
      if @expression.unwrap() instanceof IdentifierLiteral and not o.scope.check @expression.unwrap().value
        do =>
          comparisonAgainstUndefined =
            @withLocationData new Op(
              compareOp
              new Op 'typeof', @expression
              new StringLiteral 'undefined'
              .withLocationDataFrom @operatorToken ? @
            )
          return comparisonAgainstUndefined if @comparisonTarget is 'undefined'

          @withLocationData new Op(
            joinOp
            comparisonAgainstUndefined
            new Op(
              compareOp
              @expression
              new NullLiteral
            )
          )
      else
        op = new Op(
          compareOp
          @expression
          if @comparisonTarget is 'null'
            new NullLiteral
          else
            new UndefinedLiteral
        )
        if @comparisonTarget is 'null'
          op.operator = if @negated then '==' else '!='
        op

    @withLocationData(
      @wrapInParensIf(o.level <= LEVEL_COND) comparison
    ).compileToBabylon o

  compileNode: (o) ->
    @expression.front = @front
    code = @expression.compile o, LEVEL_OP
    if @expression.unwrap() instanceof IdentifierLiteral and not o.scope.check code
      [cmp, cnj] = if @negated then ['===', '||'] else ['!==', '&&']
      code = "typeof #{code} #{cmp} \"undefined\"" + if @comparisonTarget isnt 'undefined' then " #{cnj} #{code} #{cmp} #{@comparisonTarget}" else ''
    else
      # We explicity want to use loose equality (`==`) when comparing against `null`,
      # so that an existence check roughly corresponds to a check for truthiness.
      # Do *not* change this to `===` for `null`, as this will break mountains of
      # existing code. When comparing only against `undefined`, however, we want to
      # use `===` because this use case is for parity with ES2015+ default values,
      # which only get assigned when the variable is `undefined` (but not `null`).
      cmp = if @comparisonTarget is 'null'
        if @negated then '==' else '!='
      else # `undefined`
        if @negated then '===' else '!=='
      code = "#{code} #{cmp} #{@comparisonTarget}"
    [@makeCode(if o.level <= LEVEL_COND then code else "(#{code})")]

#### Parens

# An extra set of parentheses, specified explicitly in the source. At one time
# we tried to clean up the results by detecting and removing redundant
# parentheses, but no longer -- you can put in as many as you please.
#
# Parentheses are a good way to force any statement to become an expression.
exports.Parens = class Parens extends Base
  constructor: (@body) ->
    super()

  children: ['body']

  unwrap: -> @body

  shouldCache: -> @body.shouldCache()

  _compileToBabylon: (o) ->
    expr = @body.unwrap()
    compiled = expr.compileToBabylon o, LEVEL_PAREN
    shouldntWrap =
      expr instanceof Op or expr.unwrap() instanceof Call or
      (expr instanceof For and expr.returns)
    return compiled if shouldntWrap or not compiled or Array.isArray compiled
    {
      ...compiled
      extra: {
        ...(compiled.extra ? {})
        parenthesized: yes
      }
    }

  compileNode: (o) ->
    expr = @body.unwrap()
    # If these parentheses are wrapping an `IdentifierLiteral` followed by a
    # block comment, output the parentheses (or put another way, don’t optimize
    # away these redundant parentheses). This is because Flow requires
    # parentheses in certain circumstances to distinguish identifiers followed
    # by comment-based type annotations from JavaScript labels.
    shouldWrapComment = expr.comments?.some(
      (comment) -> comment.here and not comment.unshift and not comment.newLine)
    if expr instanceof Value and expr.isAtomic() and not @csxAttribute and not shouldWrapComment
      expr.front = @front
      return expr.compileToFragments o
    fragments = expr.compileToFragments o, LEVEL_PAREN
    bare = o.level < LEVEL_OP and not shouldWrapComment and (
        expr instanceof Op and not expr.isInOperator() or expr.unwrap() instanceof Call or
        (expr instanceof For and expr.returns)
      ) and (o.level < LEVEL_COND or fragments.length <= 3)
    return @wrapInCommentBoundingBraces fragments if @csxAttribute
    if bare then fragments else @wrapInParentheses fragments

  _toAst: (o) ->
    @body.unwrap().toAst o, LEVEL_PAREN

#### StringWithInterpolations

exports.StringWithInterpolations = class StringWithInterpolations extends Base
  constructor: (@body, {@quote, @startQuote, @endQuote} = {}) ->
    super()

  @fromStringLiteral: (stringLiteral) ->
    new StringWithInterpolations Block.wrap([ new Value stringLiteral ]), quote: stringLiteral.quote
    .withLocationDataFrom stringLiteral

  children: ['body']

  # `unwrap` returns `this` to stop ancestor nodes reaching in to grab @body,
  # and using @body.compileNode. `StringWithInterpolations.compileNode` is
  # _the_ custom logic to output interpolated strings as code.
  unwrap: -> this

  shouldCache: -> @body.shouldCache()

  extractElements: (o) ->
    # Assumes that `expr` is `Block`
    expr = @body.unwrap()

    elements = []
    salvagedComments = []
    expr.traverseChildren no, (node) =>
      if node instanceof StringLiteral
        if node.comments
          salvagedComments.push node.comments...
          delete node.comments
        elements.push node
        return yes
      else if node instanceof Interpolation
        isEmpty = (unwrapped = node.expression?.unwrapAll()) instanceof PassthroughLiteral and unwrapped.generated
        if salvagedComments.length isnt 0
          for comment in salvagedComments
            comment.unshift = yes
            comment.newLine = yes
          attachCommentsToNode salvagedComments, node
        if isEmpty and not @csx
          commentPlaceholder = new StringLiteral('').withLocationDataFrom node
          commentPlaceholder.comments = unwrapped.comments
          (commentPlaceholder.comments ?= []).push node.comments... if node.comments
          elements.push new Value commentPlaceholder
        else if isEmpty and not o.compiling
          empty = new Interpolation().withLocationDataFrom node
          empty.comments = node.comments
          elements.push empty
        else if node.expression
          (node.expression.comments ?= []).push node.comments... if node.comments
          node.expression.locationData = node.locationData
          elements.push node.expression
        else if not o.compiling
          elements.push node
        return no
      else if node.comments
        # This node is getting discarded, but salvage its comments.
        if elements.length isnt 0 and elements[elements.length - 1] not instanceof StringLiteral
          for comment in node.comments
            comment.unshift = no
            comment.newLine = yes
          attachCommentsToNode node.comments, elements[elements.length - 1]
        else
          salvagedComments.push node.comments...
        delete node.comments
      return yes

    elements

  astType: 'TemplateLiteral'
  astChildren: (o) ->
    elements = @extractElements o
    [first] = elements
    elements.unshift (@startQuote ? @).withLocationData new StringLiteral '' unless first instanceof StringLiteral
    [..., last] = elements
    elements.push (last = (@endQuote ? @).withLocationData new StringLiteral '') unless last instanceof StringLiteral

    quasis = []
    expressions = []
    justSawInterpolation = no
    lastElement = null
    for element, index in elements
      if element instanceof StringLiteral
        @prepareElementValue(element)# if o.compilingBabylon
        quasis.push element.withAstLocationData merge
          type: 'TemplateElement'
          value:
            raw:
              if o.compiling
                element.value
              else
                element.originalValue
            tail: element is last
        ,
          if element.heregex
            pattern: element.heregexPattern
          else
            {}
        justSawInterpolation = no
      else
        if justSawInterpolation
          quasis.push lastElement.withAstLocationData
            type: 'TemplateElement'
            value:
              raw: ''
              tail: no
        expressions.push astAsBlock element, o
        lastElement = element
        justSawInterpolation = yes

    {expressions, quasis, @quote}

  _toAst: (o) ->
    return @CSXContentToAst o if @csx
    super o

  CSXContentToAst: (o) ->
    elements = @extractElements o

    for element in elements
      element.csx = yes
      compiled = astAsBlock element, o
      hasComment = do ->
        hasComment = no
        element.traverseChildren no, ({comments, csxAttribute}) ->
          return no if csxAttribute
          if comments
            hasComment = yes
            no
        hasComment
      if element instanceof StringLiteral
        compiled unless element.isEmpty()
      else if compiled.type in ['JSXElement', 'JSXFragment'] and not hasComment
        compiled
      else
        element.withAstLocationData
          type: 'JSXExpressionContainer'
          expression: do ->
            compiled.type ?= 'JSXEmptyExpression'
            compiled

  prepareElementValue: (element) ->
    element.value = element.unquote yes, @csx
    unless @csx
      # Backticks and `${` inside template literals must be escaped.
      element.value = element.value.replace /(\\*)(`|\$\{)/g, (match, backslashes, toBeEscaped) ->
        if backslashes.length % 2 is 0
          "#{backslashes}\\#{toBeEscaped}"
        else
          match

  compileNode: (o) ->
    if @csxAttribute
      wrapped = new Parens new StringWithInterpolations @body
      wrapped.csxAttribute = yes
      return wrapped.compileNode o

    elements = @extractElements o

    fragments = []
    fragments.push @makeCode '`' unless @csx
    for element in elements
      if element instanceof StringLiteral
        @prepareElementValue(element)
        fragments.push element.compileToFragments(o)...
      else
        fragments.push @makeCode '$' unless @csx
        code = element.compileToFragments(o, LEVEL_PAREN)
        if not @isNestedTag(element) or code.some(do ->
          insideCommentBoundary = 0
          ({comments, isCommentBoundary}) ->
            insideCommentBoundary -= 1 if isCommentBoundary is 'end'
            return yes if comments?.length and not insideCommentBoundary
            insideCommentBoundary += 1 if isCommentBoundary is 'start'
            no
        )
          code = @wrapInCommentBoundingBraces code
        fragments.push code...
    fragments.push @makeCode '`' unless @csx
    fragments

  isNestedTag: (element) ->
    call = element.unwrapAll?()
    @csx and call instanceof Call and call.csx

exports.Interpolation = class Interpolation extends Base
  constructor: (@expression) ->
    super()

  astType: ->
    if @csx
      'JSXEmptyExpression'
    else
      'EmptyInterpolation'
  astChildren: []
  emptyAst: yes

  _toAst: (o) ->
    @error 'Interpolation::toAst() should only be called for empty interpolations' if @expression
    super o

  children: ['expression']

#### For

# CoffeeScript's replacement for the *for* loop is our array and object
# comprehensions, that compile into *for* loops here. They also act as an
# expression, able to return the result of each filtered iteration.
#
# Unlike Python array comprehensions, they can be multi-line, and you can pass
# the current index of the loop as a second parameter. Unlike Ruby blocks,
# you can map and filter in a single pass.
exports.For = class For extends While
  constructor: (body, source) ->
    super()
    @addBody body
    @addSource source

  children: ['body', 'source', 'guard', 'step']

  isAwait: -> @await ? no

  addBody: (body) ->
    @body = Block.wrap [body]
    this

  addSource: (source) ->
    {@source  = no} = source
    attribs   = ["name", "index", "guard", "step", "own", "ownTag", "await", "awaitTag", "object", "from", "accumulateIndex"]
    @[attr]   = source[attr] ? @[attr] for attr in attribs
    return this unless @source
    @index.error 'cannot use index with for-from' if @from and @index
    @ownTag.error "cannot use own with for-#{if @from then 'from' else 'in'}" if @own and not @object
    [@name, @index] = [@index, @name] if @object
    @index.error 'index cannot be a pattern matching expression' if @index?.isArray?() or @index?.isObject?()
    @awaitTag.error 'await must be used with for-from' if @await and not @from
    @range   = @source instanceof Value and @source.base instanceof Range and not @source.properties.length and not @from
    @pattern = @name instanceof Value
    @name.unwrap().propagateLhs? yes if @pattern
    @index.error 'indexes do not apply to range loops' if @range and @index
    @name.error 'cannot pattern match over range loops' if @range and @pattern
    @returns = no

    @hoistComments()

  # Move up any comments in the “`for` line”, i.e. the line of code with `for`,
  # from any child nodes of that line up to the `for` node itself so that these
  # comments get output, and get output above the `for` loop.
  hoistComments: ->
    for attribute in ['source', 'guard', 'step', 'name', 'index'] when @[attribute]
      @[attribute].traverseChildren yes, (node) =>
        if node.comments
          # These comments are buried pretty deeply, so if they happen to be
          # trailing comments the line they trail will be unrecognizable when
          # we’re done compiling this `for` loop; so just shift them up to
          # output above the `for` line.
          comment.newLine = comment.unshift = yes for comment in node.comments
          moveComments node, @[attribute]
      moveComments @[attribute], @
    this

  astType: 'For'

  _toAst: (o) ->
    addToScope = (name) ->
      # TODO: should check assignability etc like in addScopeVariables()?
      alreadyDeclared = o.scope.find name.value
      name.isDeclaration = not alreadyDeclared
    @name?.eachName addToScope, checkAssignability: no
    @index?.eachName addToScope, checkAssignability: no
    super o

  astChildren: (o) ->
    source: @source?.toAst o
    body:
      if @postfix
        @body.unwrap().toAst o
      else
        @body.toAst o, LEVEL_TOP
    guard: @guard?.toAst o
    name: @name?.toAst o
    index: @index?.toAst o
    step: @step?.toAst o

  astProps: -> {
    @postfix, @own, @await
    style: switch
      when @from then 'from'
      when @object then 'of'
      when @name then 'in'
  }

  compileBodyToBabylon: (o) ->
    @body.compileToBabylon o, LEVEL_TOP

  compileObjectToBabylon: ({o, sourceVar, keyVar, resultsVar, cachedSourceVarAssign}) ->
    if @own
      @body.expressions.unshift @ownTag.withLocationData new If(
        new Op '!',
          utilityBabylon 'hasProp', merge o, calledWithArgs: [sourceVar, keyVar]
        new StatementLiteral 'continue'
      )
    @wrapInResultAccumulatingBlock({o, resultsVar, cachedSourceVarAssign})
      type: 'ForInStatement'
      left: keyVar.compileToBabylon o
      right: sourceVar.compileToBabylon o
      body: @compileBodyToBabylon o

  compileFromToBabylon: ({o, sourceVar, keyVar, resultsVar, cachedSourceVarAssign}) ->
    @wrapInResultAccumulatingBlock({o, resultsVar, cachedSourceVarAssign}) {
      type: 'ForOfStatement'
      left: keyVar.compileToBabylon o
      right: sourceVar.compileToBabylon o
      body: @compileBodyToBabylon o
      @await
    }

  _compileToBabylon: (o) ->
    {scope} = o
    sourceVar = if @range then @source.base else @source
    name = @name unless @pattern
    scope.find(name.value) if name
    index = @index
    scope.find(index.value) if index and @index not instanceof Value
    indexVar =
      if @from
        new IdentifierLiteral scope.freeVariable 'x', single: true if @pattern
      else
        @object and index or (name or @).withLocationData new IdentifierLiteral scope.freeVariable 'i', single: true
    name = indexVar if @pattern
    keyVar = ((@range or @from) and name) or index or indexVar

    @updateReturnsBasedOnLastBodyExpression()

    @body.expressions.push indexVar if @accumulateIndex

    if @returns
      resultsVar = @withLocationData new IdentifierLiteral(scope.freeVariable 'results')
      @body.makeReturn accumulator: resultsVar.value

    @body = @bodyWithGuard()

    unless @range
      [cachedSourceVarAssign, sourceVar] = sourceVar.cache o, shouldCache: (source) =>
        (name or @own) and source.unwrap() not instanceof IdentifierLiteral
      cachedSourceVarAssign = null unless cachedSourceVarAssign isnt sourceVar

      @body.expressions.unshift @withLocationData new Assign(
        if @pattern
          @name
        else
          name
        new Value(
          name.withLocationData new IdentifierLiteral sourceVar.unwrap().value
          [new Index keyVar]
        )
      ) if name and not @from

    if @pattern and @from
      @body.expressions.unshift @withLocationData new Assign(
        @name
        keyVar
      )

    return @compileObjectToBabylon {o, keyVar, sourceVar, resultsVar, cachedSourceVarAssign} if @object
    return @compileFromToBabylon {o, keyVar, sourceVar, resultsVar, cachedSourceVarAssign} if @from

    if @step and not @range
      [cachedStepVarAssign, stepVar] = @step.cache o, shouldCache: shouldCacheOrIsAssignable, onlyIfCached: yes

    @wrapInResultAccumulatingBlock({o, resultsVar, cachedSourceVarAssign, cachedStepVarAssign}) {
      type: 'ForStatement'
      ...(
        if @range
          @withoutBabylonLocationData @source.base.compileToBabylon merge o, {indexVar, keyVar, @step, shouldCache: shouldCacheOrIsAssignable}
        else
          @compileForPartsToBabylon {o, keyVar, indexVar, sourceVar, stepVar}
      )
      body: @compileBodyToBabylon o
    }

  compileForPartsToBabylon: ({o, keyVar, indexVar, sourceVar, stepVar}) ->
    stepNum = getNumberValue @step if @step?.isNumber()
    down = stepNum? and stepNum < 0
    lengthVar = sourceVar.withLocationData new IdentifierLiteral(o.scope.freeVariable 'len') unless down

    shouldWrapInAssignToKeyVar = keyVar isnt indexVar
    wrapInAssignToKeyVar = do ->
      return ((x) -> x) unless keyVar isnt indexVar

      (x) -> new Assign keyVar, x

    sourceLength = new Value(
      @withLocationData new IdentifierLiteral sourceVar.unwrap().value
      [new Access new PropertyName 'length']
    )

    normalInit =
      new Sequence [
        wrapInAssignToKeyVar(
          new Assign indexVar, new NumberLiteral '0')
        new Assign lengthVar, sourceLength
      ]
    downInit = wrapInAssignToKeyVar(
      new Assign indexVar,
        new Op '-', sourceLength, new NumberLiteral '1')

    normalTest = new Op '<',  indexVar, lengthVar
    downTest   = new Op '>=', indexVar, new NumberLiteral '0'

    init:
      indexVar.withLocationData(
        if down
          downInit
        else if @step and not stepNum?
          new If(
            new Op '>', stepVar, new NumberLiteral '0'
            normalInit
          ).addElse downInit
        else
          normalInit
      ).compileToBabylon o, LEVEL_PAREN
    test:
      @withLocationData(
        if down
          downTest
        else if @step and not stepNum?
          new If(
            new Op '>', stepVar, new NumberLiteral '0'
            normalTest
          ).addElse downTest
        else
          normalTest
      ).compileToBabylon o, LEVEL_PAREN
    update:
      @withLocationData(
        wrapInAssignToKeyVar(
          if @step
            new Op '+=', indexVar, stepVar
          else
            new Op '++', indexVar, null, !shouldWrapInAssignToKeyVar
        )
      ).compileToBabylon o, LEVEL_PAREN

  updateReturnsBasedOnLastBodyExpression: ->
    [..., last] = @body.expressions
    @returns    = no if last?.jumps() instanceof Return

  # Welcome to the hairiest method in all of CoffeeScript. Handles the inner
  # loop, filtering, stepping, and result saving for array, object, and range
  # comprehensions. Some of the generated code can be shared in common, and
  # some cannot.
  compileNode: (o) ->
    @updateReturnsBasedOnLastBodyExpression()
    body        = @body
    source      = if @range then @source.base else @source
    scope       = o.scope
    name        = @name  and (@name.compile o, LEVEL_LIST) if not @pattern
    index       = @index and (@index.compile o, LEVEL_LIST)
    scope.find(name)  if name
    scope.find(index) if index and @index not instanceof Value
    rvar        = scope.freeVariable 'results' if @returns
    if @from
      ivar = scope.freeVariable 'x', single: true if @pattern
    else
      ivar = (@object and index) or scope.freeVariable 'i', single: true
    kvar        = ((@range or @from) and name) or index or ivar
    kvarAssign  = if kvar isnt ivar then "#{kvar} = " else ""
    if @step and not @range
      [step, stepVar] = @cacheToCodeFragments @step.cache o, LEVEL_LIST, shouldCache: shouldCacheOrIsAssignable
      stepNum   = Number stepVar if @step.isNumber()
    name        = ivar if @pattern
    varPart     = ''
    guardPart   = ''
    defPart     = ''
    idt1        = @tab + TAB
    if @range
      forPartFragments = source.compileToFragments merge o,
        {index: ivar, name, @step, shouldCache: shouldCacheOrIsAssignable}
    else
      svar    = @source.compile o, LEVEL_LIST
      if (name or @own) and @source.unwrap() not instanceof IdentifierLiteral
        defPart    += "#{@tab}#{ref = scope.freeVariable 'ref'} = #{svar};\n"
        svar       = ref
      if name and not @pattern and not @from
        namePart   = "#{name} = #{svar}[#{kvar}]"
      if not @object and not @from
        defPart += "#{@tab}#{step};\n" if step isnt stepVar
        down = stepNum < 0
        lvar = scope.freeVariable 'len' unless @step and stepNum? and down
        declare = "#{kvarAssign}#{ivar} = 0, #{lvar} = #{svar}.length"
        declareDown = "#{kvarAssign}#{ivar} = #{svar}.length - 1"
        compare = "#{ivar} < #{lvar}"
        compareDown = "#{ivar} >= 0"
        if @step
          if stepNum?
            if down
              compare = compareDown
              declare = declareDown
          else
            compare = "#{stepVar} > 0 ? #{compare} : #{compareDown}"
            declare = "(#{stepVar} > 0 ? (#{declare}) : #{declareDown})"
          increment = "#{ivar} += #{stepVar}"
        else
          increment = "#{if kvar isnt ivar then "++#{ivar}" else "#{ivar}++"}"
        forPartFragments = [@makeCode("#{declare}; #{compare}; #{kvarAssign}#{increment}")]
    if @returns
      resultPart   = "#{@tab}#{rvar} = [];\n"
      returnResult = "\n#{@tab}return #{rvar};"
      body.makeReturn accumulator: rvar
    body = @bodyWithGuard()
    if @pattern
      body.expressions.unshift new Assign @name, if @from then new IdentifierLiteral kvar else new Literal "#{svar}[#{kvar}]"

    varPart = "\n#{idt1}#{namePart};" if namePart
    if @object
      forPartFragments = [@makeCode("#{kvar} in #{svar}")]
      guardPart = "\n#{idt1}if (!#{utility 'hasProp', o}.call(#{svar}, #{kvar})) continue;" if @own
    else if @from
      if @await
        forPartFragments = new Op 'await', new Parens new Literal "#{kvar} of #{svar}"
        forPartFragments = forPartFragments.compileToFragments o, LEVEL_TOP
      else
        forPartFragments = [@makeCode("#{kvar} of #{svar}")]
    bodyFragments = body.compileToFragments merge(o, indent: idt1), LEVEL_TOP
    if bodyFragments and bodyFragments.length > 0
      bodyFragments = [].concat @makeCode('\n'), bodyFragments, @makeCode('\n')

    fragments = [@makeCode(defPart)]
    fragments.push @makeCode(resultPart) if resultPart
    forCode = if @await then 'for ' else 'for ('
    forClose = if @await then '' else ')'
    fragments = fragments.concat @makeCode(@tab), @makeCode( forCode),
      forPartFragments, @makeCode("#{forClose} {#{guardPart}#{varPart}"), bodyFragments,
      @makeCode(@tab), @makeCode('}')
    fragments.push @makeCode(returnResult) if returnResult
    fragments

exports.Sequence = class Sequence extends Base
  children: ['expressions']

  constructor: (@expressions) ->
    super()

  astType: 'SequenceExpression'

  _toAst: (o) ->
    return @expressions[0].toAst o if @expressions.length is 1
    super o

#### Switch

# A JavaScript *switch* statement. Converts into a returnable expression on-demand.
exports.Switch = class Switch extends Base
  constructor: (@subject, @cases, @otherwise) ->
    super()

  children: ['subject', 'cases', 'otherwise']

  isStatement: YES

  jumps: (o = {block: yes}) ->
    for [conds, block] in @cases
      return jumpNode if jumpNode = block.jumps o
    @otherwise?.jumps o

  makeReturn: (opts) ->
    pair[1].makeReturn opts for pair in @cases
    @otherwise or= new Block [new UndefinedLiteral] if opts?.accumulator
    @otherwise?.makeReturn opts
    this

  astType: 'SwitchStatement'
  astChildren: (o) ->
    {compiling} = o
    lastCaseIndex = @cases.length - 1
    discriminant: (@subject ? if compiling then new BooleanLiteral 'false' else null)?.toAst o, LEVEL_PAREN
    cases: [
      ...flatten(
        for kase, caseIndex in @cases
          [tests, consequent] = kase
          tests = flatten [tests]
          lastTestIndex = tests.length - 1
          for test, testIndex in tests
            compiledCase = test.withAstLocationData(do =>
              consequent.expressions.push new StatementLiteral 'break' if do =>
                return no unless compiling
                return no if caseIndex is lastCaseIndex and not @otherwise
                lastExpr = @lastNode consequent.expressions
                return no if lastExpr instanceof Return
                return no if lastExpr instanceof Throw
                return no if lastExpr instanceof Literal and lastExpr.jumps() and lastExpr.value isnt 'debugger'
                yes

              type: 'SwitchCase'
              test: (if @subject or not compiling then test else test.invert()).toAst o, LEVEL_PAREN
              consequent:
                if testIndex is lastTestIndex
                  consequent.toAst(o, LEVEL_TOP).body
                else []
              trailing: testIndex is lastTestIndex
            )
            mergeAstLocationData compiledCase, compiledCase.consequent[compiledCase.consequent.length - 1] if compiledCase.consequent.length
            compiledCase
      )
      ...(
        if @otherwise?.expressions.length then [
          @otherwise.withAstLocationData
            type: 'SwitchCase'
            test: null
            consequent: @otherwise.toAst(o, LEVEL_TOP).body
        ] else [])
    ]

  compileNode: (o) ->
    idt1 = o.indent + TAB
    idt2 = o.indent = idt1 + TAB
    fragments = [].concat @makeCode(@tab + "switch ("),
      (if @subject then @subject.compileToFragments(o, LEVEL_PAREN) else @makeCode "false"),
      @makeCode(") {\n")
    for [conditions, block], i in @cases
      for cond in flatten [conditions]
        cond  = cond.invert() unless @subject
        fragments = fragments.concat @makeCode(idt1 + "case "), cond.compileToFragments(o, LEVEL_PAREN), @makeCode(":\n")
      fragments = fragments.concat body, @makeCode('\n') if (body = block.compileToFragments o, LEVEL_TOP).length > 0
      break if i is @cases.length - 1 and not @otherwise
      expr = @lastNode block.expressions
      continue if expr instanceof Return or expr instanceof Throw or (expr instanceof Literal and expr.jumps() and expr.value isnt 'debugger')
      fragments.push cond.makeCode(idt2 + 'break;\n')
    if @otherwise and @otherwise.expressions.length
      fragments.push @makeCode(idt1 + "default:\n"), (@otherwise.compileToFragments o, LEVEL_TOP)..., @makeCode("\n")
    fragments.push @makeCode @tab + '}'
    fragments

#### If

# *If/else* statements. Acts as an expression by pushing down requested returns
# to the last line of each clause.
#
# Single-expression **Ifs** are compiled into conditional operators if possible,
# because ternaries are already proper expressions, and don’t need conversion.
exports.If = class If extends Base
  constructor: (@condition, @body, options = {}) ->
    super()
    @elseBody  = null
    @isChain   = false
    {@soak, @type, statement: @postfix} = options
    moveComments @condition, @ if @condition.comments

  children: ['condition', 'body', 'elseBody']

  bodyNode:     -> @body?.unwrap()
  elseBodyNode: -> @elseBody?.unwrap()

  processedCondition: ->
    @_processedCondition ?= if @type is 'unless' then @condition.invert() else @condition

  # Rewrite a chain of **Ifs** to add a default case as the final *else*.
  addElse: (elseBody) ->
    if @isChain
      @elseBodyNode().addElse elseBody
      @mergeLocationDataFrom @elseBodyNode()
    else
      @isChain  = elseBody instanceof If
      @elseBody = @ensureBlock elseBody
      @mergeLocationDataFrom @elseBody if @elseBody.locationData and @locationData
    this

  # The **If** only compiles into a statement if either of its bodies needs
  # to be a statement. Otherwise a conditional operator is safe.
  isStatement: (o) ->
    unless o.compiling
      return no if @postfix
      return yes if o?.level is LEVEL_TOP
      return @bodyNode() instanceof Block or @elseBodyNode() instanceof Block
    o?.level is LEVEL_TOP or
      @bodyNode().isStatement(o) or @elseBodyNode()?.isStatement(o)

  jumps: (o) -> @body.jumps(o) or @elseBody?.jumps(o)

  compileNode: (o) ->
    if @isStatement o then @compileStatement o else @compileExpression o

  astType: (o) ->
    if @isStatement o
      'IfStatement'
    else
      'ConditionalExpression'

  _toAst: (o) -> if @isStatement o then @statementToAst o else @expressionToAst o

  astFields: (o) ->
    return {} if o.compiling
    {
      @postfix
      inverted: @type is 'unless'
    }

  useCondition: (o) ->
    if o.compiling then @processedCondition() else @condition

  statementToAst: (o) ->
    {compiling} = o
    exeq = del o, 'isExistentialEquals'
    if exeq
      return new If(@processedCondition().invert(), @elseBodyNode(), type: 'if').toAst o

    {
      test: @useCondition(o).toAst o, LEVEL_PAREN
      consequent: @ensureBlock(@body).toAst o, LEVEL_TOP
      alternate: do =>
        return unless @elseBody
        compiled = @elseBody.toAst o, LEVEL_TOP
        if compiled.type is 'BlockStatement' and compiled.body.length is 1 and compiled.body[0].type is 'IfStatement'
          compiled.body[0]
        else
          compiled
      ...@astFields o
    }

  expressionToAst: (o) -> {
    test: @useCondition(o).toAst o, LEVEL_COND
    consequent: @bodyNode().toAst o, if o.compiling then LEVEL_LIST else LEVEL_TOP
    alternate:
      if @elseBodyNode()
        @elseBodyNode().toAst o, if o.compiling then LEVEL_LIST else LEVEL_TOP
      else if o.compiling
        new UndefinedLiteral().toAst o
    ...@astFields o
  }

  makeReturn: (opts) ->
    if opts?.mark
      @body?.makeReturn opts
      @elseBody?.makeReturn opts
      return
    @elseBody  or= new Block [new UndefinedLiteral] if opts?.accumulator
    @body     and= new Block [@body.makeReturn opts]
    @elseBody and= new Block [@elseBody.makeReturn opts]
    this

  ensureBlock: (node) ->
    block = if node instanceof Block then node else new Block [node]
    if node.locationData
      node.withLocationData block
    else
      @withLocationData block

  # Compile the `If` as a regular *if-else* statement. Flattened chains
  # force inner *else* bodies into statement form.
  compileStatement: (o) ->
    child    = del o, 'chainChild'
    exeq     = del o, 'isExistentialEquals'

    if exeq
      return new If(@processedCondition().invert(), @elseBodyNode(), type: 'if').compileToFragments o

    indent   = o.indent + TAB
    cond     = @processedCondition().compileToFragments o, LEVEL_PAREN
    body     = @ensureBlock(@body).compileToFragments merge o, {indent}
    ifPart   = [].concat @makeCode("if ("), cond, @makeCode(") {\n"), body, @makeCode("\n#{@tab}}")
    ifPart.unshift @makeCode @tab unless child
    return ifPart unless @elseBody
    answer = ifPart.concat @makeCode(' else ')
    if @isChain
      o.chainChild = yes
      answer = answer.concat @elseBody.unwrap().compileToFragments o, LEVEL_TOP
    else
      answer = answer.concat @makeCode("{\n"), @elseBody.compileToFragments(merge(o, {indent}), LEVEL_TOP), @makeCode("\n#{@tab}}")
    answer

  # Compile the `If` as a conditional operator.
  compileExpression: (o) ->
    cond = @processedCondition().compileToFragments o, LEVEL_COND
    body = @bodyNode().compileToFragments o, LEVEL_LIST
    alt  = if @elseBodyNode() then @elseBodyNode().compileToFragments(o, LEVEL_LIST) else [@makeCode('void 0')]
    fragments = cond.concat @makeCode(" ? "), body, @makeCode(" : "), alt
    if o.level >= LEVEL_COND then @wrapInParentheses fragments else fragments

  unfoldSoak: ->
    @soak and this

# Constants
# ---------

UTILITIES =
  modulo: -> 'function(a, b) { return (+a % (b = +b) + b) % b; }'

  boundMethodCheck: -> "
    function(instance, Constructor) {
      if (!(instance instanceof Constructor)) {
        throw new Error('Bound instance method accessed before binding');
      }
    }
  "

  # Shortcuts to speed up the lookup time for native functions.
  hasProp: -> '{}.hasOwnProperty'
  indexOf: -> '[].indexOf'
  slice  : -> '[].slice'
  splice : -> '[].splice'

UTILITIES_BABYLON =
  indexOf: -> new Value new Arr, [new Access new PropertyName 'indexOf']
  splice : -> new Value new Arr, [new Access new PropertyName 'splice']
  slice  : -> new Value new Arr, [new Access new PropertyName 'slice']
  hasProp: -> new Value new Obj, [new Access new PropertyName 'hasOwnProperty']
  boundMethodCheck: ->
    instance = new IdentifierLiteral 'instance'
    Constructor = new IdentifierLiteral 'Constructor'
    new Code(
      [
        new Param instance
        new Param Constructor
      ]
      Block.wrap [new If(
        new Op 'instanceof', instance, Constructor
        Block.wrap [new Throw new Op 'new', new Call(
          new Value new IdentifierLiteral 'Error'
          [new StringLiteral 'Bound instance method accessed before binding']
        )]
        type: 'unless'
      )]
    )
  modulo: ->
    a = new IdentifierLiteral 'a'
    b = new IdentifierLiteral 'b'

    new Code(
      [
        new Param a
        new Param b
      ]
      Block.wrap [new Op(
        '%'
        new Op(
          '+'
          new Op(
            '%'
            new Op '+', a
            new Assign b, new Op '+', b
          )
          b
        )
        b
      )]
    )

# Tabs are two spaces for pretty printing.
TAB = '  '

SIMPLENUM = /^[+-]?\d+$/
SIMPLE_STRING_OMIT = /\s*\n\s*/g
LEADING_BLANK_LINE  = /^[^\n\S]*\n/
TRAILING_BLANK_LINE = /\n[^\n\S]*$/
STRING_OMIT    = ///
    ((?:\\\\)+)      # Consume (and preserve) an even number of backslashes.
  | \\[^\S\n]*\n\s*  # Remove escaped newlines.
///g
HEREGEX_OMIT = ///
    ((?:\\\\)+)     # Consume (and preserve) an even number of backslashes.
  | \\(\s)          # Preserve escaped whitespace.
  | \s+(?:#.*)?     # Remove whitespace and comments.
///g

BABYLON_STATEMENT_TYPES = ['ExpressionStatement', 'ClassMethod', 'ArrayExpression', 'ReturnStatement', 'TemplateElement', 'JSXEmptyExpression', 'ThrowStatement', 'IfStatement', 'ForStatement', 'ForInStatement', 'BlockStatement', 'ImportSpecifier', 'VariableDeclarator']

# Helper Functions
# ----------------

# Helper for ensuring that utility functions are assigned at the top level.
utility = (name, o) ->
  {root} = o.scope
  if name of root.utilities
    root.utilities[name]
  else
    ref = root.freeVariable name
    root.assign ref, UTILITIES[name] o
    root.utilities[name] = ref

emptyLocationData =
  locationData:
    first_line: 0
    first_column: 0
    last_line: 0
    last_column: 0
    # range: [-1, -1]
    range: [-2, -2]

utilityBabylon = (name, o) ->
  calledWithArgs  = del o, 'calledWithArgs'
  appliedWithArgs = del o, 'appliedWithArgs'
  invokedWithArgs = del o, 'invokedWithArgs'
  {root} = o.scope
  ref = new IdentifierLiteral(
    if name of root.utilities
      root.utilities[name]
    else
      ref = root.freeVariable name
      root.assign ref, UTILITIES_BABYLON[name](o).withEmptyLocationData()
      root.utilities[name] = ref
  )#.withEmptyLocationData()
  return ref unless calledWithArgs or appliedWithArgs or invokedWithArgs
  new Call(
    new Value ref,
      if invokedWithArgs
        []
      else
        [new Access new PropertyName if calledWithArgs then 'call' else 'apply']
    calledWithArgs ? appliedWithArgs ? invokedWithArgs
  )#.withEmptyLocationData()

astAsBlock = (element, o) ->
  unwrapped = element.unwrap()
  if not o.compiling and unwrapped instanceof Block and unwrapped.expressions.length > 1
    unwrapped.toAst o, LEVEL_TOP
  else
    element.toAst o, LEVEL_PAREN

multident = (code, tab, includingFirstLine = yes) ->
  endsWithNewLine = code[code.length - 1] is '\n'
  code = (if includingFirstLine then tab else '') + code.replace /\n/g, "$&#{tab}"
  code = code.replace /\s+$/, ''
  code = code + '\n' if endsWithNewLine
  code

# Wherever in CoffeeScript 1 we might’ve inserted a `makeCode "#{@tab}"` to
# indent a line of code, now we must account for the possibility of comments
# preceding that line of code. If there are such comments, indent each line of
# such comments, and _then_ indent the first following line of code.
indentInitial = (fragments, node) ->
  for fragment, fragmentIndex in fragments
    if fragment.isHereComment
      fragment.code = multident fragment.code, node.tab
    else
      fragments.splice fragmentIndex, 0, node.makeCode "#{node.tab}"
      break
  fragments

hasLineComments = (node) ->
  return no unless node.comments
  for comment in node.comments
    return yes if comment.here is no
  return no

# Move the `comments` property from one object to another, deleting it from
# the first object.
moveComments = (from, to) ->
  return unless from?.comments
  attachCommentsToNode from.comments, to
  delete from.comments

# Sometimes when compiling a node, we want to insert a fragment at the start
# of an array of fragments; but if the start has one or more comment fragments,
# we want to insert this fragment after those but before any non-comments.
unshiftAfterComments = (fragments, fragmentToInsert) ->
  inserted = no
  for fragment, fragmentIndex in fragments when not fragment.isComment
    fragments.splice fragmentIndex, 0, fragmentToInsert
    inserted = yes
    break
  fragments.push fragmentToInsert unless inserted
  fragments

isLiteralArguments = (node) ->
  node instanceof IdentifierLiteral and node.value is 'arguments'

isLiteralThis = (node) ->
  node instanceof ThisLiteral or (node instanceof Code and node.bound)

shouldCacheOrIsAssignable = (node) -> node.shouldCache() or node.isAssignable?()

# Unfold a node's child if soak, then tuck the node under created `If`
unfoldSoak = (o, parent, name) ->
  return unless ifn = parent[name].unfoldSoak o
  parent[name] = ifn.body
  ifn.body = new Value parent
  ifn
