# Atlas: install and first use

Atlas runs inside Salesforce. It is one Lightning page with a left-hand menu of
six sections, grouped as **Work** (Work, Tickets, Salesforce changes), **Data**
(Library & recovery, Native backup) and **Setup** (Team & Jira). On mid-size
screens the menu shrinks to icons; hover one to see its name. It uses your own
Salesforce login, so there is no extra user, connected app or OAuth setup.

Everything it adds has a name starting with **Atlas**, so you can find it all in
Setup by searching for "Atlas".

**Before you rely on it:** install it in a sandbox first. If you are moving from
the older stand-alone HTML version of Atlas, keep your HTML workspace and its
backups. Native legacy import and selective recovery exist, but a native archive
omits individual Salesforce Files over 1,500,000 bytes and cannot exceed 100 MiB.
An incomplete archive is not a replacement for the original files.

## What you need

- A Salesforce org where you are a system administrator. Use a sandbox first.
- The Salesforce CLI (`sf`) on your computer, logged in to that org.
- The Atlas ZIP. To build it from this repository, run `npm ci` and then
  `npm run package:salesforce`; the ZIP lands in `artifacts/`.

## 1. Unzip and check the files

Unzip the ZIP anywhere. It contains a `salesforce/` folder, this guide, the
third-party licence notices and `SHA256SUMS`. To check nothing was damaged in
the download, run this from the unzipped folder (Mac or Linux; skip it on
Windows if you like):

```sh
shasum -a 256 -c SHA256SUMS
```

Every line should end in `OK`.

## 2. Log the CLI in to your org

Skip this if `sf org list` already shows the org. Otherwise:

```sh
sf org login web --alias my-sandbox --instance-url https://test.salesforce.com
```

Use `https://login.salesforce.com` for a production org, or your My Domain address
if your company signs in through SSO. A browser opens; log in there.

## 3. Deploy

From inside the `salesforce/` folder:

```sh
sf project deploy start --target-org my-sandbox --source-dir force-app \
  --test-level RunSpecifiedTests \
  --tests Atlas_ApiTest --tests Atlas_ChangesTest --tests Atlas_DataTest \
  --tests Atlas_ResearchTest --tests Atlas_TicketsTest \
  --tests Atlas_AccessTest --tests Atlas_LibraryTest \
  --tests Atlas_TicketParityTest --tests Atlas_WorkspaceTest \
  --tests Atlas_IdentityTest --tests Atlas_AssignmentsTest \
  --tests Atlas_VersionsTest --tests Atlas_BundleDeployTest \
  --tests Atlas_JiraTest --tests Atlas_JiraWritesTest \
  --tests Atlas_JiraSettingsTest --tests Atlas_SupportTicketsTest \
  --tests Atlas_UATBoundaryTest --tests Atlas_ManagerTest --wait 30
```

It runs Atlas's Apex test suite and takes a few minutes. It should end with
**Status: Succeeded**. If it fails, the CLI lists each error with a file name and line.

To check first without changing anything, add `--dry-run` to the same command.
If Salesforce reports pending/running Atlas Apex jobs, let the existing deployment
or restore finish before installing the update; do not disable that deployment guard.

**New object grants:** on the first test-org upgrade, the new Library permission
was not yet available to restricted-user describe assertions during deployment.
Do not remove those assertions or grant an administrator profile to make them pass.
If the only failure is the explicit Library permission assertion, an administrator
must stage the additive schema/permission metadata in the sandbox and rerun all
nineteen test classes. Do not use an untested first installation as a production
rollout.

## 4. Give yourself access

In Setup, open **Permission Sets → Atlas User → Manage Assignments → Add
Assignment**, and pick your user. "Atlas User" is a permission set, not a new
user. Give it to each teammate who should share the tickets.

The permission set covers the Atlas objects, Apex, tab and the "API Enabled"
permission. What Atlas can read or change in the rest of the org is whatever your
own login can, so an administrator sees everything.

## 5. Open it

**App Launcher → Atlas.** Until you add yourself as a person, a banner at the top
offers **Open Team & Jira**.

## 6. Set up Team & Jira (once)

