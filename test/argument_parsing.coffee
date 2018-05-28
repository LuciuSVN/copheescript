return unless require?
{buildCSOptionParser} = require '../lib/coffeescript/command'

optionParser = buildCSOptionParser()

sameOptions = (opts1, opts2, msg) ->
  ownKeys = Object.keys(opts1).sort()
  otherKeys = Object.keys(opts2).sort()
  arrayEq ownKeys, otherKeys, msg
  for k in ownKeys
    arrayEq opts1[k], opts2[k], msg
  yes

test "combined options are not split after initial file name", ->
  argv = ['some-file.coffee', '-bc']
  parsed = optionParser.parse argv
  expected = arguments: ['some-file.coffee', '-bc']
  sameOptions parsed, expected

  argv = ['some-file.litcoffee', '-bc']
  parsed = optionParser.parse argv
  expected = arguments: ['some-file.litcoffee', '-bc']
  sameOptions parsed, expected

  argv = ['-c', 'some-file.coffee', '-bc']
  parsed = optionParser.parse argv
  expected =
    compile: yes
    arguments: ['some-file.coffee', '-bc']
  sameOptions parsed, expected

  argv = ['-bc', 'some-file.coffee', '-bc']
  parsed = optionParser.parse argv
  expected =
    bare: yes
    compile: yes
    arguments: ['some-file.coffee', '-bc']
  sameOptions parsed, expected

test "combined options are not split after a '--', which is discarded", ->
  argv = ['--', '-bc']
  parsed = optionParser.parse argv
  expected =
    doubleDashed: yes
    arguments: ['-bc']
  sameOptions parsed, expected

  argv = ['-bc', '--', '-bc']
  parsed = optionParser.parse argv
  expected =
    bare: yes
    compile: yes
    doubleDashed: yes
    arguments: ['-bc']
  sameOptions parsed, expected

test "options are not split after any '--'", ->
  argv = ['--', '--', '-bc']
  parsed = optionParser.parse argv
  expected =
    doubleDashed: yes
    arguments: ['--', '-bc']
  sameOptions parsed, expected

  argv = ['--', 'some-file.coffee', '--', 'arg']
  parsed = optionParser.parse argv
  expected =
    doubleDashed: yes
    arguments: ['some-file.coffee', '--', 'arg']
  sameOptions parsed, expected

  argv = ['--', 'arg', 'some-file.coffee', '--', '-bc']
  parsed = optionParser.parse argv
  expected =
    doubleDashed: yes
    arguments: ['arg', 'some-file.coffee', '--', '-bc']
  sameOptions parsed, expected

test "any non-option argument stops argument parsing", ->
  argv = ['arg', '-bc']
  parsed = optionParser.parse argv
  expected = arguments: ['arg', '-bc']
  sameOptions parsed, expected

test "later '--' are not removed", ->
  argv = ['some-file.coffee', '--', '-bc']
  parsed = optionParser.parse argv
  expected = arguments: ['some-file.coffee', '--', '-bc']
  sameOptions parsed, expected

test "throw on invalid options", ->
  argv = ['-k']
  throws -> optionParser.parse argv

  argv = ['-ck']
  throws (-> optionParser.parse argv), /multi-flag/

  argv = ['-kc']
  throws (-> optionParser.parse argv), /multi-flag/

  argv = ['-oc']
  throws (-> optionParser.parse argv), /needs an argument/

  argv = ['-o']
  throws (-> optionParser.parse argv), /value required/

  argv = ['-co']
  throws (-> optionParser.parse argv), /value required/

  # Check if all flags in a multi-flag are recognized before checking if flags
  # before the last need arguments.
  argv = ['-ok']
  throws (-> optionParser.parse argv), /unrecognized option/

test "has expected help text", ->
  ok optionParser.help() is '''

Usage: coffee [options] path/to/script.coffee [args]

If called without options, `coffee` will run your script.

  -b, --bare         compile without a top-level function wrapper
  -c, --compile      compile to JavaScript and save as .js files
  -e, --eval         pass a string from the command line as input
  -h, --help         display this help message
  -i, --interactive  run an interactive CoffeeScript REPL
  -j, --join         concatenate the source CoffeeScript before compiling
  -m, --map          generate source map and save as .js.map files
  -M, --inline-map   generate source map and include it directly in output
  -n, --nodes        print out the parse tree that the parser produces
      --nodejs       pass options directly to the "node" binary
      --no-header    suppress the "Generated by" header
  -o, --output       set the output path or path/filename for compiled JavaScript
  -p, --print        print out the compiled JavaScript
  -r, --require      require the given module before eval or REPL
  -s, --stdio        listen for and compile scripts over stdio
  -l, --literate     treat stdio as literate style coffeescript
  -t, --transpile    pipe generated JavaScript through Babel
      --tokens       print out the tokens that the lexer/rewriter produce
  -v, --version      display the version number
  -w, --watch        watch scripts for changes and rerun commands
      --babylon      print out Babylon AST
      --prettier     compile using Prettier
      --ast-printer  generate JS via AST printer
  -a, --ast          print out AST

  '''
