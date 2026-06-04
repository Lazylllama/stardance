import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static values = { itemId: String, wishlisted: Boolean };

  toggle(event) {
    event.preventDefault();
    event.stopPropagation();

    const wasWishlisted = this.wishlistedValue;
    this.wishlistedValue = !wasWishlisted;

    const method = wasWishlisted ? "DELETE" : "POST";
    const csrfToken = document.querySelector(
      'meta[name="csrf-token"]',
    )?.content;

    fetch(`/shop/wishlists/${this.itemIdValue}`, {
      method,
      headers: {
        "X-CSRF-Token": csrfToken,
        Accept: "text/vnd.turbo-stream.html",
      },
    }).then((r) => {
      if (!r.ok) this.wishlistedValue = wasWishlisted;
      else {
        r.text().then((html) => Turbo.renderStreamMessage(html));
        this.dispatch("changed", {
          detail: {
            itemId: this.itemIdValue,
            wishlisted: this.wishlistedValue,
          },
        });
      }
    });
  }

  remove(event) {
    event.preventDefault();
    event.stopPropagation();

    this.wishlistedValue = false;

    const csrfToken = document.querySelector(
      'meta[name="csrf-token"]',
    )?.content;

    fetch(`/shop/wishlists/${this.itemIdValue}`, {
      method: "DELETE",
      headers: {
        "X-CSRF-Token": csrfToken,
        Accept: "text/vnd.turbo-stream.html",
      },
    }).then((r) => {
      if (!r.ok) this.wishlistedValue = true;
      else {
        r.text().then((html) => Turbo.renderStreamMessage(html));
        this.dispatch("changed", {
          detail: { itemId: this.itemIdValue, wishlisted: false },
        });
      }
    });
  }

  sync(event) {
    const { itemId, wishlisted } = event.detail;
    if (itemId !== this.itemIdValue) return;

    this.wishlistedValue = wishlisted;
  }

  wishlistedValueChanged() {
    this.element.classList.toggle(
      "shop-item-card--wishlisted",
      this.wishlistedValue,
    );
  }
}
