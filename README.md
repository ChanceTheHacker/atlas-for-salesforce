# Atlas for Salesforce

Atlas is a native Lightning app that lets an AI agent work inside a Salesforce org
with your own login. The agent can read anything your login can, but every metadata
change it proposes gets a ZIP backup of what is there now, a reviewed diff and your
approval before Atlas deploys it. Each component keeps a numbered version history,
and any version restores in one click as a new change that backs up the current
version first.

Around that, Atlas keeps shared tickets as Salesforce records, plans work with Jira
(by CSV, or live once you connect it), stores extracted documents and context in a
library, and exports and recovers its own data.

Everything Atlas adds to an org has a name starting with `Atlas`: labels such as
"Atlas Ticket" and API names such as `Atlas_Ticket__c`.

## Install

[docs/atlas-setup.md](docs/atlas-setup.md) walks through building the deployment
ZIP, deploying it to a sandbox, and first use.

## Develop

You need a current Node.js; it is tested with Node 24.

```sh
npm ci
npm test                      # the full test suite
npm run build:salesforce      # rebuilds the two static resources
npm run package:salesforce    # builds the deployment ZIP in artifacts/
```

One test runs the document-extraction worker in headless Chromium. It uses
Playwright's own browser if one is installed; set `CHROMIUM_PATH` to use a system
browser instead (for example `CHROMIUM_PATH=/usr/bin/chromium npm test`). With no
browser available, that one test is skipped.

`salesforce/` is a standard Salesforce DX project. `salesforce/static-src/` and
`src/` hold the browser code that the build bundles into the `Atlas_Files` and
`Atlas_Extract` static resources; the built files are not committed.

## Licence

Atlas is released under the [MIT licence](LICENSE). Third-party packages bundled
into the static resources keep their own licences, which are listed in
[THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt).
