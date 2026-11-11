-- MySQL 8.0.16+; execute ONE numbered block per backend operation.
-- @parameters are bound by Dapper/MySqlConnector; NOT SQL string interpolation.
-- This file is a catalog, NOT a migration to execute from top to bottom.
-- SELECT user_id from the authenticated server-side identity, never trust a client's user_id.
USE vacancy_aggregator;

-- Q01. Idempotent company import. If source has no company ID, use a stable
-- company URL-derived identifier or leave vacancy.company_id NULL.
INSERT INTO companies (source_id, external_id, name, original_url)
VALUES (@source_id, @company_external_id, @company_name, @company_url)
ON DUPLICATE KEY UPDATE
  id = LAST_INSERT_ID(id), name = @company_name, original_url = @company_url;
-- Same connection, immediately after the INSERT, no intervening auto-ID insert.
SELECT LAST_INSERT_ID() AS company_id;

-- Q02. Idempotent vacancy import. Do Q01/Q02/skills/slots in ONE transaction.
-- @external_id for Trudvsem = companycode + ':' + id (composite source key).
-- Always import a complete normalized object, not a search snippet replacing a full card.
INSERT INTO vacancies (
  source_id, external_id, company_id, title, description, requirements,
  responsibilities, original_url, country_code, region_name, city, address_text,
  is_remote, employment_type, schedule_text, schedule_mode, time_zone,
  salary_min, salary_max, currency, salary_period, salary_gross,
  experience_months_min, status, published_at, source_updated_at, last_seen_at, raw_payload
) VALUES (
  @source_id, @external_id, @company_id, @title, @description, @requirements,
  @responsibilities, @original_url, @country_code, @region_name, @city, @address_text,
  @is_remote, @employment_type, @schedule_text, @schedule_mode, @time_zone,
  @salary_min, @salary_max, @currency, @salary_period, @salary_gross,
  @experience_months_min, @status, @published_at, @source_updated_at, UTC_TIMESTAMP(6), @raw_payload
)
ON DUPLICATE KEY UPDATE
  id = LAST_INSERT_ID(id),
  company_id = @company_id, title = @title, description = @description,
  requirements = @requirements, responsibilities = @responsibilities,
  original_url = @original_url, country_code = @country_code,
  region_name = @region_name, city = @city, address_text = @address_text,
  is_remote = @is_remote, employment_type = @employment_type,
  schedule_text = @schedule_text, schedule_mode = @schedule_mode, time_zone = @time_zone,
  salary_min = @salary_min, salary_max = @salary_max, currency = @currency,
  salary_period = @salary_period, salary_gross = @salary_gross,
  experience_months_min = @experience_months_min, status = @status,
  published_at = @published_at, source_updated_at = @source_updated_at,
  last_seen_at = UTC_TIMESTAMP(6), raw_payload = @raw_payload;
SELECT LAST_INSERT_ID() AS vacancy_id;

