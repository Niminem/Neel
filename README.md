# Neel | HTML/JS GUI Library for Nim

Neel is a Nim library for making lightweight Electron-like HTML/JS GUI apps, with full access to Nim capabilities and targets any of the C, C++, or Objective-C backends.

> As of v0.1.0: Neel opens a new Chrome session in app mode and allows the Nim backend and HTML/JS frontend to communicate via JSON and websockets.

Neel is designed to take all the hassle out of writing GUI applications. Current Features:

* Eliminate boilerplate code
* Automatic routes
* Automatic type conversions (from JSON to each proc’s param types)
* Simple interface for backend/frontend communication
* Cross-platform (physically tested on Mac, Windows, and Linux)

Neel is inspired by [Eel](https://github.com/samuelhwilliams/Eel), its Python cousin.

----------------------

## Introduction

Currently, Nim’s options for writing GUI applications are quite limited, and if you wanted to use HTML/JS instead, there’s a lot of boilerplate code and Nim’s type system doesn’t make things any easier.

Neel is still in its infancy, so as of right now I don’t think it’s suitable for making full-blown commercial applications like Slack or Twitch. It is, however, very suitable for making all kinds of other projects and tools.

The best visualization libraries that exist are in Javascript and the most powerful capabilities of software can be harnessed with Nim- math, machine learning, etc. The goal of Neel is to combine the two languages and assist you in creating some killer applications.

## Installation

Install from nimble:
`nimble install neel`

## Usage

### Directory Structure

Neel applications consist of various web assets (HTML,CSS,JS, etc.) and various Nim files.

All of the web assets need to be placed in a single directory (they can be further divided into folders inside it if necessary). **Make sure your directory is not named "public" as this does not play well with the Jester module.**

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
import Neel #Make sure this is an uppercase N   #1

exposeProcs: #2
    proc echoThis(jsMsg :string) =
        echo "got this from frontend: " & jsMsg
        callJs("logThis", "Hello from Nim!") #3

startApp("index.html","assets",appMode=true) #4
```

##### #1 import neel

When importing neel, several modules are automatically exported into the calling module. `exposedProcs` and `start` is a macro and template that require these modules in order to work properly.

One of the modules includes `json`, which is needed should you have params in your procedures that are of type `seq` or `table`. More on this below.

##### #2 exposeProcs

`exposeProcs` is a macro that *exposes* specific procedures for javascript to be able to call from the frontend. When the macro is expanded, it creates a procedure `callProc` which contains **all exposed procedures** and will call a specified procedure based on frontend data, passing in the appropriate params (should there be any).

The data being received is initially **JSON** and needs to be converted into the appropriate types for each param in a procedure. This is also handled by the macro. Unfortunately, due to Nim's type system there's a limit on what's able to be converted programmatically.

Accepted param types for all *exposed procedures* are:
* string, int, float, bool
* seq[JsonNode]
* OrderedTable[string, JsonNode]

This above macro produces this result:

```nim
proc callProc(jsData :JsonNode) :Option[JsonNode] =
    var
        procName = jsData["procName"].getStr
        params = jsData["params"].getElems
    case procName
    of "echoThis": return echoThis(params[0].getStr)
```

Don't worry, you're still able to pass complex data as your params if need be, such as a `seq` within a `seq` containing a `table` of arbitrary types. Just have that param be either of type `seq[JsonNode]` or `OrderedTable[string, JsonNode]` and manually convert them within your procedure. Converting JSON is very simple, refer to the [documentation](https://nim-lang.org/docs/json.html).

I'm sure this is obvious, but it's much cleaner to have your exposed procedures call procedures from other modules.
Example:
```nim
exposeProcs:
    proc proc1(param :seq[JsonNode]) =
        doStuff(param)
```
Just make sure that **ALL** procedures that stem from an exposed procedure is of type `Option[JsonNode]` *unless* the final procedure **will not** be calling javascript. This will make more sense below.

##### #3 callJs

`callJs` is a template that takes in at least one value, a `string`, and it's *the name of the javascript function you want to call*. Any other value will be passed into that javascript function call on the frontend. You may pass in any amount like so:

```nim
callJs("myJavascriptFunc",1,3.14,["some stuff",1,9000])
```

The above code gets converted into JSON and returned via the `some()` procedure (part of the [Options module](https://nim-lang.org/docs/options.html)). All procedures that stem from an exposed procedure need to be of type `Option[JsonNode]` **if** the the final procedure is calling javascript.

##### #5 startApp

`startApp` is a template that handles server logic, routing, and Chrome web browser. As of v0.1.0, the `startApp` template takes 3 params:
```nim
startApp(startURL,assetsDir :string, appMode :bool = true)
```

`startURL` is the name of the file you want Chrome to open.
`assetsDir` is the name of your web assets folder.
`appMode` if "true" (default) Chrome will open a new session/window in App mode, if "false" a new tab will be opened in your **current default browser** - which can be very useful for debugging.

As of v0.1.0, Neel will start a local webserver at http://localhost:5000/ (option to change ports coming v0.2.0)

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

`callProc` is a function that takes in at least one value, a `string`, and it's *the name of the Nim procedure you want to call*. Any other value will be passed into that Nim procedure call on the backend. **You must pass in the correct number of params for that proc, in order, and of the correct types.**. Example: 

frontend call to backend:
```javascript
neel.callProc("myNimProc",1,3.14,["some stuff",1,9000])
```
must match the result of the `exposeProcs` macro:
```nim
of "myNimProc": return myNimProc(params[0].getInt,params[1].getFloat,params[2].getElems)
```

Going back to our first example, when `index.html` is served, Javascript will call the `echoThis` procedure and pass "Hello from Javascript!" as the param. This echo the string in the terminal. immediately, Nim will call the `logThis` function and pass "Hello from Nim!". Neel handles the JSON conversion, calls the function and passes in the param. Now open the console in Chrome developer tools and you should see "Hello from Nim!".

#### Compilation Step

When compiling your Neel application, make sure you compile with `--threads:on`
example:
```nim
nim c -r --threads:on main.nim
```

## Documentation
coming soon
## Examples
coming soon
## Future Work

I have a huge vision for this library. Eventually, the goal is to have this as full-fledged as Electron for Nim. I believe this has the potential for developing commercial applications and perhaps even rival Electron as a framework.

In my opinion, Nim is the best programming language in existence at the moment. My hope is also that while Neel improves in its development, Nim can get exposure that it rightfully deserves.

Neel will receive updates at least once per month, beginning with v0.2.0 by the end of October with plenty of improvements and added features.
