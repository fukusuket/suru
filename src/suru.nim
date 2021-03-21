import macros, std/monotimes, times, terminal, math, strutils, sequtils, unicode, strformat
{.experimental: "forLoopMacros".}
when compileOption("threads"): import os

type
  ExpMovingAverager = distinct float
  SingleSuruBar* = object
    length*: int
    progress: int
    total*: int                     # total amount of progresses
    progressStat: ExpMovingAverager # moving average of increments to progresses
    timeStat: ExpMovingAverager     # moving average of time difference between progresses
    startTime: MonoTime             # start time of bar
    lastChange: MonoTime         # last time bar was changed, used for timeStat
    currentAccess: MonoTime
    lastAccess: MonoTime
    format: proc(ssb: SingleSuruBar): string {.gcsafe.}
  SuruBar* = object
    bars: seq[SingleSuruBar]
    currentIndex: int # for usage in show(), tracks current index cursor is on relative to first progress bar
when compileOption("threads"):
  type
    SuruBarController = object # new object to still allow non-threaded SuruBars when threads:on
      bar: SuruBar
      finished: bool
      progressThread: Thread[ptr SuruBarController]

# utility

const
  prefixes = [
    -8: "y", "z", "a", "f", "p", "n", "u", "m",
    " ",
    "k", "M", "G", "T", "P", "E", "Z", "Y"
  ]

proc fitMagnitude(n: float, magnitude: int): (float, int) =
  if n > 1000:
    result = (n / 1000, magnitude + 1)
  elif n < 0.1:
    result = (n * 1000, magnitude - 1)
  else:
    result = (n, magnitude)

proc fittedMagnitude(n: float): (float, int) =
  result = (n, 0)
  var new = fitMagnitude(result[0], result[1])
  while result != new and (new[1] <= prefixes.high and new[1] >= prefixes.low):
    result = new
    new = fitMagnitude(result[0], result[1])

proc formatUnit*(n: float): string =
  case n.classify
  of fcNan:
    return static: "??".align(7, ' ')
  of {fcNormal, fcSubnormal, fcZero, fcNegZero}:
    let (n, mag) = fittedMagnitude(n)
    if mag == prefixes.high and n > 99:
      result = static: ">99.00Y".align(7, ' ')
    elif mag == prefixes.low and n < 0.01:
      result = static: "<0.01y".align(7, ' ')
    else:
      result = &"{n:>6.2f}" & prefixes[mag]
  of fcInf:
    result = static: ">1.00Y".align(7, ' ')
  of fcNegInf:
    result = static: "0.00".align(7, ' ')

proc formatTime*(secs: SomeFloat): string =
  if secs.classify notin {fcNormal, fcSubnormal, fcZero}:
    # if time is abnormal, output ??
    result = "  ??s"
  elif secs < 0:
    # cheat bad float subtraction by clipping anything under 0 to 0
    result = " 0.0s"
  elif secs < 100:
    # under a minute and 40 seconds, just render as seconds
    result = (secs.formatFloat(ffDecimal, 1) & "s").align(5, ' ')
  else:
    # use minute format
    let secs = secs.int
    result = ($(secs div 60)).align(2, '0') & ":" & ($(secs mod 60)).align(2, '0')

# exponential moving averager

const alpha = exp(-1/5)

proc push(mv: var ExpMovingAverager, value: SomeNumber) =
  let value = value.float
  if mv.float == 0:
    mv = value.ExpMovingAverager
  else:
    mv = (value + alpha * (mv.float - value)).ExpMovingAverager

# getters and format generators

proc progress*(ssb: SingleSuruBar): int = ssb.progress
proc perSecond*(ssb: SingleSuruBar): float =
  ssb.progressStat.float * (1_000_000_000 / ssb.timeStat.float)
proc elapsed*(ssb: SingleSuruBar): float =
  (ssb.currentAccess.ticks - ssb.startTime.ticks).float / 1_000_000_000
proc eta*(ssb: SingleSuruBar): float =
  (ssb.total - ssb.progress).float / ssb.perSecond - ((ssb.currentAccess.ticks - ssb.lastChange.ticks).float / 1_000_000_000)
proc percent*(ssb: SingleSuruBar): float = ssb.progress / ssb.total

proc `progress=`*(ssb: var SingleSuruBar, progress: int) =
  let lastProgress = ssb.progress
  ssb.progress = progress
  let newTime = getMonoTime()
  ssb.timeStat.push (newTime.ticks - ssb.lastChange.ticks).int
  ssb.lastChange = newTime
  ssb.progressStat.push ssb.progress - lastProgress

