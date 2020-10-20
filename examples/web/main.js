function sendDir() {
    const directory = document.getElementById("directory").value
    neel.callProc("filePicker",directory)
}

function showText(fileName) {
    document.getElementById("fileName").innerHTML = fileName
}
