import { LightningElement, api } from "lwc";
import savePerson from "@salesforce/apex/Atlas_Data.savePerson";
import lookupIdentity from "@salesforce/apex/Atlas_Identity.lookup";
import identityFields from "@salesforce/apex/Atlas_Identity.fields";
import saveSetting from "@salesforce/apex/Atlas_Data.saveSetting";
import runJiraConnectionTest from "@salesforce/apex/Atlas_Jira.connectionTest";
import getJiraCapabilities from "@salesforce/apex/Atlas_Jira.capabilities";
import { DEFAULT_REPLY_LIMIT, TEST_LEVELS, describeMapping, downloadFile, errorMessage, jiraReviewManager, parseMapping, replyLimit } from "c/atlasLib";

const NAMES = new Intl.Collator();
const DEFAULT_JIRA = {
  projectKey: "", siteUrl: "", priorities: "Highest, High, Medium, Low, Lowest", defaultPriority: "Medium",
  reviewManagerPersonId: "", reviewManagerIdentityType: "",
  apiBaseUrl: "", namedCredential: "", externalCredential: "", apiVersion: "3", readEnabled: false, writeEnabled: false,
};
const normalizeJira = (value = {}) => ({
  ...DEFAULT_JIRA,
  ...value,
  reviewManagerPersonId: typeof value.reviewManagerPersonId === "string" ? value.reviewManagerPersonId : "",
  reviewManagerIdentityType: ["accountId", "name"].includes(value.reviewManagerIdentityType) ? value.reviewManagerIdentityType : "",
  apiBaseUrl: typeof value.apiBaseUrl === "string" ? value.apiBaseUrl : "",
  namedCredential: typeof value.namedCredential === "string" ? value.namedCredential : "",
  externalCredential: typeof value.externalCredential === "string" ? value.externalCredential : "",
  apiVersion: ["2", "3"].includes(String(value.apiVersion)) ? String(value.apiVersion) : "3",
  readEnabled: value.readEnabled === true,
  writeEnabled: value.writeEnabled === true,
});
const JIRA_CONNECTION_FIELDS = ["siteUrl", "apiBaseUrl", "namedCredential", "externalCredential", "apiVersion", "readEnabled", "writeEnabled"];
const jiraConnectionSignature = (jira) => JSON.stringify(Object.fromEntries(JIRA_CONNECTION_FIELDS.map((name) => [name, jira?.[name]])));
// Getters run on every render, so the sorted table is rebuilt only when the people list changes.
const rowCache = new WeakMap();

export default class AtlasTeam extends LightningElement {
  @api boot;
  _settings;
  jira = { ...DEFAULT_JIRA };
  jiraSavedSnapshot = JSON.stringify(this.jira);
  jiraConnectionSavedSnapshot = jiraConnectionSignature(this.jira);
  jiraTesting = false;
  jiraTestStatus = "";
  jiraTestFailed = false;
  jiraCapabilities = null;
  jiraCapabilitiesError = "";
  jiraApiVersions = [
    { label: "Jira Cloud REST API v3", value: "3" },
    { label: "Jira Data Center REST API v2", value: "2" },
  ];
  mine = {};
  person;
  userResults = [];
  busy = false;
  error;
  saved;
  identity = {};
  fieldOptions = [{label: "No SSO field — enter Jira IDs manually", value: ""}];
  searchGeneration = 0;
  searchStatus = "";
  searching = false;

  async connectedCallback() {
    try {
      const fields = await identityFields();
      this.fieldOptions = [this.fieldOptions[0], ...fields.sort((a, b) => a.label.localeCompare(b.label))];
    } catch (e) { this.error = errorMessage(e); }
    await this.loadJiraCapabilities();
  }
  async loadJiraCapabilities() {
    try {
      const raw = await getJiraCapabilities();
      const capabilities = typeof raw === "string" ? JSON.parse(raw) : raw;
      if (!capabilities || typeof capabilities !== "object" || Array.isArray(capabilities) || typeof capabilities.connected !== "boolean") {
        throw new Error("Jira returned an unreadable access-status result.");
      }
      this.jiraCapabilities = capabilities;
      this.jiraCapabilitiesError = "";
    } catch (e) {
      this.jiraCapabilities = null;
      this.jiraCapabilitiesError = `Could not read saved Jira access status. ${errorMessage(e)}`;
    }
  }
  disconnectedCallback() { this.searchGeneration++; }
  handleIdentitySetting(event) { this.identity = {ssoField: event.detail.value}; }
  async saveIdentitySetting() {
    await this.guard(() => saveSetting({key: "identity", data: JSON.stringify(this.identity)}),
      "Saved the SSO field. Existing IDs are not silently changed; open a person to review any mismatch.");
  }
  get mappedSso() { return !!this._settings?.identity?.ssoField; }
  get ssoMismatch() { return this.person?.ssoId && this.person.ssoId !== this.person.jiraId; }
  useSso() { this.setPersonJiraId(this.person.ssoId); }
  setPersonJiraId(jiraId) {
    this.person = { ...this.person, jiraId, jiraIdentityType: jiraId === this.person.jiraId ? this.person.jiraIdentityType : "" };
  }