proc `format=`*(ssb: var SingleSuruBar, format: proc(ssb: SingleSuruBar): string {.gcsafe.}) =
  ssb.format = format

proc percentDisplay(ssb: SingleSuruBar): string =
  if ssb.total > 0:
    &"{(ssb.percent*100).int:>3}%"
  else:
    " ??%"

proc barDisplay*[N](
    ssb: SingleSuruBar,
    shaded: string,
    unshaded: string,
    fractionals: array[N, string],
  ): string =
  let
    percentage      = ssb.percent
    shadedCount     = min(floor(percentage * ssb.length.float).int, ssb.length)
    fractionalIndex =         ((percentage * ssb.length.float * fractionals.len.float).int mod fractionals.len) - 1
    unshadedCount   = ssb.length - shadedCount - min(fractionalIndex + 1, 1)

  result = newStringOfCap(ssb.length * 4)
  for _ in 0..<shadedCount:
    result &= shaded
  if shadedCount < ssb.length:
    if shadedCount + unshadedCount != ssb.length:
      result &= fractionals[fractionalIndex]
    for _ in 0..<unshadedCount:
      result &= unshaded

proc barDisplay(ssb: SingleSuruBar): string =
  if ssb.total > 0:
    ssb.barDisplay("█", " ", ["▏", "▎", "▍", "▌", "▋", "▊", "▉"])
  else:
    "░".repeat(ssb.length)

proc progressDisplay(ssb: SingleSuruBar): string =
  if ssb.total > 0:
    let totalStr = $ssb.total
    &"{($ssb.progress).align(totalStr.len, ' ')}/{totalStr}"
  else:
    let progressStr = $ssb.progress
    &"{progressStr.align(progressStr.len, ' ')}/" & "?".repeat(progressStr.len)

proc timeDisplay(ssb: SingleSuruBar): string =
  if ssb.total > 0:
    &"{ssb.elapsed.formatTime}<{ssb.eta.formatTime}"
  else:
    &"{ssb.elapsed.formatTime}"

proc speedDisplay(ssb: SingleSuruBar): string =
  &"{ssb.perSecond.formatUnit}/sec"

proc formatDefault(ssb: SingleSuruBar): string {.gcsafe.} =
  result = &"{ssb.percentDisplay}|{ssb.barDisplay}| {ssb.progressDisplay} [{ssb.timeDisplay}, {ssb.speedDisplay}]"

  when defined(suruDebug):
    result &= " " & ((getMonoTime().ticks - ssb.currentAccess.ticks).float/1_000).formatFloat(ffDecimal, 2) & "us overhead"

# single suru bar

proc initSingleSuruBar*(length: int): SingleSuruBar =
  SingleSuruBar(
    length: length,
    format: formatDefault,
  )

proc inc*(ssb: var SingleSuruBar, y: Natural = 1) =
  ## Increments the bar progress
  ssb.`progress=`(ssb.progress + y)

proc `$`(ssb: SingleSuruBar): string =
  result = ssb.format(ssb)

proc show(ssb: var SingleSuruBar) =
  ## Shows the bar in a formatted style.
  when defined(windows):
    stdout.eraseLine()
    stdout.write($ssb)
  else:
    stdout.write("\e[2K", $ssb)
  stdout.flushFile()
  stdout.setCursorXPos(0)

proc reset*(ssb: var SingleSuruBar, iterableLength: int) =
  ## Resets the bar to an empty bar, not including its length and total.
  let now = getMonoTime()
  ssb.progress = 0
  ssb.total = iterableLength
  ssb.progressStat = 0.ExpMovingAverager
  ssb.timeStat = 0.ExpMovingAverager
  ssb.startTime = now
  ssb.lastChange = now
  ssb.currentAccess = now
  ssb.lastAccess = now

# suru bar

proc initSuruBar*(bars: int = 1): SuruBar =
  ## Creates a SuruBar with the given amount of bars
  ## Does not prime the bar for a loop, use ``setup`` for that
  SuruBar(
    bars: initSingleSuruBar(25).repeat(bars),
  )

iterator items*(sb: SuruBar): SingleSuruBar =
  for bar in sb.bars:
    yield bar

iterator mitems*(sb: var SuruBar): var SingleSuruBar =
  var index: int
  while index < sb.bars.len:
    yield sb.bars[index]
    inc(index)

iterator pairs*(sb: SuruBar): (int, SingleSuruBar) =
  var index: int
  while index < sb.bars.len:
    yield (index, sb.bars[index])
    inc(index)

