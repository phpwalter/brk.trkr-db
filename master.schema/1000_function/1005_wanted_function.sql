/*
===============================================================================
 File:           1000_function/1005_wanted_function.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Calculate direct loose-part progress for build goals.
 Depends On:     wanted.build_goals
                 definition.requirement_groups
                 definition.requirement_options
                 collection.explicit_part_balance()
 Creates:        wanted.build_goal_requirements()
                 wanted.build_goal_summary()
 Key Rules:      Progress is derived rather than persisted.
                 Owned-progress and available-progress respect build-goal
                 include_allocated_parts policy.
                 ANY selects the best single alternative.
                 ALL requires all alternatives.
                 AT_LEAST_N requires the configured count of best alternatives.
 Validation:     Functions return non-negative shortages and bounded percentage
                 calculations; 1210_function_validation verifies signatures.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1000_function/1005_wanted_function.sql', ARRAY['wanted.build_goals', 'definition.requirement_groups', 'definition.requirement_options', 'collection.explicit_part_balance()']::text[]);



CREATE FUNCTION wanted.build_goal_requirements(
    p_build_goal_id uuid
)
RETURNS TABLE (
    requirement_group_id bigint,
    required_units numeric,
    satisfied_units numeric,
    missing_units numeric,
    completion_percent numeric
)
LANGUAGE sql
STABLE
AS $$
    WITH goal AS (
        SELECT
            bg.owner_id,
            bg.inventory_version_id,
            bg.target_quantity,
            bg.include_allocated_parts
        FROM wanted.build_goals bg
        WHERE bg.build_goal_id =
              p_build_goal_id
    ),
    options AS (
        SELECT
            rg.requirement_group_id,
            rg.fulfillment_rule,
            rg.minimum_options,

            rg.required_quantity::numeric
                * g.target_quantity AS required_units,

            ro.requirement_option_id,

            CASE
                WHEN ro.part_variant_id IS NULL
                    THEN 0::numeric

                WHEN g.include_allocated_parts
                    THEN
                        b.owned_quantity
                        / ro.option_quantity::numeric

                ELSE
                    b.available_quantity
                    / ro.option_quantity::numeric
            END AS capacity_units

        FROM goal g

        JOIN definition.requirement_groups rg
          ON rg.inventory_version_id =
             g.inventory_version_id

        JOIN definition.requirement_options ro
          ON ro.requirement_group_id =
             rg.requirement_group_id

        LEFT JOIN LATERAL
            collection.explicit_part_balance(
                g.owner_id,
                ro.part_variant_id
            ) b
          ON ro.part_variant_id IS NOT NULL

        WHERE rg.is_required
          AND NOT rg.is_spare
    ),
    ranked AS (
        SELECT
            o.*,

            row_number() OVER (
                PARTITION BY o.requirement_group_id
                ORDER BY
                    o.capacity_units DESC,
                    o.requirement_option_id
            ) AS capacity_rank
        FROM options o
    ),
    group_capacity AS (
        SELECT
            requirement_group_id,
            fulfillment_rule,
            minimum_options,
            required_units,

            CASE fulfillment_rule
                WHEN 'ANY' THEN
                    max(capacity_units)

                WHEN 'ALL' THEN
                    min(capacity_units)

                WHEN 'AT_LEAST_N' THEN
                    min(capacity_units)
                    FILTER (
                        WHERE capacity_rank <= minimum_options
                    )
            END AS capacity_units

        FROM ranked
        GROUP BY
            requirement_group_id,
            fulfillment_rule,
            minimum_options,
            required_units
    )
    SELECT
        requirement_group_id,

        required_units,

        least(
            coalesce(capacity_units, 0),
            required_units
        ) AS satisfied_units,

        greatest(
            required_units
            - coalesce(capacity_units, 0),
            0
        ) AS missing_units,

        round(
            least(
                coalesce(capacity_units, 0),
                required_units
            )
            / nullif(required_units, 0)
            * 100,
            2
        ) AS completion_percent

    FROM group_capacity
    ORDER BY requirement_group_id;
$$;


CREATE FUNCTION wanted.build_goal_summary(
    p_build_goal_id uuid
)
RETURNS TABLE (
    total_required_units numeric,
    total_satisfied_units numeric,
    total_missing_units numeric,
    completion_percent numeric,
    requirement_count bigint,
    complete_requirement_count bigint
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        coalesce(
            sum(r.required_units),
            0
        ),

        coalesce(
            sum(r.satisfied_units),
            0
        ),

        coalesce(
            sum(r.missing_units),
            0
        ),

        CASE
            WHEN coalesce(
                sum(r.required_units),
                0
            ) = 0
                THEN 100::numeric

            ELSE round(
                sum(r.satisfied_units)
                / sum(r.required_units)
                * 100,
                2
            )
        END,

        count(*),

        count(*) FILTER (
            WHERE r.missing_units = 0
        )

    FROM wanted.build_goal_requirements(
        p_build_goal_id
    ) r;
$$;

\echo '[PASS] 1005_wanted_function.sql'
SELECT pg_temp.bt_mark_completed('1000_function/1005_wanted_function.sql');
