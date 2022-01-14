vim9script

var util = {}
if has('patch-8.2.4019')
  import './util.vim' as util_import
  util.GetLineByteFromPos = util_import.GetLineByteFromPos
else
  import GetLineByteFromPos from './util.vim'
  util.GetLineByteFromPos = GetLineByteFromPos
endif

# jump to a symbol selected in the outline window
def s:outlineJumpToSymbol()
  var lnum: number = line('.') - 1
  if w:lspSymbols.lnumTable[lnum]->empty()
    return
  endif

  var slnum: number = w:lspSymbols.lnumTable[lnum].lnum
  var scol: number = w:lspSymbols.lnumTable[lnum].col
  var fname: string = w:lspSymbols.filename

  # Highlight the selected symbol
  prop_remove({type: 'LspOutlineHighlight'})
  var col: number = getline('.')->match('\S') + 1
  prop_add(line('.'), col, {type: 'LspOutlineHighlight',
			length: w:lspSymbols.lnumTable[lnum].name->len()})

  # disable the outline window refresh
  skipRefresh = true

  # If the file is already opened in a window, jump to it. Otherwise open it
  # in another window
  var wid: number = fname->bufwinid()
  if wid == -1
    # Find a window showing a normal buffer and use it
    for w in getwininfo()
      if w.winid->getwinvar('&buftype') == ''
	wid = w.winid
	wid->win_gotoid()
	break
      endif
    endfor
    if wid == -1
      var symWinid: number = win_getid()
      :rightbelow vnew
      # retain the fixed symbol window width
      win_execute(symWinid, 'vertical resize 20')
    endif

    exe 'edit ' .. fname
  else
    wid->win_gotoid()
  endif
  [slnum, scol]->cursor()
  skipRefresh = false
enddef

# Skip refreshing the outline window. Used to prevent recursive updates to the
# outline window
var skipRefresh: bool = false

export def SkipOutlineRefresh(): bool
  return skipRefresh
enddef

def s:addSymbolText(bnr: number,
			symbolTypeTable: dict<list<dict<any>>>,
			pfx: string,
			text: list<string>,
			lnumMap: list<dict<any>>,
			children: bool)
  var prefix: string = pfx .. '  '
  for [symType, symbols] in symbolTypeTable->items()
    if !children
      # Add an empty line for the top level symbol types. For types in the
      # children symbols, don't add the empty line.
      text->extend([''])
      lnumMap->extend([{}])
    endif
    if children
      text->extend([prefix .. symType])
      prefix ..= '  '
    else
      text->extend([symType])
    endif
    lnumMap->extend([{}])
    for s in symbols
      text->add(prefix .. s.name)
      # remember the line number for the symbol
      var start_col: number = util.GetLineByteFromPos(bnr, s.range.start) + 1
      lnumMap->add({name: s.name, lnum: s.range.start.line + 1,
			col: start_col})
      s.outlineLine = lnumMap->len()
      if s->has_key('children') && !s.children->empty()
	s:addSymbolText(bnr, s.children, prefix, text, lnumMap, true)
      endif
    endfor
  endfor
enddef

# update the symbols displayed in the outline window
export def UpdateOutlineWindow(fname: string,
				symbolTypeTable: dict<list<dict<any>>>,
				symbolLineTable: list<dict<any>>)
  var wid: number = bufwinid('LSP-Outline')
  if wid == -1
    return
  endif

  # stop refreshing the outline window recursively
  skipRefresh = true

  var prevWinID: number = win_getid()
  wid->win_gotoid()

  # if the file displayed in the outline window is same as the new file, then
  # save and restore the cursor position
  var symbols = wid->getwinvar('lspSymbols', {})
  var saveCursor: list<number> = []
  if !symbols->empty() && symbols.filename == fname
    saveCursor = getcurpos()
  endif

  :setlocal modifiable
  :silent! :%d _
  setline(1, ['# LSP Outline View',
		'# ' .. fname->fnamemodify(':t') .. ' ('
				.. fname->fnamemodify(':h') .. ')'])

  # First two lines in the buffer display comment information
  var lnumMap: list<dict<any>> = [{}, {}]
  var text: list<string> = []
  s:addSymbolText(fname->bufnr(), symbolTypeTable, '', text, lnumMap, false)
  append('$', text)
  w:lspSymbols = {filename: fname, lnumTable: lnumMap,
				symbolsByLine: symbolLineTable}
  :setlocal nomodifiable

  if !saveCursor->empty()
    saveCursor->setpos('.')
  endif

  prevWinID->win_gotoid()

  # Highlight the current symbol
  s:outlineHighlightCurrentSymbol()

  # re-enable refreshing the outline window
  skipRefresh = false
