# Neel | HTML/JS GUI Library for Nim

Neel is a Nim library for making lightweight Electron-like HTML/JS GUI apps, with full access to Nim capabilities and targets any of the C, C++, or Objective-C backends.

> As of v0.2.0: Neel opens a new Chrome session in app mode and allows the Nim backend and HTML/JS frontend to communicate via JSON and websockets.

Neel is designed to take all the hassle out of writing GUI applications. Current Features:

* Eliminate 99% of boilerplate code
* Automatic routes
* Automatic type conversions (from JSON to each proc’s param types)
* Simple interface for backend/frontend communication
* Cross-platform (tested on Mac, Windows, and Linux)

Neel is inspired by [Eel](https://github.com/samuelhwilliams/Eel), its Python cousin.

----------------------

## Introduction

Currently, Nim’s options for writing GUI applications are quite limited and if you wanted to use HTML/JS instead you can expect a lot of boilerplate code and headaches.

Neel is still in its infancy, so as of right now I don’t think it’s suitable for making full-blown commercial applications like Slack or Twitch. It is, however, very suitable for making all kinds of other projects and tools.

The best visualization libraries that exist are in Javascript and the most powerful capabilities of software can be harnessed with Nim- math, machine learning, etc. The goal of Neel is to combine the two languages and assist you in creating some killer applications.

## Installation

Install from nimble:
`nimble install neel`

## Usage

### Directory Structure

Neel applications consist of various web assets (HTML,CSS,JS, etc.) and various Nim files.

All of the web assets need to be placed in a single directory (they can be further divided into folders inside it if necessary). **As of v0.2.0, Neel serves static files up to 5 directories deep.**

```
main.nim            <---- Nim files
database.nim
other.nim
webAssetsFolder/    <---- Web assets folder
  index.html
  css/
    style.css
  js/
    main.js
```

### Developing the Application

#### Nim / Backend

We begin with a very simple example, from there I'll explain the process and each part in detail.

(main.nim)
```nim
import neel #1

exposeProcs: #2
    proc echoThis(jsMsg: string) =
        echo "got this from frontend: " & jsMsg
        callJs("logThis", "Hello from Nim!") #3

startApp(startURL="index.html",assetsDir="web") #4
```

##### #1 import neel

When you `import neel`, several modules are exported into the calling module. `exposedProcs` and `startApp` are macros that require these modules in order to work properly.

One of the exported modules includes `json`, which is needed should you have params in your procedures that are of type `seq` or `table`. More on this below.

##### #2 exposeProcs

`exposeProcs` is a macro that *exposes* specific procedures for javascript to be able to call from the frontend. When the macro is expanded, it creates a procedure `callProc` which contains **all exposed procedures** and will call a specified procedure based on frontend data, passing in the appropriate params (should there be any).

The data being received is initially **JSON** and needs to be converted into the appropriate types for each param in a procedure. This is also handled by the macro. Unfortunately, due to Nim's static type system there's a limit on what's able to be converted programmatically.

Accepted param types for all *exposed procedures* are:
* string, int, float, bool
* seq[JsonNode]
* OrderedTable[string, JsonNode]

This above macro produces this result:

```nim
proc callProc(jsData: JsonNode) =
    var
        procName = jsData["procName"].getStr
        params = jsData["params"].getElems
    case procName
    of "echoThis": echoThis(params[0].getStr)
```

Don't worry, you're still able to pass complex data as your params if need be, such as a `seq` within a `seq` containing a `table` of arbitrary types. Just have that param be either of type `seq[JsonNode]` or `OrderedTable[string, JsonNode]` and manually convert them within your procedure. Converting JSON is very simple, refer to the [documentation](https://nim-lang.org/docs/json.html).

I'm sure this is obvious, but it's much cleaner to have your exposed procedures call procedures from other modules.
Example:
```nim
exposeProcs:
    proc proc1(param: seq[JsonNode]) =
        doStuff(param[0].getInt)
```

**As of v0.3.0, you may freely call JavaScript within procedures in other modules you are using by simply importing the `callJs` macro**

**As of v0.3.0, you no longer need to declare `Option[JsonNode]` as the return type of any of your exposed procedures, or procedures calling JavaScript**

Example:
(othermodule.nim)
```nim
from neel import callJs #you only need to import this macro from Neel :)

proc doStuff(param: int) =
    var dataForFrontEnd = param + 100
    callJs("myJavascriptFunc", dataForFrontEnd)
```

##### #3 callJs

`callJs` is a macro that takes in at least one value, a `string`, and it's *the name of the javascript function you want to call*. Any other value will be passed into that javascript function call on the frontend. You may pass in any amount to satisfy your function parameters needs like so:

```nim
callJs("myJavascriptFunc",1,3.14,["some stuff",1,9000])
```

The above code gets converted into stringified JSON and sent to the frontend via websocket

**As of v0.3.0, `callJs` does not act as a return value for a procedure. You may freely make frontend calls where you want, and as many times as you want within your procedures**


##### #5 startApp

`startApp` is a macro that handles server logic, routing, and Chrome web browser. As of v0.2.0, `startApp` takes 7 params.
example:
```nim
startApp(startURL="index.html",assetsDir="web",portNo=8000,
            position= [500,150], size= [600,600], chromeFlags= @["--force-dark-mode"], appMode= true)
            # left, top          # width, height
```

* `startURL` : name of the file you want Chrome/Browser to open.
* `assetsDir` : name of your web assets folder.
* `portNo` : specifies the port for serving your application (default is 5000)
* `position` : positions the *top* and *left* side of your application window (default is 500 x 150)
* `size` : sets the size of your application window by *width* and *height*(default is 600 x 600)
* `chromeFlags` : passes any additional flags to chrome
* `appMode` : if "true" (default) Chrome will open a new session/window in App mode, if "false" a new tab will be opened in your **current default browser** - which can be very useful for debugging.

#### Javascript / Frontend

The Javascript aspect of a Neel app isn't nearly as complex. Let's build the frontend for the example above:

(index.html)
```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Neel App Example</title>
    <script src="neel.js"></script> <!-- always include neel.js in your <head>! -->
</head>
<body>
    <h1>My First Neel App</h1>
    <script src="main.js"></script>
</body>
</html>
```
(main.js)
```javascript
neel.callProc("echoThis","Hello from Javascript!")

function logThis(param){
    console.log(param)
}
```
The first thing you'll notice is we've included a script tag containing `neel.js` in the <head> section of our HTML page. This allows Neel to handle all of the logic on the frontend for websocket connections and function/procedure calls.

`callProc` is a function that takes in at least one value, a `string`, and it's *the name of the Nim procedure you want to call*. Any other value will be passed into that Nim procedure call on the backend. **You must pass in the correct number of params for that proc, in order, and of the correct types.** Example: 

frontend call to backend:
```javascript
neel.callProc("myNimProc",1,3.14,["some stuff",1,9000])
```
must match the result of the `exposeProcs` macro:
```nim
of "myNimProc": return myNimProc(params[0].getInt,params[1].getFloat,params[2].getElems)
```

Going back to our first example, when `index.html` is served, Javascript will call the `echoThis` procedure and pass "Hello from Javascript!" as the param. This will echo the string in the terminal. Then, Nim will call the `logThis` function and pass "Hello from Nim!". Neel handles the JSON conversion, calls the function and passes in the param.

Now open the console in Chrome developer tools and you should see "Hello from Nim!".

#### Compilation Step

When compiling your Neel application, make sure you compile with `--threads:on`
example:
```nim
nim c -r --threads:on main.nim
```

## Documentation
coming soon
## Examples

A simple Neel app that picks a random filename out of a given folder (something impossible from a browser):

[Random File Picker](https://github.com/Niminem/Neel/tree/master/examples)

## Future Work

The vision for this library is to eventually have this as full-fledged as Electron for Nim. I believe it has the potential for developing commercial applications and maybe one day even rival Electron as a framework.

Neel v0.4.0 will be released over the next month or two with plenty of improvements and added features.

A BIG teaser for what's to come:

### Distributable Applications

Build your Neel app and have it packaged and ready to be shipped. Supporting Windows, Mac, and Linux.

**We're accepting help with the project! Feel free to email me at leon.l.lysak@gmail.com**
