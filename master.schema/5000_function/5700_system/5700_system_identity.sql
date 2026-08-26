/*
===============================================================================
 File:           5000_function/5700_system/5700_system_identity.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Implement identity resolution, family capability checks,
                 guardianship-based managed-child access, and owner authorization.
 Depends On:     identity.users
                 identity.families
                 identity.family_memberships
                 identity.family_member_permissions
                 identity.guardianships
                 identity.owners
 Creates:        identity.current_user_id()
                 identity.current_user_id_optional()
                 identity.ensure_owner_for_user()
                 identity.ensure_owner_for_family()
                 identity.has_family_capability()
                 identity.can_manage_user()
                 identity.can_view_owner()
                 identity.can_manage_owner()
                 identity.can_transfer_between()
                 identity.validate_guardianship()
                 trg_validate_guardianship
 Key Rules:      Shared family resources distinguish VIEW from MANAGE capability.
                 PARENT members retain full family-resource authority.
                 Non-parent family authority is driven by the permission row
                 attached to that actor's active membership.
                 Managed-child personal resources may be managed only by the
                 user themself or an active guardian in the same active family.
                 The application connection is trusted to set
                 app.current_user_id transaction-locally after authenticating
                 the end user.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5700_system/5700_system_identity.sql', ARRAY['identity.users', 'identity.families', 'identity.family_memberships', 'identity.family_member_permissions', 'identity.guardianships', 'identity.owners']::text[]);



CREATE FUNCTION identity.current_user_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
SET search_path = pg_catalog
AS $$
DECLARE
    v_raw text;
BEGIN
    v_raw := NULLIF(pg_catalog.current_setting('app.current_user_id', true), '');

    IF v_raw IS NULL THEN
        RAISE EXCEPTION 'Authenticated database user context is not established'
            USING ERRCODE = '28000';
    END IF;

    BEGIN
        RETURN v_raw::uuid;
    EXCEPTION
        WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'Authenticated database user context is invalid'
                USING ERRCODE = '28000';
    END;
END;
$$;


/*
 * Anonymous-safe identity lookup.
 *
 * This helper is deliberately separate from current_user_id(). Use it only
 * where anonymous access is an explicit part of the API contract (for example,
 * PUBLIC/UNLISTED exact-ID reads). Authorization-sensitive code must use the
 * fail-closed identity.current_user_id().
 */
CREATE FUNCTION identity.current_user_id_optional()
RETURNS uuid
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
SET search_path = pg_catalog
AS $$
DECLARE
    v_raw text;
BEGIN
    v_raw := NULLIF(pg_catalog.current_setting('app.current_user_id', true), '');

    IF v_raw IS NULL THEN
        RETURN NULL;
    END IF;

    BEGIN
        RETURN v_raw::uuid;
    EXCEPTION
        WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'Authenticated database user context is invalid'
                USING ERRCODE = '28000';
    END;
END;
$$;


