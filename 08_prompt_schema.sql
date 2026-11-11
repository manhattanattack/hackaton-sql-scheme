-- Optional prompt/history tables, separate from Identity setup.
-- Contract: JSON_CONTRACT.md. Execute once on the new business schema.
USE vacancy_aggregator;

-- One free-text search request; parsed_filters stores validated structured data.
-- user_id refers to user_profiles.id, NOT the string AspNetUsers.Id.
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
