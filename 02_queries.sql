-- MySQL 8.4 + mysql2: execute ONE statement on a transaction connection as required.
-- mysql2 namedPlaceholders=true; :parameters are bound, never concatenated.
-- This file is a catalog, NOT a migration to execute from top to bottom.
-- SELECT user_id from the authenticated server-side identity, never trust a client's user_id.
USE vacancy_aggregator;

-- Q01. Idempotent company import. If source has no company ID, use a stable
-- company URL-derived identifier or leave vacancy.company_id NULL.
INSERT INTO companies (source_id, external_id, name, original_url)
VALUES (:source_id, :company_external_id, :company_name, :company_url)
ON DUPLICATE KEY UPDATE
  id = LAST_INSERT_ID(id), name = :company_name, original_url = :company_url;
-- Same connection, immediately after the INSERT, no intervening auto-ID insert.
SELECT LAST_INSERT_ID() AS company_id;

-- Q02. Idempotent vacancy import. Do Q01/Q02/skills in ONE transaction.
-- :external_id for Trudvsem = companycode + ':' + id (composite source key).
-- Always import a complete normalized object, not a search snippet replacing a full card.
INSERT INTO vacancies (
  source_id, external_id, company_id, title, typical_position, code_profession, specialisation, description, requirements,
  responsibilities, original_url, country_code, region_name, region_code, latitude, longitude, city, address_text,
  work_format, employment_type, schedule_text, schedule_type, contract_type,
  salary_min, salary_max, currency, salary_period, salary_gross,
  experience_months_min, status, published_at, source_updated_at, last_seen_at
) VALUES (
  :source_id, :external_id, :company_id, :title, :typical_position, :code_profession, :specialisation, :description, :requirements,
  :responsibilities, :original_url, :country_code, :region_name, :region_code, :latitude, :longitude, :city, :address_text,
  :work_format, :employment_type, :schedule_text, :schedule_type, :contract_type,
  :salary_min, :salary_max, :currency, :salary_period, :salary_gross,
  :experience_months_min, :status, :published_at, :source_updated_at, UTC_TIMESTAMP(6)
)
ON DUPLICATE KEY UPDATE
  id = LAST_INSERT_ID(id),
  company_id = :company_id, title = :title, typical_position = :typical_position,
  code_profession = :code_profession, specialisation = :specialisation, description = :description,
  requirements = :requirements, responsibilities = :responsibilities,
  original_url = :original_url, country_code = :country_code,
  region_name = :region_name, region_code = :region_code, latitude = :latitude, longitude = :longitude,
  city = :city, address_text = :address_text,
  work_format = :work_format, employment_type = :employment_type,
  schedule_text = :schedule_text, schedule_type = :schedule_type, contract_type = :contract_type,
  salary_min = :salary_min, salary_max = :salary_max, currency = :currency,
  salary_period = :salary_period, salary_gross = :salary_gross,
  experience_months_min = :experience_months_min, status = :status,
  published_at = :published_at, source_updated_at = :source_updated_at,
  last_seen_at = UTC_TIMESTAMP(6);
SELECT LAST_INSERT_ID() AS vacancy_id;

