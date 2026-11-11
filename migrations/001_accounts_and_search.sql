-- Upgrade ONLY the previous 11-table schema (commit 8d97ae9 or earlier).
-- Do not run on a fresh v2 schema; do not run twice. DDL implicitly commits in MySQL.
-- Existing rows are retained. Legacy account placeholders are BLOCKED and have
-- reserved example.invalid emails and unusable hashes; enroll real credentials
-- through the backend before enabling them. No existing password hashes existed.
USE vacancy_aggregator;
SET time_zone = '+00:00';

ALTER TABLE vacancies MODIFY is_remote BOOLEAN NULL DEFAULT NULL
  COMMENT 'NULL=unknown, 1=remote, 0=onsite';



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


INSERT INTO users (id,email,normalized_email,password_hash,status)
SELECT auth_subject,CONCAT('legacy-',id,'@example.invalid'),
  CONCAT('legacy-',id,'@example.invalid'),'!MIGRATED_NO_PASSWORD_HASH','blocked'
FROM user_profiles;

ALTER TABLE user_profiles ADD CONSTRAINT fk_user_profiles_account
  FOREIGN KEY (auth_subject) REFERENCES users(id) ON DELETE CASCADE;


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
