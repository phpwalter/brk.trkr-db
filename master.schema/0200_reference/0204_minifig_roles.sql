/*
===============================================================================
 File:           0200_reference/0204_minifig_roles.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Define extensible semantic roles for minifigure composition.
 Depends On:     reference schema
 Creates:        reference.minifig_roles
 Seed Data:      Core structural and accessory minifigure roles
 Key Rules:      Minifigure composition never assumes fixed humanoid anatomy.
                 Roles are extensible data rather than fixed head/torso/legs
                 columns.
 Validation:     Enforces unique role codes and verifies the baseline role set
                 was fully seeded.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0200_reference/0204_minifig_roles.sql', ARRAY['reference schema']::text[]);



CREATE TABLE reference.minifig_roles (
    minifig_role_id integer GENERATED ALWAYS AS IDENTITY,

    role_code text NOT NULL,
    display_name text NOT NULL,

    is_structural boolean NOT NULL DEFAULT true,
    is_accessory boolean NOT NULL DEFAULT false,
    allows_multiple boolean NOT NULL DEFAULT true,

    CONSTRAINT pk_minifig_roles
        PRIMARY KEY (minifig_role_id),

    CONSTRAINT uq_minifig_roles_code
        UNIQUE (role_code),

    CONSTRAINT ck_minifig_roles_code
        CHECK (role_code ~ '^[A-Z0-9_]+$'),

    CONSTRAINT ck_minifig_roles_name
        CHECK (btrim(display_name) <> '')
);

INSERT INTO reference.minifig_roles (
    role_code,
    display_name,
    is_structural,
    is_accessory,
    allows_multiple
)
VALUES
('HEAD',       'Head',       true,  false, true),
('TORSO',      'Torso',      true,  false, true),
('BODY',       'Body',       true,  false, true),
('ARM',        'Arm',        true,  false, true),
('HAND',       'Hand',       true,  false, true),
('LEG',        'Leg',        true,  false, true),
('LOWER_BODY', 'Lower Body', true,  false, true),
('WING',       'Wing',       true,  false, true),
('TAIL',       'Tail',       true,  false, true),
('HORN',       'Horn',       true,  false, true),
('SHELL',      'Shell',      true,  false, true),
('BASE',       'Base',       true,  false, true),
('HAIR',       'Hair',       false, true,  true),
('HEADGEAR',   'Headgear',   false, true,  true),
('CAPE',       'Cape',       false, true,  true),
('ACCESSORY',  'Accessory',  false, true,  true),
('OTHER',      'Other',      true,  false, true);

SELECT app.assert_true(
    (SELECT count(*) FROM reference.minifig_roles) = 17,
    'Expected exactly 17 baseline minifigure roles'
);

\echo '[PASS] 0204_minifig_roles.sql'
SELECT pg_temp.bt_mark_completed('0200_reference/0204_minifig_roles.sql');