1. **Salesforce ↔ Jira identity:** choose your **Salesforce User SSO field** and
   **Save identity settings**. Pick the field whose value really is the Jira user
   ID (for example `FederationIdentifier` or your custom User text field). Atlas
   lists only readable, filterable, unencrypted text/email fields. Each teammate
   using this feature needs read access to that field and the relevant Users.
   Leave it unset if you need to enter Jira IDs manually. Atlas never changes User
   login/SSO fields, and this setting does not connect to Jira.
2. **People:** click **Add me**, or **Add a person** to add anyone without first
   setting up your own identity. Search Salesforce by name, email, alias or SSO ID
   and select the correct User. The configured field fills their Jira ID. Keep
   all their other names on this **one person**, one name per line—for example
   `Chris`, `Christopher`, `CJ`, `Chris from support`, `C. Example`. Do not create
   a separate mapping per name. Select **Reports to me** for direct reports.
   Existing comma-separated names still work; expanded lists are stored together
   without the old 255-character alias-field limit (32,768 characters total).
3. **Jira:** enter the project key (for example `DEMO`), your Jira site address and
   priorities, then **Save Jira settings**. Leave both credential names blank and
   both live switches off to keep the existing CSV/manual workflow. For a live
   connection, complete the credential setup below.
4. **Jira import mapping:** upload the `.txt` configuration file that Jira's CSV
   importer saved for you. Atlas then writes its CSV with your column names,
   separator, date format and values, so you only import one file into Jira.
5. **My settings:** the longest message Atlas hands you is 100,000 characters by
   default. Pick the Apex test level you usually want when deploying, and add any
   standing instructions for every agent.

People, the SSO field, Jira settings and the mapping are shared with your team.
"My settings" are yours alone. Changing the SSO field does **not** overwrite saved
Jira IDs: edit each flagged person and review **Use current SSO ID** before saving.
Duplicate links, ambiguous names, inactive Users, blank SSO values and mismatched
saved/current IDs block automatic assignment rather than guessing.

### Support Tickets: investigate production issues from QA

Choose **Work → New conversation → Support Tickets**. Paste the production admin ticket
and its relevant context, such as the affected screen, exact error, what the user
expected, when the problem began, and an example the administrator is allowed to
share. Do not paste credentials or unnecessary personal data. Atlas does not connect
to the production queue or fetch its records for you.

This mode is for an administrator who is learning the org. The agent requests
read-only data and metadata from the org where Atlas is installed, normally your QA
sandbox. It can inspect Flows, Apex, Lightning components and validation rules, and
ask the administrator focused questions. QA findings are not proof that production
has the same configuration, users or records. The prompt identifies the connected
org; confirm it is the intended QA environment before sharing its data.

The final investigation report separates what was learned about the org, reported
production facts, observed QA evidence, hypotheses and remaining uncertainty. It
explains the likely problem and recommended solution before giving numbered
production instructions, required access, checks, stop conditions and rollback
considerations. If evidence is insufficient, the agent should keep asking instead
of inventing a fix. Suspected code or automation defects go to manager review, not
to a novice administrator to patch directly in production.

Support Tickets cannot back up a proposed source change, submit code edits, deploy,
restore, assign Salesforce records or update existing Jira tickets. It can save
conversation history and a reviewed Bug escalation. Other modes retain their
existing capabilities; conversation modes cannot be changed after creation.

### UAT: build and complete a user acceptance test plan

Choose **Work → New conversation → UAT**. Select **Flow**, **Apex**, **LWC** or
**Other**, enter the exact component API name, write your request, and give a brief
business goal. For **Other**, also describe what you are testing. The API name is
Salesforce's developer name, not just the screen label. These details stay with the
conversation so you can return to the same investigation later.

Confirm that Atlas is connected to the intended QA or test org. The agent uses
read-only queries and metadata retrieval to trace the process and its reachable
dependencies, then asks about business rules or missing evidence. It must identify
unreadable components, incomplete query results and unknown production differences;
a partial inspection is not proof that the entire process is understood. No tests,
source edits, deployments, record assignments or Jira writes run from this mode.

After the questions are answered, the agent provides a structured test plan. It
should cover the normal workflow, edge cases, permission differences, invalid or
missing inputs, failure paths, regression checks and relevant bulk, asynchronous
or integration behavior. Each test identifies its setup, actions and expected
results. Test data, external side effects, cleanup and any tests requiring separate
approval should be explicit. The administrator performs the tests; Atlas does not
claim a pass merely because the source looks correct.

