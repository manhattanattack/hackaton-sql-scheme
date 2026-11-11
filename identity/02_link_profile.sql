-- INITIAL SETUP, not an upgrade. Backend creates Identity tables first.
-- No Identity table, password hash, role or token is created by this script.
USE vacancy_aggregator;
DELIMITER $$
DROP PROCEDURE IF EXISTS starter_link_identity_profile$$
CREATE PROCEDURE starter_link_identity_profile()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.TABLES
    WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='AspNetUsers' AND ENGINE='InnoDB'
  ) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Backend must create InnoDB AspNetUsers first';
  END IF;
  IF (SELECT COUNT(*) FROM information_schema.COLUMNS c
    WHERE c.TABLE_SCHEMA=DATABASE()
      AND ((c.TABLE_NAME='AspNetUsers' AND c.COLUMN_NAME='Id')
        OR (c.TABLE_NAME='user_profiles' AND c.COLUMN_NAME='auth_subject'))
      AND c.DATA_TYPE='varchar' AND c.CHARACTER_MAXIMUM_LENGTH=191
      AND c.CHARACTER_SET_NAME='utf8mb4' AND c.COLLATION_NAME='utf8mb4_bin'
      AND c.IS_NULLABLE='NO') <> 2 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Identity Id and auth_subject must both be VARCHAR(191) utf8mb4_bin NOT NULL';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='AspNetUsers'
    GROUP BY INDEX_NAME
    HAVING MAX(NON_UNIQUE)=0 AND COUNT(*)=1
      AND MAX(COLUMN_NAME)='NormalizedEmail' AND MAX(SUB_PART) IS NULL
  ) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Backend must configure a unique full NormalizedEmail index';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='AspNetUsers'
      AND COLUMN_NAME='NormalizedEmail' AND RIGHT(COLLATION_NAME,3)='_ci'
  ) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Use case-insensitive NormalizedEmail collation and Identity normalizer';
  END IF;
  IF EXISTS (SELECT 1 FROM user_profiles p LEFT JOIN AspNetUsers u ON u.Id=p.auth_subject WHERE u.Id IS NULL) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Orphan profiles: backend must create/map Identity accounts before FK';
  END IF;
  IF EXISTS (
    SELECT 1 FROM information_schema.REFERENTIAL_CONSTRAINTS
    WHERE CONSTRAINT_SCHEMA=DATABASE() AND TABLE_NAME='user_profiles'
      AND CONSTRAINT_NAME='fk_user_profiles_identity'
  ) THEN
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.REFERENTIAL_CONSTRAINTS r
      JOIN information_schema.KEY_COLUMN_USAGE k
        ON k.CONSTRAINT_SCHEMA=r.CONSTRAINT_SCHEMA AND k.CONSTRAINT_NAME=r.CONSTRAINT_NAME
        AND k.TABLE_NAME=r.TABLE_NAME
      WHERE r.CONSTRAINT_SCHEMA=DATABASE() AND r.TABLE_NAME='user_profiles'
        AND r.CONSTRAINT_NAME='fk_user_profiles_identity' AND r.DELETE_RULE='RESTRICT'
        AND k.COLUMN_NAME='auth_subject' AND k.REFERENCED_TABLE_SCHEMA=DATABASE()
        AND k.REFERENCED_TABLE_NAME='AspNetUsers' AND k.REFERENCED_COLUMN_NAME='Id'
    ) THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Existing Identity FK differs from required RESTRICT relationship';
    END IF;
  ELSE
    ALTER TABLE user_profiles ADD CONSTRAINT fk_user_profiles_identity
      FOREIGN KEY (auth_subject) REFERENCES AspNetUsers(Id) ON DELETE RESTRICT;
  END IF;
END$$
CALL starter_link_identity_profile()$$
DROP PROCEDURE starter_link_identity_profile$$
DELIMITER ;