-- Q03. Search + skill ranking + fixed-weekly availability assessment.
-- Inputs: @user_id (existing profile), @search ('' means no text filter),
-- @city, @region_name, @country_code (NULL=no filter), @include_remote (0/1),
-- @is_remote (NULL=any, 1=remote only, 0=onsite only),
-- @employment_type (NULL=no filter), @min_salary (NULL=no salary filter),
-- @currency='RUB', @salary_period='month', @salary_gross (NULL=any tax basis),
-- @only_no_experience (0/1), @only_schedule_match (0/1), @require_all_required (0/1),
-- @experience_months (NULL=no cap; 0=no experience); unknown vacancy experience
-- is excluded when this cap is supplied. No skill/expertise is inferred from it.
-- @page_size (1..100), @offset (>=0). Validate ranges in backend.
-- Salary filter means "an advertised bound reaches desired amount"; no guaranteed offer.
WITH skill_stats AS (
  SELECT vs.vacancy_id,
    COUNT(*) AS listed_skills,
    SUM(us.skill_id IS NOT NULL) AS matched_skills,
    SUM(vs.is_required = 1 AND us.skill_id IS NULL) AS missing_required_skills
  FROM vacancy_skills vs
  LEFT JOIN user_skills us ON us.skill_id = vs.skill_id AND us.user_id = @user_id
  GROUP BY vs.vacancy_id
), ranked AS (
  SELECT v.id, v.title, c.name AS company_name, v.city, v.region_name,
    v.is_remote, v.employment_type, v.schedule_text,
    v.salary_min, v.salary_max, v.currency, v.salary_period, v.salary_gross,
    v.original_url, v.published_at, v.last_seen_at,
    s.name AS source_name,
    COALESCE(ss.matched_skills, 0) AS matched_skills,
    COALESCE(ss.listed_skills, 0) AS listed_skills,
    COALESCE(ss.missing_required_skills, 0) AS missing_required_skills,
    ROUND(100.0 * ss.matched_skills / NULLIF(ss.listed_skills, 0), 0) AS skill_match_percent,
    MATCH(v.title, v.description, v.requirements) AGAINST (@search IN NATURAL LANGUAGE MODE) AS text_score,
    CASE
      WHEN v.schedule_mode <> 'fixed_weekly' OR v.time_zone IS NULL
        OR v.time_zone <> u.time_zone
        OR NOT EXISTS (SELECT 1 FROM user_availability a WHERE a.user_id = u.id)
        OR NOT EXISTS (SELECT 1 FROM vacancy_schedule_slots w WHERE w.vacancy_id = v.id)
      THEN 'unknown'
      WHEN EXISTS (
        SELECT 1 FROM vacancy_schedule_slots w
        WHERE w.vacancy_id = v.id AND NOT EXISTS (
          SELECT 1 FROM user_availability a
          WHERE a.user_id = u.id AND a.day_of_week = w.day_of_week
            AND a.start_minute <= w.start_minute AND a.end_minute >= w.end_minute
        )
      ) THEN 'conflict'
      ELSE 'match'
    END AS schedule_fit
  FROM vacancies v
  JOIN sources s ON s.id = v.source_id
  JOIN user_profiles u ON u.id = @user_id
  LEFT JOIN companies c ON c.id = v.company_id
  LEFT JOIN skill_stats ss ON ss.vacancy_id = v.id
  WHERE v.status = 'active'
    AND (@search = '' OR MATCH(v.title, v.description, v.requirements)
      AGAINST (@search IN NATURAL LANGUAGE MODE) > 0)
    AND (@city IS NULL OR v.city = @city OR (@include_remote = 1 AND v.is_remote = 1))
    AND (@region_name IS NULL OR v.region_name = @region_name OR (@include_remote = 1 AND v.is_remote = 1))
    AND (@country_code IS NULL OR v.country_code = @country_code OR (@include_remote = 1 AND v.is_remote = 1))
    AND (@employment_type IS NULL OR v.employment_type = @employment_type)
    AND (@is_remote IS NULL OR v.is_remote = @is_remote)
    AND (@min_salary IS NULL OR (
      v.currency = @currency AND v.salary_period = @salary_period
      AND COALESCE(v.salary_max, v.salary_min) >= @min_salary
      AND (@salary_gross IS NULL OR v.salary_gross = @salary_gross)))
    AND (@only_no_experience = 0 OR v.experience_months_min = 0)
    AND (@experience_months IS NULL OR v.experience_months_min <= @experience_months)
)
SELECT * FROM ranked
WHERE (@only_schedule_match = 0 OR schedule_fit = 'match')
  AND (@require_all_required = 0 OR missing_required_skills = 0)
ORDER BY (schedule_fit = 'match') DESC, (schedule_fit = 'conflict') ASC,
  (skill_match_percent IS NOT NULL) DESC, skill_match_percent DESC,
  text_score DESC, published_at DESC, id DESC
