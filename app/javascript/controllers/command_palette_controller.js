import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["input", "item", "dynamicJumpResults", "dynamicJumpList", "dynamicResults", "dynamicList", "dynamicProjectResults", "dynamicProjectList", "dynamicMissionResults", "dynamicMissionList"];
  static values = { userSearchUrl: String, projectSearchUrl: String, missionSearchUrl: String };

  connect() {
    this._activeIndex = -1;
    this._searchTimer = null;
    this._boundGlobalKey = this._globalKey.bind(this);
    document.addEventListener("keydown", this._boundGlobalKey);
  }

  disconnect() {
    document.removeEventListener("keydown", this._boundGlobalKey);
  }

  _globalKey(event) {
    const trigger = navigator.platform.toUpperCase().includes("MAC")
      ? event.metaKey
      : event.ctrlKey;
    if (trigger && event.key === "k") {
      event.preventDefault();
      this.element.showModal();
      this.inputTarget.select();
    }
  }

  close() {
    this.element.close();
    this.inputTarget.value = "";
    clearTimeout(this._searchTimer);
    this._clearDynamicJump();
    this._clearDynamic();
    this._clearDynamicProjects();
    this._clearDynamicMissions();
    this.filter();
  }

  handleCancel(event) {
    event.preventDefault();
    this.close();
  }

  backdropClick(event) {
    const rect = this.element.getBoundingClientRect();
    const inside =
      event.clientX >= rect.left &&
      event.clientX <= rect.right &&
      event.clientY >= rect.top &&
      event.clientY <= rect.bottom;
    if (!inside) this.close();
  }

  filter() {
    const query = this.inputTarget.value.toLowerCase().trim();

    const directRoutes = [
      { pattern: /^user#(\d+)$/i,        path: (id) => `/admin/users/${id}`,             label: "User" },
      { pattern: /^audit#(\d+)$/i,        path: (id) => `/admin/audit_logs/${id}`,        label: "Audit Log" },
      { pattern: /^project#(\d+)$/i,      path: (id) => `/admin/projects/${id}`,          label: "Project" },
      { pattern: /^report#(\d+)$/i,       path: (id) => `/admin/reports/${id}`,           label: "Report" },
      { pattern: /^order#(\d+)$/i,        path: (id) => `/admin/shop/orders/${id}`,       label: "Shop Order" },
    ];
    const directMatch = directRoutes.reduce((found, r) => found || (query.match(r.pattern) && { id: query.match(r.pattern)[1], ...r }), null);
    if (directMatch) {
      clearTimeout(this._searchTimer);
      this._clearDynamic();
      this._clearDynamicProjects();
      this._clearDynamicMissions();
      this._renderDynamicJump({ label: `${directMatch.label} #${directMatch.id}`, path: directMatch.path(directMatch.id) });
      return;
    }
    this._clearDynamicJump();

    if (query.length >= 2 && (this.hasUserSearchUrlValue || this.hasProjectSearchUrlValue || this.hasMissionSearchUrlValue)) {
      clearTimeout(this._searchTimer);
      this._searchTimer = setTimeout(() => this._fetchAll(query), 200);
    } else {
      this._clearDynamic();
      this._clearDynamicMissions();
    }
    const list = this.itemTargets[0]?.parentElement;
    if (!list) return;

    const scored = this.itemTargets.map((item) => {
      if (!query) return { item, score: 0, match: true };
      const title =
        item
          .querySelector(".command-palette__item-title")
          ?.textContent.toLowerCase() || "";
      const words = title.split(/\s+/);
      const keywords = (item.dataset.keywords || "").split(" ").filter(Boolean);

      let score = -1;
      if (title.startsWith(query)) score = 3;
      else if (words.some((w) => w.startsWith(query))) score = 2;
      else if (title.includes(query)) score = 1;
      else if (keywords.some((kw) => kw.startsWith(query))) score = 0;

      return { item, score, match: score >= 0 };
    });

    scored.sort((a, b) => b.score - a.score);
    scored.forEach(({ item, match }) => {
      item.style.display = match ? "" : "none";
      list.appendChild(item);
    });

    this._activeIndex = -1;
    this._clearActive();
  }

  handleKey(event) {
    switch (event.key) {
      case "ArrowDown":
        event.preventDefault();
        this._move(1);
        break;
      case "ArrowUp":
        event.preventDefault();
        this._move(-1);
        break;
      case "Enter":
        event.preventDefault();
        this._activate();
        break;
      case "Escape":
        this.close();
        break;
    }
  }

  highlight(event) {
    const i = this.itemTargets.indexOf(event.currentTarget);
    if (i !== -1) {
      this._activeIndex = i;
      this._applyActive();
    }
  }

  select(event) {
    const item = event.currentTarget;
    const { path, focus, method } = item.dataset;
    if (!path && !focus) return;

    this.close();
    if (focus) {
      document.querySelector(focus)?.focus();
    } else if (method === "post") {
      this._postAction(path);
    } else {
      window.Turbo.visit(path);
    }
  }

  _fetchAll(query) {
    const q = encodeURIComponent(query);
    const fetches = [];

    if (this.hasUserSearchUrlValue)
      fetches.push(
        fetch(`${this.userSearchUrlValue}?q=${q}`, { headers: { Accept: "application/json" } })
          .then((r) => r.json())
          .then((users) => this._renderDynamic(users))
          .catch(() => this._clearDynamic())
      );

    if (this.hasProjectSearchUrlValue)
      fetches.push(
        fetch(`${this.projectSearchUrlValue}?q=${q}`, { headers: { Accept: "application/json" } })
          .then((r) => r.json())
          .then((projects) => this._renderDynamicProjects(projects))
          .catch(() => this._clearDynamicProjects())
      );

    if (this.hasMissionSearchUrlValue)
      fetches.push(
        fetch(`${this.missionSearchUrlValue}?q=${q}`, { headers: { Accept: "application/json" } })
          .then((r) => r.json())
          .then((missions) => this._renderDynamicMissions(missions))
          .catch(() => this._clearDynamicMissions())
      );

    Promise.all(fetches);
  }

  _renderDynamicJump({ label, path }) {
    const list = this.dynamicJumpListTarget;
    list.innerHTML = "";
    const li = document.createElement("li");
    li.className = "command-palette__item";
    li.role = "option";
    li.id = "cp-dyn-jump";
    li.dataset.commandPaletteTarget = "item";
    li.dataset.action = "click->command-palette#select mouseenter->command-palette#highlight";
    li.dataset.path = path;
    li.innerHTML = `<span class="command-palette__item-title">${this._escape(label)}</span>`;
    list.appendChild(li);
    this.dynamicJumpResultsTarget.style.display = "";
  }

  _clearDynamicJump() {
    if (this.hasDynamicJumpListTarget) this.dynamicJumpListTarget.innerHTML = "";
    if (this.hasDynamicJumpResultsTarget) this.dynamicJumpResultsTarget.style.display = "none";
  }

  _renderDynamic(users) {
    const list = this.dynamicListTarget;
    list.innerHTML = "";

    if (!users.length) {
      this.dynamicResultsTarget.style.display = "none";
      return;
    }

    users.forEach((user, i) => {
      const li = document.createElement("li");
      li.className = "command-palette__item";
      li.role = "option";
      li.id = `cp-dyn-${i}`;
      li.dataset.commandPaletteTarget = "item";
      li.dataset.action =
        "click->command-palette#select mouseenter->command-palette#highlight";
      li.dataset.path = user._path || `/admin/users/${user.id}`;
      li.innerHTML = `<span class="command-palette__item-title">${this._escape(user.name)}</span>`;
      list.appendChild(li);
    });

    this.dynamicResultsTarget.style.display = "";
  }

  _renderDynamicProjects(projects) {
    const list = this.dynamicProjectListTarget;
    list.innerHTML = "";

    if (!projects.length) {
      this.dynamicProjectResultsTarget.style.display = "none";
      return;
    }

    projects.forEach((project, i) => {
      const li = document.createElement("li");
      li.className = "command-palette__item";
      li.role = "option";
      li.id = `cp-dyn-proj-${i}`;
      li.dataset.commandPaletteTarget = "item";
      li.dataset.action =
        "click->command-palette#select mouseenter->command-palette#highlight";
      li.dataset.path = `/admin/projects/${project.id}`;
      li.innerHTML = `<span class="command-palette__item-title">${this._escape(project.name)}</span>`;
      list.appendChild(li);
    });

    this.dynamicProjectResultsTarget.style.display = "";
  }

  _clearDynamic() {
    if (this.hasDynamicListTarget) this.dynamicListTarget.innerHTML = "";
    if (this.hasDynamicResultsTarget)
      this.dynamicResultsTarget.style.display = "none";
  }

  _clearDynamicProjects() {
    if (this.hasDynamicProjectListTarget) this.dynamicProjectListTarget.innerHTML = "";
    if (this.hasDynamicProjectResultsTarget)
      this.dynamicProjectResultsTarget.style.display = "none";
  }

  _renderDynamicMissions(missions) {
    const list = this.dynamicMissionListTarget;
    list.innerHTML = "";

    if (!missions.length) {
      this.dynamicMissionResultsTarget.style.display = "none";
      return;
    }

    missions.forEach((mission, i) => {
      const li = document.createElement("li");
      li.className = "command-palette__item";
      li.role = "option";
      li.id = `cp-dyn-mission-${i}`;
      li.dataset.commandPaletteTarget = "item";
      li.dataset.action = "click->command-palette#select mouseenter->command-palette#highlight";
      li.dataset.path = `/missions/${mission.slug}`;
      li.innerHTML = `<span class="command-palette__item-title">${this._escape(mission.name)}</span>`;
      list.appendChild(li);
    });

    this.dynamicMissionResultsTarget.style.display = "";
  }

  _clearDynamicMissions() {
    if (this.hasDynamicMissionListTarget) this.dynamicMissionListTarget.innerHTML = "";
    if (this.hasDynamicMissionResultsTarget)
      this.dynamicMissionResultsTarget.style.display = "none";
  }

  _escape(str) {
    return str
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  _move(dir) {
    const visible = this.itemTargets.filter(
      (el) => el.style.display !== "none",
    );
    if (!visible.length) return;
    const currentItem = this.itemTargets[this._activeIndex];
    let visIdx = visible.indexOf(currentItem);
    visIdx = Math.max(0, Math.min(visible.length - 1, visIdx + dir));
    this._activeIndex = this.itemTargets.indexOf(visible[visIdx]);
    this._applyActive();
  }

  _activate() {
    const item = this.itemTargets[this._activeIndex];
    const { path, focus, method } = item?.dataset ?? {};
    if (!path && !focus) return;

    this.close();
    if (focus) {
      document.querySelector(focus)?.focus();
    } else if (method === "post") {
      this._postAction(path);
    } else {
      window.Turbo.visit(path);
    }
  }

  _postAction(path) {
    const token = document.querySelector("meta[name='csrf-token']")?.content;
    const url = new URL(path, window.location.origin);
    const enable = url.searchParams.get("enable") === "true";
    fetch(path, {
      method: "POST",
      headers: { "X-CSRF-Token": token },
    }).then(() => {
      document.body.classList.toggle("streamer-mode", enable);
      const cb = document.getElementById("streamer_mode");
      if (cb) cb.checked = enable;
    });
  }

  _applyActive() {
    this._clearActive();
    const item = this.itemTargets[this._activeIndex];
    if (item) {
      item.classList.add("command-palette__item--active");
      item.scrollIntoView({ block: "nearest" });
      this.inputTarget.setAttribute("aria-activedescendant", item.id);
    }
  }

  _clearActive() {
    this.itemTargets.forEach((el) =>
      el.classList.remove("command-palette__item--active"),
    );
    if (this.hasInputTarget)
      this.inputTarget.setAttribute("aria-activedescendant", "");
  }
}
