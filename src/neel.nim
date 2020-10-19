import macros, jester, os, strutils, ws, ws/jester_extra, osproc, options, json, threadpool, browsers
export jester, os, strutils, ws, osproc, options, json, threadpool, browsers


type
    CustomError* = object of Exception


# ------------- TRANSFORMATIONS & TYPE CONVERSION LOGIC ----------------

const PARAMTYPES* = ["string","int","float","bool","OrderedTable[string, JsonNode]", "seq[JsonNode]"]

macro callJs*(funcName: string, params: varargs[typed]): untyped =
    quote do:
        some(%*{"funcName":`funcName`,"params":`params`})
   
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

proc exposedProcs*(procs: NimNode): NimNode =
    
    for procedure in procs.children:
        #setting the return type
        procedure[3][0] = nnkBracketExpr.newTree(
                newIdentNode("Option"),
                newIdentNode("JsonNode")
            )
    result = procs   

proc ofStatements*(procedure: NimNode): NimNode =

    if procedure[3].len == 1:#handles procedure w/ empty params (formalParams has one child of kind nnkEmpty)
        result = nnkOfBranch.newTree(
                newLit(procedure[0].repr), #name of proc
                nnkStmtList.newTree(
                    nnkReturnStmt.newTree(
                            nnkCall.newTree(
                                newIdentNode(procedure[0].repr) #name of proc
                    ))))
    else:
        result = nnkOfBranch.newTree()
        result.add newLit(procedure[0].repr) #name of proc
        var
            statementList = nnkStmtList.newTree()
            returnStatement = nnkReturnStmt.newTree()
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
                    paramId.add "getElems"
                of "OrderedTable[string, JsonNode]":
                    paramId.add "getFields"

                procCall.add nnkDotExpr.newTree(
                    nnkBracketExpr.newTree(
                    newIdentNode("params"),
                    newLit(paramIndex)),
                    newIdentNode(paramId))

                inc paramIndex

        returnStatement.add procCall
        statementList.add returnStatement
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
            newIdentNode("callProc"),
            newEmptyNode(),
            newEmptyNode(),
            nnkFormalParams.newTree(
            nnkBracketExpr.newTree(
                newIdentNode("Option"),
                newIdentNode("JsonNode")
            ),
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
            exposedProcs(procs), #performs transformations on procs defined in this macro
            caseStatement(procs) #converts types into proper json parsing & returns case statement logic
            ))

# ----------------------------------------------------------------------



# ----------------------- BROWSER LOGIC --------------------------------

proc findChromeMac*: string =
    const defaultPath :string = r"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    if fileExists(absolutePath(defaultPath)):
        result = defaultPath.replace(" ", r"\ ")
    else: # include a recursive search in future version to account for any location
        raise newException(CustomError, "could not find Chrome in Applications directory")

proc findChromeWindows*: string =
    #const defaultPath = r"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe" # for registery
    const defaultPath = r"\Program Files (x86)\Google\Chrome\Application\chrome.exe"
    if fileExists(absolutePath(defaultPath)):
        result = defaultPath
    else: # include registry search in future versions to account for any location
        raise newException(CustomError, "could not find Chrome in Program Files (x86) directory")

proc findPath*: string =
    when hostOS == "macosx":
        result = findChromeMac()
    elif hostOS == "windows":
        result = findChromeWindows()
    elif hostOS == "linux":
        result = "google-chrome "
        # include a search in future version to account for the other possible locations for linux
    else:
        raise newException(CustomError, "unkown OS in findPath() for neel.nim")

proc openChrome*(portNo: int, chromeFlags: seq[string]) =
    var chromeStuff = " --app=http://localhost:" & portNo.intToStr & "/ --disable-http-cache"
    if chromeFlags != @[""]:
        for flag in chromeFlags:
            chromeStuff = chromeStuff & " " & flag.strip
    let command = findPath() & chromeStuff
    if execCmd(command) != 0:
        raise newException(CustomError,"could not open Chrome browser")

# ----------------------------------------------------------------------



# ---------------------------- SERVER LOGIC ----------------------------