Use the generated Word file's download action, as in Files mode. The document has
real checkbox content controls, test identifiers, space for results and evidence,
and any suspected bugs with Source-mode repair prompts. Open it in a compatible
Word editor with editing enabled to check the boxes. Other document viewers may
show the boxes without allowing changes; retain the original `.docx` rather than
converting it to a PDF if you need editable boxes. Save your completed document
locally. Checking a box in Word does not automatically send results back to Atlas.
You can reopen saved plans from conversation history. After restoring a workspace,
Atlas identifies plans from the original conversation and retains that provenance
in the document; saving the generated file attaches it to the restored conversation.

If a test fails, return to the **same UAT conversation** and send the test identifier,
expected result, actual result, exact error and relevant evidence through the normal
follow-up exchange. The agent can research further and give you a revised prompt
to paste into a **new Source conversation**. That prompt should identify the
component, reproduction steps, evidence, intended behavior and regression tests.
The source repair remains a separate reviewed change; UAT itself does not apply it.
Do not paste tokens, passwords or unnecessary customer data into either conversation.

### Set the manager in People

In **Team & Jira → People**, add or edit the manager's existing person and select
**Manager**. Keep their names, aliases, linked Salesforce user and Jira identity on
that one person. This shared role is separate from **Reports to me** and a person's
**Reports to** relationship. It does not create or change Jira users.

For Jira Bug escalation, explicitly confirm the saved Jira identity format on that
person: **Data Center username** for version 2, or **Cloud account ID** for version 3.
Use the actual Jira identity, not a guessed name or an unverified Salesforce SSO
value. Existing review-manager settings remain a compatibility fallback until the
role is saved on a person; you do not need to re-enter the existing identity.
Only one Manager is allowed, including inactive people. Clear the existing person's
Manager checkbox before choosing a replacement. If the earlier saved person was
deleted or is absent from this org, explicitly selecting a replacement clears that
obsolete reference. A person merely hidden by sharing is never replaced this way.
The replacement never inherits the previous person's Jira confirmation.

If a person save and a Jira settings save happen at the same time, Salesforce may
reject one with a record-lock error. The rejected save is rolled back. Let the
other save finish, reload the current settings, review your intended change and
save again. Do not remove the Manager safeguards to bypass that error.

Changing a saved Jira ID or linked Salesforce user clears the earlier identity
confirmation, including changes made directly to the Salesforce person record.
Save the identity change, then reopen the person to review and confirm its format
before routing a Bug. Alias and reporting-relationship edits do not clear confirmation.

Normal conversation prompts identify the manager alongside you and your direct
reports. Where person names or aliases are accepted, **manager** and **my manager**
refer to the single active person with that role. A nickname alone never grants
the role. Missing or duplicate manager roles, identity warnings, or a role word
that also identifies another person block automatic resolution instead of picking
someone arbitrarily. Reconcile People, then refresh the conversation's rules.

A live Support Tickets escalation proposes one **Bug**, assigned to that manager for
triage and repair assignment, with the `atlas-manager-review` label. Review the exact
request before approving it. Atlas does not send the ticket merely because the
agent found a bug, and it does not select a repair developer. Jira permissions,
required fields and assignability still apply.

Without a live connection, or when live writes are disabled, the agent can prepare
a local Bug draft for manual CSV export. If no usable manager is configured, the
draft must be unassigned and the administrator must route it manually. A missing,
inactive or conflicting person is never guessed from a name. After restoring a
workspace into another org, select the manager again if the saved reference cannot
be resolved there. Existing conversation reminders use current settings.

### Optional: connect live Jira

Salesforce needs two related settings: a **Named Credential** holds the destination
address, and its **External Credential** holds the authentication method and
principal. You choose their names; Atlas does not install or overwrite credentials.
Never put an API token, password, authorization header or OAuth secret in Atlas.

1. In Salesforce **Setup → Named Credentials → External Credentials**, create the
   authentication setup your Jira administrator permits. For Jira Cloud API-token
   authentication this is normally Basic authentication with your Atlassian account
   email as the username and the API token as the password. OAuth or a Data Center
   service account may use a different setup; Atlas leaves authentication to Salesforce.
