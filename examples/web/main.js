function sendDir() {
    const directory = document.getElementById("directory").value
    neel.callProc("filePicker",directory)
}

function showText(text) {
    document.getElementById("text").innerHTML = text
}
