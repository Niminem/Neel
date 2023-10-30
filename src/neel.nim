import std/[macros, os, strutils, osproc, json, threadpool, browsers, uri, tables]
from std/sequtils import keepItIf
import pkg/[mummy, mummy/routers]
export os, strutils, osproc, json, threadpool, browsers
export mummy, routers


type NeelError* = object of CatchableError


# ------------ EMBED STATIC ASSETS LOGIC -----------------------------

proc getWebFolder*(webDirPath: string): Table[string,string] {.compileTime.} =
    for path in walkDirRec(webDirPath,relative=true):
        if path == "index.html":
            result["/"] = staticRead(webDirPath / path)
        else:
            result["/" & path.replace('\\','/')] = staticRead(webDirPath / path)


# ----------------------------------------------------------------------


# ------------- TRANSFORMATIONS & TYPE CONVERSION LOGIC ----------------

const PARAMTYPES* = ["string","int","float","bool","OrderedTable[string, JsonNode]", "seq[JsonNode]"]

var wsVar*: WebSocket

macro callJs*(funcName: string, params: varargs[untyped]) =
    quote do:
        wsVar.send($(%*{"funcName":`funcName`,"params":[`params`]}))


proc validation*(procs: NimNode) =

    for procedure in procs.children:

        procedure.expectKind(nnkProcDef) #each has to be a proc definition
        procedure[3][0].expectKind(nnkEmpty) #there should be no return type
        procedure[4].expectKind(nnkEmpty) #there should be no pragma

        for param in procedure.params: #block below checks type of each param, should match w/ string in PARAMTYPES

            if param.kind != nnkEmpty:
                for i in 0 .. param.len-1:
                    if param[i].kind == nnkEmpty:
                        if param[i-1].repr in PARAMTYPES:
                            continue
                        else:
                            error "param type: " & param[i-1].repr & """ invalid. accepted types:
                                 string, int, float, bool, OrderedTable[string, JsonNode], seq[JsonNode]"""


proc ofStatements*(procedure: NimNode): NimNode =

    if procedure[3].len == 1:#handles procedure w/ empty params (formalParams has one child of kind nnkEmpty)
        result = nnkOfBranch.newTree(
                newLit(procedure[0].repr), #name of proc
                nnkStmtList.newTree(
                        nnkCall.newTree(
                            newIdentNode(procedure[0].repr) #name of proc
                    )))
    else:
        result = nnkOfBranch.newTree()
        result.add newLit(procedure[0].repr) #name of proc
        var
            statementList = nnkStmtList.newTree()
            procCall = nnkCall.newTree()
            paramsData :seq[tuple[paramType:string,typeQuantity:int]]

        procCall.add newIdentNode(procedure[0].repr) #name of proc

        for param in procedure.params:

            var typeQuantity :int
            for child in param.children:

                if child.kind != nnkEmpty:
                    if child.repr notin PARAMTYPES:
                        inc typeQuantity
                    else:
                        paramsData.add (paramType:child.repr, typeQuantity:typeQuantity)

        var paramIndex :int
        for i in 0 .. paramsData.high:
            for count in 1 .. paramsData[i].typeQuantity:
                var paramId :string
                case paramsData[i].paramType
                of "string":
                    paramId.add "getStr"
                of "int":
                    paramId.add "getInt"
                of "bool":
                    paramId.add "getBool"
                of "float":
                    paramId.add "getFloat"
                of "seq[JsonNode]":
                    paramId.add "getElems" #will this cause an issue if the types are different? 4/5/21
                of "OrderedTable[string, JsonNode]":
                    paramId.add "getFields" #will this cause an issue if the types are different? 4/5/21

                procCall.add nnkDotExpr.newTree(
                    nnkBracketExpr.newTree(
                    newIdentNode("params"),
                    newLit(paramIndex)),
                    newIdentNode(paramId))

                inc paramIndex

        statementList.add procCall
        result.add statementList

proc caseStatement*(procs: NimNode): NimNode =

    result = nnkCaseStmt.newTree()
    result.add newIdentNode("procName")

    for procedure in procs:
        result.add ofStatements(procedure) #converts proc param types for parsing json data & returns "of" statements

    #add an else statement for invalid/unkown proc calls in future iteration

