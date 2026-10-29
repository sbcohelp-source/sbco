# Local release acceptance — 29 October 2026

Automated checks establish that the tested behavior works with synthetic data. They do not constitute office approval. The office operator will review the reports and letters; that approval is still outstanding. Hosted deployment and legacy-data migration are outside the current fresh-local-installation scope.

## Browser and accessibility evidence

The test environment is the isolated web application at `http://localhost:3091`, with its isolated API at port 8091. No acceptance fixture was added to the fresh installation at port 3092. Browser plugin skill was not available, so validation used the project's Playwright workflow.

| Check                                  | Evidence                                                                                                     | Result                         |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------ | ------------------------------ |
| Chromium, Firefox and WebKit           | Three accessibility/report journeys, three shortcut journeys and one first-run journey per engine (21 total) | Passed                         |
| Page identity and meaningful rendering | SBCO title, expected heading and main content; no framework error overlay                                    | Passed                         |
| JavaScript and console health          | No page exceptions or unexpected console errors in the tested sign-in and administrator journeys             | Passed                         |
| Automated accessibility                | axe-core 4.14.0, WCAG 2 A/AA and 2.1 AA rule tags                                                            | No violations in tested states |
| Sign-in keyboard operation             | Email → Tab → password → Tab → Enter → Overview                                                              | Passed                         |
| Mobile navigation                      | Initial close-button focus, forward/reverse focus wrap, Escape close, focus restoration and link navigation  | Passed                         |
| Responsive reports                     | 1440×1000, 390×844 and 320×844; no document-wide horizontal overflow                                         | Passed                         |
| Report table access                    | Wide tables remain scrollable; focused region moves with the right-arrow key                                 | Passed                         |
| Report interaction                     | DPR and MPR selection, preview and PDF download                                                              | Passed                         |

The automated accessibility scan covers sign-in, imports, offices, users, verification, incidents, letters, reports, settings and My account, plus the open mobile navigation and DPR/MPR report states. Console checking excludes only the expected anonymous-session probe's 401 response from `/api/v1/me`. Screenshots were inspected for the overview, mobile report and PDF layouts. The fixes add managed mobile-menu focus and Escape handling, a skip link, and named keyboard-focusable report scrollers.

The separate keyboard-shortcut suite checks per-user preference persistence, enable/disable/reset, rejection of unsafe or duplicate bindings, focus-scoped saving, native required-field validation and prevention of duplicate submissions while busy. It also checks voucher navigation, the exact selected voucher/revision submitted by the match shortcut, protection of typing/composition/repeated keys/AltGraph, and suppression while mobile navigation is open. These command-issuing shortcut tests intercept the command requests and transaction query responses; they verify frontend behavior without adding or verifying office records. Backend command behavior has separate API tests.

The first-run wizard test uses mocked desktop IPC to check the welcome screen, administrator form, minimum password length, confirmation mismatch, Back navigation, focus and accessible errors, prevention of duplicate submissions, retry after a setup failure, and transition to sign-in. Passwords are cleared when returning to the welcome screen and are never saved in browser storage. Both stages pass the same axe rule checks, and desktop/mobile screenshots were inspected. This browser simulation does not replace the installed native setup tests; those scripts now follow the welcome step and password confirmation.

The rebuilt Linux installer subsequently passed the actual first-run wizard and operational workflow in a disposable container with networking disabled. Native tests saved the administrator's onboarding step and verified it after a full window reload. A separate prepare/reinstall/verify run preserved the original administrator, two transactions, import history, settings, saved onboarding step and exact daily-backup hash. All three native template Save dialogs produced byte-identical workbook files. This is same-version reinstall evidence, not certification of future schema-changing installer upgrades. The final offline bundle contains the tested installer and passes all 271 checksum entries.

This is not a WCAG conformance certificate. Manual screen-reader use, assistive technology combinations, all error states, real mobile hardware, and Safari on macOS/iOS still require human verification. Playwright WebKit on Linux is engine coverage, not a signed macOS desktop acceptance result.

To repeat:

```bash
source scripts/env.sh
# First create the isolated fixture account with tests/integration.py.
yarn playwright install chromium firefox webkit
yarn test:acceptance
```