2. Create a **Named Credential** with the HTTPS Jira API base address and link it to
   that External Credential. Enable callouts. A normal Cloud token uses the site
   address, such as `https://example.atlassian.net`. A scoped Cloud token uses
   `https://api.atlassian.com/ex/jira/YOUR-CLOUD-ID`. Do not append `/rest/api/3`.
   Data Center can include its installation context path and uses API version 2.
3. Give each intended Salesforce user access to the External Credential principal
   through an administrator-managed permission set. Check the required User External
   Credentials access and, for per-user authentication, authenticate each user.
   Jira's own project permissions and token scopes still apply. The Atlas permission
   set does not grant credential administration or access to arbitrary principals.
4. Assign the separate **Atlas Jira Admin** permission set to the people who
   may configure the shared live connection. Administrators need this assignment
   too. The ordinary **Atlas User** set does not permit changing credential
   destinations or enabling/disabling live access. Server enforcement also covers
   direct settings-record edits and imported recovery data.
5. In **Team & Jira**, enter the browser-facing **Jira site URL**, the **Named
   Credential API name**, and the **External Credential API name**, exactly as they
   exist in your org. Use fully qualified developer names when your org requires a
   namespace; do not use labels or remove a prefix by guessing. Set **API base URL**
   only when it differs from the site URL, and choose Cloud (3) or Data Center (2).
   Atlas checks that the configured endpoint and linked External Credential match
   the selected Named Credential. If Salesforce prevents that metadata check, ask
   your administrator to review access; Atlas will not skip the check.
6. Enable **Read** and **Write** independently, then save. Read allows scoped live
   searches and issue lookups. Write allows reviewed creations, field changes,
   comments and transitions. Write does not turn Read on, and Read does not turn
   Write on. A write-only setup needs exact field values and transition IDs; helpers
   that must look up names or available transitions need Read too.
7. With Read enabled, use the saved-connection test. It authenticates to Jira without
   changing anything. A successful test does not prove permission to create or edit
   every project. Test a small, explicitly reviewed change in a Jira test project
   before trusting this connection for real work.

With an External Credential configured, agent Jira searches go to Jira directly.
A disabled switch, expired token, wrong endpoint or Jira error returns an error;
Atlas never labels the old Salesforce mirror as fresh Jira data. The agent can
explicitly request the local mirror for planning. Live reads bypass the research
cache and return bounded pages; agents must follow the returned continuation.

Each write proposal is saved first and shows its destination, exact API request
and payload. Pasting an agent reply does not approve it. Approving queues that
exact saved request, and the result is retained in Salesforce. Reopening or
checking the same operation does not resend it. If the outcome is **unknown**,
Jira may already have applied it: check Jira and reconcile it before creating any
replacement request. Never retry it under a new operation ID merely to bypass
that warning. Changing connection settings invalidates unsent reviews. Once execution
starts, editing the ticket or disabling/reconfiguring Jira cannot cancel an in-flight
request: Jira can still receive the exact request you approved. Checks before sending
are not atomic with Jira. If local work changed meanwhile, Atlas refuses to overwrite
those newer local edits when recording the successful Jira result.

The Tickets tab still shows saved Salesforce tickets, not a continuously synchronized
Jira board. Use its separate live review actions for supported drafts and pending
updates, or let an agent propose an exact live Jira write in Work. Create epics
first and wait for confirmed Jira keys before creating their children. CSV column
and value mappings are only for CSV; live writes use actual Jira field IDs and
values. Jira and Salesforce changes are separate transactions, not an atomic action.

## 7. Day-to-day use

**Work tab.** Click **New conversation**, pick a mode, give it a title and say what
you want:

- **Source:** change Salesforce (Apex, LWC, flows, layouts, any metadata).
- **Task:** plan and track work as shared Jira tickets.
- **UAT:** investigate a process and produce a detailed Word test plan with checkable
  boxes, then discuss failed tests and prepare separate Source-mode repair prompts.
- **Support Tickets:** investigate a production support issue using QA evidence and prepare
  production guidance or a manager-reviewed Jira Bug.
- **Files:** create Word, Excel, PowerPoint files or emails.