macro exposeProcs*(procs: untyped) = #macro has to be untyped, otherwise callJs() expands & causes a type error
    procs.validation() #validates procs passed into the macro

    result = nnkProcDef.newTree(
            newIdentNode("callNim"),
            newEmptyNode(),
            newEmptyNode(),
            nnkFormalParams.newTree(
            newEmptyNode(),
            nnkIdentDefs.newTree(
                newIdentNode("jsData"),
                newIdentNode("JsonNode"),
                newEmptyNode()
            )),
            newEmptyNode(),
            newEmptyNode(),
            nnkStmtList.newTree(
            nnkVarSection.newTree(
                nnkIdentDefs.newTree(
                newIdentNode("procName"),
                newEmptyNode(),
                nnkDotExpr.newTree(
                    nnkBracketExpr.newTree(
                    newIdentNode("jsData"),
                    newLit("procName")
                    ),
                    newIdentNode("getStr")
                )),
                nnkIdentDefs.newTree(
                newIdentNode("params"),
                newEmptyNode(),
                nnkDotExpr.newTree(
                    nnkBracketExpr.newTree(
                    newIdentNode("jsData"),
                    newLit("params")
                    ),
                    newIdentNode("getElems")
                ))),
            procs,
            caseStatement(procs) #converts types into proper json parsing & returns case statement logic
            ))
    
    #echo result.repr #for testing macro expansion

# ----------------------------------------------------------------------



# ----------------------- BROWSER LOGIC --------------------------------

proc findChromeMac*: string =
    const defaultPath :string = r"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    const name = "Google Chrome.app"

    try:
        if fileExists(absolutePath(defaultPath)):
            result = defaultPath.replace(" ", r"\ ")
        else:
            var alternateDirs = execProcess("mdfind", args = [name], options = {poUsePath}).split("\n")
            alternateDirs.keepItIf(it.contains(name))
        
            if alternateDirs != @[]:
                result = alternateDirs[0] & "/Contents/MacOS/Google Chrome"
            else:
                raise newException(NeelError, "could not find Chrome using `mdfind`")

    except:
        raise newException(NeelError, "could not find Chrome in Applications directory")

when defined(Windows):
    import std/registry

proc findChromeWindows*: string =
    const defaultPath = r"\Program Files (x86)\Google\Chrome\Application\chrome.exe"
    const backupPath = r"\Program Files\Google\Chrome\Application\chrome.exe"
    if fileExists(absolutePath(defaultPath)):
        result = defaultPath
    elif fileExists(absolutePath(backupPath)):
        result = backupPath
    else:
        when defined(Windows):
            result = getUnicodeValue(
                path = r"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe",
                key = "", handle = HKEY_LOCAL_MACHINE)
        discard

    if result.len == 0:
        raise newException(NeelError, "could not find Chrome")

proc findChromeLinux*: string =
    const chromeNames = ["google-chrome", "google-chrome-stable", "chromium-browser", "chromium"]
    for name in chromeNames:
        if execCmd("which " & name) == 0:
            return name
    raise newException(NeelError, "could not find Chrome")

proc findPath*: string =
    when hostOS == "macosx":
        result = findChromeMac()
    elif hostOS == "windows":
        result = findChromeWindows()
    elif hostOS == "linux":
        result = findChromeLinux()
    else:
        raise newException(NeelError, "unkown OS in findPath() for neel.nim")

proc openChrome*(portNo: int, chromeFlags: seq[string]) =
    var chromeStuff = " --app=http://localhost:" & portNo.intToStr & "/ --disable-http-cache"
    if chromeFlags != @[""]:
        for flag in chromeFlags:
            chromeStuff = chromeStuff & " " & flag.strip
    let command = findPath() & chromeStuff
    if execCmd(command) != 0:
        raise newException(NeelError,"could not open Chrome browser")

# ----------------------------------------------------------------------



# ---------------------------- SERVER LOGIC ----------------------------