The current machine used temporary Firefox/WebKit downloads under `/tmp/sbco-browser-engines`. Missing WebKit shared libraries were unpacked under `/tmp/sbco-webkit-deps`, with symlinks in that temporary browser bundle; system packages were not changed. Ordinary developer machines can use Playwright's documented browser prerequisite installation. Test screenshots and logs remain under `/tmp`, not in source control.

## PDF evidence and operator samples

Run `cargo build --locked -p sbco-documents --example render`, then `python3 tests/pdf_acceptance.py` after the API fixtures. The read-only sample generator writes these synthetic files under `data/operator-review/`:

| Sample                     | Purpose                                                                                                                  |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `SAMPLE-DPR.pdf`           | Calendar rows, work summary, signature and remarks                                                                       |
| `SAMPLE-MPR.pdf`           | Return dates, objection balances, age bands and staff work                                                               |
| `SAMPLE-issued-letter.pdf` | Exact previously issued fixture letter bytes, address, due date and required action                                      |
| `SAMPLE-long-fields.pdf`   | A long remark spanning two pages, repeated table headers, ten Indian/Arabic script samples and a 259-character reference |

The issued fixture letter retains its original bytes, so it has no added SAMPLE watermark. Its filename, folder README and synthetic office/account values identify it as a test artifact. It must not be sent as official correspondence.

The long-reference test exposed text running beyond the page. The fixed renderer inserts invisible break opportunities in ASCII runs of at least 24 characters; it leaves the stored field and complex-script shaping unchanged. The test now passes expected-text and page-boundary checks on all four PDFs. All six rendered sample pages were visually inspected, including the three-page long-field sample. This establishes layout and supported-glyph coverage, not linguistic approval of every script.

## Office operator review

Complete this with the office operator using authorized office data. Record corrections before approval; leave unchecked items pending.

Operator: ____________________ Office: ____________________ Date: ____________________

Application/installer version: ____________________ Review period: ____________________

- [ ] Setup: office names and IDs, parent SO links, PA assignments, roles and sample percentage match the office's intended setup.
- [ ] Transactions: fill and import one SO and one BO workbook; confirm leading zeros, exact credit/debit values, report dates, agent entries and RD default entries.
- [ ] Verification: PA can see only assigned work; match, mismatch, missing voucher and required reasons behave as expected.
- [ ] Supervisor: high-value and random reviews appear for the right staff; corrections retain the old result and the final result is correct.
- [ ] DPR: calendar days, work wording, staff contributions, remarks and signature columns match the approved office format.
- [ ] MPR: opening + raised/reopened − settled/closed = closing; category transfers, age bands and staff totals reconcile with a manually checked period.
- [ ] Period rules: the operator accepts India-time final-verification dates for progress reports, original report dates for transaction reports, and the disclosed effect of corrections on staff totals.
- [ ] Staffing: the explicitly unconfigured sanctioned-staff figure is acceptable or a required rule is supplied before release.
- [ ] Correspondence: the addressee, letter number, transaction references, objection wording, reply due date, signature and reminder wording match the office's format.
- [ ] PDFs: printed A4 pages remain legible; long names/remarks and required Indian-language scripts have correct shaping; continued tables and page numbers are understandable.
- [ ] History: issued-letter downloads retain their original bytes; incident compliance/reopening history and any history warnings are understood.
- [ ] Recovery: an authorized administrator can locate a successful backup and demonstrate recovery in a disposable workspace, without replacing the live office database.
- [ ] Daily use: keyboard-only operation and the intended operator's display/printer work; the operator can complete a representative end-to-end workday.
- [ ] Keyboard preferences: the operator can view, change, disable and restore shortcuts; the chosen key combinations work with the office's keyboard layout and operating-system language switching.

Required changes or exceptions: ______________________________________________________

Decision (approve / approve after listed changes / do not approve): ____________________

Operator signature: ____________________ Administrator sign-off: ____________________

## Release gates that need external input

| Gate                                       | Status                                                  | Needed evidence                                                                            |
| ------------------------------------------ | ------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Office format and workflow approval        | Awaiting office operator                                | Completed review above and any required changes                                            |
| Real office reconciliation                 | Awaiting authorized sample/office trial                 | Manually reconciled totals, objections and letters                                         |
| Windows desktop delivery                   | Hosted MSI/runtime checks pass; office approval pending | Successful MSI build/smoke plus actual Windows 10/11 office testing and signing identities |
| Hosted CI, HTTPS and production deployment | Application/Linux CI passed; deployment pending         | Intended server, HTTPS/DNS/certificates and production rehearsal                           |

