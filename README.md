# Neel | HTML/JS GUI Library for Nim

Neel is a Nim library for making lightweight Electron-like HTML/JS GUI apps, with full access to Nim capabilities and targets any of the C, C++, or Objective-C backends.

> By default, Neel opens a new Chrome session in app mode and allows the Nim backend and HTML/JS frontend to communicate via JSON and websockets. Alternate mode available, simply opening a new tab in your system's default browser. Webview capabilities coming soon.

Neel is designed to take all the hassle out of writing GUI applications. Current Features:

* Eliminate 99% of boilerplate code
* Automatic routes
* Embeds frontend assets at compiletime (on `release` builds)
* Automatic type conversions (from JSON to each procedure's parameter types)
* Simple interface for backend/frontend communication
* Cross-platform (tested on Mac, Windows, and Linux)

Neel is inspired by [Eel](https://github.com/samuelhwilliams/Eel), its Python cousin.

----------------------

## Introduction

Currently, Nim’s options for writing GUI applications are quite limited and if you wanted to use HTML/JS instead you can expect a lot of boilerplate code and headaches.

Neel is still in its infancy, so as of right now I don’t think it’s suitable for making full-blown commercial applications like Slack or Twitch. It is, however, very suitable for making all kinds of other projects and tools.

The best visualization libraries that exist are in Javascript and the most powerful capabilities of software can be harnessed with Nim. The goal of Neel is to combine the two languages and assist you in creating some killer applications.

## Installation

Install from nimble:
`nimble install neel`

## Usage

### Directory Structure

Currently, Neel applications consist of various static web assets (HTML,CSS,JS, etc.) and Nim modules.

All of the frontend files need to be placed within a single folder (they can be further divided into more folders within it if necessary). The starting URL must be named `index.html` and placed within the root of the web folder.

```
main.nim            <----\
database.nim        <-------- Nim files
other.nim           <----/
/assets/             <------- Web folder containing frontend files (can be named whatever you want)
  index.html        <-------- The starting URL for the application (**must** be named 'index.html' and located within the root of the web folder)
  /css/
    style.css
  /js/
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

startApp(webDirPath="path-to-web-assets-folder") #4
```

##### #1 import neel

When you `import neel`, several modules are exported into the calling module. `exposedProcs` and `startApp` are macros that require these modules in order to work properly. The list below are all of the exported modules. It's not necessary to remember them, and even if you accidently imported the module twice Nim disregards it. This is just for your reference really.
* `std/os`
* `std/osproc`
* `std/strutils`
* `std/json`
* `std/threadpool`
* `std/browsers`
* `std/jsonutils`
* `pkg/mummy`
* `pkg/routers`

##### #2 exposeProcs

`exposeProcs` is a macro that *exposes* specific procedures for javascript to be able to call from the frontend. When the macro is expanded, it creates a procedure `callNim` which contains **all exposed procedures** and will call a specified procedure based on frontend data, passing in the appropriate parameters (should there be any).

The data being received is initially **JSON** and needs to be converted into the appropriate types for each parameter in a procedure. This is also handled by the macro.

As of Neel 1.1.0, you can use virtually any Nim type for parameters in *exposed procedures*. Neel uses `std/jsonutils` to programmatically handle the conversions. Some caveats:
* Does not support default values for parameters.
* Does not support generics for parameters.

This above macro produces this result:

```nim
proc callNim(procName: string; params: seq[JsonNode]) =
    proc echoThis(jsMsg: string) =
        echo "got this from frontend: " & jsMsg
        callJs("logThis", "Hello from Nim!")
    case procName
    of "echoThis": echoThis(params[0].getStr)
    ...
```

NOTE: You *can* pass complex data in a single parameter now if you'd like to. Use Javascript objects or dictionaries and simply create a custom object type to accept it from the Nim side.

I'm sure this is obvious, but it's much cleaner to have your exposed procedures call procedures from other modules.

Example:
```nim
# (main.nim)
import neel, othermodule
exposeProcs:
    proc proc1(param: seq[JsonNode]) =
        doStuff(param[0].getInt)
...

# (othermodule.nim)
from neel import callJs # you only need to import this macro from Neel :)

proc doStuff*(param: int) =
    var dataForFrontEnd = param + 100
    callJs("myJavascriptFunc", dataForFrontEnd)
...
```

##### #3 callJs

`callJs` is a macro that takes in at least one value, a `string`, and it's *the name of the javascript function you want to call*. Any other value will be passed into that javascript function call on the frontend. You may pass in any amount to satisfy your function parameters needs like so:

```nim
callJs("myJavascriptFunc",1,3.14,["some stuff",1,9000])
```

The above code gets converted into stringified JSON and sent to the frontend via websocket.

##### #4 startApp

`startApp` is a macro that handles server logic, routing, and Chrome web browser. `startApp` currently takes 6 parameters.
example:

```nim
startApp(webDirPath= "path_to_web_assets_folder", portNo=5000,
            position= [500,150], size= [600,600], chromeFlags= @["--force-dark-mode"], appMode= true)
            # left, top          # width, height
```

* `webDirPath` : sets the path to the web directory containing all frontend assets **needs to be set**
* `portNo` : specifies the port for serving your application (default is 5000)
* `position` : positions the *top* and *left* side of your application window (default is 500 x 150)
* `size` : sets the size of your application window by *width* and *height*(default is 600 x 600)
* `chromeFlags` : passes any additional flags to chrome (default is none)
* `appMode` : if "true" (default) Chrome will open a new session/window in App mode, if "false" a new tab will be opened in your *current default browser* - which can be very useful for debugging.

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
    <script src="/neel.js"></script> <!-- always include /neel.js in your <head> -->
</head>
<body>
    <h1>My First Neel App</h1>
    <script src="/main.js"></script> <!-- always use absolute paths with web assets -->
</body>
</html>
```
(main.js)
```javascript
neel.callNim("echoThis","Hello from Javascript!")

function logThis(param){
    console.log(param)
}
```
The first thing you'll notice is we've included a script tag containing `/neel.js` in the <head> section of our HTML page. This allows Neel to handle all of the logic on the frontend for websocket connections and function/procedure calls.

`neel.callNim` is a function that takes in at least one value, a `string`, and it's *the name of the Nim procedure you want to call*. Any other value will be passed into that Nim procedure call on the backend asa parameter. **You must pass in the correct number of params for that proc, in order, and of the correct types for it to be called properly.** Example: 

frontend call to backend:
```javascript
neel.callNim("myNimProc",1,3.14,["some stuff",1,9000])
```
must match the result of the `exposeProcs` macro:
```nim
...
of "myNimProc": return myNimProc(params[0].getInt,params[1].getFloat,params[2].getElems)
...
```

As of Neel 1.1.0, there is exception handling in place (with a verbose logging in debug builds) for unknown procedure calls and parameter type mismatches.

Going back to our first example, when `index.html` is served, Javascript will call the `echoThis` procedure and pass "Hello from Javascript!" as the param. This will print the string in the terminal. Then, Nim will call the `logThis` function and pass "Hello from Nim!". Neel handles the JSON conversion, calls the function and passes in the param.

Now open the console in Chrome developer tools and you should see "Hello from Nim!".

**Keep In Mind: absolute paths must be used within your HTML files** ex: `<script src="/this_js_module.js></script>`

#### Compilation Step

If using nim 1.6.X branch, compile your Neel application with `--threads:on` and `--mm:orc`. *Nim >= 2.0.0 does this by default.*
example:
```nim
nim c -r --threads:on --mm:orc main.nim
```
When compiling for Windows, also pass the `--app:gui` flag on your `release` builds if you want to prevent the app opening up with a terminal.
example:
```nim
nim c -r --threads:on --mm:orc --app:gui -d:release main.nim
```

#### Final Thoughts Before Developing With Neel
Keep the following in mind when developing you Neel App:
* All of your frontend assets are embedded into the binary when compiling a `release` build. Stick to debug builds when needing to modify/change static frontend assets, as you can simply refresh a page and see the updates in real-time.
* To prevent crashes when users spam refresh or constantly switch between different pages, we implemented a sort of countdown timer for shutting down. For debug builds, approximately 3 seconds after closing the app window the server and program is shutdown if a websocket hasn't reconnected within that time period. For release builds that time delay is approximately 10 seconds for some extra cusion.

## Examples

A simple Neel app that picks a random filename out of a given folder (something impossible from a browser):

[Random File Picker](https://github.com/Niminem/Neel/tree/master/examples/FilePicker)

## Neel version 1.0.0 Newly Released 10/28/23

Neel now leverages the power of [Mummy](https://github.com/guzba/mummy) for websever / websocket needs. Mummy returns to the ancient way of threads, removing the need for async entirely. Historically Neel applications ran into async problems in certain situations. For example, try/except blocks were necessary in some exposed procedures yet using async procedures within an except block is a no go.

## Future Work

The vision for this library is to eventually have this as full-fledged as Electron for Nim. I believe it has the potential for developing commercial applications and maybe one day even rival Electron as a framework.

A BIG teaser for what's to come within the next few releases:

- [X] Arbitrary JavaScript-To-Nim Type Conversions (JSON Parsing)

      As long as the parameter types from the Javascript side match to the Nim side, use what you want!

- [ ] Webview Capabilities

      [Webview](https://github.com/webview/webview) is an MIT licensed cross-platform webview library for C/C++. Uses WebKit (GTK/Cocoa) and Edge WebView2 (Windows). Having a webview target will get us closer to solid framework for shipping commercial builds.

- [ ] Distributable Applications

      Build your Neel app and have it packaged and ready to be shipped.