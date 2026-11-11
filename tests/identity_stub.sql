-- TEST FIXTURE ONLY. NOT an Identity schema and NEVER a deployment script.
-- Models only key/email constraints for SQL integration; no auth/roles/passwords.
-- Real Identity tables/accounts/roles are created by backend EF/UserManager.
USE vacancy_aggregator;
CREATE TABLE AspNetUsers (
  Id VARCHAR(191) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL PRIMARY KEY,
  NormalizedEmail VARCHAR(256) CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_as_ci NULL,
  UNIQUE KEY EmailIndex (NormalizedEmail)
) ENGINE=InnoDB;
INSERT INTO AspNetUsers (Id,NormalizedEmail) VALUES
  ('test-identity-user-1','FIRST@EXAMPLE.INVALID'),
  ('test-identity-user-2','SECOND@EXAMPLE.INVALID');