LIMIT @page_size OFFSET @offset;

-- Q04. Vacancy card (archived cards may still be opened from history).
SELECT v.*, c.name AS company_name, s.name AS source_name,
  EXISTS(SELECT 1 FROM favorites f WHERE f.user_id = @user_id AND f.vacancy_id = v.id) AS is_favorite
FROM vacancies v
JOIN sources s ON s.id = v.source_id
LEFT JOIN companies c ON c.id = v.company_id
WHERE v.id = @vacancy_id;
SELECT sk.id, sk.name, vs.is_required
FROM vacancy_skills vs JOIN skills sk ON sk.id = vs.skill_id
WHERE vs.vacancy_id = @vacancy_id ORDER BY vs.is_required DESC, sk.name;

-- Q05. Add to favorites, idempotently; repeat insert is a no-op.
INSERT INTO favorites (user_id, vacancy_id)
SELECT @user_id, v.id FROM vacancies v WHERE v.id = @vacancy_id AND v.status = 'active'
ON DUPLICATE KEY UPDATE created_at = favorites.created_at;

-- Q06. Remove from favorites.
DELETE FROM favorites WHERE user_id = @user_id AND vacancy_id = @vacancy_id;

-- Q07. List favorites (also show archived so saved items do not silently disappear).
SELECT v.id, v.title, v.city, v.salary_min, v.salary_max, v.currency,
  v.salary_period, v.status, v.original_url, c.name AS company_name, f.created_at AS saved_at
FROM favorites f
JOIN vacancies v ON v.id = f.vacancy_id
LEFT JOIN companies c ON c.id = v.company_id
WHERE f.user_id = @user_id ORDER BY f.created_at DESC, v.id DESC
LIMIT @page_size OFFSET @offset;

-- Q08. Record button click, then return the stored original URL.
-- Execute in one transaction / connection; if affected rows=0, return 404/409.
INSERT INTO outbound_clicks (user_id, vacancy_id)
SELECT @user_id, v.id FROM vacancies v WHERE v.id = @vacancy_id AND v.status = 'active';
SELECT original_url FROM vacancies WHERE id = @vacancy_id AND status = 'active';
-- Backend commits BEFORE returning URL; client opens URL in system browser.
-- UI label: "Переход на сайт работодателя/источника". No application-sent status.

-- Q09. Button-click history; repeated clicks are intentionally retained.
SELECT o.id, o.clicked_at, v.id AS vacancy_id, v.title, v.original_url,
  v.status, s.name AS source_name
FROM outbound_clicks o JOIN vacancies v ON v.id = o.vacancy_id
JOIN sources s ON s.id = v.source_id
WHERE o.user_id = @user_id ORDER BY o.clicked_at DESC, o.id DESC
LIMIT @page_size OFFSET @offset;

-- Q10. Replace profile skills: one backend transaction, INSERT repeated per distinct skill.
START TRANSACTION;
DELETE FROM user_skills WHERE user_id = @user_id;
INSERT INTO user_skills (user_id, skill_id) VALUES (@user_id, @skill_id);
COMMIT;
-- Empty skills list: only DELETE + COMMIT; never insert a fake "unknown" skill.

-- Q11. Replace availability: one backend transaction, INSERT repeated per merged interval.
START TRANSACTION;
DELETE FROM user_availability WHERE user_id = @user_id;
INSERT INTO user_availability (user_id, day_of_week, start_minute, end_minute)
VALUES (@user_id, @day_of_week, @start_minute, @end_minute);
COMMIT;

-- Q12. Explicitly archive vacancy when upstream API confirms archive/removal.
UPDATE vacancies SET status = 'archived'
WHERE source_id = @source_id AND external_id = @external_id;
-- Never archive all unseen vacancies after a partial search, API failure or one page.

-- Q13. Mark a successful source poll, only after its data transaction commits.
UPDATE sources SET last_success_at = UTC_TIMESTAMP(6) WHERE id = @source_id;
