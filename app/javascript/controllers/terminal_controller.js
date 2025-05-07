import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "input" ]
  static classes = [ "error" ]

  // Actions

  focus() {
    this.inputTarget.focus()
  }

  handleSubmit(event) {
    if (event.detail.success) {
      event.target.reset()
    } else {
      this.#handleErrorResponse(event.detail.fetchResponse.response.status)
    }
  }

  #handleErrorResponse(code) {
    if (code == 422) {
      this.element.classList.add(this.errorClass)
    }
  }
}