Other automated backend, recovery, import-reliability and Linux installer evidence is recorded in [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md). Keep those results separate from the uncompleted human approval gates above.

## Persisted onboarding acceptance

The new six-step administrator guide and four-step staff introduction pass 18 acceptance cases across Chromium, Firefox and WebKit using the isolated application at port 3091. Coverage includes leaving/resuming, a full page reload, completion and review, PA/supervisor scope, actual staff creation and single-office pool assignment, failed-save retry and readiness. The empty-office UI case uses a labelled mocked response; `tests/onboarding.py` separately verifies the actual PostgreSQL completion gate in a disposable database. No acceptance fixture was added to port 3092.

Desktop (1440×1000) and mobile (390×844) screenshots were inspected. Tested states pass axe checks, have no framework overlay or application page errors, and do not overflow horizontally. Browser plugin was not available; the project Playwright workflow was used. Firefox/WebKit reuse the temporary browser runtime documented above. The loopback-only test API uses `SBCO_INSECURE_LOCAL_HTTP=1`; shared HTTPS deployments retain secure cookies.

Repeat with `yarn playwright test --config playwright.onboarding.config.ts` after preparing the isolated API/fixture administrator. This suite creates unique test users/offices and disables its test users afterwards. Never run it against an office database. Rust tests, frontend type/lint/format checks and contract checks pass; the existing API workflow suite and browser transaction journey also pass with fresh test vouchers.

## Help and isolated training acceptance

The Help and training suite passes 15 cases across Chromium, Firefox and WebKit (five per engine). These tests mock API responses deliberately to check frontend boundaries: offline help search and empty results, role-appropriate links, the searchable author/support entry, explicit enable and role changes with a full reload, disable preserving practice, typed deletion, rechecking counts and generation before deletion, failed deletion retaining training, malformed/stale selections failing closed, and a frozen workspace selection across client-side navigation. Training status/control calls carry no practice context. Mobile Help and training states pass axe checks and have no horizontal overflow at 390×844. Screenshots were visually inspected. Author is S K Singh; the support email opens a mail draft and sends nothing automatically.

A separate real Chromium journey against the isolated application at port 3091 signed in as the fixture PA, enabled a workspace containing 24 sample transactions, practised Administrator to create an additional office, switched to Supervisor and downloaded a DPR, disabled training and confirmed the real role remained PA, then resumed the same generation with the extra office intact. Confirmed deletion removed all practice counts and returned to live mode. The downloaded filename starts with `TRAINING-`; extracted PDF text contains `TRAINING / NOT FOR OFFICIAL USE`. No application page errors occurred. Only that fixture user's isolated practice records were created and removed; port 3092 was untouched. Backend schema isolation, concurrent generation protection and native IPC behavior have separate tests; mocked browser cases alone do not establish these guarantees.

Repeat the UI boundary tests with `yarn playwright test --config playwright.acceptance.config.ts help-training`. Repeat the real lifecycle only after preparing the disposable fixture account with `yarn playwright test --config playwright.training-live.config.ts`. The latter is restricted to port 3091 and creates/removes that fixture user's training workspace. Temporary evidence includes `/tmp/sbco-help-mobile.png`, `/tmp/sbco-training-mobile.png`, `/tmp/sbco-training-report.png`, and `/tmp/sbco-training-browser-DPR.pdf`.

Operator checks remain pending:

- [ ] Find a relevant Help topic, search for a problem, and locate the author/support contact.
- [ ] Enable training, identify its banner and practise each role without confusing practice with official office work.
- [ ] Disable and resume training, then review and delete practice records; understand that existing backups and downloads remain.
- [ ] Confirm that printed training reports are clearly marked and never used as official correspondence.

## Connected desktop setup acceptance

The connected-client browser simulation passes nine cases across Chromium, Firefox and WebKit (three per engine). It rejects non-HTTPS addresses, embedded account details, non-root paths and queries before invoking native configuration; preserves the typed address after unavailable/incompatible-server errors; retries; prevents duplicate in-flight submissions; and remembers a successfully configured server across a full page reload. A configured client opens assigned-account sign-in and never invokes local `setup_needed`, administrator creation or backup-status operations. Local backup/restore controls are absent. Password fields clear on a server change and the synthetic password is absent from browser storage.

