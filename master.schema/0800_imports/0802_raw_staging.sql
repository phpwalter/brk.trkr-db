/*
===============================================================================
 File:           0800_imports/0802_raw_staging.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Preserve raw user-import records and run-scoped authoritative
                 staging records.
 Depends On:     import.jobs
                 import.source_runs
 Creates:        import.raw_records
                 import.source_stage_records
                 import.source_run_steps
                 import.source_run_step_progress
 Key Rules:      Raw/staged data never mutates canonical catalog or ownership
                 directly.
                 Authoritative staging is scoped to one source run/dataset.
                 Rebrickable MOC staging is rejected by runtime import policy.
 Validation:     Enforces positive optional source row numbers, valid dataset/
                 entity namespace names and required JSON payloads.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0800_imports/0802_raw_staging.sql', ARRAY['import.jobs', 'import.source_runs']::text[]);



CREATE TABLE import.raw_records (
    raw_record_id bigint GENERATED ALWAYS AS IDENTITY,

    import_job_id uuid NOT NULL,

    source_row_number bigint,
    raw_payload jsonb NOT NULL,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_raw_records
        PRIMARY KEY (raw_record_id),

    CONSTRAINT fk_raw_records_job
        FOREIGN KEY (import_job_id)
        REFERENCES import.jobs(import_job_id)
        ON DELETE CASCADE,

    CONSTRAINT ck_raw_records_row
        CHECK (
            source_row_number IS NULL
            OR source_row_number > 0
        )
);

CREATE INDEX ix_raw_records_job
    ON import.raw_records(import_job_id);


CREATE TABLE import.source_stage_records (
    source_stage_record_id bigint GENERATED ALWAYS AS IDENTITY,

    source_run_id uuid NOT NULL,

    dataset_name text NOT NULL,
    entity_namespace text NOT NULL,

    source_row_number bigint,

    normalized_payload jsonb NOT NULL,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_source_stage_records
        PRIMARY KEY (source_stage_record_id),

    CONSTRAINT fk_source_stage_records_run
        FOREIGN KEY (source_run_id)
        REFERENCES import.source_runs(source_run_id)
        ON DELETE CASCADE,

    CONSTRAINT ck_source_stage_records_dataset
        CHECK (btrim(dataset_name) <> ''),

    CONSTRAINT ck_source_stage_records_namespace
        CHECK (
            entity_namespace ~ '^[A-Z0-9_]+$'
        ),

    CONSTRAINT ck_source_stage_records_row
        CHECK (
            source_row_number IS NULL
            OR source_row_number > 0
        )
);

CREATE INDEX ix_source_stage_records_scope
    ON import.source_stage_records(
        source_run_id,
        dataset_name,
        entity_namespace
    );

SELECT app.assert_table_exists(
    'import',
    'raw_records'
);

SELECT app.assert_table_exists(
    'import',
    'source_stage_records'
);

\echo '[PASS] 0802_raw_staging.sql'

/* Rebrickable element reconciliation lookup support. */
CREATE INDEX IF NOT EXISTS ix_source_stage_records_external_element
    ON import.source_stage_records (
        source_run_id,
        dataset_name,
        entity_namespace,
        ((normalized_payload ->> 'element_id'))
    );


-- -----------------------------------------------------------------------------
-- Durable Rebrickable checkpoint state
-- Canonicalized from the working live database after Phase 5.
-- -----------------------------------------------------------------------------
CREATE TABLE "import"."source_run_steps" (
    "source_run_id" uuid NOT NULL,
    "step_name" text NOT NULL,
    "step_order" integer NOT NULL,
    "status" text DEFAULT 'PENDING'::text NOT NULL,
    "attempt_count" integer DEFAULT 0 NOT NULL,
    "started_at" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
    "completed_at" timestamp with time zone,
    "failed_at" timestamp with time zone,
    "last_error" text,
    CONSTRAINT "source_run_steps_pkey" PRIMARY KEY (source_run_id, step_name),
    CONSTRAINT "source_run_steps_source_run_id_step_order_key" UNIQUE (source_run_id, step_order),
    CONSTRAINT "source_run_steps_source_run_id_fkey" FOREIGN KEY (source_run_id) REFERENCES import.source_runs(source_run_id) ON DELETE CASCADE,
    CONSTRAINT "source_run_steps_attempt_count_check" CHECK (attempt_count >= 0),
    CONSTRAINT "source_run_steps_status_check" CHECK (status = ANY (ARRAY['PENDING'::text, 'RUNNING'::text, 'COMPLETED'::text, 'FAILED'::text]))
);

