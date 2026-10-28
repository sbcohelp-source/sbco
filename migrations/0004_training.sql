-- Metadata is used only in public. Each practice schema also runs the complete
-- migration set, without a public search_path fallback.
CREATE TABLE training_workspaces (
 owner_id uuid PRIMARY KEY REFERENCES users(id),
 generation uuid NOT NULL UNIQUE,
 schema_name text NOT NULL UNIQUE CHECK(schema_name ~ '^sbco_training_[0-9a-f]{32}$'),
 pa_id uuid NOT NULL,
 supervisor_id uuid NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);
