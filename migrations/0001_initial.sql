CREATE TABLE users (
 id uuid PRIMARY KEY, name text NOT NULL, email text NOT NULL UNIQUE, password_hash text NOT NULL,
 role text NOT NULL CHECK(role IN ('Pa','Supervisor','Administrator')), active boolean NOT NULL DEFAULT true,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE sessions (token_hash text PRIMARY KEY, user_id uuid NOT NULL REFERENCES users(id), expires_at timestamptz NOT NULL);
CREATE TABLE login_attempts (email text PRIMARY KEY, failures integer NOT NULL, blocked_until timestamptz NOT NULL);
CREATE TABLE offices (id text PRIMARY KEY, name text NOT NULL, office_type text NOT NULL CHECK(office_type IN ('SO','BO')), parent_id text REFERENCES offices(id), CHECK(parent_id IS NULL OR parent_id <> id));
CREATE TABLE pools (id uuid PRIMARY KEY, name text NOT NULL UNIQUE, pa_user uuid REFERENCES users(id), random_percent integer NOT NULL CHECK(random_percent BETWEEN 0 AND 100));
CREATE TABLE pool_offices (office_id text PRIMARY KEY REFERENCES offices(id), pool_id uuid NOT NULL REFERENCES pools(id) ON DELETE CASCADE);
CREATE TABLE settings (id boolean PRIMARY KEY DEFAULT true CHECK(id), value jsonb NOT NULL);
INSERT INTO settings VALUES (true, '{"random_percent":10,"reminder_days":7,"signatory":"","designation":"","reasons":["Voucher missing","Amount differs","Account differs","Other discrepancy"]}');
CREATE TABLE imports (
 id uuid PRIMARY KEY, filename text NOT NULL, file_hash text NOT NULL UNIQUE, content bytea NOT NULL,
 status text NOT NULL DEFAULT 'Queued', total integer NOT NULL DEFAULT 0, inserted integer NOT NULL DEFAULT 0,
 duplicates integer NOT NULL DEFAULT 0, failed integer NOT NULL DEFAULT 0, error text,
 imported_by uuid NOT NULL REFERENCES users(id), created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE jobs (id uuid PRIMARY KEY, import_id uuid UNIQUE REFERENCES imports(id), status text NOT NULL DEFAULT 'Queued', lease_id uuid, lease_until timestamptz, attempts integer NOT NULL DEFAULT 0, error text, created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE transactions (
 id uuid PRIMARY KEY, office_id text NOT NULL REFERENCES offices(id), report_type text NOT NULL, report_date date NOT NULL,
 value_date date NOT NULL, account_number text NOT NULL, scheme text NOT NULL DEFAULT '', transaction_id text NOT NULL DEFAULT '',
 reference_id text NOT NULL DEFAULT '', entry_user_id text NOT NULL DEFAULT '', transaction_type text NOT NULL DEFAULT '', description text NOT NULL DEFAULT '',
 credit numeric(20,2) NOT NULL, debit numeric(20,2) NOT NULL, agent boolean NOT NULL DEFAULT false, rd_default boolean NOT NULL DEFAULT false,
 primary_status text NOT NULL DEFAULT 'Pending' CHECK(primary_status IN ('Pending','Matched','Mismatch')),
 final_status text NOT NULL DEFAULT 'Pending' CHECK(final_status IN ('Pending','Matched','Mismatch')),
 reason text NOT NULL DEFAULT '', notes text NOT NULL DEFAULT '', final_reason text NOT NULL DEFAULT '', final_notes text NOT NULL DEFAULT '',
 verified_by uuid REFERENCES users(id), verified_at timestamptz, finalized_by uuid REFERENCES users(id), finalized_at timestamptz,
 revision integer NOT NULL DEFAULT 1, import_id uuid NOT NULL REFERENCES imports(id), source_sheet text NOT NULL, source_row integer NOT NULL,
 fingerprint text NOT NULL UNIQUE, created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(import_id,source_sheet,source_row)
);
CREATE INDEX transaction_queue ON transactions (office_id,report_date DESC,id) WHERE primary_status='Pending';
CREATE INDEX transaction_account ON transactions (account_number,id);
CREATE INDEX transaction_finalized ON transactions (finalized_at,office_id);
CREATE TABLE import_duplicates (id uuid PRIMARY KEY, import_id uuid NOT NULL REFERENCES imports(id), source_row integer NOT NULL, transaction_id uuid NOT NULL REFERENCES transactions(id), UNIQUE(import_id,source_row));
CREATE TABLE reviews (
 id uuid PRIMARY KEY, transaction_id uuid NOT NULL REFERENCES transactions(id), revision integer NOT NULL,
 basis text NOT NULL, sample integer NOT NULL, percentage integer NOT NULL, pa_status text NOT NULL, pa_reason text NOT NULL,
 status text NOT NULL DEFAULT 'Pending', supervisor_status text, reason text, notes text, reviewed_by uuid REFERENCES users(id), reviewed_at timestamptz,
 UNIQUE(transaction_id,revision)
);
CREATE TABLE corrections (
 id uuid PRIMARY KEY, transaction_id uuid NOT NULL REFERENCES transactions(id), revision integer NOT NULL,
 proposed_status text NOT NULL, reason text NOT NULL, notes text NOT NULL, request_reason text NOT NULL,
 status text NOT NULL DEFAULT 'Pending Approval', requested_by uuid NOT NULL REFERENCES users(id), requested_at timestamptz NOT NULL DEFAULT now(),
 reviewed_by uuid REFERENCES users(id), reviewed_at timestamptz, review_notes text
);
CREATE UNIQUE INDEX one_pending_correction ON corrections (transaction_id) WHERE status='Pending Approval';
CREATE TABLE incidents (
 id uuid PRIMARY KEY, transaction_id uuid NOT NULL UNIQUE REFERENCES transactions(id), office_id text NOT NULL REFERENCES offices(id),
 incident_type text NOT NULL, issue text NOT NULL, status text NOT NULL DEFAULT 'Open', due_date date,
 compliance_reference text, compliance_notes text, complied_by uuid REFERENCES users(id), complied_at timestamptz
);
CREATE SEQUENCE letter_number;
CREATE TABLE letters (
 id uuid PRIMARY KEY, number text NOT NULL UNIQUE, office_id text NOT NULL REFERENCES offices(id), kind text NOT NULL,
 parent_id uuid REFERENCES letters(id), round integer NOT NULL DEFAULT 0, due_date date NOT NULL, status text NOT NULL DEFAULT 'Draft',
 created_at timestamptz NOT NULL DEFAULT now(), issued_by uuid REFERENCES users(id), issued_at timestamptz,
 pdf bytea, pdf_hash text, template_version integer NOT NULL DEFAULT 1
);
CREATE TABLE letter_items (letter_id uuid NOT NULL REFERENCES letters(id), incident_id uuid NOT NULL REFERENCES incidents(id), is_initial boolean NOT NULL, PRIMARY KEY(letter_id,incident_id));
CREATE UNIQUE INDEX one_initial_letter ON letter_items(incident_id) WHERE is_initial;
CREATE UNIQUE INDEX one_reminder_round ON letters(parent_id,round) WHERE parent_id IS NOT NULL;
CREATE TABLE audit (id bigserial PRIMARY KEY, actor_id uuid REFERENCES users(id), action text NOT NULL, entity_id text, detail jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE command_receipts (request_id uuid PRIMARY KEY, actor_id uuid NOT NULL REFERENCES users(id), command_hash text NOT NULL, result jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE legacy_ids (source text NOT NULL, entity text NOT NULL, legacy_id text NOT NULL, new_id text NOT NULL, PRIMARY KEY(source,entity,legacy_id));