enddef

def s:outlineHighlightCurrentSymbol()
  var fname: string = expand('%')->fnamemodify(':p')
  if fname == '' || &filetype == ''
    return
  endif

  var wid: number = bufwinid('LSP-Outline')
  if wid == -1
    return
  endif

  # Check whether the symbols for this file are displayed in the outline
  # window
  var lspSymbols = wid->getwinvar('lspSymbols', {})
  if lspSymbols->empty() || lspSymbols.filename != fname
    return
  endif

  var symbolTable: list<dict<any>> = lspSymbols.symbolsByLine

  # line number to locate the symbol
  var lnum: number = line('.')

  # Find the symbol for the current line number (binary search)
  var left: number = 0
  var right: number = symbolTable->len() - 1
  var mid: number
  while left <= right
    mid = (left + right) / 2
    if lnum >= (symbolTable[mid].range.start.line + 1) &&
		lnum <= (symbolTable[mid].range.end.line + 1)
      break
    endif
    if lnum > (symbolTable[mid].range.start.line + 1)
      left = mid + 1
    else
      right = mid - 1
    endif
  endwhile

  # clear the highlighting in the outline window
  var bnr: number = wid->winbufnr()
  prop_remove({bufnr: bnr, type: 'LspOutlineHighlight'})

  if left > right
    # symbol not found
    return
  endif

  # Highlight the selected symbol
  var col: number =
	match(getbufline(bnr, symbolTable[mid].outlineLine)[0], '\S') + 1
  prop_add(symbolTable[mid].outlineLine, col,
			{bufnr: bnr, type: 'LspOutlineHighlight',
			length: symbolTable[mid].name->len()})

  # if the line is not visible, then scroll the outline window to make the
  # line visible
  var wininfo = wid->getwininfo()
  if symbolTable[mid].outlineLine < wininfo[0].topline
			|| symbolTable[mid].outlineLine > wininfo[0].botline
    var cmd: string = 'call cursor(' ..
			symbolTable[mid].outlineLine .. ', 1) | normal z.'
    win_execute(wid, cmd)
  endif
enddef

# when the outline window is closed, do the cleanup
def s:outlineCleanup()
  # Remove the outline autocommands
  :silent! autocmd! LSPOutline

  :silent! syntax clear LSPTitle
enddef

# open the symbol outline window
export def OpenOutlineWindow()
  var wid: number = bufwinid('LSP-Outline')
  if wid != -1
    return
  endif

  var prevWinID: number = win_getid()

  :topleft :20vnew LSP-Outline
  :setlocal modifiable
  :setlocal noreadonly
  :silent! :%d _
  :setlocal buftype=nofile
  :setlocal bufhidden=delete
  :setlocal noswapfile nobuflisted
  :setlocal nonumber norelativenumber fdc=0 nowrap winfixheight winfixwidth
  :setlocal shiftwidth=2
  :setlocal foldenable
  :setlocal foldcolumn=4
  :setlocal foldlevel=4
  :setlocal foldmethod=indent
  setline(1, ['# File Outline'])
  :nnoremap <silent> <buffer> q :quit<CR>
  :nnoremap <silent> <buffer> <CR> :call <SID>outlineJumpToSymbol()<CR>
  :setlocal nomodifiable

  # highlight all the symbol types
  :syntax keyword LSPTitle File Module Namespace Package Class Method Property
  :syntax keyword LSPTitle Field Constructor Enum Interface Function Variable
  :syntax keyword LSPTitle Constant String Number Boolean Array Object Key Null
  :syntax keyword LSPTitle EnumMember Struct Event Operator TypeParameter

  if str2nr(&t_Co) > 2
    highlight clear LSPTitle
    highlight default link LSPTitle Title
  endif

  prop_type_add('LspOutlineHighlight', {bufnr: bufnr(), highlight: 'Search'})

  augroup LSPOutline
    au!
    autocmd BufEnter * call lsp#requestDocSymbols()
    # when the outline window is closed, do the cleanup
    autocmd BufUnload LSP-Outline call s:outlineCleanup()
    autocmd CursorHold * call s:outlineHighlightCurrentSymbol()
  augroup END

  prevWinID->win_gotoid()
enddef

# vim: shiftwidth=2 softtabstop=2