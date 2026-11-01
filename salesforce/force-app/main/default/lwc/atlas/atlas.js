import { LightningElement } from "lwc";
import bootstrap from "@salesforce/apex/Atlas_Data.bootstrap";
import peoplePage from "@salesforce/apex/Atlas_Data.peoplePage";
import { errorMessage, readSettings, invalidateResearch, researchScope } from "c/atlasLib";

const NAV = [
  { value: "work", label: "Work", icon: "utility:chat", group: "Work" },
  { value: "tickets", label: "Tickets", icon: "utility:kanban", group: "Work" },
  { value: "changes", label: "Salesforce changes", icon: "utility:change_record_type", group: "Work" },
  { value: "library", label: "Library & recovery", icon: "utility:knowledge_base", group: "Data" },
  { value: "backup", label: "Native backup", icon: "utility:database", group: "Data" },
  { value: "team", label: "Team & Jira", icon: "utility:groups", group: "Setup" }
];

const RELOAD_ON_RETURN = { tickets: "c-atlas-tickets", changes: "c-atlas-changes" };

export default class Atlas extends LightningElement {
  boot;
  settings;
  error;
  openRequest;
  appHeight = 0;
  /** Panels mount on first visit and stay mounted, so work in one (an extraction,
      a background save) keeps running while the user looks at another. */
  visited = { work: true };
  selectedTab = "work";
  get activeTab() { return this.selectedTab; }
  set activeTab(value) {
    const returning = this.visited[value] && value !== this.selectedTab;
    if (!this.visited[value]) this.visited = { ...this.visited, [value]: true };
    this.selectedTab = value;
    // A retained panel keeps its open editors, but its list may have changed while
    // the user worked elsewhere (a saved ticket batch, a new change), so reload it.
    if (returning && RELOAD_ON_RETURN[value]) this.template.querySelector(RELOAD_ON_RETURN[value])?.refresh();
  }

  connectedCallback() {
    this.load();
    this.onResize = () => this.measure();
    window.addEventListener("resize", this.onResize);
  }

  loadGeneration = 0;
  disconnectedCallback() {
    this.loadGeneration++;
    window.removeEventListener("resize", this.onResize);
  }
  /** Fit the app to the space under the Lightning header so only the content
      area scrolls, never the page around it. */
  measure() {
    const app = this.template.querySelector(".atlas-app");
    if (!app) return;
    const height = Math.max(520, Math.floor(window.innerHeight - app.getBoundingClientRect().top - 12));
    if (Math.abs(height - this.appHeight) > 1) this.appHeight = height;
  }
  get appStyle() {
    return this.appHeight ? `height:${this.appHeight}px` : "";
  }
  async load() {
    invalidateResearch(researchScope(this.boot));
    const generation = ++this.loadGeneration;
    try {
      const boot = JSON.parse(await bootstrap());
      const ids = new Set(), cursors = new Set(), people = [];
      let page = { people: boot.people, nextCursor: boot.peopleCursor };
      while (true) {
        if (generation !== this.loadGeneration) return;
        for (const person of page.people) {
          if (ids.has(person.id)) throw Error("People paging repeated a record. Reload to retry; the previous directory is unchanged.");
          ids.add(person.id); people.push(person);
        }
        if (!page.nextCursor) break;
        if (cursors.has(page.nextCursor)) throw Error("People paging repeated a cursor. Reload to retry.");
        cursors.add(page.nextCursor);
        page = await peoplePage({ afterId: page.nextCursor });
      }
      boot.people = people.sort((a, b) => a.name.localeCompare(b.name) || a.id.localeCompare(b.id));
      boot.peopleCursor = null;
      this.settings = readSettings(boot);
      this.boot = boot;
      this.error = null;
    } catch (e) {
      if (generation === this.loadGeneration) this.error = errorMessage(e);
    }
  }

