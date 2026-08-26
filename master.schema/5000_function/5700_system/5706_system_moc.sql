/*
===============================================================================
 File:           5000_function/5700_system/5706_system_moc.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Enforce immutable MOC publication and fork invariants.
 Depends On:     moc.mocs
                 moc.revisions
                 moc.forks
 Creates:        moc.prevent_published_revision_mutation()
                 moc.validate_fork()
                 trg_moc_published_revision_immutable
                 trg_validate_moc_fork
 Key Rules:      Published MOC revisions cannot be updated or deleted.
                 Only published revisions may be forked.
                 Forking requires source forks_allowed = true.
                 Fork ancestry references the exact source revision.
 Validation:     Runtime triggers reject published mutation and invalid fork
                 relationships.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5700_system/5706_system_moc.sql', ARRAY['moc.mocs', 'moc.revisions', 'moc.forks']::text[]);



CREATE FUNCTION moc.prevent_published_revision_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status = 'PUBLISHED' THEN
        RAISE EXCEPTION
            'Published MOC revision "%" is immutable',
            OLD.moc_revision_id;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_moc_published_revision_immutable
BEFORE UPDATE OR DELETE
ON moc.revisions
FOR EACH ROW
EXECUTE FUNCTION moc.prevent_published_revision_mutation();


CREATE FUNCTION moc.validate_fork()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_allowed boolean;
    v_revision_moc uuid;
    v_revision_status moc.revision_status;
BEGIN
    SELECT forks_allowed
    INTO v_allowed
    FROM moc.mocs
    WHERE moc_id = NEW.source_moc_id;

    SELECT
        moc_id,
        status
    INTO
        v_revision_moc,
        v_revision_status
    FROM moc.revisions
    WHERE moc_revision_id =
          NEW.source_revision_id;

    IF v_allowed IS DISTINCT FROM true THEN
        RAISE EXCEPTION
            'Source MOC does not allow forks';
    END IF;

    IF v_revision_moc IS DISTINCT FROM
       NEW.source_moc_id
    THEN
        RAISE EXCEPTION
            'Fork source revision does not belong to source MOC';
    END IF;

    IF v_revision_status IS DISTINCT FROM
       'PUBLISHED'
    THEN
        RAISE EXCEPTION
            'Only published MOC revisions may be forked';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_moc_fork
BEFORE INSERT OR UPDATE
ON moc.forks
FOR EACH ROW
EXECUTE FUNCTION moc.validate_fork();

\echo '[PASS] 1006_moc_function.sql'
SELECT pg_temp.bt_mark_completed('5000_function/5700_system/5706_system_moc.sql');
