# compile with: --threads:on and --gc:orc if using Nim 1.6.X
# add --app:gui if on Windows to get prevent terminal from opening (though useful for debugging)

import
  std/[os, random],
  neel


type
  TodoItem = object
    text: string
    checked: bool


var items: seq[TodoItem] = @[]


exposeProcs:
  proc addNewItem(text: string) =
    echo text
    {.gcsafe.}:
      items.add(TodoItem(text: text, checked: false))


# Compile HappyX
assert 0 == execShellCmd"nim js assets/app.nim"

# Start Neel app
startApp(webDirPath= currentSourcePath.parentDir / "assets") # change path as necessary

echo "So after exit we have these items:"
echo items
