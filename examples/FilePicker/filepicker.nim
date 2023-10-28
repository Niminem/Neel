# compile with: --threads:on and --gc:orc if using Nim 1.6.X
# add --app:gui if on Windows to get prevent terminal from opening (though useful for debugging)

import std/[os, random]
import neel

randomize()

exposeProcs:
    proc filePicker(directory: string) =
        let absPathDir = absolutePath(directory,root=getHomeDir())
        if dirExists(absPathDir):
            var files: seq[string]
            for kind, path in absPathDir.walkDir:
                files.add(path)
            callJs("showText",sample(files))
        else:
            callJs("showText", "The directory you chose does not exist.")

startApp(webDirPath= currentSourcePath.parentDir / "assets") # change path as necessary