-- Q03. Permanent-job search by working conditions and skill ranking.
-- Inputs: :user_id (existing profile), :search ('' means no text filter),
-- :city, :region_name, :country_code (NULL=no filter), :include_remote (0/1),
-- :work_format (NULL=any, onsite/remote/hybrid/unknown),
-- :schedule_type (NULL=any, five_two/six_one/shift/flexible/other/unknown),
-- :contract_type (NULL=any, permanent/fixed_term/unknown); full_time is not a contract duration.
-- :employment_type (NULL=no filter), :min_salary (NULL=no salary filter),
-- :currency='RUB', :salary_period='month', :salary_gross (NULL=any tax basis),
-- :only_no_experience (0/1), :require_all_required (0/1),
-- :experience_months (NULL=no cap; 0=no experience); unknown vacancy experience
-- is excluded when this cap is supplied. No skill/expertise is inferred from it.
-- :region_code/:specialisation (NULL=any), :typical_positions_json (NULL=any; nonempty JSON array),
-- :page_size (1..100), :offset (>=0). Validate ranges in backend.
-- Salary filter means "an advertised bound reaches desired amount"; no guaranteed offer.
WITH skill_stats AS (
  SELECT vs.vacancy_id,
    COUNT(*) AS listed_skills,
    SUM(us.skill_id IS NOT NULL) AS matched_skills,
    SUM(vs.is_required = 1 AND us.skill_id IS NULL) AS missing_required_skills
  FROM vacancy_skills vs
  LEFT JOIN user_skills us ON us.skill_id = vs.skill_id AND us.user_id = :user_id
  GROUP BY vs.vacancy_id
), ranked AS (
  SELECT v.id, v.title, v.typical_position, v.specialisation, v.region_code, c.name AS company_name, v.city, v.region_name,
    v.work_format, v.employment_type, v.schedule_text, v.schedule_type, v.contract_type,
    v.salary_min, v.salary_max, v.currency, v.salary_period, v.salary_gross,
    v.original_url, v.published_at, v.last_seen_at,
    s.name AS source_name,
    COALESCE(ss.matched_skills, 0) AS matched_skills,
    COALESCE(ss.listed_skills, 0) AS listed_skills,
    COALESCE(ss.missing_required_skills, 0) AS missing_required_skills,
    ROUND(100.0 * ss.matched_skills / NULLIF(ss.listed_skills, 0), 0) AS skill_match_percent,
    MATCH(v.title, v.description, v.requirements) AGAINST (:search IN NATURAL LANGUAGE MODE) AS text_score
  FROM vacancies v
  JOIN sources s ON s.id = v.source_id
  JOIN user_profiles u ON u.id = :user_id
  LEFT JOIN companies c ON c.id = v.company_id
  LEFT JOIN skill_stats ss ON ss.vacancy_id = v.id
  WHERE v.status = 'active'
    AND (:search = '' OR MATCH(v.title, v.description, v.requirements)
      AGAINST (:search IN NATURAL LANGUAGE MODE) > 0)
    AND (:city IS NULL OR v.city = :city OR (:include_remote = 1 AND v.work_format = 'remote'))
    AND (:region_name IS NULL OR v.region_name = :region_name OR (:include_remote = 1 AND v.work_format = 'remote'))
    AND (:country_code IS NULL OR v.country_code = :country_code OR (:include_remote = 1 AND v.work_format = 'remote'))
    AND (:region_code IS NULL OR v.region_code=:region_code OR (:include_remote=1 AND v.work_format='remote'))
    AND (:specialisation IS NULL OR v.specialisation=:specialisation)
    AND (:typical_positions_json IS NULL OR JSON_CONTAINS(:typical_positions_json,JSON_QUOTE(v.typical_position)))
    AND (:employment_type IS NULL OR v.employment_type = :employment_type)
    AND (:work_format IS NULL OR v.work_format = :work_format)
    AND (:schedule_type IS NULL OR v.schedule_type = :schedule_type)
    AND (:contract_type IS NULL OR v.contract_type = :contract_type)
    AND (:min_salary IS NULL OR (
      v.currency = :currency AND v.salary_period = :salary_period
      AND COALESCE(v.salary_max, v.salary_min) >= :min_salary
      AND (:salary_gross IS NULL OR v.salary_gross = :salary_gross)))
    AND (:only_no_experience = 0 OR v.experience_months_min = 0)
    AND (:experience_months IS NULL OR v.experience_months_min <= :experience_months)
)
SELECT * FROM ranked
WHERE (:require_all_required = 0 OR missing_required_skills = 0)
ORDER BY (skill_match_percent IS NOT NULL) DESC, skill_match_percent DESC,
  text_score DESC, published_at DESC, id DESC
LIMIT :page_size OFFSET :offset;

