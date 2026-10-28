CREATE TABLE change_history (
 id bigserial PRIMARY KEY,
 entity text NOT NULL,
 entity_id uuid NOT NULL,
 actor_id uuid REFERENCES users(id),
 request_id uuid,
 before_value jsonb,
 after_value jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX change_history_entity ON change_history(entity,entity_id,id);
CREATE INDEX change_history_request ON change_history(request_id);

CREATE FUNCTION retain_change() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE previous jsonb;
DECLARE current_value jsonb;
BEGIN
 current_value := to_jsonb(NEW) - 'pdf';
 IF TG_OP = 'UPDATE' THEN
   previous := to_jsonb(OLD) - 'pdf';
   IF previous = current_value THEN RETURN NEW; END IF;
 END IF;
 INSERT INTO change_history(entity,entity_id,actor_id,request_id,before_value,after_value)
 VALUES(TG_TABLE_NAME,NEW.id,nullif(current_setting('sbco.actor_id',true),'')::uuid,
        nullif(current_setting('sbco.request_id',true),'')::uuid,previous,current_value);
 RETURN NEW;
END;
$$;
CREATE TRIGGER transaction_history AFTER UPDATE ON transactions FOR EACH ROW EXECUTE FUNCTION retain_change();
CREATE TRIGGER review_history AFTER INSERT OR UPDATE ON reviews FOR EACH ROW EXECUTE FUNCTION retain_change();
CREATE TRIGGER correction_history AFTER INSERT OR UPDATE ON corrections FOR EACH ROW EXECUTE FUNCTION retain_change();
CREATE TRIGGER incident_history AFTER INSERT OR UPDATE ON incidents FOR EACH ROW EXECUTE FUNCTION retain_change();
CREATE TRIGGER letter_history AFTER INSERT OR UPDATE ON letters FOR EACH ROW EXECUTE FUNCTION retain_change();

CREATE FUNCTION reject_history_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 RAISE EXCEPTION 'History is append-only';
END;
$$;
CREATE TRIGGER immutable_history BEFORE UPDATE OR DELETE OR TRUNCATE ON change_history
 FOR EACH STATEMENT EXECUTE FUNCTION reject_history_change();
CREATE TRIGGER immutable_audit BEFORE UPDATE OR DELETE OR TRUNCATE ON audit
 FOR EACH STATEMENT EXECUTE FUNCTION reject_history_change();
