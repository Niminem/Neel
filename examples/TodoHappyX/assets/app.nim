import happyx
import components/task


type
  TodoItem = object
    text: cstring
    checked: bool


var
  item: cstring
  items: seq[TodoItem] = @[]


appRoutes "app":
  "/":
    tDiv(class = "flex flex-col w-screen h-screen jusfity-center items-center"):
      tP(class = "text-5xl"): "HappyX TODO App"
      tDiv(class = "flex py-2"):
        tInput(placeholder = "edit item ..."):
          @input(event):
            item = event.target.value
        tButton:
          "Add item"
          @click:
            # Add TODO items
            items.add(TodoItem(text: item, checked: false))
            # Send data to Neel side
            buildJs:
              neel.callNim("addNewItem", ~item)
            item = cstring""
            route("/")
      tDiv(class = "flex flex-col gap-2"):
        for i in items:
          Task($i.text, i.checked)