-- Q04. Vacancy card (archived cards may still be opened from history).
SELECT v.*, c.name AS company_name, s.name AS source_name,
  EXISTS(SELECT 1 FROM favorites f WHERE f.user_id = :user_id AND f.vacancy_id = v.id) AS is_favorite
FROM vacancies v
JOIN sources s ON s.id = v.source_id
LEFT JOIN companies c ON c.id = v.company_id
WHERE v.id = :vacancy_id;
SELECT sk.id, sk.name, vs.is_required
FROM vacancy_skills vs JOIN skills sk ON sk.id = vs.skill_id
WHERE vs.vacancy_id = :vacancy_id ORDER BY vs.is_required DESC, sk.name;

-- Q05. Add to favorites, idempotently; repeat insert is a no-op.
INSERT INTO favorites (user_id, vacancy_id)
SELECT :user_id, v.id FROM vacancies v WHERE v.id = :vacancy_id AND v.status = 'active'
ON DUPLICATE KEY UPDATE created_at = favorites.created_at;

-- Q06. Remove from favorites.
DELETE FROM favorites WHERE user_id = :user_id AND vacancy_id = :vacancy_id;

-- Q07. List favorites (also show archived so saved items do not silently disappear).
SELECT v.id, v.title, v.city, v.salary_min, v.salary_max, v.currency,
  v.salary_period, v.status, v.original_url, c.name AS company_name, f.created_at AS saved_at
FROM favorites f
JOIN vacancies v ON v.id = f.vacancy_id
LEFT JOIN companies c ON c.id = v.company_id
WHERE f.user_id = :user_id ORDER BY f.created_at DESC, v.id DESC
LIMIT :page_size OFFSET :offset;

-- Q08. Record button click, then return the stored original URL.
-- Execute in one transaction / connection; if affected rows=0, return 404/409.
INSERT INTO outbound_clicks (user_id, vacancy_id)
SELECT :user_id, v.id FROM vacancies v WHERE v.id = :vacancy_id AND v.status = 'active';
SELECT original_url FROM vacancies WHERE id = :vacancy_id AND status = 'active';
-- Backend commits BEFORE returning URL; client opens URL in system browser.
-- UI label: "Переход на сайт работодателя/источника". No application-sent status.

-- Q09. Button-click history; repeated clicks are intentionally retained.
SELECT o.id, o.clicked_at, v.id AS vacancy_id, v.title, v.original_url,
  v.status, s.name AS source_name
FROM outbound_clicks o JOIN vacancies v ON v.id = o.vacancy_id
JOIN sources s ON s.id = v.source_id
WHERE o.user_id = :user_id ORDER BY o.clicked_at DESC, o.id DESC
LIMIT :page_size OFFSET :offset;

-- Q10. Replace profile skills: one backend transaction, INSERT repeated per distinct skill.
START TRANSACTION;
DELETE FROM user_skills WHERE user_id = :user_id;
INSERT INTO user_skills (user_id, skill_id) VALUES (:user_id, :skill_id);
COMMIT;
-- Empty skills list: only DELETE + COMMIT; never insert a fake "unknown" skill.

-- Q12. Explicitly archive vacancy when upstream API confirms archive/removal.
UPDATE vacancies SET status = 'archived'
WHERE source_id = :source_id AND external_id = :external_id;
-- Never archive all unseen vacancies after a partial search, API failure or one page.

-- Q13. Source monitor timestamp only after an audited fully succeeded run.
-- Incremental cursor MUST come from QI01 by source/scope, not last_success_at.
UPDATE sources s JOIN import_runs r ON r.source_id=s.id AND r.id=:import_run_id
SET s.last_success_at=r.finished_at WHERE s.id=:source_id AND r.status='succeeded';

-- Q14. Catalog profession dictionary for controlled LLM candidate mapping.
SELECT DISTINCT typical_position,code_profession,specialisation FROM vacancies
WHERE status='active' AND typical_position IS NOT NULL
ORDER BY specialisation,typical_position LIMIT 500;