proc `[]`*(sb: SuruBar, index: Natural): SingleSuruBar =
  sb.bars[index]

proc `[]`*(sb: var SuruBar, index: Natural): var SingleSuruBar =
  sb.bars[index]

proc inc*(sb: var SuruBar, y: Natural = 1) =
  ## Increments the bar progress
  for bar in sb.mitems:
    inc bar, y

proc moveCursor(sb: var SuruBar, index: int = 0) =
  let difference = index - sb.currentIndex
  if difference < 0:
    stdout.cursorUp(abs(difference))
  elif difference > 0:
    stdout.cursorDown(abs(difference))
  sb.currentIndex = index

proc `format=`*(sb: var SuruBar, format: proc(ssb: SingleSuruBar): string {.gcsafe.}) =
  for bar in sb.mitems:
    bar.format = format

proc setup*(sb: var SuruBar, iterableLengths: varargs[int]) =
  # call this immediately before your loop
  # sets certain fields more properly now that the iterable length is known
  doAssert iterableLengths.len == sb.bars.len

  for index in 1..<iterableLengths.len:
    echo ""
  if iterableLengths.len > 1:
    stdout.cursorUp(iterableLengths.len - 1)

  for index, iterableLength in iterableLengths:
    sb[index].total = iterableLength
    sb[index].startTime = getMonoTime()
    sb[index].currentAccess = sb[index].startTime
    sb[index].lastAccess = sb[index].startTime
    sb[index].lastChange = sb[index].startTime
    sb[index].timeStat.push 0
    sb[index].progressStat.push 0
    sb.moveCursor(index)
    sb[index].show()

proc setup*(sb: var SuruBar, iterableLengthsAndAmounts: varargs[(int, int)]) =
  sb.setup((@iterableLengthsAndAmounts).foldl(a & b[0].repeat(b[1]), newSeq[int]()))

proc start*(sb: var SuruBar, iterableLengths: varargs[int]) {.deprecated: "Deprecated, use ``setup``".} =
  sb.setup(iterableLengths)

proc start*(sb: var SuruBar, iterableLengthsAndAmounts: varargs[(int, int)]) {.deprecated: "Deprecated, use ``setup``".} =
  sb.setup(iterableLengthsAndAmounts)

proc update*(sb: var SuruBar, delay: int = 8_000_000, index: int = -1) =
  template update {.dirty.} =
    let
      difference = newTime.ticks - sb[index].lastAccess.ticks # in nanoseconds
    if difference > max(delay, 1_000_000): # in nanoseconds
      sb[index].currentAccess = newTime
      sb.moveCursor(index)
      sb[index].show()
      sb[index].lastAccess = newTime
  let
    newTime = getMonoTime()
  if index < 0:
    for index, _ in sb:
      update()
  else:
    update()

proc finish*(sb: var SuruBar) =
  for index, _ in sb:
    sb.moveCursor(index)
    sb[index].show()
  echo ""

#

when compileOption("threads"):
  # TODO: fix code duplication
  proc initSuruBarThreaded*(bars: int = 1): ptr SuruBarController =
    ## Creates a SuruBar with the given amount of bars
    ## Does not prime the bar for a loop, use ``setup`` for that
    result = createShared(SuruBarController)
    result[] = SuruBarController(
      bar: SuruBar(bars: initSingleSuruBar(25).repeat(bars)),
    )

  iterator items*(sbc: ptr SuruBarController): SingleSuruBar =
    for bar in sbc[].bar.bars:
      yield bar

  iterator mitems*(sbc: ptr SuruBarController): var SingleSuruBar =
    var index: int
    while index < sbc[].bar.bars.len:
      yield sbc[].bar.bars[index]
      inc(index)

  iterator pairs*(sbc: ptr SuruBarController): (int, SingleSuruBar) =
    var index: int
    while index < sbc[].bar.bars.len:
      yield (index, sbc[].bar.bars[index])
      inc(index)

  proc `[]`*(sbc: ptr SuruBarController, index: Natural): var SingleSuruBar =
    sbc[].bar.bars[index]

  proc inc*(sbc: ptr SuruBarController, y: Natural = 1) =
    ## Increments the bar progress
    for bar in sbc[].bar.mitems:
      inc bar, y

  proc `format=`*(sbc: ptr SuruBarController, format: proc(ssb: SingleSuruBar): string {.gcsafe.}) =
    for bar in sbc[].mitems:
      bar.format = format

  proc moveCursor(sbc: ptr SuruBarController, index: int = 0) =
    let difference = index - sbc[].bar.currentIndex
    if difference < 0:
      stdout.cursorUp(abs(difference))
    elif difference > 0:
      stdout.cursorDown(abs(difference))
    sbc[].bar.currentIndex = index

  proc setup*(sbc: ptr SuruBarController, iterableLengths: varargs[int]) =
    sbc[].bar.setup(iterableLengths)

    proc progressThread(sbc: ptr SuruBarController) {.thread.} =
      while not sbc.finished:
        sleep 50
        sbc[].bar.update()
      # finished now
      sbc[].bar.finish()

    createThread(sbc[].progressThread, progressThread, sbc)

  proc setup*(sbc: ptr SuruBarController, iterableLengthsAndAmounts: varargs[(int, int)]) =
    sbc.setup((@iterableLengthsAndAmounts).foldl(a & b[0].repeat(b[1]), newSeq[int]()))

  template update*(sbc: ptr SuruBarController, delay: int = 0, index: int = 0) =
    discard

  proc finish*(sbc: ptr SuruBarController) =
    sbc[].finished = true
    joinThread(sbc[].progressThread)
    freeShared(sbc)
