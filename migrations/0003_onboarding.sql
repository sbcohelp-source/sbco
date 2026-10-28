CREATE TABLE user_onboarding (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    role text NOT NULL CHECK (role IN ('Pa', 'Supervisor', 'Administrator')),
    step text NOT NULL DEFAULT 'welcome'
        CHECK (step IN ('welcome', 'offices', 'team', 'preferences', 'import', 'work', 'review', 'ready')),
    completed boolean NOT NULL DEFAULT false,
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK (NOT completed OR step = 'ready')
);