macro startApp*(webDirPath: string, portNo: int = 5000,
                    position: array[2, int] = [500,150], size: array[2, int] = [600,600],
                        chromeFlags: seq[string] = @[""], appMode: bool = true) =
    quote do:
        when defined(release):
            const Assets = getWebFolder(`webDirPath`)
        var openSockets = false

        proc handleFrontEndData*(frontEndData :string) {.gcsafe.} =
            callNim(frontEndData.parseJson)

        proc shutdown = # quick implementation to reduce crashing from users spamming refresh / clicking on new pages
            for i in 1 .. 10:
                sleep 1000
                if openSockets: return
            if not openSockets: quit()

        if `appMode`:
            spawn openChrome(portNo=`portNo`, chromeFlags=`chromeFlags`)
        else:
            spawn openDefaultBrowser("http://localhost:" & $`portNo` & "/")

        proc indexHandler(request: Request) =
            var headers: HttpHeaders
            headers["Cache-Control"] = "no-store"
            when not defined(release):
                request.respond(200, headers, readFile(`webDirPath` / "index.html"))
            else:
                let path = parseUri(request.uri).path
                request.respond(200, headers, Assets[path])
        proc jsHandler(request: Request) =
            var headers: HttpHeaders
            headers["Cache-Control"] = "no-store"
            headers["Content-Type"] = "application/javascript"
            request.respond(200, headers,"window.moveTo(" & $`position`[0] & "," & $`position`[1] & ")\n" &
                        "window.resizeTo(" & $`size`[0] & "," & $`size`[1] & ")\n" &
                        "var ws = new WebSocket(\"ws://localhost:" & $`portNo` & "/ws\")\n" &
                        """var connected = false
                        ws.onmessage = (data) => {
                          let x;
                          try {
                          x = JSON.parse(data.data)
                          } catch (err) {
                            x = JSON.parse(data)
                          }
                          let v = Object.values(x)
                          neel.callJs(v[0], v[1])
                        }
                        var neel = {
                            callJs: function (func, arr) {
                                window[func].apply(null, arr);
                            },
                            callNim: function (func, ...args) {
                                if (!connected) {
                                    function check(func, ...args) { if (ws.readyState == 1) { connected = true; neel.callNim(func, ...args); clearInterval(myInterval); } }
                                    var myInterval = setInterval(check,15,func,...args)
                                } else {
                                    let paramArray = []
                                    for (var i = 0; i < args.length; i++) {
                                        paramArray.push(args[i])
                                    }
                                    let data = JSON.stringify({ "procName": func, "params": paramArray })
                                    ws.send(data)
                                }
                            }
                        }""")

        proc wsHandler(request: Request) =
            let ws = request.upgradeToWebSocket()
            wsVar = ws

        proc websocketHandler(
            websocket: WebSocket,
            event: WebSocketEvent,
            message: Message
          ) =
            case event:
            of OpenEvent:
                when not defined(release):
                    echo "App opened connection."
                openSockets = true
            of MessageEvent:
                spawn handleFrontEndData(message.data)
            of ErrorEvent:
                when not defined(release):
                    echo "Socket error: ", message
                spawn shutdown()
            of CloseEvent:
                when not defined(release):
                    echo "Socket closed."
                openSockets = false
                spawn shutdown()

        proc pathHandler(request: Request) =
            let path = parseUri(request.uri).path
            try:
                var headers: HttpHeaders
                headers["Cache-Control"] = "no-store"
                if "js" == path.split('.')[^1]: # forcing MIME-type to support JS modules
                    headers["Content-Type"] = "application/javascript"
                when not defined(release):
                    request.respond(200, headers, readFile(`webDirPath` / path))
                else:
                    request.respond(200,headers,Assets[path])
            except:
                raise newException(NeelError, "path: " & path & " doesn't exist")

 
        proc main =
            var router: Router
            router.get("/", indexHandler)
            router.get("/neel.js", jsHandler)
            router.get("/ws", wsHandler)
            router.get("/**", pathHandler)
            let server = newServer(router, websocketHandler)
            server.serve(Port(`portNo`))

        main()