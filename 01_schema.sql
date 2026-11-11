-- MySQL 8.0.16+ (CHECK constraints), tested target: MySQL 8.4.
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
  description MEDIUMTEXT NOT NULL,
  requirements TEXT NULL,
  responsibilities TEXT NULL,
  original_url VARCHAR(2048) NOT NULL,
  country_code CHAR(2) CHARACTER SET ascii NULL,
  region_name VARCHAR(150) NULL,
  city VARCHAR(150) NULL,
  address_text VARCHAR(500) NULL,
  is_remote BOOLEAN NULL DEFAULT NULL COMMENT 'NULL=unknown, 1=remote, 0=onsite',
  employment_type ENUM('full_time','part_time','temporary','seasonal','internship','volunteer','unknown')
    NOT NULL DEFAULT 'unknown',
  schedule_text TEXT NULL,
  schedule_mode ENUM('unknown','fixed_weekly','flexible','rotating') NOT NULL DEFAULT 'unknown',
  time_zone VARCHAR(80) CHARACTER SET ascii NULL COMMENT 'IANA identifier, e.g. Europe/Moscow',
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
  raw_payload JSON NULL,
  UNIQUE KEY uq_vacancies_source_external (source_id, external_id),
  KEY ix_vacancies_location (status, country_code, region_name, city),
  KEY ix_vacancies_feed (status, published_at, id),
  KEY ix_vacancies_company_source (company_id, source_id),
  FULLTEXT KEY ft_vacancies_search (title, description, requirements),
  CONSTRAINT fk_vacancies_source FOREIGN KEY (source_id) REFERENCES sources(id),
  CONSTRAINT fk_vacancies_company_source FOREIGN KEY (company_id, source_id)
    REFERENCES companies(id, source_id),
  CONSTRAINT ck_vacancies_salary_min CHECK (salary_min IS NULL OR salary_min >= 0),
  CONSTRAINT ck_vacancies_salary_max CHECK (salary_max IS NULL OR salary_max >= 0),
  CONSTRAINT ck_vacancies_salary_range CHECK (salary_min IS NULL OR salary_max IS NULL OR salary_min <= salary_max),
  CONSTRAINT ck_vacancies_salary_currency CHECK ((salary_min IS NULL AND salary_max IS NULL) OR currency IS NOT NULL)
) ENGINE=InnoDB;

-- Minimal account storage. Password hashing/verification happens in the backend.
-- String identifiers (normally UUIDs) preserve existing auth_subject references.
CREATE TABLE users (
  id VARCHAR(191) COLLATE utf8mb4_bin NOT NULL PRIMARY KEY,
  email VARCHAR(254) NOT NULL,
  normalized_email VARCHAR(254) COLLATE utf8mb4_bin NOT NULL,
  password_hash VARCHAR(1024) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  status ENUM('active','blocked') NOT NULL DEFAULT 'active',
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  last_login_at DATETIME(6) NULL,
  UNIQUE KEY uq_users_email (normalized_email),
  CONSTRAINT ck_users_email CHECK (CHAR_LENGTH(TRIM(normalized_email)) > 0),
  CONSTRAINT ck_users_email_normalized CHECK (normalized_email = LOWER(TRIM(normalized_email))),
  CONSTRAINT ck_users_password_hash CHECK (CHAR_LENGTH(password_hash) > 0)
) ENGINE=InnoDB;

