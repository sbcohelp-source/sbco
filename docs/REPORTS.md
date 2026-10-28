# Reports and correspondence

The web and desktop applications use the same Rust report reader and embedded PDF renderer. Each report reads totals, summaries, settings and transaction details from one PostgreSQL repeatable-read snapshot. Preview limits never constrain totals, daily work, staff activity or objection balances.

## Report definitions

- **DPR:** one row for every calendar day, including blank days; work counts, participating staff, signature and remarks columns.
- **Daily Detail:** staff contribution followed by office-grouped transaction details, final verification time/user, high-value flag and final reasons/notes.
- **MPR:** BO/AO and SO return dates represented by finalized work in the selected period; objection opening, raised/reopened, settled/closed and closing balances; outstanding age bands; staff activity and active staff count. Sanctioned staffing is explicitly marked unconfigured.
- **Transactions, Mismatch, MAP and Pending Voucher:** complete office totals and grouped transaction details. MAP and Pending Voucher require an outstanding incident of the corresponding type.

Progress reports use the current final verification record's date in Asia/Kolkata. They default to today minus 30 days through today, inclusive, and accept at most 366 days. Correcting a transaction can move its final verification into a later period; the staff-work report is not an immutable historical workload ledger. Other transaction reports use the original report date. Explicit office, queue, status and search filters remain in effect.

MPR objections use retained incident transitions, independently of transaction report dates. Opening means outstanding immediately before the first day; closing means outstanding at the end of the final day in India time. Reopening counts as raised. A category transfer settles the old category and raises the new one, with no change to the All category. Closing equals opening plus raised minus settled. Age is measured from the most recent opening in each category to period end, with bands below 90, 90–179 and at least 180 days.

An incident without a retained creation event is excluded from historical objection balances and ageing, and the report shows a reconciliation warning and count. Its dates are never guessed. This matters for prototype data created before history capture, and must be addressed in legacy migration acceptance. Finalized-work totals still include matching transactions.

## PDF behavior

The `sbco-documents` crate embeds Typst 0.15.1, the fixed template, and licensed Noto fonts. It installs no filesystem, package, network or system-font resolver. User text is passed as data rather than evaluated template code. Embedded coverage includes Latin, Devanagari, Bengali, Gujarati, Gurmukhi, Kannada, Malayalam, Odia, Tamil, Telugu and Arabic; characters outside the fonts' coverage produce an explicit error. This does not promise coverage of every Unicode character or linguistic approval of every script.

PDFs have A4 pages, repeated table headers, page numbers, wrapped text and a signatory. Detailed exports allow up to 20,000 transactions; serialized document input is capped at 16 MiB and rendering uses two blocking-worker slots. DPR and MPR use complete summaries instead of exporting every transaction. Detailed on-screen previews contain at most 100 transactions.

ASCII account/reference tokens of at least 24 uninterrupted characters receive invisible line-break opportunities between characters so narrow columns do not overflow. Stored values remain unchanged; copying text from a PDF may include these invisible separators and should not be used as a data-import source. Complex-script shaping is not changed by this rule.

Newly issued letters retain template version 2, PDF bytes and a hash. Subsequent downloads return the stored bytes, even after settings or incident status change. Existing version-1 letters retain their original PDF. Unissued previews are marked DRAFT.

## Verification and remaining acceptance

Automated coverage includes calendar gaps, range limits, missing glyphs, literal template-like text, reopened and transferred objections, India-time boundaries, age bands, office isolation, complete totals, all seven export types and unchanged issued bytes. Historical SQL fixtures use temporary tables and roll back:

```bash
cargo test --workspace --locked
cargo test --locked -p sbco-infrastructure historical_balances -- --ignored
python3 tests/integration.py
yarn test:e2e
```

Use only an isolated database for the API integration suite. It creates fixture data. PDF rendering and the report queries are also exercised without network access in the Linux prototype checks. The templates require operator approval against actual office formats, larger real workbooks, long-field samples and authorized production reconciliation before cutover.

`tests/pdf_acceptance.py` checks the production renderer with a multipage remark and a 259-character reference, verifies expected text/page boundaries, and creates synthetic office-review samples. The current samples passed visual review of all six pages. The [acceptance checklist](ACCEPTANCE_CHECKLIST.md) separates automated evidence from the office operator's pending format and workflow approval.
