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

-- Identity tables are created by backend EF migrations, never by this script.
-- Physical FK to AspNetUsers is attached after preflight (identity/02_link_profile.sql).
CREATE TABLE user_profiles (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  auth_subject VARCHAR(191) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
  display_name VARCHAR(150) NOT NULL,
  city VARCHAR(150) NULL,
  time_zone VARCHAR(80) CHARACTER SET ascii NOT NULL DEFAULT 'Europe/Moscow',
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  UNIQUE KEY uq_user_profiles_subject (auth_subject)
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

