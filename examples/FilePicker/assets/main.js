function sendDir() {
    const directory = document.getElementById("directory").value
    neel.callNim("filePicker", directory)
}

function showText(fileName) {
    document.getElementById("fileName").innerHTML = fileName
}