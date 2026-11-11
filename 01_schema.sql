-- Canonical NEW schema: MySQL 8.4, Node.js/Express + mysql2.
-- Run once against an empty schema. All DATETIME values are UTC.
CREATE DATABASE IF NOT EXISTS vacancy_aggregator
  CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE vacancy_aggregator;
SET time_zone = '+00:00';

CREATE TABLE sources (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  code VARCHAR(40) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  name VARCHAR(150) NOT NULL,
  base_url VARCHAR(2048) NOT NULL,
  access_type ENUM('api','html','manual') NOT NULL DEFAULT 'api',
  is_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  last_success_at DATETIME(6) NULL,
  UNIQUE KEY uq_sources_code (code)
) ENGINE=InnoDB;

-- Companies are source-scoped. Names are NOT unique identifiers.
CREATE TABLE companies (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  source_id BIGINT NOT NULL,
  external_id VARCHAR(255) COLLATE utf8mb4_bin NOT NULL,
  name VARCHAR(255) NOT NULL,
  original_url VARCHAR(2048) NULL,
  UNIQUE KEY uq_companies_source_external (source_id, external_id),
  UNIQUE KEY uq_companies_id_source (id, source_id),
  CONSTRAINT fk_companies_source FOREIGN KEY (source_id) REFERENCES sources(id)
) ENGINE=InnoDB;

CREATE TABLE vacancies (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  source_id BIGINT NOT NULL,
  external_id VARCHAR(255) COLLATE utf8mb4_bin NOT NULL,
  company_id BIGINT NULL,
  title VARCHAR(255) NOT NULL,
  typical_position VARCHAR(255) NULL,
  code_profession VARCHAR(64) CHARACTER SET ascii NULL,
  specialisation VARCHAR(255) NULL,
  description MEDIUMTEXT NOT NULL,
  requirements TEXT NULL,
  responsibilities TEXT NULL,
  original_url VARCHAR(2048) NOT NULL,
  country_code CHAR(2) CHARACTER SET ascii NULL,
  region_name VARCHAR(150) NULL,
  region_code VARCHAR(32) CHARACTER SET ascii NULL,
  latitude DECIMAL(10,7) NULL,
  longitude DECIMAL(10,7) NULL,
  city VARCHAR(150) NULL,
  address_text VARCHAR(500) NULL,
  work_format ENUM('onsite','remote','hybrid','unknown') NOT NULL DEFAULT 'unknown',
  employment_type ENUM('full_time','part_time','internship','unknown')
    NOT NULL DEFAULT 'unknown',
  schedule_text TEXT NULL,
  schedule_type ENUM('five_two','six_one','shift','flexible','other','unknown') NOT NULL DEFAULT 'unknown',
  contract_type ENUM('permanent','fixed_term','unknown') NOT NULL DEFAULT 'unknown',
  salary_min DECIMAL(12,2) NULL,
  salary_max DECIMAL(12,2) NULL,
  currency CHAR(3) CHARACTER SET ascii NULL COMMENT 'ISO 4217; normalize RUR to RUB',
  salary_period ENUM('hour','shift','day','week','month','year','unknown') NOT NULL DEFAULT 'unknown',
  salary_gross BOOLEAN NULL COMMENT 'NULL=unknown, 1=before tax, 0=net',
  experience_months_min SMALLINT UNSIGNED NULL COMMENT 'NULL=unknown; 0=no experience required',
  status ENUM('active','archived') NOT NULL DEFAULT 'active',
  published_at DATETIME(6) NULL,
  source_updated_at DATETIME(6) NULL,
  first_seen_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  last_seen_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  content_hash BINARY(32) GENERATED ALWAYS AS (
    UNHEX(SHA2(CAST(JSON_ARRAY(title,typical_position,code_profession,specialisation,
      description,requirements,responsibilities,country_code,region_code,region_name,city,
      work_format,employment_type,schedule_text,schedule_type,contract_type,
      salary_min,salary_max,currency,salary_period,salary_gross,experience_months_min)
      AS CHAR CHARACTER SET utf8mb4),256))
  ) STORED,
  UNIQUE KEY uq_vacancies_source_external (source_id, external_id),
  KEY ix_vacancies_location (status, country_code, region_name, city),
  KEY ix_vacancies_region (status,region_code,specialisation),
  KEY ix_vacancies_profession (status,code_profession),
  KEY ix_vacancies_feed (status, published_at, id),
  KEY ix_vacancies_company_source (company_id, source_id),
  FULLTEXT KEY ft_vacancies_search (title, description, requirements),
  CONSTRAINT fk_vacancies_source FOREIGN KEY (source_id) REFERENCES sources(id),
  CONSTRAINT fk_vacancies_company_source FOREIGN KEY (company_id, source_id)
    REFERENCES companies(id, source_id),
  CONSTRAINT ck_vacancies_latitude CHECK (latitude IS NULL OR latitude BETWEEN -90 AND 90),
  CONSTRAINT ck_vacancies_longitude CHECK (longitude IS NULL OR longitude BETWEEN -180 AND 180),
  CONSTRAINT ck_vacancies_salary_min CHECK (salary_min IS NULL OR salary_min >= 0),
  CONSTRAINT ck_vacancies_salary_max CHECK (salary_max IS NULL OR salary_max >= 0),
  CONSTRAINT ck_vacancies_salary_range CHECK (salary_min IS NULL OR salary_max IS NULL OR salary_min <= salary_max),
  CONSTRAINT ck_vacancies_salary_currency CHECK ((salary_min IS NULL AND salary_max IS NULL) OR currency IS NOT NULL)
) ENGINE=InnoDB;

