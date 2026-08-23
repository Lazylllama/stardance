import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["card"];

  close() {
    this.element.remove();
  }

  connect() {
    showModal()
  }

  backdropClose(event) {
    if (this.hasCardTarget && this.cardTarget.contains(event.target)) return;
    this.close();
  }

  
}
