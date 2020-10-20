function sendDir() {
    const directory = document.getElementById("directory").value
    neel.callProc("filePicker",directory)
}

function showText(text,text2) {
    document.getElementById("text").innerHTML = text
}