-- Accounts are framework-independent; backend hashes/verifies passwords.
CREATE TABLE users (
  id VARCHAR(191) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL PRIMARY KEY,
  email VARCHAR(254) NOT NULL,
  normalized_email VARCHAR(254) COLLATE utf8mb4_0900_as_ci NOT NULL,
  password_hash VARCHAR(1024) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  role ENUM('user','admin') NOT NULL DEFAULT 'user',
  status ENUM('active','blocked') NOT NULL DEFAULT 'active',
  token_version INT UNSIGNED NOT NULL DEFAULT 0,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  last_login_at DATETIME(6) NULL,
  UNIQUE KEY uq_users_email (normalized_email),
  CONSTRAINT ck_users_email CHECK (CHAR_LENGTH(TRIM(normalized_email)) > 0),
  CONSTRAINT ck_users_password CHECK (CHAR_LENGTH(password_hash) > 0)
) ENGINE=InnoDB;

CREATE TABLE refresh_tokens (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_subject VARCHAR(191) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
  token_hash BINARY(32) NOT NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  expires_at DATETIME(6) NOT NULL,
  revoked_at DATETIME(6) NULL,
  UNIQUE KEY uq_refresh_tokens_hash (token_hash),
  KEY ix_refresh_tokens_user (user_subject,expires_at),
  CONSTRAINT fk_refresh_tokens_user FOREIGN KEY (user_subject) REFERENCES users(id) ON DELETE CASCADE,
  CONSTRAINT ck_refresh_tokens_expiry CHECK (expires_at > created_at)
) ENGINE=InnoDB;

CREATE TABLE user_profiles (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  auth_subject VARCHAR(191) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
  display_name VARCHAR(150) NOT NULL,
  city VARCHAR(150) NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  UNIQUE KEY uq_user_profiles_subject (auth_subject),
  CONSTRAINT fk_user_profiles_account FOREIGN KEY (auth_subject) REFERENCES users(id) ON DELETE RESTRICT
) ENGINE=InnoDB;

CREATE TABLE skills (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(150) NOT NULL,
  normalized_name VARCHAR(150) NOT NULL,
  UNIQUE KEY uq_skills_normalized (normalized_name)
) ENGINE=InnoDB;