Atlas shows the first message. Click **Copy** and paste it into your AI agent's
chat. Then repeat: paste the agent's reply into Atlas, and copy back what Atlas gives you.

- **Lookups.** The agent can request accessible org information: SOQL and SOSL queries,
  Tooling API, object and field descriptions, metadata supported by Salesforce's
  list/retrieve APIs, REST reads, and recent Setup and metadata activity.
  Permission, protected-package, size and history limits apply; these are not
  guaranteed exhaustive searches. Activity replies explicitly flag capped or
  unreadable sources. Narrow the time period or request scoped queries before
  drawing conclusions from missing activity.
- **Fast repeat lookups.** Atlas reuses recent identical research in this page's
  memory: 30 seconds for records/people/local tickets/activity, 60 seconds for metadata
  lists/source, and 5 minutes for schema/types. Live Jira and automatic ticket routing
  always recheck the server. Reused answers show their timestamp.
  Atlas writes clear that cache. For changes made elsewhere, choose **Refresh
  research** or **Clear research cache**, or have the agent include `"fresh":true`.
  Approvals and backups still recheck Salesforce directly; cached research never
  authorizes a write.
- **Background history.** Routine replies appear before their history/draft saves
  finish. Watch **History saved in Salesforce**; on failure use **Retry Save history**
  or **Download unsaved history** before leaving. Exact retries do not duplicate
  messages or replay commands. Browser recovery is tab-local, not a durable backup.
  If browser storage is unavailable, Atlas waits for Salesforce before clearing
  the input. Messages over 1,500,000 characters are refused without blocking the
  save queue: keep the output and ask for smaller batches.
- **People across Salesforce and Jira.** Agent context includes each saved person's
  names, Salesforce User ID and Jira ID. If uncertain about someone mentioned in an
  email or Teams paste, the agent can ask for an on-demand lookup with
  `{"type":"atlas-request","requests":[{"id":"who","op":"users","term":"Chris"}]}`.
  This reads Users without creating a person. Multiple matches require human
  clarification; fuzzy suggestions are not resolved identities. Save a confirmed
  User link and aliases under Team & Jira for future Jira assignments.
- **Case ownership.** “Assign this Case and Jira ticket to Chris” uses the same
  identity, but two separate reviews. An `atlas-assign` reply names up to ten Case
  IDs, the assignee and a reason. Atlas shows current → proposed owners. Only
  **Approve Case assignments** changes `Case.OwnerId`, under your own permissions;
  org automation can run. Reject leaves ownership untouched. Changed Case state or
  identity blocks stale approval. If the response is lost, reopen the conversation
  and **Retry Case decision** to replay the exact saved consent, not a new write.
  The Jira half uses a separately reviewed live Jira operation when configured, or
  the existing draft/CSV/manual checklist otherwise. It is never an atomic
  Salesforce-plus-Jira transaction. Atlas does not grant Case update/transfer
  permissions or perform arbitrary Salesforce record writes.
- **Message size.** Every agent reply has a 14,000-character ceiling, including
  JSON escaping, code fences and any explanation. This also applies to Files and
  UAT; a complete document can be much larger, but each reply cannot. Atlas tells
  the agent to aim below 12,000 characters, measure the finished reply when tools
  are available, and send long documents as numbered JSON parts, one per response.
  Say **Continue** after each part until the agent has sent them all, then paste
  all the parts together into Atlas. Do not process a single incomplete part as
  a finished plan. Splitting must preserve the full document and every test.
  Work adds the current reminder to active outgoing messages, including the
  latest saved handoff when reopening a conversation, and each part of a large
  Atlas message. The separate raw-history Copy action keeps the original text.
  The separate setting for how
  much Atlas sends to the agent does not raise the agent's reply ceiling. After
  installing this update, refresh Atlas and use **Remind the agent of the rules**
  in existing conversations. These instructions cannot force an external agent
  to comply; if it still sends an oversized reply, ask it to resend in smaller parts.
- **Keeping the agent's context small.** Query results are one column header and
  one compact line per record. A file the agent already received, unchanged, in the
  same conversation comes back as a one-line note; the agent can ask for it again
  with `"resend":true`, and **Remind the agent of the rules** makes Atlas send
  every file in full next time. Picklists show their first 25 values unless the
  agent asks for that field. Deployment results give the outcome and the exact
  Salesforce errors, not the raw result, which stays on the change.
