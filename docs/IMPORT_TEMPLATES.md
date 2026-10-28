# Setup and transaction import templates

Download the Excel workbooks from **Excel imports → Import templates**. The same files are packaged for offline desktop use; its download links open the native Save dialog. Editable cells are amber. Each workbook includes instructions and examples; example sheets are never imported.

## Setup

Use `SBCO_Setup_Template.xlsx` as an administrator. Keep the `Users`, `Offices` and `Pools` sheets and their row 1 headers. Unused sheets may be blank below their headers.

| Sheet   | Columns                                           | Rules                                                                                                                                                        |
| ------- | ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Users   | Full Name, Email, Role                            | Role is `Pa`, `Supervisor` or `Administrator`. Maximum 200 users.                                                                                            |
| Offices | Office ID, Office Name, Office Type, Parent SO ID | Type is `SO` or `BO`. A BO must reference an SO; an SO has no parent. Preserve IDs as text. Maximum 10,000 rows.                                             |
| Pools   | Pool Name, PA Email, Office ID, Random Percent    | One office per row; repeat pool details. PA Email may be blank, otherwise an active PA is required. Random Percent is an integer 0–100. Maximum 10,000 rows. |

Choose the completed workbook, select **Preview setup**, review the counts, then select **Import setup**. Preview does not save setup records. Import validates again and commits the complete file atomically. Existing identical records are skipped; conflicting details and office reassignments are rejected. Use the normal administration forms to edit existing records. File limit: 5 MB.

Passwords are excluded. New users receive distinct unguessable password hashes; an administrator must set their passwords using **Users → Reset password** before they can sign in. Setup import and preview outcomes are audited without storing raw workbook contents or passwords.

## Transactions

Use `SBCO_SO_Transactions_Template.xlsx` or `SBCO_BO_Transactions_Template.xlsx`. Keep `LongBook` first and preserve the header order.

- SO: enter SO ID in B1, name in C1 and report date in B2.
- BO: enter parent SO ID/name in B1/C1, BO ID/name in B2/C2 and report date in B3.
- Enter records from row 6. Every transaction needs a numeric Sl No and Account Number. Unnumbered rows are skipped.
- Keep account and reference IDs as text. Amounts are numeric INR with up to two decimal places. Blank Credit/Debit means zero.
- A blank Value Date uses the report date. A blank Type is inferred from the amounts.
- Upload through **Import transaction workbooks**, then check **Import history**. File limit: 20 MB; worksheet limit: 200,000 rows.
- Existing duplicate handling, office permissions and verification workflows apply. Templates do not import historical verification decisions or issued letters.

The named input sheets contain no sample business data. Fresh installations remain empty until the operator fills and imports them. Formatting and dropdowns are provided for 200 rows; copy a formatted row downward for larger office, pool or transaction files.

## Verification

`tests/setup_import.py` fills test-only copies of the actual distributed XLSX files and exercises preview, rollback after a late invalid pool reference, repeat imports, conflicting user roles, authorization, SO/BO ingestion, leading-zero accounts, exact amounts and date fallback. Run it only against an isolated test database. Native desktop coverage also imports a filled setup template without network access.