macro startApp*(startURL, assetsDir: string, portNo: int = 5000,
                    position: array[2, int] = [500,150], size: array[2, int] = [600,600],
                        chromeFlags: seq[string] = @[""], appMode: bool = true) =

    quote do:

        const NOCACHE_HEADER = @[("Cache-Control","no-store")]
        var openSockets: bool

        proc detectShutdown =
            sleep(1200)#what is the best time?
            if not openSockets:
                quit()

        if not `appMode`:
            spawn openDefaultBrowser("http://localhost:" & $`portNo` & "/")
        else:
            spawn openChrome(portNo=`portNo`, chromeFlags=`chromeFlags`)

        router myrouter:
            get "/":
                resp(Http200,NOCACHE_HEADER,readFile(getCurrentDir() / `assetsDir` / `startURL`))#is this most efficient?
            get "/neel.js":
                resp "window.moveTo(" & $`position`[0] & "," & $`position`[1] & ")\n" &
                        "window.resizeTo(" & $`size`[0] & "," & $`size`[1] & ")\n" &
                        "var ws = new WebSocket(\"ws://localhost:" & $`portNo` & "/ws\")\n" &
                        """var connected = false
                        ws.onmessage = (data) => {
                            try {
                                let x = JSON.parse(data.data)
                                let v = Object.values(x)
                                neel.callJs(v[0], v[1])
                            } catch (err) {
                                let x = JSON.parse(data)
                                let v = Object.values(x)
                                neel.callJs(v[0], v[1])
                            }
                        }
                        var neel = {
                            callJs: function (func, arr) {
                                window[func].apply(null, arr);
                            },
                            callProc: function (func, ...args) {
                                if (!connected) {
                                    function check(func, ...args) { if (ws.readyState == 1) { connected = true; neel.callProc(func, ...args); clearInterval(myInterval); } }
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
                        }"""
                        
            get "/ws":
                try:
                    var ws = await newWebSocket(request)
                    while ws.readyState == Open:
                        openSockets = true
                        let
                            jsData = await ws.receiveStrPacket
                            nimData = callProc(jsData.parseJson)
                        if not nimData.isNone:
                            await ws.send($nimData.get)
                except WebSocketError:
                    openSockets = false
                    spawn detectShutdown()

            get "/@path": #get re".*": #can't use re within a templates/macro here, why?
                try:
                    resp(Http200,NOCACHE_HEADER,readFile(getCurrentDir() / `assetsDir` / request.path))
                except:
                    raise newException(CustomError, "path: " & request.path & " doesn't exist") #is this proper?
            # below are exact copies of route above, supporting static files up to 5 directories deep
            # ***review later for better implementation & reduce code duplication***
            get "/@path/@path2":
                try:
                    resp(Http200,NOCACHE_HEADER,readFile(getCurrentDir() / `assetsDir` / request.path))
                except:
                    raise newException(CustomError, request.path & " doesn't exist")
            get "/@path/@path2/@path3":
                try:
                    resp(Http200,NOCACHE_HEADER,readFile(getCurrentDir() / `assetsDir` / request.path))
                except:
                    raise newException(CustomError, request.path & " doesn't exist")
            get "/@path/@path2/@path3/@path4":
                try:
                    resp(Http200,NOCACHE_HEADER,readFile(getCurrentDir() / `assetsDir` / request.path))
                except:
                    raise newException(CustomError, request.path & " doesn't exist")
            get "/@path/@path2/@path3/@path4/@path5":
                try:
                    resp(Http200,NOCACHE_HEADER,readFile(getCurrentDir() / `assetsDir` / request.path))
                except:
                    raise newException(CustomError, request.path & " doesn't exist")
            get "/@path/@path2/@path3/@path4/@path5/@path6":
                try:
                    resp(Http200,NOCACHE_HEADER,readFile(getCurrentDir() / `assetsDir` / request.path))
                except:
                    raise newException(CustomError, request.path & " doesn't exist")
        
        proc main =
            let settings = newSettings(`portNo`.Port)
            var jester = initJester(myrouter, settings=settings)
            jester.serve
        
        main()