CREATE FUNCTION identity.ensure_owner_for_user(
    p_user_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
    v_owner_id uuid;
BEGIN
    INSERT INTO identity.owners (
        owner_type,
        user_id
    )
    VALUES (
        'USER',
        p_user_id
    )
    ON CONFLICT (user_id)
    WHERE owner_type = 'USER'
      AND user_id IS NOT NULL
    DO UPDATE
       SET user_id = EXCLUDED.user_id
    RETURNING owner_id
    INTO v_owner_id;

    RETURN v_owner_id;
END;
$$;


CREATE FUNCTION identity.ensure_owner_for_family(
    p_family_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
    v_owner_id uuid;
BEGIN
    INSERT INTO identity.owners (
        owner_type,
        family_id
    )
    VALUES (
        'FAMILY',
        p_family_id
    )
    ON CONFLICT (family_id)
    WHERE owner_type = 'FAMILY'
      AND family_id IS NOT NULL
    DO UPDATE
       SET family_id = EXCLUDED.family_id
    RETURNING owner_id
    INTO v_owner_id;

    RETURN v_owner_id;
END;
$$;


/*
 * p_access is VIEW or MANAGE.
 *
 * The permission row is optional. Its absence means no delegated capability
 * for non-parent members. PARENT members have full family-resource authority.
 */
CREATE FUNCTION identity.has_family_capability(
    p_actor_user_id uuid,
    p_family_id uuid,
    p_capability text,
    p_access text DEFAULT 'MANAGE'
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM identity.family_memberships fm
        LEFT JOIN identity.family_member_permissions p
          ON p.family_membership_id = fm.family_membership_id
        WHERE fm.family_id = p_family_id
          AND fm.user_id = p_actor_user_id
          AND fm.membership_status = 'ACTIVE'
          AND (
              fm.member_role = 'PARENT'
              OR CASE upper(p_access)
                  WHEN 'VIEW' THEN
                      CASE upper(p_capability)
                          WHEN 'COLLECTION'
                              THEN coalesce(p.can_view_family_collection, false)
                          WHEN 'WISHLIST'
                              THEN coalesce(p.can_view_family_wanted, false)
                          WHEN 'MOCS'
                              THEN coalesce(p.can_view_family_mocs, false)
                          WHEN 'STORAGE'
                              THEN coalesce(p.can_view_family_storage, false)
                          WHEN 'PURCHASES'
                              THEN coalesce(p.can_view_family_purchases, false)
                          WHEN 'AUDIT'
                              THEN coalesce(p.can_view_family_audit, false)
                          WHEN 'FAMILY'
                              THEN coalesce(p.can_manage_family, false)
                          ELSE false
                      END
                  WHEN 'MANAGE' THEN
                      CASE upper(p_capability)
                          WHEN 'COLLECTION'
                              THEN coalesce(p.can_manage_family_collection, false)
                          WHEN 'WISHLIST'
                              THEN coalesce(p.can_manage_family_wanted, false)
                          WHEN 'MOCS'
                              THEN coalesce(p.can_manage_family_mocs, false)
                          WHEN 'STORAGE'
                              THEN coalesce(p.can_manage_family_storage, false)
                          WHEN 'PURCHASES'
                              THEN coalesce(p.can_manage_family_purchases, false)
                          WHEN 'FAMILY'
                              THEN coalesce(p.can_manage_family, false)
                          ELSE false
                      END
                  ELSE false
              END
          )
    );
$$;


CREATE FUNCTION identity.can_manage_user(
    p_actor_user_id uuid,
    p_subject_user_id uuid,
    p_capability text DEFAULT 'PROFILE'
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT
        p_actor_user_id IS NOT NULL
        AND p_subject_user_id IS NOT NULL
        AND (
            p_actor_user_id = p_subject_user_id
            OR (
                upper(p_capability) <> 'FAMILY'
                AND EXISTS (
                    SELECT 1
                    FROM identity.guardianships g
                    JOIN identity.users child
                      ON child.user_id = g.child_user_id
                    JOIN identity.family_memberships guardian_membership
                      ON guardian_membership.family_id = g.family_id
                     AND guardian_membership.user_id = g.guardian_user_id
                     AND guardian_membership.membership_status = 'ACTIVE'
                     AND guardian_membership.member_role IN ('PARENT', 'ADULT')
                    JOIN identity.family_memberships child_membership
                      ON child_membership.family_id = g.family_id
                     AND child_membership.user_id = g.child_user_id
                     AND child_membership.membership_status = 'ACTIVE'
                     AND child_membership.member_role = 'CHILD'
                    WHERE g.guardian_user_id = p_actor_user_id
                      AND g.child_user_id = p_subject_user_id
                      AND g.revoked_at IS NULL
                      AND child.account_management_type = 'MANAGED_CHILD'
                )
            )
        );
$$;


CREATE FUNCTION identity.can_view_owner(
    p_actor_user_id uuid,
    p_owner_id uuid,
    p_capability text DEFAULT 'COLLECTION'
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM identity.owners o
        WHERE o.owner_id = p_owner_id
          AND (
              (
                  o.owner_type = 'USER'
                  AND identity.can_manage_user(
                      p_actor_user_id,
                      o.user_id,
                      p_capability
                  )
              )
              OR
              (
                  o.owner_type = 'FAMILY'
                  AND identity.has_family_capability(
                      p_actor_user_id,
                      o.family_id,
                      p_capability,
                      'VIEW'
                  )
              )
          )
    );
$$;


CREATE FUNCTION identity.can_manage_owner(
    p_actor_user_id uuid,
    p_owner_id uuid,
    p_capability text DEFAULT 'COLLECTION'
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM identity.owners o
        WHERE o.owner_id = p_owner_id
          AND (
              (
                  o.owner_type = 'USER'
                  AND identity.can_manage_user(
                      p_actor_user_id,
                      o.user_id,
                      p_capability
                  )
              )
              OR
              (
                  o.owner_type = 'FAMILY'
                  AND identity.has_family_capability(
                      p_actor_user_id,
                      o.family_id,
                      p_capability,
                      'MANAGE'
                  )
              )
          )
    );
$$;


CREATE FUNCTION identity.can_view_family_shared_owner(
    p_actor_user_id uuid,
    p_owner_id uuid,
    p_capability text
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM identity.owners o
        WHERE o.owner_id = p_owner_id
          AND (
              (
                  o.owner_type = 'USER'
                  AND (
                      identity.can_manage_user(
                          p_actor_user_id,
                          o.user_id,
                          p_capability
                      )
                      OR EXISTS (
                          SELECT 1
                          FROM identity.family_memberships actor_membership
                          JOIN identity.family_memberships owner_membership
                            ON owner_membership.family_id =
                               actor_membership.family_id
                           AND owner_membership.user_id = o.user_id
                           AND owner_membership.membership_status = 'ACTIVE'
                          WHERE actor_membership.user_id = p_actor_user_id
                            AND actor_membership.membership_status = 'ACTIVE'
                      )
                  )
              )
              OR
              (
                  o.owner_type = 'FAMILY'
                  AND identity.can_view_owner(
                      p_actor_user_id,
                      o.owner_id,
                      p_capability
                  )
              )
          )
    );
$$;


CREATE FUNCTION identity.can_transfer_between(
    p_actor_user_id uuid,
    p_from_owner_id uuid,
    p_to_owner_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    WITH owner_pair AS (
        SELECT
            src.owner_type AS from_type,
            src.user_id AS from_user_id,
            src.family_id AS from_family_id,
            dst.owner_type AS to_type,
            dst.user_id AS to_user_id,
            dst.family_id AS to_family_id
        FROM identity.owners src
        CROSS JOIN identity.owners dst
        WHERE src.owner_id = p_from_owner_id
          AND dst.owner_id = p_to_owner_id
    )
    SELECT EXISTS (
        SELECT 1
        FROM owner_pair op
        WHERE
            (
                (
                    op.from_type = 'USER'
                    AND identity.can_manage_user(
                        p_actor_user_id,
                        op.from_user_id,
                        'COLLECTION'
                    )
                )
                OR
                (
                    op.from_type = 'FAMILY'
                    AND EXISTS (
                        SELECT 1
                        FROM identity.family_memberships fm
                        LEFT JOIN identity.family_member_permissions p
                          ON p.family_membership_id = fm.family_membership_id
                        WHERE fm.family_id = op.from_family_id
                          AND fm.user_id = p_actor_user_id
                          AND fm.membership_status = 'ACTIVE'
                          AND (
                              fm.member_role = 'PARENT'
                              OR coalesce(p.can_transfer_from_family, false)
                          )
                    )
                )
            )
            AND
            (
                (
                    op.to_type = 'USER'
                    AND identity.can_manage_user(
                        p_actor_user_id,
                        op.to_user_id,
                        'COLLECTION'
                    )
                )
                OR
                (
                    op.to_type = 'FAMILY'
                    AND EXISTS (
                        SELECT 1
                        FROM identity.family_memberships fm
                        LEFT JOIN identity.family_member_permissions p
                          ON p.family_membership_id = fm.family_membership_id
                        WHERE fm.family_id = op.to_family_id
                          AND fm.user_id = p_actor_user_id
                          AND fm.membership_status = 'ACTIVE'
                          AND (
                              fm.member_role = 'PARENT'
                              OR coalesce(p.can_transfer_to_family, false)
                          )
                    )
                )
            )
    );
$$;


CREATE FUNCTION identity.validate_guardianship()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_guardian_role identity.family_member_role;
    v_child_role identity.family_member_role;
    v_management identity.account_management_type;
BEGIN
    SELECT member_role
    INTO v_guardian_role
    FROM identity.family_memberships
    WHERE family_id = NEW.family_id
      AND user_id = NEW.guardian_user_id
      AND membership_status = 'ACTIVE';

    SELECT
        fm.member_role,
        u.account_management_type
    INTO
        v_child_role,
        v_management
    FROM identity.family_memberships fm
    JOIN identity.users u
      ON u.user_id = fm.user_id
    WHERE fm.family_id = NEW.family_id
      AND fm.user_id = NEW.child_user_id
      AND fm.membership_status = 'ACTIVE';

    IF v_guardian_role IS NULL
       OR v_guardian_role NOT IN ('PARENT', 'ADULT')
    THEN
        RAISE EXCEPTION
            'Guardian must be an active PARENT or ADULT in the same family';
    END IF;

    IF v_child_role IS DISTINCT FROM 'CHILD'
       OR v_management IS DISTINCT FROM 'MANAGED_CHILD'
    THEN
        RAISE EXCEPTION
            'Guardianship target must be an active MANAGED_CHILD';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_guardianship
BEFORE INSERT OR UPDATE OF
    family_id,
    guardian_user_id,
    child_user_id,
    revoked_at
ON identity.guardianships
FOR EACH ROW
WHEN (NEW.revoked_at IS NULL)
EXECUTE FUNCTION identity.validate_guardianship();

\echo '[PASS] 1000_identity_function.sql'
SELECT pg_temp.bt_mark_completed('5000_function/5700_system/5700_system_identity.sql');