  get loading() {
    return !this.boot && !this.error;
  }
  get ready() {
    return this.boot && this.settings;
  }
  get notReady() {
    return !this.ready;
  }
  get startError() {
    return this.error && !this.boot;
  }
  get refreshError() {
    return this.error && this.boot;
  }
  get orgName() {
    return this.boot.org.name;
  }
  get userName() {
    return this.boot.user.name;
  }
  get environmentLabel() {
    return this.boot.org.isSandbox ? "Sandbox" : "Production";
  }
  get environmentClass() {
    return this.boot.org.isSandbox ? "atlas-env atlas-env_sandbox" : "atlas-env atlas-env_production";
  }
  get needsSetup() {
    return !this.boot.people.some((p) => p.isMe);
  }
  get hasNotices() {
    return this.needsSetup || this.migrationProblem || this.refreshError;
  }
  get navGroups() {
    const groups = [];
    for (const item of NAV) {
      const selected = item.value === this.selectedTab;
      let group = groups.find((g) => g.label === item.group);
      if (!group) groups.push(group = { label: item.group, items: [] });
      group.items.push({
        ...item,
        selected: String(selected),
        tabIndex: selected ? "0" : "-1",
        tabId: `atlas-tab-${item.value}`,
        panelId: `atlas-panel-${item.value}`,
        className: selected ? "atlas-nav-item atlas-nav-item_active" : "atlas-nav-item"
      });
    }
    return groups;
  }
  get hidden() {
    const hidden = {};
    for (const item of NAV) hidden[item.value] = item.value !== this.selectedTab;
    return hidden;
  }

  handleTab(event) {
    const value = event.currentTarget.dataset.value;
    if (this.activeTab !== value) invalidateResearch(researchScope(this.boot));
    this.activeTab = value;
  }
  handleNavKey(event) {
    const keys = { ArrowDown: 1, ArrowRight: 1, ArrowUp: -1, ArrowLeft: -1 };
    let index = NAV.findIndex((item) => item.value === this.selectedTab);
    if (event.key in keys) index = (index + keys[event.key] + NAV.length) % NAV.length;
    else if (event.key === "Home") index = 0;
    else if (event.key === "End") index = NAV.length - 1;
    else return;
    event.preventDefault();
    const value = NAV[index].value;
    if (this.activeTab !== value) invalidateResearch(researchScope(this.boot));
    this.activeTab = value;
    this.focusTab = value;
  }
  handleRefresh() {
    this.load();
  }
  retryStart() {
    this.error = null;
    this.load();
  }
  async handleRecovery() {
    await this.load();
    this.template.querySelector("c-atlas-tickets")?.refresh();
    this.template.querySelector("c-atlas-library")?.refresh();
  }
  /** detail {id} opens a conversation; {draft} starts a new one with the form filled in. */
  ticketRecovery;
  handleOpenConversation(event) {
    if (event.detail.draft?.type === "atlas-jira-operation") {
      this.ticketRecovery = { ...event.detail.draft };
      this.activeTab = "tickets";
      return;
    }
    this.openRequest = { ...event.detail };
    this.activeTab = "work";
  }
  pendingLegacy;
  migrationProblem = "";
  importingLegacy = false;
  handleLibraryContext(event) {
    this.openRequest = {draft: {mode: "Source", title: "Library follow-up", request: event.detail.text}};
    this.activeTab = "work";
  }
  handleLegacyImport(event) {
    if (!event.detail.areas?.task || !event.detail.workspace?.taskAtlas) return;
    this.pendingLegacy = event.detail.workspace;
    this.migrationProblem = "";
    this.activeTab = "tickets";
  }
  renderedCallback() {
    if (!this.appHeight || this.measuredReady !== Boolean(this.ready)) {
      this.measuredReady = Boolean(this.ready);
      this.measure();
    }
    if (this.focusTab) {
      this.template.querySelector(`[data-value="${this.focusTab}"]`)?.focus();
      this.focusTab = null;
    }
    const tickets = this.template.querySelector("c-atlas-tickets");
    if (!tickets || !this.pendingLegacy || this.importingLegacy || this.migrationProblem) return;
    this.importingLegacy = true;
    const workspace = this.pendingLegacy;
    tickets.importLegacy(workspace).then((result) => {
      if (result?.complete) this.pendingLegacy = null;
      else this.migrationProblem = result?.error || "Migration is incomplete; the original archive and completed chunks are preserved.";
    }).catch((e) => { this.migrationProblem = errorMessage(e); })
      .finally(() => { this.importingLegacy = false; });
  }
  retryLegacy() { this.migrationProblem = ""; this.activeTab = "tickets"; }
  goToTeam() {
    this.activeTab = "team";
  }
}
