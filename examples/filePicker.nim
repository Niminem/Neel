import neel, os, random

exposeProcs:
    proc filePicker(directory: string) =

        let absPathDir = absolutePath(directory,root=getHomeDir())

        if dirExists(absPathDir):
            randomize() 

            var files :seq[string]
            for kind, path in absPathDir.walkDir:
                files.add(path)

            callJs("showText",sample(files))

        else:
            callJs("showText", "The directory you chose does not exist. Does it stem from the Home Directory?")


startApp(startURL="index.html",assetsDir="web",size=[400,250])