  @api
  get settings() {
    return this._settings;
  }
  set settings(value) {
    this._settings = value;
    this.jira = normalizeJira(value?.jira || {});
    this.jiraSavedSnapshot = JSON.stringify(this.jira);
    this.jiraConnectionSavedSnapshot = jiraConnectionSignature(this.jira);
    this.jiraTestStatus = "";
    this.jiraTestFailed = false;
    this.mine = { ...(value?.mine || {}) };
    this.identity = { ...(value?.identity || {}) };
  }

  get jiraDirty() { return JSON.stringify(this.jira) !== this.jiraSavedSnapshot; }
  get jiraConnectionDirty() { return jiraConnectionSignature(this.jira) !== this.jiraConnectionSavedSnapshot; }
  get jiraPermissionMessage() {
    return this.jiraCapabilities?.canConfigure === false && this.jiraConnectionDirty
      ? "Your account needs the Atlas Jira Admin permission set to change connection settings. You can still save the project key and CSV priority options without changing this saved connection."
      : "";
  }
  get jiraSaveDisabled() { return this.busy || (this.jiraCapabilities?.canConfigure === false && this.jiraConnectionDirty); }
  get jiraCredentialNamesRequired() { return !!(this.jira.externalCredential?.trim() || this.jira.readEnabled || this.jira.writeEnabled); }
  get jiraSiteRequired() { return this.jiraCredentialNamesRequired; }
  get jiraManualMode() { return !this.jira.externalCredential?.trim() && !this.jira.readEnabled && !this.jira.writeEnabled; }
  get jiraConfigurationIncomplete() {
    return !this.jiraManualMode && (!this.jira.externalCredential?.trim() || !this.jira.namedCredential?.trim() || !this.jira.siteUrl?.trim());
  }
  get jiraModeLabel() {
    if (this.jiraManualMode) return "Manual CSV mode";
    if (this.jiraConfigurationIncomplete) return "Jira configuration incomplete";
    if (!this.jira.readEnabled && !this.jira.writeEnabled) return "Jira access disabled";
    return "Live Jira access configured";
  }
  get jiraModeDescription() {
    if (this.jiraManualMode) return "No External Credential is configured. Atlas does not call Jira, so CSV export and import remain the existing manual workflow.";
    if (this.jiraConfigurationIncomplete) return "Live access is requested or partly configured. Complete the credential API names and Jira site address. A failed live request is never silently replaced by CSV instructions.";
    if (!this.jira.readEnabled && !this.jira.writeEnabled) return "The credential names are saved, but both Jira reads and writes are disabled. CSV remains available.";
    if (this.jira.readEnabled && this.jira.writeEnabled) return "Jira reads and writes are independently enabled. Every write shows its exact request and requires your explicit approval.";
    return this.jira.readEnabled ? "Jira reads are enabled; direct writes are disabled. Reads and writes can be enabled independently." : "Approved Jira writes are enabled; Jira reads remain disabled. A connection test requires reads and does not test write permission.";
  }
  get jiraReadState() { return this.jira.readEnabled ? "enabled" : "disabled"; }
  get jiraWriteState() { return this.jira.writeEnabled ? "enabled; each write requires approval" : "disabled"; }
  get jiraCapabilitySummary() {
    if (!this.jiraCapabilities) return this.jiraCapabilitiesError || "Checking saved Jira access status. This status is separate from a network connection test.";
    const connection = this.jiraCapabilities.connected ? "Saved Jira credentials are configured." : "No Jira External Credential is configured.";
    const mode = this.jiraCapabilities.mode === "live" ? "Live API access is active." : "Manual CSV mode is active.";
    return `${connection} ${mode} This status does not test a network connection; use the connection test below.`;
  }
  get jiraConnectionSummary() {
    if (this.jiraTestStatus) return this.jiraTestStatus;
    if (this.jiraDirty) return "Settings have unsaved changes. Save them before testing; the test uses saved settings only.";
    if (!this.jira.readEnabled) return "Not tested. Enable Jira reads to run the non-mutating connection test.";
    if (this.jiraConfigurationIncomplete) return "Not tested. Complete the Jira connection settings first.";
    return "Not tested with the saved settings.";
  }
  get jiraTestDisabled() {
    return this.busy || this.jiraTesting || this.jiraDirty || !this.jira.readEnabled || this.jiraConfigurationIncomplete;
  }
  get jiraTestClass() { return `atlas-notice ${this.jiraTestFailed ? "atlas-notice_error" : "atlas-notice_success"}`; }
  get jiraTestRole() { return this.jiraTestFailed ? "alert" : "status"; }