CREATE TABLE user_profiles (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  auth_subject VARCHAR(191) COLLATE utf8mb4_bin NOT NULL,
  display_name VARCHAR(150) NOT NULL,
  city VARCHAR(150) NULL,
  time_zone VARCHAR(80) CHARACTER SET ascii NOT NULL DEFAULT 'Europe/Moscow',
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  UNIQUE KEY uq_user_profiles_subject (auth_subject),
  CONSTRAINT fk_user_profiles_account FOREIGN KEY (auth_subject) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB;

-- Opaque session-token option for the backend. Store SHA-256 of a random token,
-- not the raw token; passwords must use a dedicated password hasher instead.
CREATE TABLE auth_sessions (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_subject VARCHAR(191) COLLATE utf8mb4_bin NOT NULL,
  token_hash BINARY(32) NOT NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  expires_at DATETIME(6) NOT NULL,
  revoked_at DATETIME(6) NULL,
  UNIQUE KEY uq_auth_sessions_token (token_hash),
  KEY ix_auth_sessions_user (user_subject, expires_at),
  CONSTRAINT fk_auth_sessions_account FOREIGN KEY (user_subject) REFERENCES users(id) ON DELETE CASCADE,
  CONSTRAINT ck_auth_sessions_expiry CHECK (expires_at > created_at)
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

-- Weekly local intervals [start_minute, end_minute). Monday=1, Sunday=7.
-- 1440 means midnight at end of day. Split overnight intervals into two rows.
-- Backend must merge overlapping AND adjacent user intervals before saving.
CREATE TABLE user_availability (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_id BIGINT NOT NULL,
  day_of_week TINYINT UNSIGNED NOT NULL,
  start_minute SMALLINT UNSIGNED NOT NULL,
  end_minute SMALLINT UNSIGNED NOT NULL,
  UNIQUE KEY uq_user_availability_slot (user_id, day_of_week, start_minute, end_minute),
  CONSTRAINT fk_user_availability_user FOREIGN KEY (user_id) REFERENCES user_profiles(id) ON DELETE CASCADE,
  CONSTRAINT ck_user_availability_day CHECK (day_of_week BETWEEN 1 AND 7),
  CONSTRAINT ck_user_availability_time CHECK (start_minute < end_minute AND end_minute <= 1440)
) ENGINE=InnoDB;

-- Only REQUIRED fixed-weekly periods, not alternative shifts.
-- Use schedule_mode=unknown/rotating/flexible when exact required times are unavailable.
CREATE TABLE vacancy_schedule_slots (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  vacancy_id BIGINT NOT NULL,
  day_of_week TINYINT UNSIGNED NOT NULL,
  start_minute SMALLINT UNSIGNED NOT NULL,
  end_minute SMALLINT UNSIGNED NOT NULL,
  UNIQUE KEY uq_vacancy_schedule_slot (vacancy_id, day_of_week, start_minute, end_minute),
  CONSTRAINT fk_vacancy_schedule_vacancy FOREIGN KEY (vacancy_id) REFERENCES vacancies(id) ON DELETE CASCADE,
  CONSTRAINT ck_vacancy_schedule_day CHECK (day_of_week BETWEEN 1 AND 7),
  CONSTRAINT ck_vacancy_schedule_time CHECK (start_minute < end_minute AND end_minute <= 1440)
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

-- One free-text search request; parsed_filters stores validated structured data.
-- user_id refers to user_profiles.id, NOT the string users.id.
CREATE TABLE search_requests (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_id BIGINT NOT NULL,
  prompt_text TEXT NOT NULL,
  parsed_filters JSON NULL,
  status ENUM('pending','parsed','failed') NOT NULL DEFAULT 'pending',
  parser_kind ENUM('ai','rules','manual') NULL,
  model_name VARCHAR(150) NULL,
  error_code VARCHAR(80) NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  parsed_at DATETIME(6) NULL,
  KEY ix_search_requests_user (user_id, created_at, id),
  UNIQUE KEY uq_search_requests_id_user (id, user_id),
  CONSTRAINT fk_search_requests_user FOREIGN KEY (user_id) REFERENCES user_profiles(id) ON DELETE CASCADE,
  CONSTRAINT ck_search_requests_prompt CHECK (CHAR_LENGTH(TRIM(prompt_text)) BETWEEN 1 AND 10000),
  CONSTRAINT ck_search_requests_filters CHECK (parsed_filters IS NULL OR JSON_TYPE(parsed_filters) = 'OBJECT'),
  CONSTRAINT ck_search_requests_state CHECK (
    (status = 'pending' AND parsed_filters IS NULL AND error_code IS NULL AND parsed_at IS NULL)
    OR (status = 'parsed' AND parsed_filters IS NOT NULL AND error_code IS NULL AND parsed_at IS NOT NULL)
    OR (status = 'failed' AND parsed_filters IS NULL AND error_code IS NOT NULL AND parsed_at IS NOT NULL)
  )
) ENGINE=InnoDB;

-- Snapshot of actual DB results, with explanation. A score is a skill match,
-- not a hiring probability. Historical rows may refer to archived vacancies.
CREATE TABLE search_results (
  search_request_id BIGINT NOT NULL,
  vacancy_id BIGINT NOT NULL,
  position SMALLINT UNSIGNED NOT NULL,
  skill_match_percent DECIMAL(5,2) NULL,
  explanation TEXT NULL,
  PRIMARY KEY (search_request_id, vacancy_id),
  UNIQUE KEY uq_search_results_position (search_request_id, position),
  KEY ix_search_results_vacancy (vacancy_id),
  CONSTRAINT fk_search_results_request FOREIGN KEY (search_request_id) REFERENCES search_requests(id) ON DELETE CASCADE,
  CONSTRAINT fk_search_results_vacancy FOREIGN KEY (vacancy_id) REFERENCES vacancies(id),
  CONSTRAINT ck_search_results_position CHECK (position BETWEEN 1 AND 1000),
  CONSTRAINT ck_search_results_score CHECK (skill_match_percent IS NULL OR skill_match_percent BETWEEN 0 AND 100)
) ENGINE=InnoDB;
