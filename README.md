# Neel | HTML/JS GUI Library for Nim

Neel is a Nim library for making lightweight Electron-like HTML/JS GUI apps, with full access to Nim capabilities and targets any of the C, C++, or Objective-C backends.

> As of v0.0.1: Neel opens a new Chrome session in app mode and allows the Nim backend and HTML/JS frontend to communicate via JSON and websockets.

Neel is designed to take all the hassle out of writing GUI applications. Current Features:

* eliminate boilerplate code
* automatic routes
* automatic type conversions (from JSON to each proc’s param types)
* simple interface for backend/frontend communication
... this is just the beginning!

Neel is inspired by [Eel](https://github.com/samuelhwilliams/Eel), the Python library equivalent.

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

Neel applications consist of various web assets (html, css, js, etc.) and various Nim files.

All of the web assets need to be placed in a single directory (they can be further divided into folders inside it if necessary). **Make sure your directory is not named "public" as this does not play well with Jester.**

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

We'll begin with a simple example, from there I'll explain the process and each part in detail.

(main.nim)
```nim
import neel #1

exposeProcs: #2
    proc echoThis(jsMsg :string) =
        echo "got this from frontend: " & jsMsg
        callJs("logThis", "hello from Nim!" #3

start("index.html","assets",appMode=true) #4
```

##### #1 import neel

When importing neel, several modules are automatically exported into the calling module. `exposedProcs` and `start` is a macro and template that require these modules in order to work properly.

One of the modules includes `json`, which is needed should you have a params in your procedures that are of type `seq` or `table`. More on this below.

##### #2 exposeProcs

`exposeProcs` is a macro that *exposes* specific procedures for javascript to be able to call from the frontend. When the macro is expanded, it creates a procedure `callProc` which contains **all exposed procedures** and will call a specified procedure based on frontend data, and passing in the appropriate params (should there be any).

The data being received is initially **JSON** and needs to be converted into the appropriate types for each param in a procedure. This is also handled by the macro. Unfortunately, due to Nim's type system I'm limited on what's able to be converted.

Accepted types for any *exposed procedures* are:
* string, int, float, bool
* seq[JsonNode]
* OrderedTable[string, JsonNode]