CREATE TABLE user_skills (
  user_id BIGINT NOT NULL,
  skill_id BIGINT NOT NULL,
  PRIMARY KEY (user_id, skill_id),
  KEY ix_user_skills_skill (skill_id),
  CONSTRAINT fk_user_skills_user FOREIGN KEY (user_id) REFERENCES user_profiles(id) ON DELETE CASCADE,
  CONSTRAINT fk_user_skills_skill FOREIGN KEY (skill_id) REFERENCES skills(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE vacancy_skills (
  vacancy_id BIGINT NOT NULL,
  skill_id BIGINT NOT NULL,
  is_required BOOLEAN NOT NULL DEFAULT FALSE COMMENT 'Set only if explicitly required',
  PRIMARY KEY (vacancy_id, skill_id),
  KEY ix_vacancy_skills_skill (skill_id, vacancy_id),
  CONSTRAINT fk_vacancy_skills_vacancy FOREIGN KEY (vacancy_id) REFERENCES vacancies(id) ON DELETE CASCADE,
  CONSTRAINT fk_vacancy_skills_skill FOREIGN KEY (skill_id) REFERENCES skills(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE favorites (
  user_id BIGINT NOT NULL,
  vacancy_id BIGINT NOT NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (user_id, vacancy_id),
  KEY ix_favorites_vacancy (vacancy_id),
  CONSTRAINT fk_favorites_user FOREIGN KEY (user_id) REFERENCES user_profiles(id) ON DELETE CASCADE,
  CONSTRAINT fk_favorites_vacancy FOREIGN KEY (vacancy_id) REFERENCES vacancies(id) ON DELETE CASCADE
) ENGINE=InnoDB;

-- Records intent / click only; NEVER evidence that an application was sent.
CREATE TABLE outbound_clicks (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_id BIGINT NOT NULL,
  vacancy_id BIGINT NOT NULL,
  clicked_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  KEY ix_outbound_clicks_history (user_id, clicked_at, id),
  KEY ix_outbound_clicks_vacancy (vacancy_id),
  CONSTRAINT fk_outbound_clicks_user FOREIGN KEY (user_id) REFERENCES user_profiles(id) ON DELETE CASCADE,
  CONSTRAINT fk_outbound_clicks_vacancy FOREIGN KEY (vacancy_id) REFERENCES vacancies(id)
) ENGINE=InnoDB;


-- One running importer per source + canonical region/filter scope.
-- Cursor advances only via a fully succeeded run, separately for each scope.
CREATE TABLE import_runs (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  source_id BIGINT NOT NULL,
  scope_hash BINARY(32) NOT NULL,
  scope_json JSON NOT NULL,
  mode ENUM('full','incremental') NOT NULL,
  status ENUM('running','succeeded','partial','failed') NOT NULL DEFAULT 'running',
  active_scope_hash BINARY(32) GENERATED ALWAYS AS (IF(status='running',scope_hash,NULL)) STORED,
  window_from DATETIME(6) NULL,
  window_to DATETIME(6) NOT NULL,
  started_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  finished_at DATETIME(6) NULL,
  records_seen INT UNSIGNED NOT NULL DEFAULT 0,
  inserted_count INT UNSIGNED NOT NULL DEFAULT 0,
  updated_count INT UNSIGNED NOT NULL DEFAULT 0,
  skipped_count INT UNSIGNED NOT NULL DEFAULT 0,
  error_code VARCHAR(80) NULL,
  UNIQUE KEY uq_import_runs_active (source_id,active_scope_hash),
  KEY ix_import_runs_cursor (source_id,scope_hash,status,window_to),
  CONSTRAINT fk_import_runs_source FOREIGN KEY (source_id) REFERENCES sources(id),
  CONSTRAINT ck_import_runs_scope CHECK (JSON_TYPE(scope_json)='OBJECT'),
  CONSTRAINT ck_import_runs_window CHECK (window_from IS NULL OR window_from <= window_to),
  CONSTRAINT ck_import_runs_counters CHECK (inserted_count+updated_count+skipped_count<=records_seen),
  CONSTRAINT ck_import_runs_finish CHECK (
    (status='running' AND finished_at IS NULL)
    OR (status<>'running' AND finished_at IS NOT NULL)
  )
) ENGINE=InnoDB;