else:
  proc initSuruBarThreaded*(bars: int = 1): SuruBar =
    ## Creates a SuruBar with the given amount of bars
    ## Does not prime the bar for a loop, use ``setup`` for that
    {.hint: "threads is not on, using non-threaded version".}
    initSuruBar(bars)

#

template len(x: typedesc[array]): int =
  system.len(x)

template len[N, T](x: array[N, T]): int =
  system.len(x)

template len(arg: untyped): int =
  0

macro suru*(forLoop: ForLoopStmt): untyped =
  ## Wraps an iterable for printing a progress bar
  expectKind forLoop, nnkForStmt

  let
    toIterate = forLoop[^2][1] # the "x" in "for i in x"
  
  var
    preLoop = newStmtList()
    body = forLoop[^1]
    newFor = newTree(nnkForStmt)
    postLoop = newStmtList()

  var
    bar = genSym(nskVar, "bar")
    barSet: bool
    delayVal = quote do: 50_000_000
    threaded: bool
    formatVal: NimNode
    totalVal: NimNode

  # handle settings
  if forLoop[^2].len > 2:
    let settings = forLoop[^2][2..^1]
    for setting in settings:
      setting.expectKind(nnkExprEqExpr)
      setting[0].expectKind(nnkIdent)

      # threaded
      # ? format: not really needed if barIdent...
      # barIdent: for manual incrementing
      #   will not disable update call, only the increment call
      # delay
      # ? total: not needed if barIdent...

      if setting[0].eqIdent "threaded":
        setting[1].expectKind(nnkIdent)
        if setting[1].eqIdent "true":
          threaded = true
        elif setting[1].eqIdent "true":
          discard
        else:
          error("invalid value for setting value (bool expected): " & $setting[1], setting[1])
      elif setting[0].eqIdent "format":
        formatVal = setting[1]
      elif setting[0].eqIdent "total":
        totalVal = setting[1]
      elif setting[0].eqIdent "barIdent":
        setting[1].expectKind(nnkIdent)
        bar = setting[1]
      elif setting[0].eqIdent "delay":
        delayVal = setting[1]
      else:
        error("invalid value for setting: " & $setting[0], setting)

  # first printing of the progress bar
  if threaded:
    preLoop.add quote do:
      var
        `bar` = initSuruBarThreaded()
  else:
    preLoop.add quote do:
      var
        `bar` = initSuruBar()

  if not formatVal.isNil:
    preLoop.add quote do:
      `bar`.format = `formatVal`

  if not totalVal.isNil:
    preLoop.add quote do:
      `bar`.setup(`totalVal`)
  else:
    preLoop.add quote do:
      when compiles(len(`toIterate`)):
        `bar`.setup(len(`toIterate`))
      else:
        `bar`.setup(0)

  # makes body a statement list to be able to add statements
  if body.kind != nnkStmtList:
    body = newTree(nnkStmtList, body)

  # in-loop printing of the progress bar
  body.add quote do:
    inc `bar`
    `bar`.update(`delayVal`)

  # re-adds the variables into the new for statement
  for i in 0..<forLoop.len-2:
    newFor.add forLoop[i]

  # transforms suru(...) to '...'
  newFor.add toIterate
  newFor.add body

  postLoop.add quote do:
    `bar`.finish()

  # wraps the whole macro in a block to create a new scope
  # also includes final print of the bar
  result = quote do:
    block:
      `preLoop`
      `newFor`
      `postLoop`