  async guard(work, done) {
    if (this.busy) return;
    this.busy = true;
    this.error = null;
    this.saved = null;
    try {
      await work();
      this.saved = done;
      this.dispatchEvent(new CustomEvent("refresh"));
    } catch (e) {
      this.error = errorMessage(e);
    } finally {
      this.busy = false;
    }
  }

  // ---- people

  get people() {
    return this.boot?.people || [];
  }
  get me() {
    return this.people.find((p) => p.isMe);
  }
  get needsSelf() { return !this.me; }
  get legacyManagerId() {
    return this.people.some((p) => p.isManager === true) ? "" : this.jira.reviewManagerPersonId;
  }
  get rows() {
    const legacyManagerId = this.legacyManagerId;
    const cached = rowCache.get(this);
    if (cached?.people === this.people && cached.legacyManagerId === legacyManagerId) return cached.rows;
    const order = (p) => (p.isMe ? 0 : p.isMyReport ? 1 : 2);
    const rows = [...this.people]
      .sort((a, b) => order(a) - order(b) || NAMES.compare(a.name, b.name))
      .map((p) => ({
        ...p,
        role: [p.isMe && "Me", p.isMyReport && "My direct report", (p.isManager === true || p.id === legacyManagerId) && "Manager"].filter(Boolean).join(" · ") || "Other",
        aliasText: p.aliases.join(", "),
        activeText: p.active === false ? "No" : "Yes",
        missingJira: !p.jiraId,
        initials: p.name.split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0].toUpperCase()).join(""),
        roleClass: "atlas-pill " + (p.isMe ? "atlas-pill_accent" : p.isMyReport ? "atlas-pill_success" : ""),
        rowClass: p.active === false ? "atlas-inactive" : "",
      }));
    rowCache.set(this, { people: this.people, legacyManagerId, rows });
    return rows;
  }
  get hasPeople() {
    return this.people.length > 0;
  }

  async addMe() {
    await this.guard(
      () => savePerson({ personJson: JSON.stringify({ name: this.boot.user.name, userId: this.boot.user.id, active: true }) }),
      "Added you. Now add your Jira account ID and any names agents might use for you.",
    );
  }
  addPerson() {
    if (this.busy) return;
    this.searchGeneration++;
    this.searchStatus = "";
    this.person = { name: "", jiraId: "", jiraIdentityType: "", aliases: "", userId: "", userName: "", reportsToMe: !!this.me, isManager: false, active: true, isMe: false };
    this.userResults = [];
  }
  editPerson(event) {
    if (this.busy) return;
    this.searchGeneration++;
    this.searchStatus = "";
    const p = this.people.find((x) => x.id === event.currentTarget.dataset.id);
    this.person = {
      id: p.id,
      version: p.version,
      ssoId: p.ssoId,
      identityWarning: p.identityWarning,
      name: p.name,
      jiraId: p.jiraId || "",
      jiraIdentityType: p.jiraIdentityType || (p.id === this.legacyManagerId ? this.jira.reviewManagerIdentityType : ""),
      isManager: p.isManager === true || p.id === this.legacyManagerId,
      aliases: p.aliases.join("\n"),
      userId: p.userId || "",
      userName: p.userName || "",
      managerId: p.managerId || "",
      reportsToMe: p.isMyReport,
      active: p.active !== false,
      isMe: p.isMe,
    };
    this.userResults = [];
  }
  cancelPerson() {
    if (this.busy) return;
    this.searchGeneration++;
    this.searching = false;
    this.person = null;
  }
  handlePerson(event) {
    const { name, type } = event.target;
    if (name === "jiraId") {
      this.setPersonJiraId(event.detail.value);
      return;
    }
    this.person = { ...this.person, [name]: type === "checkbox" || type === "toggle" ? event.detail.checked : event.detail.value };
  }
  get canReport() {
    return !!this.me && !this.person?.isMe;
  }
  get personTitle() {
    return this.person?.id ? `Edit ${this.person.name}` : "Add a person";
  }

  async searchUsers(event) {
    const term = event.detail.value || "";
    const generation = ++this.searchGeneration;
    this.userResults = [];
    this.searchStatus = "";
    this.searching = false;
    if (term.trim().length < 2) return;
    this.searching = true;
    try {
      const result = JSON.parse(await lookupIdentity({term}));
      if (generation !== this.searchGeneration || !this.person) return;
      this.userResults = result.matches.filter((u) => u.userId).map((u) => ({...u, id: u.userId, disabled: u.active === false}));
      this.searchStatus = result.truncated ? "More matches exist. Use a more specific name, email or SSO ID."
        : result.status === "ambiguous" ? "Multiple people match. Check their email and SSO ID before selecting."
          : result.status === "not_found" ? "No matching person found." : "Select the correct Salesforce user below.";
    } catch (e) {
      if (generation === this.searchGeneration) this.error = errorMessage(e);
    } finally { if (generation === this.searchGeneration) this.searching = false; }
  }
  pickUser(event) {
    event.preventDefault();
    if (this.busy || !this.person) return;
    const user = this.userResults.find((u) => u.id === event.currentTarget.dataset.id);
    if (!user || user.active === false) return;
    const existing = this.people.find((p) => p.userId === user.id && p.id !== this.person.id);
    if (existing) {
      this.error = `This user already links to ${existing.name}. Edit that person to add names instead of creating another mapping.`;
      return;
    }
    this.searchGeneration++;
    this.setPersonJiraId(this.mappedSso ? user.ssoId || "" : this.person.jiraId || user.jiraId || "");
    this.person = { ...this.person, userId: user.id, userName: user.userName, name: this.person.name || user.userName,
      ssoId: user.ssoId };
    this.userResults = [];
    this.searching = false;
  }
  clearUser() {
    if (this.busy) return;
    this.searchGeneration++;
    this.person = { ...this.person, userId: "", userName: "", ssoId: "", identityWarning: "" };
  }

  async submitPerson() {
    const p = this.person;
    let managerId = p.managerId || null;
    if (p.reportsToMe && this.me) managerId = this.me.id;
    else if (!p.reportsToMe && managerId === this.me?.id) managerId = null;
    await this.guard(async () => {
      await savePerson({
        personJson: JSON.stringify({
          id: p.id || null,
          version: p.version,
          name: p.name,
          jiraId: p.jiraId,
          jiraIdentityType: p.jiraIdentityType,
          isManager: p.isManager,
          aliases: p.aliases.split(/[,;\n]/).map((a) => a.trim()).filter(Boolean),
          userId: p.userId || null,
          managerId,
          active: p.active,
        }),
      });
      this.person = null;
    }, `Saved ${p.name}.`);
  }

  // ---- Jira settings

  get jiraIdentityOptions() {
    return [{ label: "Not confirmed — do not route automatically", value: "" },
      { label: "Confirmed Jira Cloud account ID", value: "accountId" },
      { label: "Confirmed Jira Data Center username", value: "name" }];
  }
  get reviewManagerStatus() { return jiraReviewManager(this.jira, this.people).message; }
  get priorityText() {
    return this.jira.priorities || "";
  }
  handleJira(event) {
    const { name, type } = event.target;
    const value = type === "checkbox" ? event.detail.checked : event.detail.value;
    this.jira = { ...this.jira, [name]: value };
    this.jiraTestStatus = "";
    this.jiraTestFailed = false;
  }
  async saveJira() {
    const requiredNames = ["siteUrl", "externalCredential", "namedCredential"];
    const fields = requiredNames.map((name) => this.template.querySelector(`lightning-input[name="${name}"]`)).filter(Boolean);
    if (!fields.every((field) => field.reportValidity())) return;
    const jira = {
      ...normalizeJira(this.jira),
      projectKey: (this.jira.projectKey || "").trim().toUpperCase(),
      siteUrl: (this.jira.siteUrl || "").trim().replace(/\/+$/, ""),
      apiBaseUrl: (this.jira.apiBaseUrl || "").trim().replace(/\/+$/, ""),
      namedCredential: (this.jira.namedCredential || "").trim(),
      externalCredential: (this.jira.externalCredential || "").trim(),
    };
    // Manager choices belong to People. Omit legacy keys so a stale form cannot overwrite them.
    const payload = { ...jira };
    delete payload.reviewManagerPersonId;
    delete payload.reviewManagerIdentityType;
    await this.guard(async () => {
      await saveSetting({ key: "jira", data: JSON.stringify(payload) });
      this.jira = jira;
      this.jiraSavedSnapshot = JSON.stringify(jira);
      this.jiraConnectionSavedSnapshot = jiraConnectionSignature(jira);
      this.jiraTestStatus = "";
      this.jiraTestFailed = false;
      await this.loadJiraCapabilities();
    }, "Saved the Jira settings.");
  }
  async testJiraConnection() {
    if (this.jiraTestDisabled) return;
    this.jiraTesting = true;
    this.jiraTestStatus = "";
    this.jiraTestFailed = false;
    try {
      const result = JSON.parse(await runJiraConnectionTest());
      if (!result || typeof result !== "object") throw new Error("Jira returned an unreadable connection-test result.");
      const detail = result.message || (result.ok === true ? "Jira authenticated this Salesforce user." : "Jira did not confirm this connection.");
      this.jiraTestFailed = result.ok !== true;
      this.jiraTestStatus = `${result.ok === true ? "Connection test passed." : "Connection test did not pass."} ${detail} ${result.writePermissionVerified === true ? "Write permission was verified." : "Write permission was not tested."}`;
    } catch (e) {
      this.jiraTestFailed = true;
      this.jiraTestStatus = `Connection test failed. ${errorMessage(e)}`;
    } finally {
      this.jiraTesting = false;
    }
  }

  // ---- Jira import mapping

  get mappingLines() {
    return describeMapping(this._settings?.mapping).map((text, i) => ({ key: i, text }));
  }
  get hasMapping() {
    return !!this._settings?.mappingText;
  }
  get mappingUnmapped() {
    const list = this._settings?.mapping?.unmapped || [];
    return list.length ? `Custom columns: ${list.join(", ")}. These are exported when the ticket has an exact text value under that custom field name. Repeated import headers remain in the raw snapshot.` : "";
  }
  async uploadMapping(event) {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) return;
    let text;
    try {
      text = await file.text();
      parseMapping(text);
    } catch (e) {
      this.error = `${file.name} is not a mapping Atlas can read: ${errorMessage(e)}`;
      return;
    }
    await this.guard(
      () => saveSetting({ key: "jira-mapping", data: JSON.stringify({ name: file.name, text }) }),
      `Saved ${file.name}. Every Jira CSV export now uses it.`,
    );
  }
  downloadMapping() {
    downloadFile(this.template.querySelector("a.atlas-download"), this._settings.mappingName || "jira-mapping.txt", this._settings.mappingText, "text/plain");
  }
  async removeMapping() {
    await this.guard(() => saveSetting({ key: "jira-mapping", data: null }), "Removed the mapping. Exports use Jira's standard column names again.");
  }

  // ---- my settings

  get testOptions() {
    return TEST_LEVELS;
  }
  handleMine(event) {
    this.mine = { ...this.mine, [event.target.name]: event.detail.value };
  }
  async saveMine() {
    const mine = { ...this.mine, replyLimit: replyLimit(this.mine.replyLimit) };
    await this.guard(() => saveSetting({ key: "mine", data: JSON.stringify(mine) }), "Saved your settings.");
  }
  get defaultLimit() {
    return DEFAULT_REPLY_LIMIT.toLocaleString();
  }
}
