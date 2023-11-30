import happyx


component Task:
  text: string
  checked: bool

  `template`:
    tDiv:
      class := (
        if self.checked:
          "px-4 py-1 rounded-md bg-green-200 text-neutral-700 flex justify-center items-center cursor-pointer"
        else:
          "px-4 py-1 rounded-md bg-red-200 text-neutral-700 flex justify-center items-center cursor-pointer"
      )
      {self.text}
      @click:
        self.checked = not self.checked
