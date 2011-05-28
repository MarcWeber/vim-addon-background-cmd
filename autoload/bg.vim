exec vam#DefineAndBind('s:c','g:vim_bg', '{}')

let s:vim = get(s:c,'vim', 'vim')

" /bin/sh only works if its a bash implementation !
let s:bash_shell = filereadable('/bin/bash') ? '/bin/bash' : '/bin/sh'

" you can use hooks to change colorscheme or such
" event one of start / stop
fun! bg#CallEvent(event)
  if has_key(s:c, a:event)
    call funcref#Call(s:c[a:event])
  endif
endf

fun! bg#ShEscape(list)
  return map(copy(a:list), 'escape(v:val,'.string("`&\"\\' <>();{}").')')
endf

fun! bg#ListToCmd(cmd)
  if type(a:cmd) == type('')
    return a:cmd
  else
    return join(bg#ShEscape(a:cmd)," ")
  endif
endfun

fun! bg#Run(cmd, outToTmpFile, onFinish)
  call bg#CallEvent("start")
  let S = function('bg#ShEscape')

  let cmd = '{ '.bg#ListToCmd(a:cmd).'; }'
  if a:outToTmpFile
    let tmpFile = tempname()
    let cmd .=  ' &> '.shellescape(tmpFile)
    let escapedFile = ','.S([string(tmpFile)])[0]
  else
    let escapedFile = ''
  endif

  " call back into vim using client server feature.. This seams to be the only
  " thread safe way
  if has('clientserver') && v:servername != '' && exists('g:bg_use_python')
    let nr = tiny_cmd#Put(a:onFinish)
    call bg#ProcessInPython(a:cmd, tmpFile, nr)
  elseif has('clientserver') && v:servername != '' && filereadable(s:bash_shell)
    " force usage of /bin/sh
    let nr = tiny_cmd#Put(a:onFinish)
    let cmd .= '; '.s:vim.' --servername '.S([v:servername])[0].' --remote-send \<esc\>:call\ funcref#Call\(tiny_cmd#Pop\('.nr.'\),\[$?'.escapedFile.'\]\)\<cr\>' 
    call system(s:bash_shell,'{ '.cmd.'; }&')
  elseif filereadable(s:bash_shell)
    " fall back using system
    call system(s:bash_shell,cmd)
    call funcref#Call(a:onFinish, [v:shell_error] + (a:outToTmpFile ? [tmpFile] : []))
    call bg#CallEvent("stop")
  elseif executable('cmd')
    throw "TODO: finish Windows implementation (quoting!) - consider using Python implementation which works great on Windows! let g:bg_use_python = 1 !"
    let c = system('cmd',cmd)
    call funcref#Call(a:onFinish, [v:shell_error] + (a:outToTmpFile ? [tmpFile] : []))
    call bg#CallEvent("stop")
  endif
endf

" file either c for quickfix or l for location list
" first opt arg: errorformat string
" second opt arg: callback after errors have been loaded
fun! bg#RunQF(cmd, file, ...)
  let efm = a:0 > 0 ? a:1 : 0
  let onFinish = a:0 > 1 ? a:2 : 0
  call bg#Run(a:cmd, 1, funcref#Function('bg#LoadIntoQF', { 'args' : [efm, a:file, onFinish]}))
endf

fun! bg#LoadIntoQF(efm, f, onFinish, status, file)
  if type(a:efm) == type("")
    silent! exec 'set efm='.a:efm
  endif
  exec a:f.'file '.a:file
  if type(a:onFinish) != type(0)
    call funcref#Call(a:onFinish, [a:status])
  endif
endf

if !exists('g:bg_use_python')
  finish
endif

" =======================  run handlers ======================================
fun! bg#ProcessInPython(cmd_or_list, tmpfile, nr)
  if !has('python') | throw "RunHandlerPython: no python support" | endif
  " lets hope this vim has clientserver support..

let g:use_this_vim = "vim"
let g:cmd_or_list = a:cmd_or_list
let g:callback_nr = a:nr
let g:tmpfile = a:tmpfile
py << EOF
thread=MyThread(vim.eval("g:use_this_vim"), vim.eval("v:servername"), vim.eval("g:cmd_or_list"), vim.eval("g:tmpfile"), vim.eval("g:callback_nr"))
thread.start()
EOF
endf

py << EOF
import threading
import string
import sys, tokenize, cStringIO, types, socket, string, vim, os
from subprocess import Popen, PIPE, STDOUT

class MyThread ( threading.Thread ):
  def __init__(self, vim, servername, cmd, tmpfile, callback_nr):
    threading.Thread.__init__(self)
    self.vim = vim
    self.servername = servername
    self.command = cmd
    self.tmpfile = tmpfile
    self.callback_nr = callback_nr

    self.su = subprocess.STARTUPINFO()
    if subprocess.mswindows:
      self.su.dwFlags |= subprocess._subprocess.STARTF_USESHOWWINDOW
      self.su.wShowWindow = subprocess._subprocess.SW_HIDE

  def run ( self ):
    try:
      if type(self.command) == type(""):
        # FIXME: split should be done by regex ignoring multiple spaces etc.. quoting is not supported either...
        # or should cmd /c be used on windows?
        self.command = self.command.split(" ")

      popenobj  = Popen(self.command, shell = False, bufsize = 1, stdin = PIPE, stdout = PIPE, stderr = STDOUT, startupinfo = self.su)
      stdoutwriter = open(self.tmpfile,'w')
      # never mix \r\n and \n
      lines = popenobj.stdout.readlines()
      s = "\n".join(lines).replace("\r\n","\n").replace("\r","\n")
      stdoutwriter.writelines([s])
      stdoutwriter.close()
      popenobj.wait()
      self.executeVimCommand("call funcref#Call(tiny_cmd#Pop(%s),[%d, \"%s\"])"%(self.callback_nr, popenobj.returncode, self.tmpfile))
    except Exception, e:
      self.executeVimCommand("echoe '%s'"%("exception: "+str(e)))
    except:
      # I hope command not found is the only error which might  occur here
      self.executeVimCommand("echoe '%s'"%("command not found"))

  def executeVimCommand(self, cmd):
    # can't use vim.command! here because vim hasn't been written for multiple
    # threads. I'm getting Xlib: unexpected async reply (sequence 0x859) ;-)
    # will use server commands again
    popenobj = Popen([self.vim,"--servername","%s"%(self.servername),"--remote-send","<esc>:%s<cr>"%cmd], startupinfo = self.su)
    popenobj.wait()
EOF
