import std/[macros, os, strutils, osproc, json, threadpool, browsers, uri, tables, jsonutils]
import pkg/[mummy, mummy/routers]
import chrome
export os, strutils, osproc, json, threadpool, browsers, jsonutils, mummy, routers


# ------------ EMBED STATIC ASSETS LOGIC -----------------------------

proc getWebFolder*(webDirPath: string): Table[string, string] {.compileTime.} =
    for path in walkDirRec(webDirPath,relative=true):
        if path == "index.html":
            result["/"] = staticRead(webDirPath / path)
        else:
            result["/" & path.replace('\\','/')] = staticRead(webDirPath / path)

# ----------------------------------------------------------------------


# ------------- TRANSFORMATIONS & TYPE CONVERSION LOGIC ----------------

var frontendSocket*: WebSocket #

macro callJs*(funcName: string, params: varargs[untyped]) =
    quote do:
        frontendSocket.send($(%*{"funcName":`funcName`,"params":[`params`]}))

proc validation*(procs: NimNode) =

    for procedure in procs.children:

        procedure.expectKind(nnkProcDef) #each has to be a proc definition
        procedure[3][0].expectKind(nnkEmpty) #there should be no return type
        procedure[4].expectKind(nnkEmpty) #there should be no pragma

        for param in procedure.params:
            if param.kind != nnkEmpty:
                param[2].expectKind(nnkEmpty) # default value for parameters should be empty

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
        procCall.add newIdentNode(procedure[0].repr) #name of proc

        var idx = 0
        for param in procedure.params:
            if param.kind == nnkEmpty: continue # the first argument here is return type for proc (which must be empty)
            let paramType = param[1]
            procCall.add(
                nnkCall.newTree(nnkDotExpr.newTree(
                    nnkBracketExpr.newTree(
                        newIdentNode("params"),newLit(idx)),newIdentNode("jsonTo")),
                    paramType))
            idx += 1

        statementList.add procCall
        result.add statementList

proc caseStatement*(procs: NimNode): NimNode =

    result = nnkCaseStmt.newTree()
    result.add newIdentNode("procName")

    for procedure in procs:
        result.add ofStatements(procedure) #converts proc param types for parsing json data & returns "of" statements

    result.add nnkElse.newTree( # else statement for handling unknown procedure call from frontend
        nnkStmtList.newTree(
            nnkWhenStmt.newTree(
            nnkElifBranch.newTree(
                nnkPrefix.newTree(
                newIdentNode("not"),
                nnkCall.newTree(
                    newIdentNode("defined"),
                    newIdentNode("release"))),
                nnkStmtList.newTree(
                nnkCommand.newTree(
                    newIdentNode("echo"),
                    nnkInfix.newTree(
                    newIdentNode("&"),
                    newLit("Uknown procedure called from frontend: "),
                    newIdentNode("procName"))))),
            nnkElse.newTree(
                nnkStmtList.newTree(
                nnkDiscardStmt.newTree(
                    newEmptyNode()))))))

macro exposeProcs*(procs: untyped) = #macro has to be untyped, otherwise callJs() expands & causes a type error
    procs.validation() #validates procs passed into the macro

    result = nnkProcDef.newTree(
            newIdentNode("callNim"),
            newEmptyNode(),
            newEmptyNode(),
            nnkFormalParams.newTree(
                newEmptyNode(),
                nnkIdentDefs.newTree(newIdentNode("procName"), newIdentNode("string"), newEmptyNode()),
                nnkIdentDefs.newTree(newIdentNode("params"), nnkBracketExpr.newTree(newIdentNode("seq"),newIdentNode("JsonNode")), newEmptyNode())
                ),
            newEmptyNode(),
            newEmptyNode(),
            nnkStmtList.newTree(
                procs,
                caseStatement(procs) # converts types into proper json parsing & returns case statement logic
                )
            )

    # echo result.repr # for testing macro expansion

# ----------------------------------------------------------------------

# ---------------------------- SERVER LOGIC ----------------------------

macro startApp*(webDirPath: string, portNo: int = 5000,
                    position: array[2, int] = [500,150], size: array[2, int] = [600,600],
                        chromeFlags: seq[string] = @[""], appMode: bool = true) =
    quote do:
        when defined(release):
            const Assets = getWebFolder(`webDirPath`)
        var
            openSockets: bool
            server: Server

        proc handleFrontEndData*(frontEndData :string) {.gcsafe.} =
            let
                frontendDataJson = frontendData.parseJson
                procName = frontendDataJson["procName"].getStr
                params = frontendDataJson["params"].getElems
            try:
                callNim(procName, params)
            except:
                when not defined(release):
                    echo "\nError from Javascript call to Nim.\nFunction: " & procName & "\nParameters: " & $params
                    echo "ERROR [" & $(getCurrentException().name) & "] Message: " & getCurrentExceptionMsg()
                else: discard

        proc shutdown = # quick implementation to reduce crashing from users spamming refresh / clicking on new pages
            const maxTime = when defined(release): 10 else: 3 # update: long delay applies to release builds
            for i in 1 .. maxTime:
                sleep 1000
                if openSockets: return
                when not defined(release): echo "Trying to re-establish a connection: " & $i & "/" & $maxTime
            if not openSockets:
                when not defined(release): echo "Shutting down."
                server.close()
                # quit()

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
            frontendSocket = ws

        proc websocketHandler(websocket: WebSocket, event: WebSocketEvent, message: Message) =
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
                else: discard
                # spawn shutdown() # 11/1/23: I don't think we need to spawn a shutdown.
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
                raise newException(ValueError, "path: " & path & " doesn't exist")

        var router: Router
        router.get("/", indexHandler)
        router.get("/neel.js", jsHandler)
        router.get("/ws", wsHandler)
        router.get("/**", pathHandler)
        server = newServer(router, websocketHandler)
        server.serve(Port(`portNo`))