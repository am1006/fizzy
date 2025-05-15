import { Controller } from "@hotwired/stimulus"
import { HttpStatus } from "helpers/http_helpers"
import { isMultiLineString } from "helpers/text_helpers";
import { marked } from "marked"

export default class extends Controller {
  static targets = [ "input", "form", "output", "confirmation", "recentCommands" ]
  static classes = [ "error", "confirmation", "help", "output", "busy" ]
  static values = { originalInput: String, waitingForConfirmation: Boolean }

  connect() {
    if (this.waitingForConfirmationValue) { this.focus() }
  }

  // Actions

  focus() {
    this.inputTarget.setSelectionRange(this.inputTarget.value.length, this.inputTarget.value.length)
    this.inputTarget.focus()
  }

  executeCommand(event) {
    if (this.#showHelpCommandEntered) {
      this.#showHelpMenu()
      event.preventDefault()
      event.stopPropagation()
    } else {
      this.#hideHelpMenu()
    }
  }

  hideMenus() {
    this.#hideHelpMenu()
    this.#hideOutput()
  }

  handleKeyPress(event) {
    if (this.waitingForConfirmationValue) {
      this.#handleConfirmationKey(event.key.toLowerCase())
      event.preventDefault()
    }
  }

  handleCommandResponse(event) {
    const response = event.detail.fetchResponse?.response

    if (event.detail.success) {
      this.#handleSuccessResponse(response)
    } else if (response) {
      this.#handleErrorResponse(response)
    }
  }

  restoreCommand(event) {
    const target = event.target.querySelector("[data-line]") || event.target
    if (target.dataset.line) {
      this.#reset(target.dataset.line)
      this.focus()
    }
  }

  hideError() {
    this.element.classList.remove(this.errorClass)
  }

  commandSubmitted() {
    this.element.classList.add(this.busyClass)
  }

  get #showHelpCommandEntered() {
    return [ "/help", "/?" ].includes(this.inputTarget.value)
  }

  #showHelpMenu() {
    this.element.classList.add(this.helpClass)
  }

  #hideHelpMenu() {
    if (this.#showHelpCommandEntered) { this.#reset() }
    this.element.classList.remove(this.helpClass)
  }

  get #isHelpMenuOpened() {
    return this.element.classList.contains(this.helpClass)
  }

  #handleSuccessResponse(response) {
    if (response.headers.get("Content-Type")?.includes("application/json")) {
      response.json().then((responseJson) => {
        this.#handleJsonResponse(responseJson)
      })
    }
    this.recentCommandsTarget.reload()
    this.#reset()
  }

  async #handleErrorResponse(response) {
    const status = response.status

    if (status === HttpStatus.UNPROCESSABLE) {
      this.#showError()
    } else if (status === HttpStatus.CONFLICT) {
      await this.#handleConflictResponse(response)
    }
  }

  #reset(inputValue = "") {
    this.inputTarget.value = inputValue
    this.confirmationTarget.value = ""
    this.waitingForConfirmationValue = false
    this.originalInputValue = null

    this.element.classList.remove(this.errorClass)
    this.element.classList.remove(this.confirmationClass)
    this.element.classList.remove(this.busyClass)
  }

  #showError() {
    this.element.classList.add(this.errorClass)
  }

  async #handleConflictResponse(response) {
    this.originalInputValue = this.inputTarget.value
    this.#handleJsonResponse(await response.json())
  }

  #handleJsonResponse(responseJson) {
    const { confirmation, message, redirect_to } = responseJson

    if (message) {
      this.#showOutput(message)
    }

    if (confirmation) {
      this.#requestConfirmation(confirmation)
    }

    if (redirect_to) {
      Turbo.visit(redirect_to)
    }
  }

  async #requestConfirmation(confirmationPrompt) {
    this.element.classList.add(this.confirmationClass)
    this.#showConfirmationPrompt(confirmationPrompt)
    this.waitingForConfirmationValue = true
  }

  #showConfirmationPrompt(confirmationPrompt) {
    if (isMultiLineString(confirmationPrompt)) {
      this.#showOutput(confirmationPrompt)
      this.inputTarget.value = `Do you confirm? [Y/n] `
    } else {
      this.inputTarget.value = `${confirmationPrompt}? [Y/n] `
    }
  }

  #handleConfirmationKey(key) {
    if (key === "enter" || key === "y") {
      this.#submitWithConfirmation()
    } else if (key === "escape" || key === "n") {
      this.#reset(this.originalInputValue)
      this.#hideOutput()
    }
  }

  #submitWithConfirmation() {
    this.inputTarget.value = this.originalInputValue
    this.confirmationTarget.value = "confirmed"
    this.#hideOutput()
    this.formTarget.requestSubmit()
    this.#reset()
  }

  #showOutput(markdown) {
    const html = marked.parse(markdown)
    this.element.classList.add(this.outputClass)
    this.outputTarget.innerHTML = html
  }

  #hideOutput(html) {
    this.element.classList.remove(this.outputClass)
  }
}