- **Changes (Source mode).** Before any change, the agent names the components.
  Atlas saves a ZIP backup in Salesforce Files and requests a browser download.
  Check that the ZIP arrived; browser settings can block downloads. The agent then
  sends its change. You see a diff with reasons and line comments, then click
  **Approve and deploy** or **Reject** with a note. Approval rechecks the backed-up
  source and refuses to overwrite changes detected since backup. Deployment and
  restore are queued. The open view tracks progress; bounded background checks also
  run after you leave. A very long job can exhaust those checks: reopen/refresh the
  same change to resume, not to resubmit it. The result and agent handoff save
  together. Failed Apex, Flow or LWC deployments and failed Apex tests automatically
  put the exact Salesforce diagnostics in the next message to copy—no separate error
  hunt or agent request. Corrections still require a reviewed proposal and approval.
  Rejection and its note also save together, so reloading after a lost response retains
  the handoff. Rollback-on-error does not promise reversal of test/external effects.
  An **UNKNOWN** outcome is not a confirmed failure: check the existing deployment
  and reconcile its verified ID before attempting further changes.
- **Tickets (Task mode).** The agent can create tickets, assign them by name, alias
  or Jira ID, and keep adding tickets as the conversation goes on. They are saved
  in Salesforce, where your whole team sees them. The ticket batch and its agent
  acknowledgment save together. The exact reviewed request is saved before submission.
  After a lost response, reopen the conversation; retrying that saved review reuses
  its receipt instead of duplicating tickets. If an uncertain review predates this
  upgrade and still reports a conflict, inspect its saved tickets and acknowledgment
  before requesting another batch; old reviews may lack the original request bytes.

**Tickets tab.** Filter by **Me**, **All (me and my direct reports)**, or one person.
The board groups tickets by their saved **Jira status**, in this order: **Registered**,
**Not Started**, **Planning**, **Working**, **Waiting On Others**, **On Hold**,
**Ready To Release**, **Completed**, **Cancelled**. Missing or unfamiliar statuses
remain visible in an extra, clearly labeled column. The manual **Planning lane**
field is still editable, but no longer decides which column contains the ticket.
The columns wrap on smaller screens rather than squeezing nine unreadable columns
into one row.

These are the statuses saved in Salesforce, not a continuously refreshed Jira
feed. A live agent lookup does not automatically update the saved ticket board.
Use the existing import or reviewed update workflow to refresh saved tickets.
**Review progress with an agent** starts a Task conversation that looks up open
tickets and recent Salesforce activity for the people in the filter.

Without an External Credential, Jira stays manual. The same import/export tools
remain available with a live connection, but do not use them to repeat an operation
already submitted or whose live outcome is unknown:

1. Filter the intended scope, then **Export drafts for Jira**. Review the plan.
   Epics export first; import them in Jira and confirm their real Jira keys before
   exporting dependent tickets. Exact CSVs and receipts remain in Salesforce Files.
2. Export the issues from Jira (all fields), select the CSV on Tickets, review
   ambiguous matches/unknown assignments, then **Confirm / resume import**.
   Completed chunks remain committed if a later chunk fails; retry the saved review.
3. Reconciliation choices and unsaved ticket edits are cached immediately in this
   browser tab and autosaved as private recovery drafts after a short pause. Watch
   the recovery status: a storage or server error means the private draft is not
   safely saved. **Save review** and **Save and close review** remain available.
   Restore private Jira drafts from **Library & recovery → Hand saved draft to
   host → Restore queued Jira work**. Restoration itself does not import/export
   or update a ticket.
4. Unsaved ticket editors also have **Save edits as draft and close**. Their original
   optimistic version stays with the draft, so later teammate edits cause a conflict
   instead of being overwritten. Autosaving a private draft is not saving changes
   to the shared ticket. Planning lanes, blockers, dependencies, follow-ups and
   snooze are local planning, not proof of Jira completion.