An additional integration regression checks Change server while training is active. The initial implementation reloaded prematurely to the old server's sign-in. The corrected disconnect clears the native session and saved training selection, opens the prefilled connection wizard, and reloads only after the new server is successfully configured. This regression passes all three engines. Normal sign-out behavior remains covered separately.

The standalone wizard and five Help/training journeys were rerun alongside these checks: all 27 combined cases passed. TypeScript and scoped lint pass. The connected wizard's narrow-screen error state passes axe checks and has no horizontal overflow at 390×844; `/tmp/sbco-connection-mobile.png` was visually inspected. Help now explains the difference between standalone offline setup/local backups and the connected client's server account/network/server backups.

These tests mock native IPC. They establish frontend flow and boundary calls, not actual TLS validation, native configuration-file persistence, server compatibility enforcement, Windows credential handling or MSI installation. Those require the native transport tests and Windows build/runtime evidence. No connection was made to an office server and production port 3092 was untouched.

Repeat with `yarn playwright test --config playwright.acceptance.config.ts 'connection|first-run|help-training'`. Actual Windows operator acceptance must still check a trusted server certificate, unavailable/incompatible server handling, sign-in, restart persistence, server changes, expected role access, and server-managed backup/recovery.

## Hosted verification update — 29 October 2026

[Application and Linux CI passed](https://github.com/sbcohelp-source/sbco/actions/runs/40681285697) on commit `019116d`. The local production acceptance suite passed 45 cases across Chromium, Firefox and WebKit. The onboarding sign-out regression in commit `6a2c1c4` passed three targeted repetitions and the complete 18-case local production onboarding suite. [Windows server/client MSI install, repair and uninstall](https://github.com/sbcohelp-source/sbco/actions/runs/40864684093) now pass all six operations on a disposable Windows 2025 runner. Configured services, scheduled backup/restore and standalone lifecycle checks now pass; hosted Windows packaging checks do not replace the office operator gates above.

A further hosted WebKit failure exposed late onboarding data stealing focus from mobile navigation. A gated query reproduced the runtime issue; the guide now preserves external control focus while retaining intentional step-heading focus. The corrected production build passed five focus repetitions, all 45 acceptance cases and all 18 onboarding cases across the three engines. The regression deliberately mocks only onboarding progress so it cannot alter the shared fixture's saved guide state.

## Hosted Windows runtime evidence — 29 October 2026

[Configured same-version server replacement passed](https://github.com/sbcohelp-source/sbco/actions/runs/40889683192) from source build `40873108070` to `40881136580`. Both packages are version 0.1.0. Accounts/session, exact transactions, configuration values, service/TLS files, scheduled task/preferences and the existing archive survived; a new SYSTEM backup, API crash recovery, restart/repair and uninstall preservation passed afterward. Future version/schema upgrades, forced installer-failure rollback and office Windows 10/11 acceptance remain separate gates.

[The full shared-server rehearsal passed](https://github.com/sbcohelp-source/sbco/actions/runs/40883757329) on Windows 2025 against installer source `ac85c31`. It exercised actual guided setup, five services, trusted HTTPS and secure login, a template download, two worker-imported transactions, PDF export, isolated training reset, API child crash recovery, restart/repair and uninstall database preservation. [Refreshed server/client packaging smoke](https://github.com/sbcohelp-source/sbco/actions/runs/40876179179) passed all six MSI operations.

[The Windows standalone build](https://github.com/sbcohelp-source/sbco/actions/runs/40872620033) passed the actual PostgreSQL lifecycle/recovery test. [Standalone installer smoke](https://github.com/sbcohelp-source/sbco/actions/runs/40874936841) also passed installation, repair, uninstall and synthetic AppData/backup preservation. The clean final standalone package also passed [its own smoke](https://github.com/sbcohelp-source/sbco/actions/runs/40876658266). [Actual SYSTEM scheduled backup/restore passed](https://github.com/sbcohelp-source/sbco/actions/runs/40883720195), including exact restored data, retention, rollback and uninstall preservation. These hosted results do not replace the Windows 10/11 LAN, printer, accessibility and operator approvals in this checklist.