CREATE TABLE "import"."source_run_step_progress" (
    "source_run_id" uuid NOT NULL,
    "step_name" text NOT NULL,
    "substep_name" text NOT NULL,
    "step_order" integer NOT NULL,
    "substep_order" integer NOT NULL,
    "status" text DEFAULT 'PENDING'::text NOT NULL,
    "rows_expected" bigint,
    "rows_processed" bigint DEFAULT 0 NOT NULL,
    "last_source_row_number" bigint,
    "batch_count" integer DEFAULT 0 NOT NULL,
    "attempt_count" integer DEFAULT 0 NOT NULL,
    "started_at" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
    "completed_at" timestamp with time zone,
    "failed_at" timestamp with time zone,
    "last_error" text,
    CONSTRAINT "source_run_step_progress_pkey" PRIMARY KEY (source_run_id, step_name, substep_name),
    CONSTRAINT "source_run_step_progress_source_run_id_step_order_substep_o_key" UNIQUE (source_run_id, step_order, substep_order),
    CONSTRAINT "source_run_step_progress_source_run_id_step_name_fkey" FOREIGN KEY (source_run_id, step_name) REFERENCES import.source_run_steps(source_run_id, step_name) ON DELETE CASCADE,
    CONSTRAINT "source_run_step_progress_attempt_count_check" CHECK (attempt_count >= 0),
    CONSTRAINT "source_run_step_progress_batch_count_check" CHECK (batch_count >= 0),
    CONSTRAINT "source_run_step_progress_rows_processed_check" CHECK (rows_processed >= 0),
    CONSTRAINT "source_run_step_progress_status_check" CHECK (status = ANY (ARRAY['PENDING'::text, 'RUNNING'::text, 'COMPLETED'::text, 'FAILED'::text]))
);
CREATE INDEX IF NOT EXISTS ix_source_run_step_progress_status ON import.source_run_step_progress USING btree (source_run_id, status, step_order, substep_order);


-- BRICKTRACKR_PHASE6_CANONICAL_RELATIONSHIPS_V1
CREATE TABLE catalog.external_item_relationships (
    external_item_relationship_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),
    source_id smallint NOT NULL
        REFERENCES reference.external_sources(source_id) ON DELETE RESTRICT,
    entity_namespace text NOT NULL DEFAULT 'PART_RELATIONSHIP',
    external_relationship_key text NOT NULL,
    source_relationship_code text NOT NULL,
    child_external_id text NOT NULL,
    parent_external_id text NOT NULL,
    child_catalog_item_id uuid
        REFERENCES catalog.items(catalog_item_id) ON DELETE RESTRICT,
    parent_catalog_item_id uuid
        REFERENCES catalog.items(catalog_item_id) ON DELETE RESTRICT,
    catalog_item_relationship_id uuid
        REFERENCES catalog.item_relationships(catalog_item_relationship_id) ON DELETE SET NULL,
    reconciliation_status text NOT NULL,
    reconciliation_note text,
    source_present boolean NOT NULL DEFAULT true,
    first_seen_run_id uuid NOT NULL
        REFERENCES import.source_runs(source_run_id) ON DELETE RESTRICT,
    last_seen_run_id uuid NOT NULL
        REFERENCES import.source_runs(source_run_id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT ck_external_item_relationships_namespace
        CHECK (btrim(entity_namespace) <> ''),
    CONSTRAINT ck_external_item_relationships_key
        CHECK (btrim(external_relationship_key) <> ''),
    CONSTRAINT ck_external_item_relationships_code
        CHECK (btrim(source_relationship_code) <> ''),
    CONSTRAINT ck_external_item_relationships_child_external
        CHECK (btrim(child_external_id) <> ''),
    CONSTRAINT ck_external_item_relationships_parent_external
        CHECK (btrim(parent_external_id) <> ''),
    CONSTRAINT ck_external_item_relationships_status
        CHECK (reconciliation_status IN ('MAPPED', 'UNMAPPED', 'QUARANTINED')),
    CONSTRAINT uq_external_item_relationships_source_key
        UNIQUE (source_id, entity_namespace, external_relationship_key)
);

CREATE INDEX ix_external_item_relationships_source_present
    ON catalog.external_item_relationships (source_id, entity_namespace, source_present);

CREATE INDEX ix_external_item_relationships_child
    ON catalog.external_item_relationships (child_catalog_item_id)
    WHERE child_catalog_item_id IS NOT NULL;

CREATE INDEX ix_external_item_relationships_parent
    ON catalog.external_item_relationships (parent_catalog_item_id)
    WHERE parent_catalog_item_id IS NOT NULL;

CREATE INDEX ix_external_item_relationships_canonical
    ON catalog.external_item_relationships (catalog_item_relationship_id)
    WHERE catalog_item_relationship_id IS NOT NULL;

SELECT pg_temp.bt_mark_completed('0800_imports/0802_raw_staging.sql');

-- BEGIN BRICKTRACKR REBRICKABLE PHASE 5 CANONICAL: import.source_stage_records indexes
CREATE INDEX IF NOT EXISTS ix_source_stage_records_inventory_id
    ON import.source_stage_records (
        source_run_id,
        dataset_name,
        entity_namespace,
        ((normalized_payload ->> 'inventory_id'))
    );

CREATE INDEX IF NOT EXISTS ix_source_stage_records_checkpoint
    ON import.source_stage_records (
        source_run_id,
        dataset_name,
        entity_namespace,
        source_row_number
    );
-- END BRICKTRACKR REBRICKABLE PHASE 5 CANONICAL: import.source_stage_records indexes
