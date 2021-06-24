# compile with: --app:gui --threads:on

import neel, os, random

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
            callJs("showText", "The directory you chose does not exist")

startApp(size=[400,250])