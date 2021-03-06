url = require('url')
Repl = require('./repl')
{Range} = require 'atom'
$ = require 'jquery'
Q = require('q')


module.exports =
class Controller

  constructor: (directory) ->
    @defaultURI = "sclang://localhost:57120"
    @projectRoot = if directory then directory.path else ''
    @repls = {}
    @activeRepl = null
    @markers = []

  start: ->
    atom.commands.add 'atom-workspace',
      'supercollider:recompile', => @recompile()
    atom.commands.add 'atom-workspace',
      'supercollider:open-post-window', => @openPostWindow()
    atom.commands.add 'atom-workspace',
      'supercollider:clear-post-window', => @clearPostWindow()
    atom.commands.add 'atom-workspace',
      'supercollider:cmd-period', => @cmdPeriod()
    atom.commands.add 'atom-workspace',
      'supercollider:eval', => @eval()
    atom.commands.add 'atom-workspace',
      'supercollider:open-help-file', => @openHelpFile()

    # open a REPL for sclang on this host/port
    atom.workspace.addOpener (uri, options) =>
      try
        {protocol, hostname, port} = url.parse(uri)
      catch error
        return
      return unless protocol is 'sclang:'

      onClose = =>
        if @activeRepl is repl
          @destroyRepl()
        delete @repls[uri]

      repl = new Repl(uri, @projectRoot, onClose)
      @activateRepl repl
      @repls[uri] = repl
      window = repl.createPostWindow()
      repl.startSCLang()
      window

  stop: ->
    for repl in @repls
      repl.stop()
    @destroyRepl()
    @repls = {}

  activateRepl: (repl) ->
    @activeRepl = repl
    @activeRepl.unsubscriber = repl.emit.subscribe (event) =>
      @handleReplEvent(event)

  destroyRepl: () ->
    @activeRepl?.unsubscriber()
    @activeRepl = null

  handleReplEvent: (event) ->
    error = event.value()
    # only expecting compile errors for now
    if error.index == 0
      @openToSyntaxError(error.file, error.line, error.char)

  openPostWindow: (uri) ->
    # @returns {Promise}
    repl = @repls[uri]

    if repl
      @activateRepl repl
      # a resolved promise
      return Q()
    else
      # open links on click
      fileOpener = (event) =>

        # A or child of A
        link = event.target.href
        unless link
          link = $(event.target).parents('a').attr('href')

        return unless link

        event.preventDefault()

        if link.substr(0, 7) == 'file://'
          path = link.substr(7)
          atom.workspace.open(path, split: 'left', searchAllPanes: true)
          return

        if link.substr(0, 10) == 'scclass://'
          link = link.substr(10)
          [path, charPos] = link.split(':')
          if ',' in charPos
            [lineno, char] = charPos.split(',')
            @openFile(
              path,
              null,
              parseInt(lineno),
              parseInt(char),
              'line',
              'line-highlight')
          else
            @openFile(
              path,
              parseInt(charPos),
              null,
              null,
              'line',
              'line-highlight')

      options =
        split: 'right'
        searchAllPanes: true
      atom.workspace.open(uri, options)
        .then () =>
          @activateRepl @repls[uri]
          $('.post-window').on 'click', fileOpener

  clearPostWindow: ->
    @activeRepl?.clearPostWindow()

  recompile: ->
    @destroyMarkers()
    if @activeRepl
      @activeRepl.recompile()
    else
      @openPostWindow(@defaultURI)

  cmdPeriod: ->
    @activeRepl?.cmdPeriod()

  editorIsSC: ->
    editor = atom.workspace.getActiveTextEditor()
    editor and editor.getGrammar().scopeName is 'source.supercollider'

  currentExpression: ->
    editor = atom.workspace.getActiveTextEditor()
    return unless editor?

    selection = editor.getLastSelection()
    expression = selection.getText()
    if expression
      range = selection.getBufferRange()
    else
      # execute the line you are on
      pos = editor.getCursorBufferPosition()
      row = editor.getCursorScreenPosition().row
      if row?
        range = new Range([row, 0], [row + 1, 0])
        expression = editor.lineTextForBufferRow(row)
      else
        range = null
        expression = null
    [expression, range]

  currentPath: ->
    editor = atom.workspace.getActiveTextEditor()
    return unless editor?
    editor.getPath()

  eval: ->
    return unless @editorIsSC()
    [expression, range] = @currentExpression()
    @evalWithRepl(expression, @currentPath(), range)

  evalWithRepl: (expression, path, range) ->
    @destroyMarkers()

    return unless expression

    doIt = () =>
      if range?
        unflash = @evalFlash(range)

      onSuccess = () ->
        unflash?('eval-success')

      onError = (error) =>
        if error.type is 'SyntaxError'
          unflash?('eval-syntax-error')
          if path
            # offset syntax error by position of selected text in file
            row = range.getRows()[0] + error.error.line
            col = error.error.charPos
            @openToSyntaxError(path, parseInt(row), parseInt(col))
        else
          # runtime error
          unflash?('eval-error')

      @activeRepl.eval(expression, false, path)
        .then(onSuccess, onError)

    if @activeRepl
      # if stuck in compile error
      # then post warning and return
      unless @activeRepl.isCompiled()
        @activeRepl.warnIsNotCompiled()
        return
      doIt()
    else
      @openPostWindow(@defaultURI)
        .then doIt

  openToSyntaxError: (path, line, char) ->
    @openFile(path, null, line, char)

  openHelpFile: ->
    unless @editorIsSC()
      return false
    [expression, range] = @currentExpression()

    base = null

    # Klass.openHelpFile
    klassy = /^([A-Z]{1}[a-zA-Z0-9\_]*)$/
    match = expression.match(klassy)
    if match
      base = expression
    else
      # 'someMethod'.openHelpFile
      # starts with lowercase has no punctuation, wrap in ''
      # TODO match ops
      methody = /^([a-z]{1}[a-zA-Z0-9\_]*)$/
      match = expression.match(methody)
      if match
        base = "'#{expression}'"
      else
        # anything else just do a search
        stringy = /^([^"]+)$/
        match = expression.match(stringy)
        if match
          base = '"' + expression + '"'

    if base
      @evalWithRepl("#{base}.openHelpFile")

  openFile: (uri, charPos, row, col, markerType="line", cssClass="line-error")->
    options =
      initialLine: row
      initialColumn: col
      split: 'left'
      activatePane: false
      searchAllPanes: true

    atom.workspace.open(uri, options)
      .then (editor) =>
        setMark = (point) =>
          editor.setCursorBufferPosition(point)
          expression = editor.lineTextForBufferRow(point[0])
          range = [point, [point[0], expression.length - 1]]
          @destroyMarkers()

          marker = editor.markBufferRange(range, invalidate: 'touch')
          decoration = editor.decorateMarker(marker,
            type: markerType,
            class: cssClass)
          @markers.push marker

        if row?
          # mark is zero indexed
          return setMark([row - 1, col])

        text = editor.getText()
        cursor = 0
        li = 0
        for ll in text.split('\n')
          cursor += (ll.length + 1)
          if cursor > charPos
            return setMark([li, cursor - charPos - ll.length])
          li += 1

  destroyMarkers: () ->
    @markers.forEach (m) ->
      m.destroy()
    @markers = []

  evalFlash: (range) ->
    editor = atom.workspace.getActiveTextEditor()
    marker = editor.markBufferRange(range, invalidate: 'touch')
    decoration = editor.decorateMarker(marker,
                    type: 'line',
                    class: "eval-flash")
    # return fn to flash error/success and destroy the flash
    (cssClass) ->
      decoration.setProperties(type: 'line', class: cssClass)
      destroy = ->
        marker.destroy()
      setTimeout(destroy, 100)