5. **Copy for Jira** includes only pending checklist actions. A cleared assignee is
   explicitly shown as **Unassign**; completed/dismissed actions remain history,
   not instructions to repeat. Confirm each part only after doing it in Jira.
   A same-timestamp/undated import cannot reverse that confirmation; export a newer
   Jira snapshot when the source changes. Archiving/unarchiving an exported ticket
   does not make it eligible for another creation export.

**Library & recovery tab.** Save extracted documents and targeted context, source
notebooks, notes, briefs, groups, snippets, source snapshots and dependency/context
packs. Save revisions before switching entries; earlier revisions remain available.
For an HTML backup, preview the JSON and choose Source/Task/Files recovery. The exact
original archive is saved first, including unknown data. Task recovery also offers
native ticket migration; unresolved identities and links require explicit review.
Keep the original binaries: extracted text is not a replacement for them.

**Document extraction.** Work attachments and Library documents parse in a
background worker, with progress and **Cancel**. The browser stays responsive;
Work's request fields remain usable. Cancelling, timing out or failing leaves the previous Library entry and
previously accepted Work attachments unchanged; a multi-file Work selection is
accepted only when the entire selection succeeds. Retry by selecting the file
again. Extraction stays in the browser; it does not upload documents to an
external service. Supported formats and warnings are unchanged; PDF extraction
is not included. Each file has a 60-second limit (Library input: 20 MiB; Work
attachment input: 25 MiB). Those are input-file limits, not conversation-message
limits: the complete request and prompt still must fit Salesforce's 1,500,000-
character limits. Use Library's selected context ranges or split the request rather
than dropping attachment text silently. A rejected overlong title or oversized first
message leaves the draft editable so you can correct it. If the response is uncertain
(for example, a lost connection), retry the unchanged **Start** request; Atlas keeps
its receipt to avoid creating another conversation.

**Reload recovery.** Unfinished Library forms and source-review notes are restored
from this browser tab when available. They are not a cross-device backup and do
not silently apply form changes, approve a source change or restore Flow-activation
consent. Save important work explicitly if a recovery warning appears. Closing the
browser tab can remove its local recovery data. New small Library saves reserve
one stable identity before writing; after a lost response, retry the recovered
entry rather than starting a duplicate. Storage failure blocks the first save,
so keep an explicit copy if the UI reports that recovery is unavailable.

**Native backup tab.** Export the permitted Atlas scope and inspect its completeness
and omissions. Preview a native archive, select records and dependencies, prepare a
review, resolve mappings, then explicitly acknowledge/apply it. Recovery is additive;
it never replaces existing records or deploys recovered Change histories. Files over
1,500,000 bytes and archives over 100 MiB need another retained backup; do not describe
an incomplete export as a complete backup. These archives hold your org's data, so
never put them anywhere public, such as a shared link.

**Salesforce changes tab.** Every change with its backup, the agent's proposal,
who decided and the deploy result. Switch between **All changes** and **Component
history** at the top.

- **Component history** lists every component Atlas has deployed or restored.
  Open one to see its versions, newest first: v1 is the original, and each deployed
  change or restore adds the next number, described by the change's one-line
  summary; a restore reads "Restored to v2". Click **Restore vN** to go back to that
  version.
- **Restore the backup** on a change puts back every component that change backed up.
- **Every restore is a new change.** Before it deploys, Atlas backs up what is in
  the org right now, including edits made outside Atlas, so the restore itself
  appears in the history and you can switch back by restoring the version before it.
  The confirmation lists what each component goes back to and what it replaces. A
  restore never deletes components created later and does not reverse record data.
  It is refused if the backup or any of those components changed after you opened
  the confirmation; reload and review again. The agent gets a short note naming what
  was restored and is told to re-read those components before changing them.
- **Free up storage** removes the backup, proposal and result files of finished
  changes older than 30, 90, 180 or 365 days. It shows how many changes, files and
  bytes that is, and how many restore points go, before you confirm. Each
  component's original version and its newest restore point are always kept, and
  the changes and their history stay; removed versions show "Backup removed to free
  storage" and cannot be restored. Files deleted this way go to the Salesforce
  Recycle Bin for its usual retention period.

## Removing Atlas

Delete the Atlas app, tab, page, Apex classes, LWCs, objects and permission set in
Setup, or deploy a destructive change. Deleting the objects deletes the tickets and
conversations, so export anything you need first. Backups stay in Salesforce Files.
