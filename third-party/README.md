# Supplemental license notices

`saxes-5.0.1-LICENSE.txt` is the unmodified upstream license downloaded from
https://raw.githubusercontent.com/lddubeau/saxes/v5.0.1/LICENSE on 2026-10-08.
The npm 5.0.1 package omits that file.

`node scripts/licenses.mjs` rebuilds `THIRD-PARTY-NOTICES.txt` from installed,
locked production packages, README license sections and the extra notices embedded
in ExcelJS's browser distribution. Node-only unzipper helpers (`binary`, `buffers`,
`chainsaw`) and the empty `https` placeholder are not bundled in the browser HTML.
Do not fetch licenses at application runtime.
